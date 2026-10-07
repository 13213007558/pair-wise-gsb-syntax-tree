# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class ExtractMethodTest < Minitest::Test
    def test_extracts_statements_with_external_local
      source = <<~RUBY
        def add_one(value)
          value + 1
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "value + 1"), "calculate")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal("calculate", result.method_name)
      assert_equal(2, result.changes.length)
      assert_equal(<<~RUBY, result.new_source)
        def add_one(value)
          calculate(value)
        end

        private def calculate(value)
          value + 1
        end
      RUBY
    end

    def test_tail_expression_return_value_is_preserved
      source = <<~RUBY
        def work(value)
          value + 1
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "value + 1"), "calculate")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(41, evaluate(source, :work, 40))
      assert_equal(41, evaluate(result.new_source, :work, 40))
      assert_equal("  calculate(value)", result.new_source.lines[1].chomp)
    end

    def test_conditional_assignment_preserves_uninitialized_visible_value
      source = <<~RUBY
        def value(flag)
          if flag
            result = 1
          end
          result
        end
      RUBY

      range_start = source.index("if flag")
      range_end = source.index("end", range_start) + 3
      result = SyntaxTree.extract_method(source, range_start...range_end, "assign_result")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(%w[flag result], result.variables.map(&:name))
      assert_equal([:input, :output], result.variables.map(&:kind))
      assert_equal(1, evaluate(source, :value, true))
      assert_nil(evaluate(source, :value, false))
      assert_equal(1, evaluate(result.new_source, :value, true))
      assert_nil(evaluate(result.new_source, :value, false))
    end

    def test_synchronizes_output_when_helper_raises
      source = <<~RUBY
        def work
          result = :before
          result = :after
          raise "boom"
        rescue RuntimeError
          result
        end
      RUBY

      start = source.index("result = :after")
      finish = source.index("raise \"boom\"") + "raise \"boom\"".length
      result = SyntaxTree.extract_method(source, start...finish, "explode")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(:after, evaluate(source, :work))
      assert_equal(:after, evaluate(result.new_source, :work))
    end

    def test_tail_result_inside_rescued_method_keeps_rescue_result
      source = <<~RUBY
        def work
          result = :before
          result = :after
          raise "boom"
        rescue RuntimeError
          result
        end
      RUBY

      start = source.index("result = :after")
      finish = source.index("raise \"boom\"") + "raise \"boom\"".length
      result = SyntaxTree.extract_method(source, start...finish, "explode")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(:after, evaluate(source, :work))
      assert_equal(:after, evaluate(result.new_source, :work))
    end

    def test_rescue_clause_tail_expression_is_preserved
      source = <<~RUBY
        def work
          raise "boom"
        rescue RuntimeError
          42
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "42"), "rescue_value")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(42, evaluate(source, :work))
      assert_equal(42, evaluate(result.new_source, :work))
    end

    def test_complete_begin_expression_can_be_moved
      source = <<~RUBY
        def work
          begin
            raise "boom"
          rescue RuntimeError
            42
          end
        end
      RUBY

      range_start = source.index("begin")
      range_end = source.index("end", range_start) + 3
      result = SyntaxTree.extract_method(source, range_start...range_end, "guarded")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(42, evaluate(source, :work))
      assert_equal(42, evaluate(result.new_source, :work))
    end

    def test_multiple_assignment_returns_all_live_values
      source = <<~RUBY
        def work
          left, right = pair
          [left, right]
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "left, right = pair"), "assign_pair")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(%w[left right], result.variables.map(&:name))
      assert(result.variables.all?(&:output?))
      assert_includes(result.new_source, "left, right = __syntax_tree_extract_state[:left], __syntax_tree_extract_state[:right]")
    end

    def test_preserves_evaluation_count_of_arguments_and_receivers
      source = <<~RUBY
        def work(receiver, argument)
          receiver.side_effect(argument.side_effect(:argument), :receiver)
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "receiver.side_effect(argument.side_effect(:argument), :receiver)"), "call_side_effect")
      assert_kind_of(ExtractMethod::Plan, result)

      assert_equal(evaluation_log(source), evaluation_log(result.new_source))
    end

    def test_preserves_evaluation_count_when_assignment_output_is_synchronized
      source = <<~RUBY
        def work(receiver, argument)
          result = receiver.side_effect(argument.side_effect(:argument), :receiver)
          result
        end
      RUBY

      range_start = source.index("result = receiver")
      range_end = source.index("result", range_start + 1) + 6
      result = SyntaxTree.extract_method(source, range_start...range_end, "call_side_effect")

      assert_kind_of(ExtractMethod::Plan, result)
      assert_equal(evaluation_log(source), evaluation_log(result.new_source))
    end

    def test_rejects_incomplete_statement_selection_with_location
      source = <<~RUBY
        def work
          receiver.side_effect
        end
      RUBY

      start = source.index("receiver")
      result = SyntaxTree.extract_method(source, start...(start + 4), "extracted")

      assert_kind_of(ExtractMethod::Rejection, result)
      assert_equal(:incomplete_syntax_selection, result.reason)
      assert_equal(2, result.locations.first.start_line)
    end

    def test_rejects_crossing_rescue_boundary
      source = <<~RUBY
        def work
          before
          raise "boom"
        rescue RuntimeError
          after
        end
      RUBY

      range = source.index("before")...(source.index("after") + "after".length)
      result = SyntaxTree.extract_method(source, range, "extracted")

      assert_kind_of(ExtractMethod::Rejection, result)
      assert_equal(:rescue_boundary, result.reason)
      refute_empty(result.locations)
    end

    def test_rejects_return_break_and_yield_ownership_changes
      source = <<~RUBY
        def work
          return 1
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "return 1"), "early_return")

      assert_kind_of(ExtractMethod::Rejection, result)
      assert_equal(:control_flow_ownership, result.reason)
    end

    def test_rejects_unsafe_binding_dependency
      source = <<~RUBY
        def work
          eval("1 + 1")
        end
      RUBY

      result = SyntaxTree.extract_method(source, selection(source, "eval(\"1 + 1\")"), "dynamic_work")

      assert_kind_of(ExtractMethod::Rejection, result)
      assert_equal(:unsafe_dynamic_dependency, result.reason)
      assert_equal(2, result.locations.first.start_line)
    end

    private

    def selection(source, snippet)
      match = source.match(Regexp.new(Regexp.escape(snippet).sub(/\A\\s\+/, "\\s*")))
      start = source.index(/\S/, source.index(snippet.lines.first.strip))
      last = snippet.lines.last.strip
      finish = source.index(last, start) + last.length
      start...finish
    end

    def evaluate(source, method_name = :value, argument = :__none__)
      Object.class_eval(source)
      object = Object.new
      argument == :__none__ ? object.send(method_name) : object.send(method_name, argument)
    rescue StandardError
      raise unless source.match?(/def value/)
    end

    def evaluation_log(source)
      evaluated = Class.new do
        def initialize
          @log = []
        end

        attr_reader :log

        def side_effect(label, value = nil)
          @log << [label, value]
          label
        end
      end

      receiver = evaluated.new
      argument = evaluated.new
      Object.class_eval(source)
      Object.new.send(:work, receiver, argument)
      [receiver.log, argument.log]
    ensure
      Object.send(:remove_method, :work) rescue nil
    end
  end
end
