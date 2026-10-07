# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class ExtractMethodTest < Minitest::Test
    def test_extracts_locals_and_preserves_behavior_and_side_effects
      source = <<~RUBY
        def calculate(values)
          total = 0
          values.each do |value|
            total += value
            $extract_method_events << [:value, value]
          end
          total
        end
      RUBY

      before = behavior(source, :calculate, [1, 2, 3])
      result = SyntaxTree.extract_method(source, start_line: 2, end_line: 6)
      after = behavior(result.source, :calculate, [1, 2, 3])

      assert_equal(before.return_value, after.return_value)
      assert_equal(before.events, after.events)
      refute_equal(SyntaxTree.format(source), SyntaxTree.format(result.source))
    end

    def test_plan_reports_block_parameters_and_block_locals
      source = <<~RUBY
        def calculate(values, memo)
          values.each do |value; temporary|
            temporary = value * 2
            memo << temporary
            $extract_method_events << temporary
          end
          memo
        end
      RUBY

      plan = SyntaxTree.extract_method_analysis(source, start_line: 3, end_line: 4)

      assert_equal(%w[memo value], plan.parameters.map(&:name))
      assert_equal(%i[parameter parameter], plan.parameters.map(&:kind))
      assert_equal(
        %w[__syntax_tree_extract_result__ temporary],
        plan.return_values.map(&:name)
      )
      assert_predicate(plan, :safe?)

      before = behavior(source, :calculate, [1, 2, 3], [])
      after = behavior(
        SyntaxTree.extract_method(source, start_line: 3, end_line: 4).source,
        :calculate,
        [1, 2, 3],
        []
      )

      assert_equal(before.return_value, after.return_value)
      assert_equal(before.events, after.events)
    end

    def test_returns_multiple_values_in_fixed_order
      source = <<~RUBY
        def calculate
          left = 1
          right = 2
          left += 1
          right += 2
          $extract_method_events << [left, right]
          [left, right]
        end
      RUBY

      plan = SyntaxTree.extract_method_analysis(source, start_line: 2, end_line: 5)

      assert_equal(
        %w[__syntax_tree_extract_result__ left right],
        plan.return_values.map(&:name)
      )

      before = behavior(source, :calculate)
      after = behavior(
        SyntaxTree.extract_method(source, start_line: 2, end_line: 5).source,
        :calculate
      )

      assert_equal(before.return_value, after.return_value)
      assert_equal(before.events, after.events)
    end

    def test_rejects_return_that_escapes_selected_region
      source = <<~RUBY
        def calculate(values)
          values.each do |value|
            return value if value.positive?
          end
          0
        end
      RUBY

      plan = SyntaxTree.extract_method_analysis(source, start_line: 3, end_line: 3)

      assert_equal(:return, plan.unsafe_control_flow.first.type)
      refute_predicate(plan, :safe?)
      assert_raises(ExtractMethod::InvalidExtraction) do
        SyntaxTree.extract_method(source, start_line: 3, end_line: 3)
      end
    end

    def test_rejects_break_that_escapes_selected_block_body
      source = <<~RUBY
        def calculate(values)
          values.each do |value|
            break if value.positive?
          end
          0
        end
      RUBY

      plan = SyntaxTree.extract_method_analysis(source, start_line: 3, end_line: 3)

      assert_equal(:break, plan.unsafe_control_flow.first.type)
      refute_predicate(plan, :safe?)
    end

    def test_rejects_escaping_closure_capturing_selected_locals
      source = <<~RUBY
        def calculate(base)
          increment = -> { base + 1 }
          increment.call
        end
      RUBY

      plan = SyntaxTree.extract_method_analysis(source, start_line: 2, end_line: 2)

      assert_equal(:closure_capture, plan.unsafe_closures.first.type)
      assert_equal(%w[base], plan.parameters.map(&:name))
      assert_equal(%w[increment], plan.return_values.map(&:name).drop(1))
      refute_predicate(plan, :safe?)
    end

    private

    Observed = Struct.new(:return_value, :events)

    def behavior(source, method_name, *arguments)
      mod = Module.new
      mod.module_eval(source)
      object = Object.new.extend(mod)

      $extract_method_events = []
      return_value = object.public_send(method_name, *arguments)
      Observed.new(return_value, $extract_method_events.dup)
    end
  end
end
