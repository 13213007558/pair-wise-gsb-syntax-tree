# frozen_string_literal: true

module SyntaxTree
  # ForwardingChecker analyzes statically resolvable argument-forwarding
  # chains (methods that capture arguments with `*args`, `**kwargs`,
  # `...`, or a bare splat and pass them on to another method defined in the
  # same source) and reports what each forwarding element actually does for a
  # given target Ruby version.
  #
  # It only emits rewrite suggestions where the semantics are provable from
  # the source alone. For example, replacing a `ruby2_keywords`-flagged
  # splat forwarder with explicit `**kwargs` forwarding on Ruby 3+ is a
  # known equivalence, so it is suggested; when a chain goes through dynamic
  # dispatch (`send` with a non-literal name) or a callee that is not
  # defined in the analyzed source, it keeps an explanation instead.
  #
  #   checker = SyntaxTree::ForwardingChecker.new(target_version: "3.0")
  #   report = checker.check(source)
  #   report.entries.each { |entry| puts entry.message }
  #
  class ForwardingChecker
    SEND_METHODS = %w[send public_send __send__].freeze

    # A single source edit: replace the character range
    # [start_char...end_char] with +replacement+.
    Edit = Struct.new(:start_char, :end_char, :replacement)

    # A provable rewrite, expressed as a list of source edits that can be
    # applied to the original source with Suggestion#apply.
    class Suggestion
      attr_reader :message, :edits

      def initialize(message:, edits:)
        @message = message
        @edits = edits
      end

      # Applies a set of edits to +source+ in one pass. Edits are applied
      # from the end of the source backwards so earlier offsets stay valid.
      def self.rewrite(source, edits)
        edits
          .sort_by { |edit| -edit.start_char }
          .reduce(source.dup) do |result, edit|
            result[edit.start_char...edit.end_char] = edit.replacement
            result
          end
      end

      def apply(source)
        Suggestion.rewrite(source, edits)
      end
    end

    # One finding about a forwarding chain. +kind+ is one of:
    #
    # [:role]         explains what a forwarding element does in the chain
    # [:issue]        semantics change (or rely on deprecated behavior) on
    #                 the target Ruby version
    # [:unresolvable] the chain cannot be fully resolved statically, so only
    #                 an explanation is kept and no rewrite is suggested
    Entry =
      Struct.new(
        :kind,
        :element, # "*args" | "**kwargs" | "..." | "ruby2_keywords" | "send" | ...
        :method_name,
        :line,
        :message,
        :suggestion,
        keyword_init: true
      )

    # The result of analyzing one source string.
    class Report
      attr_reader :entries

      def initialize(entries)
        @entries = entries
      end

      def roles
        entries.select { |entry| entry.kind == :role }
      end

      def issues
        entries.select { |entry| entry.kind == :issue }
      end

      def unresolvable
        entries.select { |entry| entry.kind == :unresolvable }
      end

      def suggestions
        entries.filter_map(&:suggestion)
      end

      # Applies every suggestion in the report to +source+ at once.
      def apply_suggestions(source)
        Suggestion.rewrite(source, suggestions.flat_map(&:edits))
      end
    end

    # A method definition discovered in the source.
    class MethodInfo
      attr_reader :name,
                  :qname,
                  :namespace,
                  :node,
                  :params,
                  :rest,
                  :keyword_rest,
                  :keywords,
                  :block,
                  :line

      # +ruby2_keywords_node+ is the Command/CallNode that applied the flag,
      # or the DefNode for the inline `ruby2_keywords def ...` form.
      attr_accessor :ruby2_keywords, :ruby2_keywords_mark, :ruby2_keywords_node

      def initialize(node:, namespace:, singleton:)
        @node = node
        @namespace = namespace
        @name = node.name.value
        @singleton = singleton
        @qname = (namespace + [singleton ? "self.#{@name}" : @name]).join("::")
        @line = node.location.start_line
        @ruby2_keywords = false
        @ruby2_keywords_mark = nil
        @ruby2_keywords_node = nil

        params = node.params
        params = params.contents if params.is_a?(Paren)
        @params = params

        @rest = summarize_rest(params&.rest)
        @keyword_rest = summarize_keyword_rest(params&.keyword_rest)
        @keywords =
          if params
            params.keywords.map { |label, _| label.value.chomp(":") }
          else
            []
          end
        @block = summarize_block(params&.block)
      end

      def singleton?
        @singleton
      end

      def args_forward?
        rest == :forward || keyword_rest == :forward
      end

      def captures_positionals?
        args_forward? || !rest.nil?
      end

      def captures_keywords?
        args_forward? || keywords.any? ||
          (!keyword_rest.nil? && keyword_rest != :nil)
      end

      # Whether callers can pass keywords that this method keeps separated
      # from the positional arguments.
      def accepts_keywords?
        captures_keywords?
      end

      # Whether keyword arguments passed to this method are rejected
      # outright (`**nil`).
      def rejects_keywords?
        keyword_rest == :nil
      end

      def rest_label
        case rest
        when :forward
          "..."
        when :anonymous
          "*"
        when nil
          nil
        else
          "*#{rest}"
        end
      end

      def keyword_rest_label
        case keyword_rest
        when :anonymous
          "**"
        when :nil
          "**nil"
        when nil
          nil
        else
          "**#{keyword_rest}"
        end
      end

      private

      def summarize_rest(rest)
        case rest
        when nil
          nil
        when ArgsForward
          :forward
        when RestParam
          rest.name ? rest.name.value : :anonymous
        else
          nil # ExcessedComma and friends: no captured splat
        end
      end

      def summarize_keyword_rest(keyword_rest)
        case keyword_rest
        when nil
          nil
        when :nil
          :nil
        when ArgsForward
          :forward
        when KwRestParam
          keyword_rest.name ? keyword_rest.name.value : :anonymous
        end
      end

      def summarize_block(block)
        case block
        when nil
          nil
        when BlockArg
          block.name ? block.name.value : :anonymous
        end
      end
    end

    # A call site inside a method body that forwards some of the enclosing
    # method's captured arguments.
    CallSite =
      Struct.new(
        :node,
        :receiver_kind, # :internal | :external
        :callee, # String or nil when dynamic
        :via_send, # true when dispatched through send/public_send/__send__
        :dynamic, # true when the callee name is not statically known
        :forwarded, # subset of [:positionals, :keywords, :block, :all]
        :arg_star, # the ArgStar node forwarding positionals, if any
        :line,
        keyword_init: true
      )

    # First pass: collect method definitions and ruby2_keywords marks.
    class Collector < Visitor
      attr_reader :methods, :r2k_marks

      def initialize
        @namespace = []
        @methods = {}
        # Each mark is [namespace, name_or_def_node, command_node].
        @r2k_marks = []
      end

      def visit_class(node)
        with_namespace(const_name(node.constant)) { super }
      end

      def visit_module(node)
        with_namespace(const_name(node.constant)) { super }
      end

      def visit_def(node)
        info =
          MethodInfo.new(
            node: node,
            namespace: @namespace.dup,
            singleton: !node.target.nil?
          )
        @methods[info.qname] = info
        super
      end

      def visit_command(node)
        record_r2k(node, node.message, node.arguments)
        super
      end

      def visit_call(node)
        if node.receiver.nil?
          record_r2k(node, node.message, node.arguments&.arguments)
        end
        super
      end

      private

      def with_namespace(name)
        @namespace.push(name || "(anonymous)")
        yield
      ensure
        @namespace.pop
      end

      def const_name(node)
        case node
        when ConstRef
          node.constant.value
        when ConstPathRef
          "#{const_name(node.parent)}::#{const_name(node.constant)}"
        when TopConstRef
          "::#{const_name(node.constant)}"
        when VarRef
          node.value.respond_to?(:value) ? node.value.value : nil
        end
      end

      def record_r2k(command, message, args)
        return unless message.is_a?(Ident) && message.value == "ruby2_keywords"
        return unless args.is_a?(Args)

        args.parts.each do |part|
          case part
          when SymbolLiteral
            @r2k_marks << [@namespace.dup, part.value.value, command]
          when DefNode
            @r2k_marks << [@namespace.dup, part, command]
          end
        end
      end
    end

    # Second pass (per method): find call sites that forward the method's
    # captured arguments.
    class CallSiteVisitor < Visitor
      attr_reader :sites

      def initialize(method)
        @method = method
        @sites = []
      end

      # Nested method definitions capture their own arguments; calls inside
      # them are not forwarding on behalf of the outer method.
      def visit_def(node)
      end

      def visit_call(node)
        record(node.receiver, node.message, node.arguments, node)
        super
      end

      def visit_command(node)
        record(nil, node.message, node.arguments, node)
        super
      end

      def visit_command_call(node)
        record(node.receiver, node.message, node.arguments, node)
        super
      end

      private

      def record(receiver, message, arguments, node)
        return unless message.is_a?(Ident)

        name = message.value
        receiver_kind = internal_receiver?(receiver) ? :internal : :external
        via_send = receiver_kind == :internal && SEND_METHODS.include?(name)

        args = arguments
        args = args.arguments if args.is_a?(ArgParen)

        callee = name
        dynamic = false
        parts = args.is_a?(Args) ? args.parts : []

        if via_send
          first, *rest_parts = parts
          static = static_symbol(first)
          if static
            callee = static
          else
            callee = nil
            dynamic = true
          end
          parts = rest_parts
        end

        forwarded, arg_star = detect_forwarded(args, parts)
        return if forwarded.empty?

        @sites << CallSite.new(
          node: node,
          receiver_kind: receiver_kind,
          callee: callee,
          via_send: via_send,
          dynamic: dynamic,
          forwarded: forwarded,
          arg_star: arg_star,
          line: node.location.start_line
        )
      end

      def internal_receiver?(receiver)
        receiver.nil? ||
          (
            receiver.is_a?(VarRef) && receiver.value.is_a?(Kw) &&
              receiver.value.value == "self"
          )
      end

      def static_symbol(node)
        case node
        when SymbolLiteral
          node.value.value
        when DynaSymbol
          if node.parts.all? { |part| part.is_a?(TStringContent) }
            node.parts.map(&:value).join
          end
        end
      end

      def detect_forwarded(args, parts)
        return [:all], nil if args.is_a?(ArgsForward)

        forwarded = []
        arg_star = nil

        parts.each do |part|
          case part
          when ArgStar
            if splat_matches?(part.value, @method.rest)
              forwarded << :positionals
              arg_star = part
            end
          when ArgBlock
            forwarded << :block if block_matches?(part.value)
          when BareAssocHash, HashLiteral
            part.assocs.each do |assoc|
              if assoc.is_a?(AssocSplat) &&
                   splat_matches?(assoc.value, @method.keyword_rest)
                forwarded << :keywords
              end
            end
          end
        end

        [forwarded.uniq, arg_star]
      end

      def splat_matches?(value, captured)
        case captured
        when nil, :forward, :nil
          false
        when :anonymous
          value.nil?
        else
          value.is_a?(VarRef) && value.value.is_a?(Ident) &&
            value.value.value == captured
        end
      end

      def block_matches?(value)
        case @method.block
        when nil
          false
        when :anonymous
          value.nil?
        else
          value.is_a?(VarRef) && value.value.is_a?(Ident) &&
            value.value.value == @method.block
        end
      end
    end

    attr_reader :target_version

    def initialize(target_version:)
      @target_version = Gem::Version.new(target_version.to_s)
    end

    def check(source)
      @source = source
      program = SyntaxTree.parse(source)
      collector = Collector.new
      collector.visit(program)
      apply_r2k_marks(collector)
      @methods = collector.methods
      @sites = {}
      @keyword_closure = {}

      @methods.each_value do |method|
        visitor = CallSiteVisitor.new(method)
        visitor.visit(method.node.bodystmt)
        @sites[method.qname] = visitor.sites
      end

      entries = []
      @methods.each_value do |method|
        sites = @sites[method.qname]
        next if sites.empty? && !method.ruby2_keywords

        entries.concat(role_entries(method))
        sites.each { |site| entries.concat(analyze_site(method, site, sites)) }
        entries.concat(r2k_entries(method, sites))
      end

      Report.new(entries.sort_by(&:line))
    ensure
      @source = @methods = @sites = @keyword_closure = nil
    end

    private

    def ruby3_target?
      target_version >= Gem::Version.new("3.0")
    end

    def ruby27_target?
      target_version >= Gem::Version.new("2.7")
    end

    def apply_r2k_marks(collector)
      collector.r2k_marks.each do |namespace, mark, command|
        name = mark.is_a?(DefNode) ? mark.name.value : mark
        info = collector.methods[(namespace + [name]).join("::")]
        next unless info

        info.ruby2_keywords = true
        info.ruby2_keywords_mark = mark
        info.ruby2_keywords_node = command
      end
    end

    def role_entries(method)
      entries = []

      if method.args_forward?
        entries << Entry.new(
          kind: :role,
          element: "...",
          method_name: method.qname,
          line: method.line,
          message:
            "#{method.qname}: `...` captures and forwards all arguments " +
              "(positionals, keywords, and the block) unchanged."
        )
        return entries
      end

      if method.rest
        detail =
          if method.captures_keywords?
            "keyword arguments are captured separately."
          elsif method.ruby2_keywords
            "a final keyword Hash is kept flagged by `ruby2_keywords` so " +
              "the callee can re-split it into keywords."
          else
            "keyword arguments from callers are silently absorbed into " +
              "the final positional Hash."
          end
        entries << Entry.new(
          kind: :role,
          element: method.rest_label,
          method_name: method.qname,
          line: method.line,
          message:
            "#{method.qname}: `#{method.rest_label}` captures positional " +
              "arguments; #{detail}"
        )
      end

      if method.keyword_rest && method.keyword_rest != :nil
        entries << Entry.new(
          kind: :role,
          element: method.keyword_rest_label,
          method_name: method.qname,
          line: method.line,
          message:
            "#{method.qname}: `#{method.keyword_rest_label}` captures " +
              "keyword arguments and keeps them separated from positionals."
        )
      elsif method.rejects_keywords?
        entries << Entry.new(
          kind: :role,
          element: "**nil",
          method_name: method.qname,
          line: method.line,
          message: "#{method.qname}: `**nil` rejects keyword arguments."
        )
      end

      if method.ruby2_keywords
        entries << Entry.new(
          kind: :role,
          element: "ruby2_keywords",
          method_name: method.qname,
          line: method.line,
          message:
            "#{method.qname}: `ruby2_keywords` flags the final positional " +
              "Hash so a keyword-aware callee re-splits it into keywords."
        )
      end

      entries
    end

    # Whether keyword arguments passed to +method+ can still arrive at a
    # keyword-aware callee somewhere down the forwarding chain (computed
    # transitively over statically resolvable hops, with a cycle guard).
    def effectively_accepts_keywords?(method)
      return true if method.accepts_keywords?
      if @keyword_closure.key?(method.qname)
        return @keyword_closure[method.qname]
      end

      @keyword_closure[method.qname] = false # cycle guard
      @keyword_closure[method.qname] = @sites[method.qname].any? do |site|
        next false if site.dynamic || site.receiver_kind == :external
        unless site.forwarded.include?(:positionals) ||
                 site.forwarded.include?(:all)
          next false
        end

        callee = resolve_callee(method, site.callee)
        callee && effectively_accepts_keywords?(callee)
      end
    end

    def analyze_site(method, site, all_sites)
      if site.dynamic
        return [
          Entry.new(
            kind: :unresolvable,
            element: "send",
            method_name: method.qname,
            line: site.line,
            message:
              "#{method.qname}: forwards #{forwarded_desc(site)} through " +
                "dynamic dispatch (`send` with a non-literal name); the " +
                "callee cannot be determined statically, so no rewrite is " +
                "suggested."
          )
        ]
      end

      if site.receiver_kind == :external
        return [
          Entry.new(
            kind: :unresolvable,
            element: method.rest_label || "...",
            method_name: method.qname,
            line: site.line,
            message:
              "#{method.qname}: forwards #{forwarded_desc(site)} to " +
                "`#{site.callee}` on an explicit receiver; the callee is " +
                "not resolvable within the analyzed source, so no rewrite " +
                "is suggested."
          )
        ]
      end

      callee = resolve_callee(method, site.callee)
      unless callee
        return [
          Entry.new(
            kind: :unresolvable,
            element: method.rest_label || "...",
            method_name: method.qname,
            line: site.line,
            message:
              "#{method.qname}: callee `#{site.callee}` is not defined in " +
                "the analyzed source; keyword separation across this hop " +
                "cannot be verified, so no rewrite is suggested."
          )
        ]
      end

      return [] if site.forwarded.include?(:all)
      return [] unless site.forwarded.include?(:positionals)
      return [] if site.forwarded.include?(:keywords)
      return [] unless effectively_accepts_keywords?(callee)
      return [] if method.ruby2_keywords

      if ruby3_target?
        suggestion = explicit_kwargs_suggestion(method, all_sites)
        message =
          if callee.accepts_keywords?
            "#{method.qname}: callers' keyword arguments are absorbed into " +
              "\`#{method.rest_label}\` and forwarded to " +
              "\`#{callee.qname}\` as a positional Hash; on Ruby >= 3.0 " +
              "\`#{callee.name}\` will not receive them as keywords."
          else
            "#{method.qname}: callers' keyword arguments are absorbed into " +
              "\`#{method.rest_label}\` and forwarded as a positional " +
              "Hash; the chain through \`#{callee.qname}\` ultimately " +
              "reaches keyword-aware methods, so keywords are lost at " +
              "this hop on Ruby >= 3.0."
          end
        message +=
          " The chain cannot be rewritten automatically because not every " +
            "hop is statically provable." unless suggestion
        return [
          Entry.new(
            kind: :issue,
            element: method.rest_label,
            method_name: method.qname,
            line: site.line,
            message: message,
            suggestion: suggestion
          )
        ]
      elsif ruby27_target?
        return [
          Entry.new(
            kind: :issue,
            element: method.rest_label,
            method_name: method.qname,
            line: site.line,
            message:
              "#{method.qname}: forwarding to `#{callee.qname}` relies on " +
                "the deprecated automatic Hash-to-keyword conversion; on " +
                "Ruby 2.7 prefer explicit `**kwargs` forwarding (or " +
                "`ruby2_keywords` when Ruby 2.6 must keep working).",
            suggestion: explicit_kwargs_suggestion(method, all_sites)
          )
        ]
      end

      []
    end

    def r2k_entries(method, sites)
      return [] unless method.ruby2_keywords

      unless method.rest
        return [
          Entry.new(
            kind: :role,
            element: "ruby2_keywords",
            method_name: method.qname,
            line: method.line,
            message:
              "#{method.qname}: `ruby2_keywords` has no effect because " +
                "the method has no `*args` rest parameter."
          )
        ]
      end

      return [] unless ruby3_target?

      unresolvable_site =
        sites.find do |site|
          site.dynamic || site.receiver_kind == :external ||
            !resolve_callee(method, site.callee)
        end

      if sites.empty? || unresolvable_site
        return [
          Entry.new(
            kind: :unresolvable,
            element: "ruby2_keywords",
            method_name: method.qname,
            line: method.line,
            message:
              "#{method.qname}: `ruby2_keywords` is still load-bearing; " +
                "the chain contains dynamic or unknown hops, so explicit " +
                "forwarding cannot be proven equivalent. Keep it."
          )
        ]
      end

      # Every hop is statically resolvable. On Ruby 3+, explicit keyword
      # forwarding is a proven equivalence for ruby2_keywords delegation.
      edits = []
      edits.concat(kwargs_edits(method, sites)) unless method.captures_keywords?
      edits.concat(r2k_removal_edits(method))

      [
        Entry.new(
          kind: :role,
          element: "ruby2_keywords",
          method_name: method.qname,
          line: method.line,
          message:
            "#{method.qname}: every forwarding hop is statically " +
              "resolvable; on Ruby >= 3.0 explicit `**kwargs` forwarding " +
              "is equivalent and `ruby2_keywords` can be dropped.",
          suggestion:
            Suggestion.new(
              message:
                "Replace `ruby2_keywords` delegation with explicit keyword " +
                  "forwarding in #{method.qname}.",
              edits: edits
            )
        )
      ]
    end

    def resolve_callee(method, name)
      return nil unless name

      @methods[(method.namespace + [name]).join("::")] ||
        @methods[(method.namespace + ["self.#{name}"]).join("::")]
    end

    def forwarded_desc(site)
      site
        .forwarded
        .map do |part|
          case part
          when :all
            "all arguments"
          when :positionals
            "positional arguments"
          when :keywords
            "keyword arguments"
          when :block
            "the block"
          end
        end
        .join(", ")
    end

    # Builds a suggestion that adds explicit `**kwargs` capture and
    # forwarding to +method+, or nil when the rewrite cannot be proven safe
    # (dynamic/unknown hops, or a callee that rejects keywords with `**nil`).
    def explicit_kwargs_suggestion(method, sites)
      return nil if method.captures_keywords?

      forwarding_sites =
        sites.select do |site|
          site.forwarded.include?(:positionals) &&
            !site.forwarded.include?(:keywords)
        end

      provable =
        forwarding_sites.all? do |site|
          next false if site.dynamic || site.receiver_kind == :external

          callee = resolve_callee(method, site.callee)
          callee && !callee.rejects_keywords?
        end
      return nil unless provable

      Suggestion.new(
        message:
          "Forward keywords explicitly in #{method.qname} with " +
            "`#{method.rest_label}, **kwargs`.",
        edits: kwargs_edits(method, forwarding_sites)
      )
    end

    # Source edits that add `**kwargs` to the method's parameter list and
    # to every call site that forwards its splat.
    def kwargs_edits(method, sites)
      params = method.params
      rest = params&.rest
      return [] unless rest.is_a?(RestParam)

      edits = []
      anonymous = rest.name.nil?

      if anonymous
        edits << Edit.new(
          rest.location.start_char,
          rest.location.end_char,
          "*args, **kwargs"
        )
      else
        edits << Edit.new(
          rest.location.end_char,
          rest.location.end_char,
          ", **kwargs"
        )
      end

      sites.each do |site|
        star = site.arg_star
        next unless star

        if anonymous
          edits << Edit.new(
            star.location.start_char,
            star.location.end_char,
            "*args, **kwargs"
          )
        else
          edits << Edit.new(
            star.location.end_char,
            star.location.end_char,
            ", **kwargs"
          )
        end
      end

      edits
    end

    # Source edits that remove the `ruby2_keywords` mark for +method+.
    def r2k_removal_edits(method)
      command = method.ruby2_keywords_node
      mark = method.ruby2_keywords_mark
      return [] unless command

      if mark.is_a?(DefNode)
        # Inline form: `ruby2_keywords def name(...) ... end`. Strip the
        # `ruby2_keywords` prefix, keeping the def itself.
        [Edit.new(command.location.start_char, mark.location.start_char, "")]
      else
        # Symbol form: `ruby2_keywords :name`. Remove the whole line.
        start_char = command.location.start_char
        end_char = command.location.end_char
        end_char += 1 if @source[end_char] == "\n"
        [Edit.new(start_char, end_char, "")]
      end
    end
  end
end
