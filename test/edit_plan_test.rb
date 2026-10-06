# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class EditPlanTest < Minitest::Test
    def test_commutable_plans_merge_in_either_order
      source = <<~RUBY
        foo(1)
        bar(2)
      RUBY

      program = SyntaxTree.parse(source)
      first, second = program.statements.body

      plan_a = EditPlan.new
      plan_a.replace(first, "baz(1)")

      plan_b = EditPlan.new
      plan_b.insert_after(second, "\nqux(3)")

      expected = "baz(1)\nbar(2)\nqux(3)\n"
      assert_equal expected, plan_a.merge(plan_b).apply(source)
      assert_equal expected, plan_b.merge(plan_a).apply(source)
    end

    def test_merge_does_not_modify_original_plans_or_tree
      source = <<~RUBY
        foo(1)
        bar(2)
      RUBY

      program = SyntaxTree.parse(source)
      first, second = program.statements.body

      plan_a = EditPlan.new
      plan_a.replace(first, "baz(1)")
      plan_b = EditPlan.new
      plan_b.delete(second)

      merged = plan_a.merge(plan_b)

      assert_equal 1, plan_a.edits.length
      assert_equal 1, plan_b.edits.length
      assert_equal 2, merged.edits.length

      merged.apply(source)

      # The original tree is untouched: the same nodes still describe the
      # same ranges of the original source.
      assert_equal "foo(1)", slice(source, first)
      assert_equal "bar(2)", slice(source, second)
      assert_equal 2, program.statements.body.length
    end

    def test_parent_replacement_conflicts_with_inner_edit
      source = <<~RUBY
        if foo
          bar
        end
      RUBY

      program = SyntaxTree.parse(source)
      if_node = program.statements.body.first
      inner = if_node.statements.body.first

      outer = EditPlan.new
      outer.replace(if_node, "baz")

      inner_plan = EditPlan.new
      inner_plan.replace(inner, "qux")

      error = assert_raises(EditPlan::ConflictError) { outer.merge(inner_plan) }
      assert_match(/contains/, error.message)
      assert_raises(EditPlan::ConflictError) { inner_plan.merge(outer) }
    end

    def test_parent_delete_conflicts_with_inner_insert
      source = <<~RUBY
        if foo
          bar
        end
      RUBY

      program = SyntaxTree.parse(source)
      if_node = program.statements.body.first
      inner = if_node.statements.body.first

      outer = EditPlan.new
      outer.delete(if_node)

      inner_plan = EditPlan.new
      inner_plan.insert_before(inner, "baz\n")

      assert_raises(EditPlan::ConflictError) { outer.merge(inner_plan) }
    end

    def test_same_position_insertions_require_explicit_order
      source = "foo\n"
      program = SyntaxTree.parse(source)
      node = program.statements.body.first

      plan_a = EditPlan.new
      plan_a.insert_before(node, "a\n")
      plan_b = EditPlan.new
      plan_b.insert_before(node, "b\n")

      error = assert_raises(EditPlan::ConflictError) { plan_a.merge(plan_b) }
      assert_match(/order/, error.message)
    end

    def test_same_position_insertions_apply_in_explicit_order
      source = "foo\n"
      program = SyntaxTree.parse(source)
      node = program.statements.body.first

      plan_a = EditPlan.new
      plan_a.insert_before(node, "a\n", order: 1)
      plan_b = EditPlan.new
      plan_b.insert_before(node, "b\n", order: 2)

      assert_equal "a\nb\nfoo\n", plan_a.merge(plan_b).apply(source)
      assert_equal "a\nb\nfoo\n", plan_b.merge(plan_a).apply(source)
    end

    def test_replace_and_delete_on_same_node_conflict
      source = "foo\n"
      program = SyntaxTree.parse(source)
      node = program.statements.body.first

      plan_a = EditPlan.new
      plan_a.replace(node, "bar")
      plan_b = EditPlan.new
      plan_b.delete(node)

      assert_raises(EditPlan::ConflictError) { plan_a.merge(plan_b) }
    end

    def test_comments_on_unedited_nodes_are_preserved
      source = <<~RUBY
        foo
        # leading comment
        bar # trailing comment
      RUBY

      program = SyntaxTree.parse(source)
      foo, bar = program.statements.body

      plan = EditPlan.new
      plan.replace(foo, "baz")

      result = plan.apply(source)
      assert_equal "baz\n# leading comment\nbar # trailing comment\n", result

      # The re-parsed tree still contains the comment on its own line, and
      # the trailing comment is still attached to the untouched node.
      reparsed = SyntaxTree.parse(result)
      _baz, comment, reparsed_bar = reparsed.statements.body
      assert_kind_of Comment, comment
      assert_equal "# leading comment", comment.value
      assert_equal ["# trailing comment"], reparsed_bar.comments.map(&:value)
    end

    def test_apply_raises_when_result_does_not_parse
      source = "foo\n"
      program = SyntaxTree.parse(source)
      node = program.statements.body.first

      plan = EditPlan.new
      plan.replace(node, "end")

      assert_raises(EditPlan::InvalidResultError) { plan.apply(source) }
    end

    private

    def slice(source, node)
      location = node.location
      source[location.start_char...location.end_char]
    end
  end
end
