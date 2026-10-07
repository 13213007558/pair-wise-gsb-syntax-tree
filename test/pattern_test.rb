# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class PatternTest < Minitest::Test
    # The compiled matcher keeps its original boolean interface.
    def test_call_returns_boolean
      matcher = compile("Int")
      node = parse("1").statements.body.first

      assert_equal true, matcher.call(node)
      assert matcher === node
      assert_nil matcher.match(parse("'x'").statements.body.first)
      refute matcher.call(parse("'x'").statements.body.first)
    end

    def test_compiled_matcher_works_in_a_case_when
      matcher = compile("Int")
      node = parse("1").statements.body.first

      matched =
        case node
        when matcher
          true
        else
          false
        end

      assert matched
    end

    def test_search_boolean_interface_unchanged
      results = SyntaxTree.search("1 + 2", "Int").to_a

      assert_equal 2, results.length
      assert(results.all? { |node| node.is_a?(Int) })
    end

    def test_bare_identifier_captures_a_subtree
      binary = parse("1 + 2").statements.body.first
      result = compile("Binary[left: left, right: right]").match(binary)

      assert_instance_of Pattern::MatchResult, result
      assert_equal [:left, :right], result.captures.keys.sort
      assert_instance_of Int, result[:left]
      assert_equal 0, result.location(:left).start_char
      assert_equal 1, result.location(:left).end_char
      assert_equal 4, result.location(:right).start_char
    end

    def test_root_identifier_captures_the_whole_node
      result = compile("whole").match(parse("1").statements.body.first)

      assert_instance_of Int, result[:whole]
    end

    def test_splat_captures_prefix_middle_and_suffix_of_sequences
      result = match(
        "foo(a, b, c, d)",
        "CallNode[arguments: ArgParen[arguments: Args[parts: " \
          "[first, *middle, last]]]]",
        node: parse("foo(a, b, c, d)").statements.body.first
      )

      assert_instance_of VCall, result[:first]
      assert_instance_of VCall, result[:last]
      assert_equal 2, result[:middle].length
      assert_equal %w[b c], result[:middle].map { |node| node.value.value }
    end

    def test_splat_with_no_prefix_or_suffix_captures_everything
      result = match("a; b; c", "Statements[body: [*statements]]")

      assert_equal 3, result[:statements].length
    end

    def test_empty_splat_captures_an_empty_value_with_a_zero_width_location
      result = match("a", "Statements[body: [VCall, *rest]]")

      capture = result.captures[:rest]
      assert_equal [], capture.value
      assert_equal capture.location.start_char, capture.location.end_char
    end

    def test_empty_splat_between_two_elements_anchors_after_the_prefix
      source = "a\nb"
      result = match(source, "Statements[body: [first, *rest, last]]")

      assert_equal [], result[:rest]
      location = result.captures[:rest].location
      assert_equal 2, location.start_char
      assert_equal 2, location.end_char
    end

    def test_find_pattern_captures_left_and_right_sequences
      result = match(
        "foo(a, 1, b)",
        "CallNode[arguments: ArgParen[arguments: Args[parts: " \
          "[*before, Int, *after]]]]",
        node: parse("foo(a, 1, b)").statements.body.first
      )

      assert_equal %w[a], result[:before].map { |node| node.value.value }
      assert_equal %w[b], result[:after].map { |node| node.value.value }
    end

    def test_find_pattern_empty_fragments_have_zero_width_locations
      result = match(
        "foo.bar\nfoo.bar\n",
        "Statements[body: [*before, CallNode, CallNode, *after]]"
      )

      assert_equal [], result[:before]
      assert_equal [], result[:after]
      before_location = result.captures[:before].location
      after_location = result.captures[:after].location
      refute_nil before_location
      refute_nil after_location
      assert_equal before_location.start_char, before_location.end_char
      assert_equal after_location.start_char, after_location.end_char
    end

    def test_repeated_capture_requires_structural_equality
      same = match(
        "foo(a, a)",
        "CallNode[arguments: ArgParen[arguments: Args[parts: " \
          "[argument, argument]]]]",
        node: parse("foo(a, a)").statements.body.first
      )
      different = match(
        "foo(a, b)",
        "CallNode[arguments: ArgParen[arguments: Args[parts: " \
          "[argument, argument]]]]",
        node: parse("foo(a, b)").statements.body.first
      )

      refute_nil same
      assert_instance_of VCall, same[:argument]
      assert_nil different
    end

    def test_repeated_capture_ignores_location
      source = <<~RUBY
        foo.bar
        foo.baz
      RUBY
      result = match(
        source,
        "Statements[body: [CallNode[receiver: receiver]," \
          " CallNode[receiver: receiver], *rest]]"
      )

      refute_nil result
      assert_instance_of VCall, result[:receiver]
      assert_equal "foo", result[:receiver].value.value
      assert_equal [], result[:rest]
    end

    def test_repeated_capture_ignores_comments
      left = parse("a # one\n").statements.body.first
      right = parse("a # two\n").statements.body.first

      assert Pattern::Compiler.structurally_equal?(left, right)
    end

    def test_repeated_capture_does_not_compare_object_identity
      left = parse("a\n").statements.body.first
      right = parse("a\n").statements.body.first

      refute_same left, right
      assert Pattern::Compiler.structurally_equal?(left, right)
    end

    def test_same_text_but_different_structure_is_not_equal
      target = parse("x = 1").statements.body.first.target
      reference = parse("x = 1").statements.body.first
      reference = SyntaxTree.parse("x").statements.body.first

      refute Pattern::Compiler.structurally_equal?(target, reference)

      result = match(
        "x = x",
        "Assign[target: VarField[value: value], value: VarRef[value: value]]"
      )
      assert_nil result
    end

    def test_same_receiver_two_calls_captures_receiver_arguments_and_rest
      source = <<~RUBY
        foo.bar
        foo.baz(1)
      RUBY
      result = match(
        source,
        "Statements[body: [" \
          "CallNode[receiver: receiver, message: first_message]," \
          "CallNode[receiver: receiver, arguments: ArgParen[arguments: " \
            "Args[parts: [*arguments]]]]," \
          "*rest]]"
      )

      refute_nil result
      assert_equal "foo", result[:receiver].value.value
      assert_equal "bar", result[:first_message].value
      assert_equal 1, result[:arguments].length
      assert_instance_of Int, result[:arguments].first
      assert_equal [], result[:rest]
    end

    def test_nested_call_does_not_confuse_sequence_and_subtree_captures
      result = match(
        "foo(foo(1))",
        "CallNode[arguments: ArgParen[arguments: Args[parts: [nested]]]]",
        node: parse("foo(foo(1))").statements.body.first
      )

      assert_instance_of CallNode, result[:nested]
      assert_equal "foo", result[:nested].message.value
    end

    def test_alternation_binds_the_same_names
      matcher = compile("Binary[left: value] | CallNode[receiver: value]")

      binary = parse("1 + 2").statements.body.first
      call = parse("foo.bar").statements.body.first
      assert_equal :value, matcher.match(binary).captures.keys.first
      assert_equal :value, matcher.match(call).captures.keys.first
    end

    def test_failed_alternation_branch_does_not_leak_its_captures
      string_node = parse("'hi'").statements.body.first
      matcher2 = compile("Binary[left: value] | StringLiteral[parts: [value]]")
      result = matcher2.match(string_node)
      refute_nil result
      assert_instance_of TStringContent, result[:value]
      assert_equal "hi", result[:value].value

      # When the first branch fails, a same-named capture from the second
      # branch is not contaminated by the first branch's partial binding.
      binary = parse("1 + 2").statements.body.first
      result = matcher2.match(binary)
      refute_nil result
      assert_instance_of Int, result[:value]
    end

    def test_alternation_with_different_capture_sets_is_a_compile_error
      assert_raises(Pattern::CompilationError) do
        compile("Binary[left: a] | Int")
      end
    end

    def test_negation_does_not_match_its_predicate
      matcher = compile("VarRef unless Const")

      assert matcher.call(parse("Foo").statements.body.first)
      refute matcher.call(parse("foo").statements.body.first)
    end

    def test_nested_negation_pattern
      string_left = parse("'x' + 2").statements.body.first
      int_left = parse("1 + 2").statements.body.first
      matcher = compile("Binary[left: Not[Int]]")

      assert matcher.call(string_left)
      refute matcher.call(int_left)
    end

    def test_negation_has_its_own_binding_boundary
      matcher = compile(
        "Assign[target: VarField[value: value]," \
          " value: Not[VarRef[value: value]]]"
      )

      assert matcher.call(parse("x = y").statements.body.first)
      refute matcher.call(parse("x = x").statements.body.first)

      result = matcher.match(parse("x = y").statements.body.first)
      assert_equal [:value], result.captures.keys
    end

    def test_ancestor_constraint
      source = "foo(1)\n"
      results = scan(source, "Ancestor[Int, CallNode]")

      assert_equal 1, results.length
      assert_instance_of Int, results.first
    end

    def test_ancestor_constraint_respects_order
      source = "foo(1)\n"

      assert_empty scan(source, "Ancestor[Int, Statements, CallNode]")
      assert_equal 1, scan(source, "Ancestor[Int, CallNode, Statements]").length
    end

    def test_ancestor_constraint_has_its_own_binding_boundary
      source = "foo(1)\n"
      results =
        scan_with_matches(source, "Ancestor[Int[value: value], CallNode]")

      assert_equal 1, results.length
      _node, result = results.first
      assert_equal [:value], result.captures.keys
      assert_equal "1", result[:value]
    end

    def test_pinned_expressions_are_compile_errors
      assert_raises(Pattern::CompilationError) { compile("^variable") }
      assert_raises(Pattern::CompilationError) { compile("^@ivar") }
      assert_raises(Pattern::CompilationError) { compile("^(1 + 2)") }
    end

    def test_illegal_capture_names_are_compile_errors
      ["@ivar", "$gvar", "Constant", "a | Int", "A[x, *x]"].each do |query|
        assert_raises(Pattern::CompilationError, query) { compile(query) }
      end
    end

    def test_capture_kind_mismatch_is_a_compile_error
      assert_raises(Pattern::CompilationError) do
        compile("Statements[body: [name, *name]]")
      end
      assert_raises(Pattern::CompilationError) do
        compile("Binary[left: name, **name]")
      end
    end

    def test_keyword_rest_captures_the_remaining_attributes
      binary = parse("1 + 2").statements.body.first
      result = compile("Binary[left: left, **rest]").match(binary)

      assert_instance_of Int, result[:left]
      assert_equal %i[operator right], result[:rest].keys.sort
    end

    def test_same_capture_name_in_two_positions_compares_across_them
      matcher = compile(
        "Statements[body: [" \
          "CallNode[arguments: ArgParen[arguments: Args[parts: [argument]]]]," \
          "CallNode[arguments: ArgParen[arguments: Args[parts: [argument]]]]]]"
      )

      refute_nil matcher.match(parse("foo(a)\nbar(a)").statements)
      assert_nil matcher.match(parse("foo(a)\nbar(b)").statements)
    end

    def test_input_ruby_is_never_evaluated
      # A pin is the only way to run an expression from a Ruby pattern; it is
      # rejected at compile time, so this never raises despite evaluating to a
      # non-integer at runtime in real Ruby.
      assert_raises(Pattern::CompilationError) do
        compile("Int unless ^(raise 'evaluated')")
      end
    end

    def test_standalone_not_and_ancestor_constants_are_compile_errors
      assert_raises(Pattern::CompilationError) { compile("Not") }
      assert_raises(Pattern::CompilationError) { compile("Ancestor") }
      assert_raises(Pattern::CompilationError) { compile("Not[]") }
      assert_raises(Pattern::CompilationError) { compile("Ancestor[]") }
    end

    def test_capture_source_range
      source = "foo.bar(1, 2)\n"
      result = match(
        source,
        "CallNode[receiver: receiver, arguments: ArgParen[arguments: " \
          "Args[parts: [first, *rest]]]]",
        node: parse(source).statements.body.first
      )

      assert_equal 0, result.location(:receiver).start_char
      assert_equal 3, result.location(:receiver).end_char
      assert_equal "2", result[:rest].first.value
    end

    private

    def compile(query)
      SyntaxTree::Pattern.new(query).compile
    end

    def parse(source)
      SyntaxTree.parse(source)
    end

    def match(source, query, node: nil)
      matcher = compile(query)
      target = node || parse(source).statements
      matcher.match(target)
    end

    def match_first(source, query)
      matcher = compile(query)
      target = parse(source).statements.body
      matcher.match(target) || matcher.match(parse(source).statements)
    end

    def scan(source, query)
      SyntaxTree.search(source, query).to_a
    end

    def scan_with_matches(source, query)
      results = []
      block = proc { |node, result| results << [node, result] }
      SyntaxTree.search_matches(source, query, &block)
      results
    end
  end
end
