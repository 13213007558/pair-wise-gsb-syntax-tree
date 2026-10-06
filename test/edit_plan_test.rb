# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class EditPlanTest < Minitest::Test
    def test_independent_plans_merge_commutatively
      source = <<~RUBY
        first
        middle
        last
      RUBY

      root = parse(source)
      middle = statement_value(root, "middle")
      left_plan =
        EditPlan.new(root).insert_before(middle, statement("left\n", "left"))
      right_plan =
        EditPlan.new(root).insert_after(middle, statement("right\n", "right"))

      merged = left_plan.merge(right_plan)
      reversed = right_plan.merge(left_plan)

      assert_equal(apply(source, merged), apply(source, reversed))
      assert_equal(<<~RUBY, apply(source, merged))
        first
        left
        middle
        right
        last
      RUBY
    end

    def test_same_position_inserts_require_explicit_order
      source = "middle\n"
      root = parse(source)
      middle = statement_value(root, "middle")
      left_plan =
        EditPlan.new(root).insert_before(middle, statement("left\n", "left"))
      right_plan =
        EditPlan.new(root).insert_before(middle, statement("right\n", "right"))

      error = assert_raises(EditPlan::Conflict) { left_plan.merge(right_plan) }
      assert_match(/explicit order/, error.message)

      ordered_left =
        EditPlan.new(root).insert_before(
          middle,
          statement("left\n", "left"),
          order: 0
        )
      ordered_right =
        EditPlan.new(root).insert_before(
          middle,
          statement("right\n", "right"),
          order: 1
        )

      assert_equal(<<~RUBY, apply(source, ordered_left.merge(ordered_right)))
        left
        right
        middle
      RUBY
    end

    def test_parent_replace_conflicts_with_descendant_delete
      source = <<~RUBY
        class Example
          first
          second
        end
      RUBY

      root = SyntaxTree.parse(source)
      klass = root.statements.body.first
      second = klass.bodystmt.statements.body.last
      replacement = parse("class Changed; end\n").statements.body.first

      parent_plan = EditPlan.new(root).replace(klass, replacement)
      child_plan = EditPlan.new(root).delete(second)

      error =
        assert_raises(EditPlan::Conflict) { parent_plan.merge(child_plan) }
      assert_match(
        /replace on ancestor.*conflicts with delete on descendant/m,
        error.message
      )
    end

    def test_insert_anchor_ancestor_can_merge_with_descendant_edit
      source = <<~RUBY
        wrapper
        other
      RUBY

      root = parse(source)
      statements = root.statements
      wrapper = statement_value(root, "wrapper")
      inserted = statement("added\n", "added")

      insert_plan = EditPlan.new(root).insert_before(wrapper, inserted)
      delete_plan = EditPlan.new(root).delete(statements.body.last)
      merged = insert_plan.merge(delete_plan)

      assert_equal(<<~RUBY, apply(source, merged))
        added
        wrapper
      RUBY
    end

    def test_applies_replace_and_delete_once_without_mutating_original
      source = <<~RUBY
        first
        second
        third
      RUBY

      root = SyntaxTree.parse(source)
      first = root.statements.body.first
      second = root.statements.body[1]
      replacement = parse("changed\n").statements.body.first

      plan = EditPlan.new(root).replace(first, replacement).delete(second)
      applied = plan.apply(source)

      assert_equal(<<~RUBY, SyntaxTree.format_node(source, applied))
        changed
        third
      RUBY
      assert_equal(source, SyntaxTree.format_node(source, root))
    end

    def test_edits_bound_to_original_subtree_do_not_mutate_it
      source = "target\n"
      root = parse(source)
      target = statement_value(root, "target")
      replacement = target.copy

      plan = EditPlan.new(root).replace(target, replacement)
      plan.apply(source)

      assert_equal(1, target.location.start_line)
      assert_equal(1, replacement.location.start_line)
    end

    def test_comments_on_unchanged_nodes_are_preserved
      source = <<~RUBY
        remove
        # kept
        keep
      RUBY

      root = SyntaxTree.parse(source)
      remove = statement_value(root, "remove")
      plan = EditPlan.new(root).delete(remove)

      assert_equal(<<~RUBY, apply(source, plan))
        # kept
        keep
      RUBY
    end

    def test_attached_comment_state_is_preserved_when_tree_is_copied
      source = "value # trailing\n"
      root = parse(source)
      comment = root.statements.body.first.comments.first
      plan =
        EditPlan.new(root).insert_before(
          root.statements.body.first,
          statement("other\n", "other")
        )

      applied = plan.apply(source)

      assert_predicate(comment, :trailing?)
      assert_equal(<<~RUBY, SyntaxTree.format_node(source, applied))
        other
        value # trailing
      RUBY
    end

    private

    def parse(source)
      SyntaxTree.parse(source)
    end

    def statement(source, value = nil)
      body = parse(source).statements.body
      value ? body.find { |node| node_value(node) == value } : body.first
    end

    def statement_value(root, value)
      root.statements.body.find { |node| node_value(node) == value }
    end

    def node_value(node)
      if node.respond_to?(:value) && node.value.respond_to?(:value)
        return node.value.value
      end
      node.value if node.respond_to?(:value)
    end

    def apply(source, plan)
      SyntaxTree.format_node(source, plan.apply(source))
    end
  end
end
