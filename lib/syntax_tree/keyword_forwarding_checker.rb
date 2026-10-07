# frozen_string_literal: true

module SyntaxTree
  class KeywordForwardingChecker
    STRICT_VERSION = Formatter::SemanticVersion.new("3.0.0")

    DYNAMIC_DISPATCH = %i[__send__ send public_send].freeze

    Patch =
      Struct.new(
        :start_char,
        :end_char,
        :replacement,
        :reason,
        keyword_init: true
      )
    Finding =
      Struct.new(
        :status,
        :message,
        :explanation,
        :location,
        :method,
        :callee,
        :callee_status,
        :roles,
        :chain,
        :patches,
        keyword_init: true
      )

    MethodInfo =
      Struct.new(
        :node,
        :scope,
        :name,
        :params,
        :rest,
        :keyword_rest,
        :block,
        :ruby2_keywords,
        :singleton,
        :edges,
        keyword_init: true
      )

    Edge =
      Struct.new(
        :node,
        :method,
        :name,
        :scope,
        :receiver,
        :dispatch,
        :channels,
        :roles,
        keyword_init: true
      )

    attr_reader :target_ruby_version

    def self.check(source, target_ruby_version: RUBY_VERSION)
      new(target_ruby_version: target_ruby_version).check(source)
    end

    def self.rewrite(source, target_ruby_version: RUBY_VERSION)
      checker = new(target_ruby_version: target_ruby_version)
      checker.rewrite(source)
    end

    def initialize(target_ruby_version: RUBY_VERSION)
      @target_ruby_version =
        if target_ruby_version.is_a?(Gem::Version)
          target_ruby_version
        else
          Formatter::SemanticVersion.new(target_ruby_version.to_s)
        end
    end

    def check(source)
      program = SyntaxTree.parse(source)
      collector = Collector.new(program)
      Analyzer.new(collector, self).analyze
    end

    def rewrite(source)
      patches =
        check(source)
          .flat_map(&:patches)
          .uniq do |patch|
            [patch.start_char, patch.end_char, patch.replacement]
          end
      return source if patches.empty?

      patches
        .sort_by { |patch| [-patch.start_char, -patch.end_char] }
        .inject(source) do |current, patch|
          rewritten = current.dup
          rewritten[patch.start_char...patch.end_char] = patch.replacement
          rewritten
        end
    end

    def strict_keywords?
      target_ruby_version >= STRICT_VERSION
    end

    class Collector
      attr_reader :methods, :edges

      def initialize(program)
        @methods = {}
        @edges = []
        @markers = Hash.new { |hash, key| hash[key] = [] }
        @duplicates = []

        collect_scope(program.statements, [], false, false)
        apply_markers
        @methods.each_value do |method|
          find_edges(
            method.node.bodystmt,
            method,
            method.scope,
            method.singleton ? :self : false
          )
        end
      end

      private

      def collect_scope(node, scope, singleton, skip_class_bodies)
        each_direct(node) do |child|
          case child
          when DefNode
            register_definition(child, scope, singleton) unless child.target
          when Command
            if ruby2_keywords_command?(child)
              register_marker(child, scope, singleton)
            else
              collect_scope(child, scope, singleton, true)
            end
          when CallNode
            collect_scope(child, scope, singleton, true)
          when ClassDeclaration, ModuleDeclaration
            unless skip_class_bodies
              constant = constant_name(child.constant)
              child_scope = constant ? scope + [constant] : scope
              collect_scope(child.bodystmt, child_scope, false, false)
            end
          when SClass
            unless skip_class_bodies
              collect_scope(
                child.bodystmt,
                scope,
                self_target?(child.target) ? :self : :other,
                false
              )
            end
          else
            collect_scope(child, scope, singleton, skip_class_bodies)
          end
        end
      end

      def register_definition(node, scope, singleton)
        key = method_key(scope, singleton, node.name.value)

        if @methods.key?(key)
          @duplicates << key
          return
        end

        params = unwrap_params(node.params)
        info =
          MethodInfo.new(
            node: node,
            scope: scope,
            name: node.name.value,
            params: params,
            rest: parameter_name(params&.rest),
            keyword_rest: keyword_rest_info(params),
            block: parameter_name(params&.block),
            ruby2_keywords: false,
            singleton: singleton == :self,
            edges: []
          )

        @methods[key] = info

        if body_pragma?(node)
          marker_key = marker_key(scope, singleton)
          unless @markers[marker_key].include?(node.name.value)
            @markers[marker_key] << node.name.value
          end
        end
      end

      def register_marker(command, scope, singleton)
        marker_key = marker_key(scope, singleton)

        command
          .arguments
          .parts
          .grep(DefNode)
          .each do |definition|
            next if definition.target

            register_definition(definition, scope, singleton)
            add_marker(marker_key, definition.name.value)
          end

        command
          .arguments
          .parts
          .grep(SymbolLiteral)
          .each do |symbol|
            ident = symbol.value
            add_marker(marker_key, ident.value) if ident.is_a?(Ident)
          end
      end

      def add_marker(key, name)
        @markers[key] << name unless @markers[key].include?(name)
      end

      def find_edges(node, method, scope, singleton)
        each_direct(node) do |child|
          case child
          when DefNode, ClassDeclaration, ModuleDeclaration, SClass, BlockNode,
               MethodAddBlock
            next
          when CallNode, Command, CommandCall
            register_edge(child, method, scope, singleton)
          end

          find_edges(child, method, scope, singleton)
        end
      end

      def register_edge(node, method, scope, singleton)
        parts = argument_parts(node.arguments)
        edge =
          Edge.new(
            node: node,
            method: method,
            name: message_name(node.message),
            scope: scope,
            receiver:
              receiver_name(node.respond_to?(:receiver) ? node.receiver : nil),
            dispatch: dispatch_for(node, scope, singleton),
            channels: channels_for(parts),
            roles: roles_for(parts, method)
          )

        @edges << edge
        method.edges << edge
      end

      def dispatch_for(node, scope, singleton)
        name = message_name(node.message)
        return { kind: :unknown, name: nil } unless name

        if DYNAMIC_DISPATCH.include?(name.to_sym)
          return { kind: :dynamic_dispatch, name: name }
        end

        receiver = node.respond_to?(:receiver) ? node.receiver : nil

        if receiver.nil? || self_receiver?(receiver)
          key = resolve_method(scope, singleton, name)
          if key && !@duplicates.include?(key)
            { kind: :static, name: name, target: @methods[key] }
          else
            { kind: :unknown_callee, name: name }
          end
        else
          { kind: :receiver, name: name }
        end
      end

      def resolve_method(scope, singleton, name)
        scopes =
          if singleton == :self
            [scope]
          else
            scope.length.downto(0).map { |count| scope.first(count) }
          end

        scopes.each do |candidate_scope|
          key = method_key(candidate_scope, false, name)
          return key if @methods.key?(key)
        end

        nil
      end

      def argument_parts(arguments)
        case arguments
        when Args
          arguments.parts
        when ArgParen
          case arguments.arguments
          when Args
            arguments.arguments.parts
          when ArgsForward
            [arguments.arguments]
          else
            []
          end
        else
          []
        end
      end

      def channels_for(parts)
        parts.flat_map do |part|
          case part
          when ArgsForward
            [:forward]
          when ArgStar
            [:positional_splat]
          when ArgBlock
            [:block_splat]
          when BareAssocHash
            part.assocs.grep(AssocSplat).map { :keyword_splat }
          else
            []
          end
        end
      end

      def roles_for(parts, owner_method)
        roles = Hash.new { |hash, key| hash[key] = [] }

        parts.each do |part|
          case part
          when ArgsForward
            roles["..."] << "forwards positional, keyword, and block arguments"
          when ArgStar
            name = expression_name(part.value)
            roles["*#{name || "<anonymous>"}"] << positional_splat_role(
              name,
              owner_method
            )
          when ArgBlock
            name = expression_name(part.value)
            roles["&#{name || "<anonymous>"}"] << "forwards the block argument"
          when BareAssocHash
            part
              .assocs
              .grep(AssocSplat)
              .each do |assoc|
                name = expression_name(assoc.value)
                roles["**#{name || "<anonymous>"}"] << keyword_splat_role(
                  name,
                  owner_method
                )
              end
          end
        end

        if owner_method&.keyword_rest&.dig(:kind) == :keywords &&
             !roles.keys.any? { |key| key.start_with?("**") }
          name = owner_method.keyword_rest[:name] || "<anonymous>"
          roles[
            "**#{name}"
          ] << "captures keyword arguments but this call does not forward them"
        end

        roles
      end

      def positional_splat_role(name, owner_method)
        method = variable_method(name, owner_method)
        return "forwards unknown positional values" unless method

        if method.ruby2_keywords && markable?(method)
          "forwards positional values and preserves the ruby2_keywords marker"
        elsif method.keyword_rest
          "forwards only positional values; keyword arguments stay in **#{method.keyword_rest[:name]}"
        else
          "forwards positional values; a keyword hash is not converted back to keywords"
        end
      end

      def keyword_splat_role(name, owner_method)
        method = variable_method(name, owner_method)
        return "forwards unknown keyword values" unless method

        "forwards keyword arguments captured in **#{method.keyword_rest&.dig(:name) || name}"
      end

      def variable_method(name, owner_method)
        return owner_method if owner_method_variable?(name, owner_method)

        method_named(name)
      end

      def owner_method_variable?(name, owner_method)
        name &&
          (
            owner_method&.rest == name ||
              owner_method&.keyword_rest&.dig(:name) == name ||
              owner_method&.block == name
          )
      end

      def method_named(name)
        return nil unless name

        @methods.values.detect do |method|
          method.rest == name || method.keyword_rest&.dig(:name) == name ||
            method.block == name
        end
      end

      def apply_markers
        @markers.each do |(scope, kind), names|
          names.each do |name|
            method = @methods[[[scope, kind], name.to_sym]]
            method.ruby2_keywords = true if method && markable?(method)
          end
        end
      end

      def markable?(method)
        method.params && method.rest && !method.keyword_rest &&
          method.params.posts.empty?
      end

      def each_direct(node, &block)
        return unless node

        children =
          case node
          when Program
            [node.statements]
          when Statements
            node.body
          when BodyStmt
            [node.statements]
          else
            node.respond_to?(:child_nodes) ? node.child_nodes.compact : []
          end

        children.each(&block)
      end

      def body_pragma?(node)
        statements(node.bodystmt).any? do |statement|
          statement.is_a?(VCall) && statement.value.is_a?(Ident) &&
            statement.value.value == "ruby2_keywords"
        end
      end

      def statements(node)
        node.is_a?(BodyStmt) ? node.statements.body : []
      end

      def ruby2_keywords_command?(node)
        node.message.value == "ruby2_keywords"
      end

      def marker_key(scope, singleton)
        [scope, singleton == :self ? :self : :instance]
      end

      def method_key(scope, singleton, name)
        kind = singleton == :self ? :self : :instance
        [[scope, kind], name.to_sym]
      end

      def unwrap_params(params)
        params.is_a?(Paren) ? params.contents : params
      end

      def keyword_rest_info(params)
        return nil unless params

        case params.keyword_rest
        when KwRestParam
          {
            kind: :keywords,
            name: params.keyword_rest.name&.value,
            anonymous: params.keyword_rest.name.nil?
          }
        when ArgsForward
          { kind: :forward, name: nil, anonymous: true }
        when :nil
          { kind: :nil, name: nil, anonymous: true }
        end
      end

      def parameter_name(node)
        node&.name&.value
      end

      def constant_name(node)
        case node
        when ConstRef, TopConstRef
          node.constant.value
        end
      end

      def self_target?(node)
        node.is_a?(VarRef) && node.value.is_a?(Kw) && node.value.value == "self"
      end

      def self_receiver?(node)
        self_target?(node)
      end

      def receiver_name(node)
        expression_name(node)
      end

      def message_name(message)
        case message
        when Ident, Const, Backtick, Kw
          message.value
        when Symbol
          message == :call ? nil : message.to_s
        end
      end

      def expression_name(node)
        case node
        when VarRef, VCall
          expression_name(node.value)
        when Ident, Const, Kw
          node.value
        end
      end
    end

    class Analyzer
      def initialize(collector, checker)
        @collector = collector
        @checker = checker
      end

      def analyze
        @collector.edges.flat_map { |edge| findings_for(edge) }
      end

      private

      def findings_for(edge)
        return [] unless forwarding_edge?(edge)

        case edge.dispatch[:kind]
        when :dynamic_dispatch
          [dynamic_dispatch_finding(edge)]
        when :receiver, :unknown_callee
          [local_keyword_patch_finding(edge) || unknown_callee_finding(edge)]
        when :static
          static_findings(edge)
        else
          []
        end
      end

      def forwarding_edge?(edge)
        edge.channels.any?
      end

      def static_findings(edge)
        findings = []

        if edge.method.keyword_rest&.dig(:kind) == :keywords &&
             (
               edge.channels.include?(:keyword_splat) ||
                 edge.channels.include?(:forward) ||
                 directly_accepts_keywords?(edge.dispatch[:target])
             )
          findings << keywords_finding(edge)
        end

        if edge.method.keyword_rest&.dig(:kind) == :forward &&
             edge.channels.include?(:forward)
          findings << forwarded_finding(edge)
        end

        if positional_legacy_edge?(edge) && !edge.method.keyword_rest
          findings << legacy_finding(edge)
        end

        findings.compact
      end

      def local_keyword_patch_finding(edge)
        return nil unless edge.method.keyword_rest&.dig(:kind) == :keywords
        return nil if edge.channels.include?(:keyword_splat)
        return nil unless edge.method.keyword_rest[:name]

        patches = call_keyword_patches(edge, edge.method.keyword_rest[:name])
        return nil unless patches.any? && patchable_call?(edge)

        build_finding(
          edge: edge,
          status: :keyword_arguments_locally_added,
          message:
            "**#{edge.method.keyword_rest[:name]} can be forwarded to #{edge.name}",
          explanation:
            "The local call site can include the captured keyword arguments, but the " \
              "callee chain is not statically resolved, so final arrival is not proven.",
          result: {
            chain: [edge]
          },
          patches: patches
        )
      end

      def keywords_finding(edge)
        name = edge.method.keyword_rest[:name]

        if edge.channels.include?(:keyword_splat) ||
             edge.channels.include?(:forward)
          result = trace_keywords(edge, [edge])
          return dropped_finding(edge, result) unless result[:arrives]

          safe_finding(
            edge,
            result,
            "keyword arguments are forwarded through **#{name || "..."}"
          )
        elsif directly_accepts_keywords?(edge.dispatch[:target])
          patches =
            call_keyword_patches(edge, name).select do |patch|
              patchable_call?(edge)
            end
          dropped_finding(
            edge,
            {
              arrives: false,
              chain: [edge],
              reason: :missing_keyword_splat,
              patches: patches
            }
          )
        end
      end

      def forwarded_finding(edge)
        target = edge.dispatch[:target]

        if directly_accepts_keywords?(target)
          safe_finding(
            edge,
            { chain: [edge], arrives: true },
            "... forwards positional, keyword, and block arguments"
          )
        elsif forwarding_target?(target)
          next_edge =
            target.edges.detect do |candidate|
              candidate.channels.include?(:forward)
            end
          if next_edge
            result = trace_forward(next_edge, [edge, next_edge])
            return dropped_finding(edge, result) unless result[:arrives]
          end

          safe_finding(
            edge,
            { chain: [edge], arrives: true },
            "... forwards positional, keyword, and block arguments"
          )
        else
          incompatible_finding(
            edge,
            "... cannot be passed to a method that does not accept forwarding arguments"
          )
        end
      end

      def legacy_finding(edge)
        marks = initial_legacy_marks(edge)
        active =
          edge.method.ruby2_keywords || marks.any? || !@checker.strict_keywords?
        result = trace_legacy(edge, [edge], marks, active)

        if result[:arrives]
          if (result[:patches] || []).any?
            return(
              dropped_finding(
                edge,
                result.merge(reason: :ruby2_keywords_chain_broken)
              )
            )
          end

          status =
            (
              if result[:implicit_keywords]
                :implicit_keyword_conversion
              else
                :forwards_keywords
              end
            )
          message =
            if result[:implicit_keywords]
              "positional splat relies on pre-Ruby 3 implicit keyword conversion"
            elsif edge.method.ruby2_keywords
              "*#{edge.method.rest || "<anonymous>"} preserves the ruby2_keywords marker"
            else
              "positional splat reaches a keyword method"
            end

          safe_finding(edge, result, message, status: status)
        elsif (result[:patches] || []).any?
          dropped_finding(edge, result)
        else
          explained_finding(edge, result)
        end
      end

      def trace_forward(edge, chain)
        target = edge.dispatch[:target]
        unless edge.dispatch[:kind] == :static
          return incompatible(chain, "... target is not statically resolvable")
        end

        if directly_accepts_keywords?(target)
          return { arrives: true, chain: chain }
        end

        next_edge =
          target.edges.detect do |candidate|
            candidate.channels.include?(:forward)
          end
        unless next_edge
          return(
            { arrives: false, chain: chain, reason: :forwarding_chain_stops }
          )
        end

        trace_forward(next_edge, chain + [next_edge])
      end

      def trace_keywords(edge, chain)
        target = edge.dispatch[:target]
        unless edge.dispatch[:kind] == :static
          return incompatible(chain, "callee is not statically resolvable")
        end

        if directly_accepts_keywords?(target)
          return { arrives: true, chain: chain }
        end

        if target.ruby2_keywords && plain_rest?(target)
          next_edge = legacy_edge_for(target)
          return trace_legacy(next_edge, chain + [next_edge]) if next_edge
        end

        if plain_rest?(target)
          marks = target.ruby2_keywords ? [] : legacy_marker(target)
          next_edge = legacy_edge_for(target)
          if next_edge && (target.ruby2_keywords || marks.any?)
            return trace_legacy(next_edge, chain + [next_edge], marks, true)
          end
        end

        if target.keyword_rest
          next_edge = keyword_edge_for(target)
          return trace_keywords(next_edge, chain + [next_edge]) if next_edge
        end

        { arrives: false, chain: chain, reason: :keyword_chain_stops }
      end

      def trace_legacy(
        edge,
        chain,
        marks = [],
        active = edge.method.ruby2_keywords
      )
        target = edge.dispatch[:target]
        unless edge.dispatch[:kind] == :static
          return incompatible(chain, "callee is not statically resolvable")
        end

        if directly_accepts_keywords?(target)
          unless active
            return(
              {
                arrives: false,
                chain: chain,
                reason: :unmarked_splat_does_not_reconstruct_keywords,
                patches: marks
              }
            )
          end

          return(
            {
              arrives: true,
              chain: chain,
              patches: marks,
              implicit_keywords:
                !@checker.strict_keywords? && !edge.method.ruby2_keywords &&
                  marks.empty?
            }
          )
        end

        unless active
          return(
            {
              arrives: false,
              chain: chain,
              reason: :ruby2_keywords_marker_was_lost,
              patches: marks
            }
          )
        end

        if target.keyword_rest
          next_edge = keyword_edge_for(target)
          if next_edge
            result = trace_keywords(next_edge, chain + [next_edge])
            if result[:arrives]
              merged_patches = marks + (result[:patches] || [])
              return(
                result.merge(
                  chain: chain + result[:chain].drop(1),
                  patches: merged_patches
                )
              )
            end
          end
        end

        if plain_rest?(target)
          target_marks = legacy_marker(target)
          next_marks = marks + target_marks
          active_next =
            target.ruby2_keywords || target_marks.any? ||
              !@checker.strict_keywords?

          unless active_next
            return(
              {
                arrives: false,
                chain: chain,
                reason: :cannot_prove_safe_ruby2_keywords_marker,
                patches: marks
              }
            )
          end

          next_edges =
            target.edges.select { |candidate| legacy_edge?(candidate) }

          next_edges.each do |next_edge|
            result =
              trace_legacy(next_edge, chain + [next_edge], next_marks, true)
            if result[:arrives] || result[:patches].length == next_marks.length
              next result
            end
          end

          if next_marks.any? && next_edges.empty?
            return(
              {
                arrives: false,
                chain: chain,
                reason: :keyword_hash_is_positional,
                patches: next_marks
              }
            )
          end

          if next_marks.any?
            return(
              {
                arrives: false,
                chain: chain,
                reason: :ruby2_keywords_chain_broken,
                patches: next_marks
              }
            )
          end
        end

        {
          arrives: false,
          chain: chain,
          reason: :keyword_arguments_do_not_reach_a_keyword_method
        }
      end

      def initial_legacy_marks(edge)
        if @checker.strict_keywords? && !edge.method.ruby2_keywords
          legacy_marker(edge.method)
        else
          []
        end
      end

      def legacy_marker(method)
        return [] unless @checker.strict_keywords?
        return [] if method.ruby2_keywords
        return [] unless safe_to_mark?(method)

        [marker_patch(method)]
      end

      def safe_to_mark?(method)
        return false unless plain_rest?(method)
        return false unless method.params.posts.empty? && !method.keyword_rest

        return false if method.rest && !rest_uses_preserve_marker?(method)

        forwarding_nodes(method).any?
      end

      def forwarding_nodes(method)
        nodes = []
        walk(method.node.bodystmt) do |node|
          next unless node.is_a?(ArgStar)

          name = expression_name(node.value)
          nodes << node if node.value.nil? || name == method.rest
        end
        nodes
      end

      def rest_uses_preserve_marker?(method)
        uses = []

        walk(method.node.bodystmt) do |node|
          next unless local_reference?(node, method.rest)

          uses << node
        end

        uses.all? { |node| marker_preserving_use?(method, node) }
      end

      def marker_preserving_use?(method, node)
        edge =
          method.edges.detect do |candidate|
            range =
              candidate.node.location.start_char..candidate
                .node
                .location
                .end_char
            range.cover?(node.location.start_char)
          end

        return false unless edge

        edge.roles.keys.any? { |role| role == "*#{method.rest}" }
      end

      def local_reference?(node, name)
        return false unless name

        (node.is_a?(VarRef) || node.is_a?(VCall)) && node.value.is_a?(Ident) &&
          node.value.value == name
      end

      def marker_patch(method)
        Patch.new(
          start_char: method.node.location.start_char,
          end_char: method.node.location.start_char,
          replacement: "ruby2_keywords ",
          reason: "mark #{method.name} with ruby2_keywords"
        )
      end

      def call_keyword_patches(edge, name)
        return [] unless edge.node.arguments.is_a?(ArgParen)

        expression =
          name ||
            (
              if @checker.target_ruby_version >=
                   Formatter::SemanticVersion.new("3.2.0")
                nil
              else
                "_kwargs"
              end
            )
        return [] if name.nil? && expression == "_kwargs"

        arguments = edge.node.arguments
        inner = arguments.arguments
        return [] unless inner.is_a?(Args)

        block = inner.parts.grep(ArgBlock).first
        insertion = block ? block.location.start_char : inner.location.end_char
        replacement =
          if inner.parts.empty?
            "**#{expression}"
          elsif block
            "**#{expression}, "
          else
            ", **#{expression}"
          end

        [
          Patch.new(
            start_char: insertion,
            end_char: insertion,
            replacement: replacement,
            reason: "forward captured keyword arguments to #{edge.name}"
          )
        ]
      end

      def patchable_call?(edge)
        edge.node.arguments.is_a?(ArgParen)
      end

      def keyword_edge_for(method)
        method.edges.detect do |edge|
          edge.dispatch[:kind] == :static &&
            (
              edge.channels.include?(:keyword_splat) ||
                edge.channels.include?(:forward)
            )
        end
      end

      def legacy_edge_for(method)
        method.edges.detect do |edge|
          edge.dispatch[:kind] == :static && legacy_edge?(edge)
        end
      end

      def legacy_edge?(edge)
        return false unless edge
        return false if edge.channels.include?(:keyword_splat)

        edge.channels.include?(:positional_splat) ||
          edge.channels.include?(:forward)
      end

      def positional_legacy_edge?(edge)
        edge && !edge.channels.include?(:keyword_splat) &&
          edge.channels.include?(:positional_splat)
      end

      def plain_rest?(method)
        method.params && method.rest && !method.keyword_rest
      end

      def forwarding_target?(method)
        method.keyword_rest&.dig(:kind) == :forward
      end

      def directly_accepts_keywords?(method)
        return false unless method.params
        return false if method.keyword_rest&.dig(:kind) == :nil

        method.params.keywords.any? ||
          method.keyword_rest&.dig(:kind) == :keywords ||
          method.keyword_rest&.dig(:kind) == :forward
      end

      def incompatible(chain, reason)
        { arrives: false, incompatible: true, chain: chain, reason: reason }
      end

      def dynamic_dispatch_finding(edge)
        message =
          if edge.method.ruby2_keywords
            "ruby2_keywords preserves the marker through #{edge.name}, but the callee is selected dynamically"
          else
            "#{edge.name} selects the callee dynamically; the checker cannot prove keyword arrival"
          end

        build_finding(
          edge: edge,
          status: :dynamic_dispatch,
          message: message,
          explanation:
            "No automatic rewrite is generated because the callee is selected dynamically " \
              "and cannot be resolved statically.",
          patches: []
        )
      end

      def unknown_callee_finding(edge)
        build_finding(
          edge: edge,
          status: :unknown_callee,
          message:
            "keyword arrival through #{edge.name} cannot be proven statically",
          explanation:
            "The call has an explicit receiver or an unresolved callee, so the forwarding chain stops here.",
          patches: []
        )
      end

      def safe_finding(edge, result, message, status: :forwards_keywords)
        build_finding(
          edge: edge,
          status: status,
          message: message,
          explanation:
            "The statically resolved chain preserves keyword arguments.",
          result: result,
          patches: result[:patches] || []
        )
      end

      def dropped_finding(edge, result)
        build_finding(
          edge: edge,
          status:
            (
              if result[:patches].any?
                :keyword_arguments_dropped
              else
                :keyword_arguments_unprovable
              end
            ),
          message: "keyword arguments are lost before #{edge.name}",
          explanation: result[:reason].to_s.tr("_", " "),
          result: result,
          patches: result[:patches] || []
        )
      end

      def explained_finding(edge, result)
        build_finding(
          edge: edge,
          status: :keyword_arguments_unprovable,
          message:
            "the forwarding chain does not prove keyword arrival at #{edge.name}",
          explanation: result[:reason].to_s.tr("_", " "),
          result: result,
          patches: []
        )
      end

      def incompatible_finding(edge, message)
        build_finding(
          edge: edge,
          status: :incompatible_forwarding,
          message: message,
          explanation:
            "The source and target parameter shapes are not statically compatible.",
          patches: []
        )
      end

      def build_finding(
        edge:,
        status:,
        message:,
        explanation:,
        result: nil,
        patches: []
      )
        chain = (result && result[:chain]) || [edge]
        Finding.new(
          status: status,
          message: message,
          explanation: explanation,
          location: edge.node.location,
          method: edge.method.name,
          callee: edge.name,
          callee_status: edge.dispatch[:kind],
          roles: edge.roles,
          chain: chain.map { |item| [item.method.name, item.name] },
          patches: patches
        )
      end

      def walk(node, &block)
        return unless node

        yield(node)
        return unless node.respond_to?(:child_nodes)

        node.child_nodes.compact.each { |child| walk(child, &block) }
      end

      def expression_name(node)
        case node
        when VarRef, VCall
          expression_name(node.value)
        when Ident, Const, Kw
          node.value
        end
      end
    end
  end
end
