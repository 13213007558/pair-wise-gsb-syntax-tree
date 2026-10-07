# frozen_string_literal: true

module SyntaxTree
  class Pattern
    # Compiler walks the AST of a parsed pattern query and produces Matcher
    # objects. Matchers never evaluate Ruby expressions found in the input:
    # anything that would require running query code (pins, generic guard
    # expressions, interpolations) is rejected at compile time.
    class Compiler
      # Names used by the structural-search extensions. They never refer to
      # syntax tree node classes at match time even though the queries parse
      # as ordinary constants.
      NOT_CONSTANT = "Not"
      ANCESTOR_CONSTANT = "Ancestor"

      # Compares two matched values for structural equality. Locations and
      # attached comments are ignored, and two expressions are equal only if
      # they parse to the same tree of node types and attributes. This is
      # deliberately structural rather than a check of object identity, and it
      # also does not consider source text alone: identical text that builds a
      # different tree fails the comparison.
      def self.structurally_equal?(left, right)
        case left
        when Node
          left.class == right.class &&
            attribute_keys(left).all? do |key|
              structurally_equal?(
                left.deconstruct_keys([key])[key],
                right.deconstruct_keys([key])[key]
              )
            end
        when Array
          right.is_a?(Array) && left.length == right.length &&
            left.zip(right).all? do |lvalue, rvalue|
              structurally_equal?(lvalue, rvalue)
            end
        when Hash
          right.is_a?(Hash) && left.keys == right.keys &&
            left.all? { |key, value| structurally_equal?(value, right[key]) }
        else
          left == right
        end
      end

      def self.attribute_keys(node)
        node.deconstruct_keys(nil).keys - %i[location comments]
      end

      def initialize
        @capture_kinds = {}
      end

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
        when FndPtn
          compile_fndptn(node)
        when HshPtn
          compile_hshptn(node)
        when IfNode
          compile_if(node)
        when Paren
          compile_node(unwrap_paren(node.contents))
        when RegexpLiteral
          compile_regexp_literal(node)
        when StringLiteral
          compile_string_literal(node)
        when SymbolLiteral
          compile_symbol_literal(node)
        when UnlessNode
          compile_unless(node)
        when VarField
          compile_var_field(node)
        when VarRef
          compile_var_ref(node)
        else
          compile_error(node)
        end
      end

      private

      # Raise an error because the given node is not supported.
      def compile_error(node, detail = nil)
        raise CompilationError.new(PP.pp(node, +"").chomp, detail)
      end

      # Helpers invoked from the standalone matcher objects generated below.
      # They need to remain public because those objects call back into the
      # compiler that built them.
      public

      # There are a couple of nodes (string literals, dynamic symbols, and
      # regexp) that contain list of parts. This can include plain string
      # content, interpolated expressions, and interpolated variables. We
      # only support plain string content, so this method extracts the plain
      # string content if it is the only element in the list.
      def extract_string(node)
        parts = node.parts

        if parts.length == 1 && (part = parts.first) &&
             part.is_a?(TStringContent)
          part.value
        end
      end

      # Pulls the single statement out of a modifier-form guard body.
      def single_statement(node)
        body = node.statements.body
        compile_error(node) unless body.length == 1 && node.consequent.nil?
        body.first
      end

      # A guard predicate can be parenthesized (e.g. `... unless (A | B)`).
      def unwrap_paren(node)
        node.is_a?(Statements) && node.body.length == 1 ? node.body.first : node
      end

      # Registers a capture name at compile time and makes sure the same name
      # is always used for the same kind of capture (subtree versus sequence
      # versus keywords). Returns the symbol name.
      def register_capture(ident_node, kind, source_node)
        ident = ident_node.value
        name = ident.to_sym

        unless ident.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)
          compile_error(
            source_node,
            "#{ident.inspect} is not a valid capture name"
          )
        end

        if (previous = @capture_kinds[name]) && previous != kind
          compile_error(
            source_node,
            "capture #{name.inspect} is used as both #{previous} and #{kind}"
          )
        end

        @capture_kinds[name] = kind
        name
      end

      # Builds an anonymous matcher object carrying its compile-time capture
      # name set. +names+ is the set this boundary exports when it succeeds.
      def build_matcher(names)
        matcher = Object.new
        matcher.extend(Matcher)
        matcher.instance_variable_set(:@captures, names)
        matcher.define_singleton_method(:captures) { @captures }
        matcher.instance_variable_set(:@compiler, self)
        matcher.define_singleton_method(:compiler) { @compiler }
        matcher
      end

      def array_location(values, default)
        first = values.find { |value| value.is_a?(Node) }
        last = values.reverse.find { |value| value.is_a?(Node) }

        if first && last
          first.location.to(last.location)
        elsif default
          empty_location(default)
        end
      end

      def hash_location(values, default)
        nodes = values.values.grep(Node)
        if nodes.empty?
          default && empty_location(default)
        else
          nodes.first.location.to(nodes.last.location)
        end
      end

      def empty_location(location)
        return nil unless location

        Location.new(
          start_line: location.start_line,
          start_char: location.start_char,
          start_column: location.start_column,
          end_line: location.start_line,
          end_char: location.start_char,
          end_column: location.start_column
        )
      end

      def simple_matcher(&block)
        matcher = build_matcher(Set.new)
        matcher.define_singleton_method(:match?, &block)
        matcher
      end

      # Returns the special structural-search constant name used by a pattern
      # constant, or nil if the constant is a regular node type constant.
      def special_constant(constant)
        return nil unless constant.is_a?(VarRef) && constant.value.is_a?(Const)

        case constant.value.value
        when NOT_CONSTANT
          :not
        when ANCESTOR_CONSTANT
          :ancestor
        end
      end

      # Compiles Not[pattern] and Ancestor[pattern, ...]. Neither accepts a
      # splat or trailing elements, and both use an isolated binding boundary.
      def compile_special_aryptn(node, kind)
        compile_error(node) if node.rest || node.posts.any?

        submatchers = node.requireds.map { |required| compile_node(required) }

        case kind
        when :not
          unless submatchers.length == 1
            compile_error(node, "Not[] requires exactly one pattern")
          end
          inner = submatchers.first

          matcher = build_matcher(Set.new)
          matcher.define_singleton_method(:match?) do |value, bindings, anc|
            !with_isolation(bindings) do |branch|
              inner.match?(value, branch, anc)
            end
          end
          matcher
        when :ancestor
          if submatchers.empty?
            compile_error(node, "Ancestor[] requires at least one pattern")
          end
          head, *constraints = submatchers

          matcher = build_matcher(head.captures)
          matcher.define_singleton_method(:match?) do |value, bind, ancestors|
            next false unless head.match?(value, bind, ancestors)

            # Constraints match a chain of ancestors in outermost order.
            # Each subsequent constraint must match an ancestor that is
            # strictly outside the previous one, but intermediate ancestor
            # nodes do not need to be named. The chain may begin at any point
            # in the ancestor chain, so a CallNode ancestor can be required
            # without naming the surrounding Statements and Program.
            chain = ancestors.reverse
            next false if constraints.length > chain.length

            search_index = 0
            constraints.all? do |constraint|
              matched_index =
                (search_index...chain.length).find do |index|
                  ancestor = chain[index]
                  outer_count = ancestors.length - index - 1
                  with_isolation(bind) do |branch|
                    constraint.match?(
                      ancestor,
                      branch,
                      ancestors[0, outer_count]
                    )
                  end
                end

              next false unless matched_index
              search_index = matched_index + 1
              true
            end
          end
          matcher
        end
      end

      def match_each(matchers, values, bindings, ancestors)
        matchers.length == values.length &&
          matchers.zip(values).all? do |submatcher, value|
            submatcher.match?(value, bindings, ancestors)
          end
      end

      # Compiles an optional splat. Anonymous splats produce no captures.
      def compile_rest(var_field)
        return nil if var_field.nil?
        compile_error(var_field) unless var_field.is_a?(VarField)

        if var_field.value.nil? || var_field.value == :nil
          { names: Set.new }
        else
          ident = var_field.value
          compile_error(var_field) unless ident.is_a?(Ident)
          name = register_capture(ident, :sequence, var_field)
          { names: Set[name] }
        end
      end

      # Location covered by the middle slice between a prefix and a suffix.
      # Empty slices use a zero-width location adjacent to the surrounding
      # elements.
      def rest_location(container, prefix, middle, suffix)
        container_location = container.is_a?(Node) ? container.location : nil

        array_location(middle, container_location) ||
          empty_location(
            if suffix.first.is_a?(Node)
              # The gap sits immediately before the first suffix element.
              suffix.first.location
            elsif prefix.last.is_a?(Node)
              # The gap sits immediately after the last prefix element. Build
              # a location positioned at its end rather than its start.
              ending_location(prefix.last.location)
            else
              container_location
            end
          )
      end

      # A zero-width location positioned at the end of another location.
      def ending_location(location)
        Location.new(
          start_line: location.end_line,
          start_char: location.end_char,
          start_column: location.end_column,
          end_line: location.end_line,
          end_char: location.end_char,
          end_column: location.end_column
        )
      end

      # Location for an empty leading fragment of a find pattern: the gap is
      # immediately before the first matched value. This works even when the
      # sequence is a plain array attribute, since the matched window is never
      # empty for a find pattern and therefore always provides an anchor.
      def leading_gap_location(_container, middle)
        first = middle.find { |value| value.is_a?(Node) }
        first && empty_location(first.location)
      end

      # Location for an empty trailing fragment: immediately after the last
      # matched value.
      def trailing_gap_location(_container, middle)
        last = middle.reverse.find { |value| value.is_a?(Node) }
        last && ending_location(last.location)
      end

      # in [foo, bar, baz]
      # in A[foo, *rest, baz]
      def compile_aryptn(node)
        if (special = special_constant(node.constant))
          return compile_special_aryptn(node, special)
        end

        if node.constant && node.constant.is_a?(VarField)
          compile_error(node.constant)
        end
        compiled_constant = compile_node(node.constant) if node.constant

        requireds = node.requireds.map { |required| compile_node(required) }
        posts = node.posts.map { |post| compile_node(post) }
        rest = compile_rest(node.rest)

        names = (requireds + posts).map(&:captures).reduce(Set.new, :merge)
        names.merge(rest[:names]) if rest

        matcher = build_matcher(names)
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          deconstructed =
            begin
              value.deconstruct
            rescue StandardError
              return false
            end

          next false unless deconstructed.is_a?(Array)
          constant_matches =
            compiled_constant.nil? ||
              compiled_constant.match?(value, bindings, ancestors)
          next false unless constant_matches

          minimum = requireds.length + posts.length
          next false if deconstructed.length < minimum

          if rest
            middle_length = deconstructed.length - minimum
          elsif deconstructed.length != minimum
            next false
          else
            middle_length = 0
          end

          split = requireds.length
          prefix = deconstructed[0, split]
          middle = deconstructed[split, middle_length] || []
          suffix_start = split + middle_length
          suffix = deconstructed[suffix_start, posts.length] || []

          result = false
          with_boundary(bindings, names) do |branch|
            next false unless compiler.match_each(
              requireds,
              prefix,
              branch,
              ancestors
            )

            if rest && !rest[:names].empty?
              name = rest[:names].first
              location = compiler.rest_location(value, prefix, middle, suffix)
              next false unless branch.bind(name, middle, location)
            end

            next false unless compiler.match_each(
              posts,
              suffix,
              branch,
              ancestors
            )
            result = true
            end

          result
        end
        matcher
      end

      # in [*, foo, *]
      # in [*left, foo, *right]
      def compile_fndptn(node)
        if node.constant && node.constant.is_a?(VarField)
          compile_error(node.constant)
        end
        compiled_constant = compile_node(node.constant) if node.constant
        values = node.values.map { |value| compile_node(value) }
        left = compile_rest(node.left)
        right = compile_rest(node.right)

        compile_error(node) if values.empty?

        names = values.map(&:captures).reduce(Set.new, :merge)
        names.merge(left[:names]) if left
        names.merge(right[:names]) if right

        matcher = build_matcher(names)
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          deconstructed =
            begin
              value.deconstruct
            rescue StandardError
              return false
            end

          next false unless deconstructed.is_a?(Array)
          constant_matches =
            compiled_constant.nil? ||
              compiled_constant.match?(value, bindings, ancestors)
          next false unless constant_matches
          next false if deconstructed.length < values.length

          window = values.length

          found = false
          (0..deconstructed.length - window).each do |offset|
            with_boundary(bindings, names) do |branch|
              middle = deconstructed[offset, window] || []
              prefix = deconstructed[0, offset] || []
              suffix_start = offset + window
              suffix = deconstructed[suffix_start..] || []
              next false unless compiler.match_each(
                values,
                middle,
                branch,
                ancestors
              )

              if left && !left[:names].empty?
                location =
                  compiler.array_location(prefix, nil) ||
                    compiler.leading_gap_location(value, middle)
                next false unless branch.bind(
                  left[:names].first,
                  prefix,
                  location
                )
              end

              if right && !right[:names].empty?
                location =
                  compiler.array_location(suffix, nil) ||
                    compiler.trailing_gap_location(value, middle)
                next false unless branch.bind(
                  right[:names].first,
                  suffix,
                  location
                )
              end

              found = true
            end
            break if found
          end

          found
        end
        matcher
      end

      # in foo | bar
      def compile_binary(node)
        compile_error(node) if node.operator != :|

        left = compile_node(node.left)
        right = compile_node(node.right)
        names = left.captures | right.captures

        if left.captures != right.captures
          compile_error(
            node,
            "alternation branches must bind the same captures, but got " \
              "#{left.captures.to_a.sort.inspect} and " \
                "#{right.captures.to_a.sort.inspect}"
          )
        end

        matcher = build_matcher(names)
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          with_boundary(bindings, names) do |branch|
            left.match?(value, branch, ancestors)
          end ||
            with_boundary(bindings, names) do |branch2|
              right.match?(value, branch2, ancestors)
            end
        end
        matcher
      end

      # in Ident
      # in String
      def compile_const(node)
        value = node.value

        if value == NOT_CONSTANT || value == ANCESTOR_CONSTANT
          compile_error(
            node,
            "#{value} is a structural-search constraint and " \
              "requires an array pattern"
          )
        elsif SyntaxTree.const_defined?(value, false)
          clazz = SyntaxTree.const_get(value)
          simple_matcher { |other, _bindings, _ancestors| clazz === other }
        elsif Object.const_defined?(value, false)
          clazz = Object.const_get(value)
          simple_matcher { |other, _bindings, _ancestors| clazz === other }
        else
          compile_error(node)
        end
      end

      # in SyntaxTree::Ident
      def compile_const_path_ref(node)
        parent = node.parent
        if !parent.is_a?(VarRef) || !parent.value.is_a?(Const)
          compile_error(node)
        end

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
          simple_matcher { |other, _bindings, _ancestors| symbol === other }
        elsif (value = extract_string(node))
          symbol = value.to_sym
          simple_matcher { |other, _bindings, _ancestors| symbol === other }
        else
          compile_error(node)
        end
      end

      # in Ident[value: String]
      # in { value: String }
      def compile_hshptn(node)
        if node.constant && node.constant.is_a?(VarField)
          compile_error(node.constant)
        end
        compiled_constant = compile_node(node.constant) if node.constant

        keywords =
          node.keywords.map do |keyword, value|
            compile_error(node) unless keyword.is_a?(Label)
            [keyword.value.chomp(":").to_sym, compile_node(value)]
          end.to_h

        rest = compile_rest(node.keyword_rest)

        names = keywords.values.map(&:captures).reduce(Set.new, :merge)
        names.merge(rest[:names]) if rest

        matcher = build_matcher(names)
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          deconstructed =
            begin
              value.deconstruct_keys(nil)
            rescue StandardError
              return false
            end

          next false unless deconstructed.is_a?(Hash)
          constant_matches =
            compiled_constant.nil? ||
              compiled_constant.match?(value, bindings, ancestors)
          next false unless constant_matches

          result = false
          with_boundary(bindings, names) do |branch|
            next false unless keywords.all? do |keyword, submatcher|
              submatcher.match?(deconstructed[keyword], branch, ancestors)
            end

            if rest
              bound_keys = keywords.keys
              extras =
                deconstructed.reject do |key, _value|
                  bound_keys.include?(key) ||
                    key == :location || key == :comments
                end

              unless rest[:names].empty?
                name = rest[:names].first
                default =
                  if value.is_a?(Node)
                    compiler.empty_location(value.location)
                  end
                location = compiler.hash_location(extras, default)
                next false unless branch.bind(name, extras, location)
              end
            end

            result = true
          end
          result
        end
        matcher
      end

      # in /foo/
      def compile_regexp_literal(node)
        if (value = extract_string(node))
          regexp = /#{value}/
          simple_matcher do |attribute, _bindings, _ancestors|
            regexp === attribute
          end
        else
          compile_error(node)
        end
      end

      # in ""
      # in "foo"
      def compile_string_literal(node)
        if node.parts.empty?
          simple_matcher { |attribute, _bindings, _ancestors| "" === attribute }
        elsif (value = extract_string(node))
          simple_matcher do |attribute, _bindings, _ancestors|
            value === attribute
          end
        else
          compile_error(node)
        end
      end

      # in :+
      # in :foo
      def compile_symbol_literal(node)
        symbol = node.value.value.to_sym
        simple_matcher do |attribute, _bindings, _ancestors|
          symbol === attribute
        end
      end

      # in receiver
      def compile_var_field(node)
        ident = node.value
        compile_error(node) unless ident.is_a?(Ident)
        name = register_capture(ident, :node, node)

        matcher = build_matcher(Set[name])
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          default = value.is_a?(Node) ? value.location : nil
          bindings.bind(name, value, default)
        end
        matcher
      end

      # in Foo
      # in nil
      def compile_var_ref(node)
        value = node.value

        if value.is_a?(Const)
          compile_node(value)
        elsif value.is_a?(Kw) && value.value.nil?
          simple_matcher { |other, _bindings, _ancestors| nil === other }
        else
          compile_error(node)
        end
      end

      # in Pattern unless Negative[...]
      # Guards cannot run arbitrary Ruby: the predicate must itself be a
      # structural pattern. Captures inside a negative condition are bound in
      # an isolated boundary and never escape.
      def compile_unless(node)
        body = compile_node(single_statement(node))
        predicate = compile_node(node.predicate)

        matcher = build_matcher(body.captures)
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          next false unless body.match?(value, bindings, ancestors)

          negated = with_isolation(bindings) do |branch|
            predicate.match?(value, branch, ancestors)
          end
          !negated
        end
        matcher
      end

      # in Pattern if Positive[...]
      # Same isolation rules as #compile_unless: only the guarded pattern
      # exports captures.
      def compile_if(node)
        body = compile_node(single_statement(node))
        predicate = compile_node(node.predicate)

        matcher = build_matcher(body.captures)
        matcher.define_singleton_method(:match?) do |value, bindings, ancestors|
          next false unless body.match?(value, bindings, ancestors)

          with_isolation(bindings) do |branch|
            predicate.match?(value, branch, ancestors)
          end
        end
        matcher
      end
    end
  end
end
