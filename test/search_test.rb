# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class SearchTest < Minitest::Test
    def test_search_invalid_syntax
      assert_raises(Pattern::CompilationError) { search("", "<>") }
    end

    def test_search_invalid_constant
      assert_raises(Pattern::CompilationError) { search("", "Foo") }
    end

    def test_search_invalid_nested_constant
      assert_raises(Pattern::CompilationError) { search("", "Foo::Bar") }
    end

    def test_search_regexp_with_interpolation
      assert_raises(Pattern::CompilationError) { search("", "/\#{foo}/") }
    end

    def test_search_string_with_interpolation
      assert_raises(Pattern::CompilationError) { search("", '"#{foo}"') }
    end

    def test_search_symbol_with_interpolation
      assert_raises(Pattern::CompilationError) { search("", ":\"\#{foo}\"") }
    end

    def test_search_invalid_node
      assert_raises(Pattern::CompilationError) { search("", "Int[^foo]") }
    end

    def test_search_self
      assert_raises(Pattern::CompilationError) { search("", "self") }
    end

    def test_search_array_pattern_no_constant
      results = search("1 + 2", "[Int, Int]")

      assert_equal 1, results.length
    end

    def test_search_array_pattern
      results = search("1 + 2", "Binary[Int, Int]")

      assert_equal 1, results.length
    end

    def test_search_binary_or
      results = search("Foo + Bar + 1", "VarRef | Int")

      assert_equal 3, results.length
      assert_equal "1", results.min_by { |node| node.class.name }.value
    end

    def test_search_const
      results = search("Foo + Bar + Baz", "VarRef")

      assert_equal 3, results.length
      assert_equal %w[Bar Baz Foo], results.map { |node| node.value.value }.sort
    end

    def test_search_object_const
      results = search("1 + 2 + 3", "Int[value: String]")

      assert_equal 3, results.length
    end

    def test_search_syntax_tree_const
      results = search("Foo + Bar + Baz", "SyntaxTree::VarRef")

      assert_equal 3, results.length
    end

    def test_search_hash_pattern_no_constant
      results = search("Foo + Bar + Baz", "{ value: Const }")

      assert_equal 3, results.length
    end

    def test_search_hash_pattern_string
      results = search("Foo + Bar + Baz", "VarRef[value: Const[value: 'Foo']]")

      assert_equal 1, results.length
      assert_equal "Foo", results.first.value.value
    end

    def test_search_hash_pattern_regexp
      results = search("Foo + Bar + Baz", "VarRef[value: Const[value: /^Ba/]]")

      assert_equal 2, results.length
      assert_equal %w[Bar Baz], results.map { |node| node.value.value }.sort
    end

    def test_search_string_empty
      results = search("", "''")

      assert_empty results
    end

    def test_search_symbol_empty
      results = search("", ":''")

      assert_empty results
    end

    def test_search_symbol_plain
      results = search("1 + 2", "Binary[operator: :'+']")

      assert_equal 1, results.length
    end

    def test_search_symbol
      results = search("1 + 2", "Binary[operator: :+]")

      assert_equal 1, results.length
    end

    def test_search_capture_value_and_location
      match = match_captures("1 + 2", "Binary[left: Int => number]")

      assert_equal %i[number], match.captures.keys
      assert_equal "1", match[:number].value.value
      assert_equal 0, match[:number].location.start_column
      assert_equal 1, match[:number].location.end_column
    end

    def test_search_capture_bare_identifier
      match = match_captures("1 + 2", "Binary[operator: operator]")

      assert_equal :+, match[:operator].value
      assert_nil match[:operator].location
    end

    def test_search_capture_no_match
      matcher =
        SyntaxTree::Pattern.new(
          "Binary[left: Binary => b]"
        ).compile_with_captures

      assert_nil matcher.call(SyntaxTree.parse("1 + 2").statements.body.first)
    end

    def test_search_capture_wildcard
      match = match_captures("1 + 2", "Binary[left: _, right: _]")

      assert_empty match.captures
    end

    def test_search_capture_wildcard_as
      match = match_captures("1 + 2", "Binary[left: Int => _]")

      assert_empty match.captures
    end

    def test_search_capture_repeated_name
      query =
        "Statements[CallNode[receiver: VCall => recv], *, CallNode[receiver: VCall => recv]]"

      assert search("foo.bar; foo.baz", query).one?
      assert_empty search("foo.bar; baz.qux", query)
    end

    def test_search_capture_repeated_name_ignores_location_and_comments
      query =
        "Statements[CallNode[receiver: VCall => recv], *, CallNode[receiver: VCall => recv]]"

      assert search("foo.bar; foo.baz # note", query).one?
    end

    def test_search_capture_repeated_name_nested_calls
      query =
        "Statements[CallNode[receiver: CallNode => recv], *, CallNode[receiver: CallNode => recv]]"

      assert search("foo(1).bar; foo(1).baz", query).one?
      assert_empty search("foo(1).bar; foo(2).baz", query)
    end

    def test_search_capture_repeated_name_textually_same_structurally_different
      query = "Statements[VCall => call, *, VCall => call]"

      assert search("foo; foo", query).one?
      assert_empty search("foo; foo = 1; foo", query)
    end

    def test_search_capture_repeated_name_attribute
      query = "Statements[Binary[operator: op], Binary[operator: op]]"

      assert search("1 + 2\n3 + 4", query).one?
      assert_empty search("1 + 2\n3 - 4", query)
    end

    def test_search_capture_rest_fragment
      match = match_captures("1\n2\n3", "Statements[Int, *rest, Int]")

      assert_equal 1, match[:rest].value.length
      assert_equal "2", match[:rest].value.first.value
      assert_equal 2, match[:rest].location.start_line
      assert_equal 2, match[:rest].location.end_line
    end

    def test_search_capture_rest_fragment_empty
      match = match_captures("1\n2", "Statements[Int, *rest, Int]")

      assert_empty match[:rest].value
      assert_nil match[:rest].location
    end

    def test_search_array_pattern_rest_wildcard
      assert search("1\n2\n3", "Statements[Int, *, Int]").one?
      assert_empty search("1\n2\n3", "Statements[Int, Int]")
    end

    def test_search_capture_alternation_scoped_bindings
      query =
        "Statements[VCall => a, Int => b] | Statements[VCall => b, VCall => a]"
      match = match_captures("foo; bar", query)

      assert_equal "bar", match[:a].value.value.value
      assert_equal "foo", match[:b].value.value.value
    end

    def test_search_capture_nested_constraint_scoped_bindings
      query =
        "Binary[left: Binary[Int => x, Int], right: Int] | Binary[left: Binary[Int, VCall => x], right: Int]"
      match = match_captures("1 + foo + 1", query)

      assert_equal "foo", match[:x].value.value.value
    end

    def test_search_capture_alternation_ambiguous_bindings
      assert_raises(Pattern::CompilationError) do
        SyntaxTree::Pattern.new("[Ident => x] | [Int]").compile
      end
    end

    def test_search_capture_pinned_reference
      assert_raises(Pattern::CompilationError) do
        SyntaxTree::Pattern.new("^x").compile
      end

      assert_raises(Pattern::CompilationError) do
        SyntaxTree::Pattern.new("^(1 + 1)").compile
      end
    end

    def test_search_capture_guard
      assert_raises(Pattern::CompilationError) do
        SyntaxTree::Pattern.new("Int if true").compile
      end
    end

    def test_search_capture_illegal_target
      assert_raises(Pattern::CompilationError) do
        SyntaxTree::Pattern.new("Ident => 1").compile
      end
    end

    def test_search_capture_boolean_interface
      results =
        search(
          "foo.bar; foo.baz",
          "Statements[CallNode[receiver: VCall => recv], *, CallNode[receiver: VCall => recv]]"
        )

      assert_equal 1, results.length
      assert_kind_of Statements, results.first
    end

    def test_search_scan_with_captures
      matcher = SyntaxTree::Pattern.new("Int => i").compile_with_captures
      results =
        SyntaxTree::Search
          .new(matcher)
          .scan_with_captures(SyntaxTree.parse("1 + 2"))
          .to_a

      assert_equal 2, results.length
      results.each { |node, match| assert_same node, match[:i].value }
    end

    private

    def search(source, query)
      SyntaxTree.search(source, query).to_a
    end

    def match_captures(source, query)
      matcher = SyntaxTree::Pattern.new(query).compile_with_captures
      program = SyntaxTree.parse(source)

      SyntaxTree::Search
        .new(matcher)
        .scan(program)
        .filter_map { |node| matcher.call(node) }
        .first
    end
  end
end
