# frozen_string_literal: true

module SyntaxTree
  # A pattern is an object that wraps a Ruby pattern matching expression. The
  # expression would normally be passed to an `in` clause within a `case`
  # expression or a rightward assignment expression. For example, in the
  # following snippet:
  #
  #     case node
  #     in Const[value: "SyntaxTree"]
  #     end
  #
  # the pattern is the `Const[value: "SyntaxTree"]` expression. Within Syntax
  # Tree, every node generates these kinds of expressions using the
  # #construct_keys method.
  #
  # The pattern gets compiled into an object that responds to call by running
  # the #compile method. This method itself will run back through Syntax Tree to
  # parse the expression into a tree, then walk the tree to generate the
  # necessary callable objects. For example, if you wanted to compile the
  # expression above into a callable, you would:
  #
  #     callable = SyntaxTree::Pattern.new("Const[value: 'SyntaxTree']").compile
  #     callable.call(node)
  #
  # The callable object returned by #compile is guaranteed to respond to #call
  # with a single argument, which is the node to match against. It also is
  # guaranteed to respond to #===, which means it itself can be used in a `case`
  # expression, as in:
  #
  #     case node
  #     when callable
  #     end
  #
  # If the query given to the initializer cannot be compiled into a valid
  # matcher (either because of a syntax error or because it is using syntax we
  # do not yet support) then a SyntaxTree::Pattern::CompilationError will be
  # raised.
  #
  # == Captures
  #
  # In addition to the boolean matching described above, patterns can name
  # parts of the matched tree so that they can be extracted later. A subtree
  # can be captured with the <tt>=></tt> operator or by using a bare
  # identifier, and a sequence of sibling nodes can be captured by naming the
  # starred portion of an array pattern:
  #
  #     Binary[left: Int => number]
  #     Binary[operator: operator]
  #     Statements[first, *rest, last]
  #
  # When a pattern contains captures it can be compiled with
  # #compile_with_captures, which returns a callable that returns a
  # SyntaxTree::Pattern::Match (or nil when the node does not match):
  #
  #     callable = SyntaxTree::Pattern.new("Binary[left: Int => n]").compile_with_captures
  #     match = callable.call(node)
  #     match.captures[:n].value    # the captured Int node
  #     match.captures[:n].location # the location of the captured node
  #
  # If the same name is captured more than once in a pattern, the captured
  # values are required to be structurally equal (that is, equal in every
  # respect except for their location and any attached comments). This makes
  # it possible to search for things like two calls made on the same
  # receiver:
  #
  #     Statements[CallNode[receiver: VCall => recv], *, CallNode[receiver: VCall => recv]]
  #
  # Captures are scoped to the branch of the pattern that created them: when
  # an alternation branch, a negated condition, or a nested (ancestor)
  # constraint fails to match, the captures it created are discarded and do
  # not leak into the next branch. Alternation branches are required to bind
  # the same set of names, and patterns that would require evaluating Ruby
  # expressions from the input (pinned references, guards, interpolation)
  # are rejected. Both kinds of errors are reported at compile time through
  # SyntaxTree::Pattern::CompilationError.
  class Pattern
    # Raised when the query given to a pattern is either invalid Ruby syntax or
    # is using syntax that we don't yet support.
    class CompilationError < StandardError
      def initialize(repr)
        super(<<~ERROR)
          Syntax Tree was unable to compile the pattern you provided to search
          into a usable expression. It failed on to understand the node
          represented by:

          #{repr}

          Note that not all syntax supported by Ruby's pattern matching syntax
          is also supported by Syntax Tree's code search. If you're using some
          syntax that you believe should be supported, please open an issue on
          GitHub at https://github.com/ruby-syntax-tree/syntax_tree/issues/new.
        ERROR
      end
    end

    # A single named value captured by a pattern while matching. Contains
    # both the captured value (a node, an attribute, or a list of nodes when
    # a sequence fragment was captured) and the source location that the
    # value spans.
    class Capture
      attr_reader :value, :location

      def initialize(value:, location:)
        @value = value
        @location = location
      end

      def ==(other)
        other.is_a?(Capture) && value == other.value &&
          location == other.location
      end
    end

    # The result of matching a node against a pattern that was compiled with
    # #compile_with_captures. Contains the set of captures that were bound
    # while matching, keyed by the name given to them in the pattern.
    class Match
      attr_reader :captures

      def initialize(captures)
        @captures = captures
      end

      def [](name)
        captures[name]
      end

      def ==(other)
        other.is_a?(Match) && captures == other.captures
      end
    end

    attr_reader :query

    def initialize(query)
      @query = query
    end

    # Compiles the query into a callable that answers whether or not a node
    # matches the pattern. Any captures in the pattern are matched but not
    # exposed; use #compile_with_captures to extract them.
    def compile
      matcher = compile_matcher

      ->(other) { !matcher.call(other, {}).nil? }
    end

    # Compiles the query into a callable that returns a
    # SyntaxTree::Pattern::Match when the given node matches the pattern
    # (and nil when it does not). The match object contains every value
    # captured by the pattern along with the source location it spans.
    def compile_with_captures
      matcher = compile_matcher

      ->(other) do
        bindings = matcher.call(other, {})
        Match.new(bindings) if bindings
      end
    end

    private

    # Parse the query and compile it into a matcher. A matcher is a callable
    # that accepts a value and a set of bindings (a hash mapping capture
    # names to Capture objects) and returns the extended set of bindings when
    # the value matches, or nil when it does not. Because bindings are
    # threaded through the match instead of being mutated, every alternation
    # branch, negated condition, and nested constraint naturally operates on
    # its own binding boundary: a failed branch can never leak captures into
    # the next one.
    def compile_matcher
      program =
        begin
          SyntaxTree.parse("case nil\nin #{query}\nend")
        rescue Parser::ParseError
          raise CompilationError, query
        end

      raise CompilationError, query if program.nil?
      compile_node(program.statements.body.first.consequent.pattern)
    end

    # Shortcut for combining two matchers into one that matches when both
    # match, threading the bindings from the first into the second.
    def combine_and(left, right)
      ->(value, bindings) do
        if (captured = left.call(value, bindings))
          right.call(value, captured)
        end
      end
    end

    # Shortcut for combining two matchers into one that matches when either
    # matches. Each branch receives the same incoming bindings, so captures
    # made by a branch that goes on to fail are discarded.
    def combine_or(left, right)
      ->(value, bindings) do
        left.call(value, bindings) || right.call(value, bindings)
      end
    end

    # Raise an error because the given node is not supported.
    def compile_error(node)
      raise CompilationError, PP.pp(node, +"").chomp
    end

    # There are a couple of nodes (string literals, dynamic symbols, and regexp)
    # that contain list of parts. This can include plain string content,
    # interpolated expressions, and interpolated variables. We only support
    # plain string content, so this method will extract out the plain string
    # content if it is the only element in the list.
    def extract_string(node)
      parts = node.parts

      if parts.length == 1 && (part = parts.first) && part.is_a?(TStringContent)
        part.value
      end
    end

    # The name that a VarField capture binds to, or nil if the field is a
    # wildcard (either a bare * or the conventional _ name).
    def capture_name(node)
      value = node.value
      value.value.to_sym if value.is_a?(Ident) && value.value != "_"
    end

    # The set of names that would be captured when matching the given
    # pattern node. Used to verify at compile time that alternation branches
    # bind the same names, since otherwise the bindings that are visible
    # after the alternation would depend on which branch matched.
    def capture_names(node)
      names =
        case node
        when AryPtn
          node.requireds.flat_map { |required| capture_names(required) } +
            (node.rest ? capture_names(node.rest) : []) +
            node.posts.flat_map { |post| capture_names(post) }
        when Binary
          capture_names(node.left) + capture_names(node.right)
        when HshPtn
          node.keywords.flat_map { |(_keyword, value)| capture_names(value) }
        when VarField
          (name = capture_name(node)) ? [name] : []
        else
          []
        end

      names.uniq.sort
    end

    # Extend a matcher so that whatever it matches is bound to the given
    # capture name.
    def combine_capture(matcher, name)
      ->(value, bindings) do
        if (captured = matcher.call(value, bindings))
          bind_capture(captured, name, value)
        end
      end
    end

    # Bind a captured value to a name within a set of bindings. When the
    # name has already been bound, the previously captured value and the new
    # value are required to be structurally equal for the match to continue.
    def bind_capture(bindings, name, value)
      if bindings.key?(name)
        structural_equal?(bindings[name].value, value) ? bindings : nil
      else
        bindings.merge(
          name => Capture.new(value: value, location: capture_location(value))
        )
      end
    end

    # Determine the source location that a captured value spans. Nodes know
    # their own location; a sequence fragment spans from its first element
    # to its last (and has no location when it is empty); anything else
    # (like a captured symbol or string attribute) has no location.
    def capture_location(value)
      if value.is_a?(Node)
        value.location
      elsif value.is_a?(Array)
        locations =
          value.filter_map { |element| element.location if element.is_a?(Node) }

        locations.first.to(locations.last) if locations.any?
      end
    end

    # Compare two values for structural equality. Nodes are equal when they
    # are instances of the same class and every field other than their
    # location and attached comments is itself structurally equal. Lists are
    # equal element-wise, and anything else falls back to regular equality.
    def structural_equal?(left, right)
      if left.is_a?(Node) && right.is_a?(Node)
        return false unless left.class == right.class

        left_keys = left.deconstruct_keys(nil)
        right_keys = right.deconstruct_keys(nil)

        (left_keys.keys - %i[location comments]).all? do |key|
          structural_equal?(left_keys[key], right_keys[key])
        end
      elsif left.is_a?(Array) && right.is_a?(Array)
        left.length == right.length &&
          left.zip(right).all? { |(a, b)| structural_equal?(a, b) }
      else
        left == right
      end
    end

    # in [foo, bar, baz]
    def compile_aryptn(node)
      constant = node.constant
      compiled_constant = compile_node(constant) if constant

      compiled_requireds =
        node.requireds.map { |required| compile_node(required) }
      compiled_rest = compile_rest(node.rest) if node.rest
      compiled_posts = node.posts.map { |post| compile_node(post) }

      compiled_elements = ->(value, bindings) do
        return unless value.respond_to?(:deconstruct)

        deconstructed = value.deconstruct
        current = bindings

        if compiled_rest
          minimum = compiled_requireds.length + compiled_posts.length
          return if deconstructed.length < minimum

          compiled_requireds.each_with_index do |matcher, index|
            unless (current = matcher.call(deconstructed[index], current))
              return
            end
          end

          compiled_posts.each_with_index do |matcher, post_index|
            index = deconstructed.length - compiled_posts.length + post_index
            unless (current = matcher.call(deconstructed[index], current))
              return
            end
          end

          fragment =
            deconstructed[
              compiled_requireds.length...deconstructed.length -
                compiled_posts.length
            ] || []

          compiled_rest.call(fragment, current)
        else
          return unless deconstructed.length == compiled_requireds.length

          compiled_requireds.each_with_index do |matcher, index|
            unless (current = matcher.call(deconstructed[index], current))
              return
            end
          end

          current
        end
      end

      if compiled_constant
        combine_and(compiled_constant, compiled_elements)
      else
        compiled_elements
      end
    end

    # Compile the starred portion of an array pattern. A named star captures
    # the sequence of elements between the prefix and the suffix (which may
    # be empty), while a bare star or _ matches and ignores them.
    def compile_rest(node)
      if (name = capture_name(node))
        ->(fragment, bindings) { bind_capture(bindings, name, fragment) }
      elsif node.value.nil? || node.value.is_a?(Ident)
        ->(_fragment, bindings) { bindings }
      else
        compile_error(node)
      end
    end

    # in foo | bar
    # in foo => bar
    def compile_binary(node)
      case node.operator
      when :|
        # Both branches of an alternation must bind the same set of names,
        # otherwise the bindings that are visible after the alternation
        # would depend on which branch matched.
        if capture_names(node.left) != capture_names(node.right)
          compile_error(node)
        end

        combine_or(compile_node(node.left), compile_node(node.right))
      when :"=>"
        right = node.right
        compile_error(node) unless right.is_a?(VarField)

        if (name = capture_name(right))
          combine_capture(compile_node(node.left), name)
        else
          compile_node(node.left)
        end
      else
        compile_error(node)
      end
    end

    # in Ident
    # in String
    def compile_const(node)
      value = node.value

      if SyntaxTree.const_defined?(value, false)
        clazz = SyntaxTree.const_get(value)

        ->(other, bindings) { bindings if clazz === other }
      elsif Object.const_defined?(value, false)
        clazz = Object.const_get(value)

        ->(other, bindings) { bindings if clazz === other }
      else
        compile_error(node)
      end
    end

    # in SyntaxTree::Ident
    def compile_const_path_ref(node)
      parent = node.parent
      compile_error(node) if !parent.is_a?(VarRef) || !parent.value.is_a?(Const)

      if parent.value.value == "SyntaxTree"
        compile_node(node.constant)
      else
        compile_error(node)
      end
    end

    # in :""
    # in :"foo"
    def compile_dyna_symbol(node)
      if node.parts.empty?
        symbol = :""

        ->(other, bindings) { bindings if symbol === other }
      elsif (value = extract_string(node))
        symbol = value.to_sym

        ->(other, bindings) { bindings if symbol === other }
      else
        compile_error(node)
      end
    end

    # in Ident[value: String]
    # in { value: String }
    def compile_hshptn(node)
      compile_error(node) unless node.keyword_rest.nil?
      compiled_constant = compile_node(node.constant) if node.constant

      preprocessed =
        node.keywords.to_h do |keyword, value|
          compile_error(node) unless keyword.is_a?(Label)
          [keyword.value.chomp(":").to_sym, compile_node(value)]
        end

      compiled_keywords = ->(value, bindings) do
        return unless value.respond_to?(:deconstruct_keys)

        deconstructed = value.deconstruct_keys(preprocessed.keys)
        current = bindings

        preprocessed.each do |keyword, matcher|
          unless (current = matcher.call(deconstructed[keyword], current))
            return
          end
        end

        current
      end

      if compiled_constant
        combine_and(compiled_constant, compiled_keywords)
      else
        compiled_keywords
      end
    end

    # in /foo/
    def compile_regexp_literal(node)
      if (value = extract_string(node))
        regexp = /#{value}/

        ->(attribute, bindings) { bindings if regexp === attribute }
      else
        compile_error(node)
      end
    end

    # in ""
    # in "foo"
    def compile_string_literal(node)
      if node.parts.empty?
        ->(attribute, bindings) { bindings if "" === attribute }
      elsif (value = extract_string(node))
        ->(attribute, bindings) { bindings if value === attribute }
      else
        compile_error(node)
      end
    end

    # in :+
    # in :foo
    def compile_symbol_literal(node)
      symbol = node.value.value.to_sym

      ->(attribute, bindings) { bindings if symbol === attribute }
    end

    # in Foo
    # in nil
    def compile_var_ref(node)
      value = node.value

      if value.is_a?(Const)
        compile_node(value)
      elsif value.is_a?(Kw) && value.value.nil?
        ->(attribute, bindings) { bindings if nil === attribute }
      else
        compile_error(node)
      end
    end

    # in foo
    # in _
    def compile_var_field(node)
      if (name = capture_name(node))
        combine_capture(->(_value, bindings) { bindings }, name)
      elsif node.value.nil? || node.value.is_a?(Ident)
        ->(_value, bindings) { bindings }
      else
        compile_error(node)
      end
    end

    # Compile any kind of node. Dispatch out to the individual compilation
    # methods based on the type of node.
    def compile_node(node)
      case node
      when AryPtn
        compile_aryptn(node)
      when Binary
        compile_binary(node)
      when Const
        compile_const(node)
      when ConstPathRef
        compile_const_path_ref(node)
      when DynaSymbol
        compile_dyna_symbol(node)
      when HshPtn
        compile_hshptn(node)
      when RegexpLiteral
        compile_regexp_literal(node)
      when StringLiteral
        compile_string_literal(node)
      when SymbolLiteral
        compile_symbol_literal(node)
      when VarRef
        compile_var_ref(node)
      when VarField
        compile_var_field(node)
      else
        compile_error(node)
      end
    end
  end
end
