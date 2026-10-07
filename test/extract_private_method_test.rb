# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class ExtractPrivateMethodTest < Minitest::Test
    def test_extracts_statement_with_arguments
      source = <<~RUBY
        def total(items)
          amount = items.sum
          amount
        end
      RUBY
      plan = extract(source, "amount = items.sum", "calculate")

      assert plan.accepted?
      assert_equal(%w[items], plan.arguments)
      assert_equal(%w[amount], plan.returned_variables)
      assert_behavior(source, plan.updated_source) { |example| example.total([1, 2, 3]) }
    end

    def test_returns_value_used_after_selection
      source = <<~RUBY
        def total(items)
          amount = items.sum
          amount
        end
      RUBY
      plan = extract(source, "amount = items.sum", "calculate")

      refute_match(/^\s+amount = items\.sum/, plan.updated_source)
      assert_includes(plan.updated_source, "private def calculate(items, amount: nil)")
      assert_equal(%w[amount], plan.returned_variables)
      assert_behavior(source, plan.updated_source) { |example| example.total([1, 2, 3]) }
    end

    def test_conditional_assignment_preserves_undefined_value
      source = <<~RUBY
        def value(flag)
          if flag
            result = 42
          end
          [defined?(result), result]
        end
      RUBY
      start_char = source.index("if flag")
      end_char = source.index("\n  [defined?")
      plan = SyntaxTree.extract_private_method(source, start_char...end_char, "assign")

      assert plan.accepted?, plan.reason
      assert_behavior(source, plan.updated_source) { |example| example.value(false) }
      assert_behavior(source, plan.updated_source) { |example| example.value(true) }
    end

    def test_multiple_assignment_returns_every_output
      source = <<~RUBY
        def split(flag, pair)
          if flag
            left, right = pair
          end
          [left, right]
        end
      RUBY
      start_char = source.index("if flag")
      end_char = source.index("\n  [left")
      plan = SyntaxTree.extract_private_method(source, start_char...end_char, "divide")

      assert plan.accepted?, plan.reason
      assert_equal(%w[left right], plan.returned_variables)
      assert_behavior(source, plan.updated_source) { |example| example.split(false, [1, 2]) }
      assert_behavior(source, plan.updated_source) { |example| example.split(true, [1, 2]) }
    end

    def test_receivers_and_arguments_are_evaluated_once
      source = <<~RUBY
        def value(receiver, argument)
          result = receiver.transform(argument)
          result
        end
      RUBY
      plan = extract(source, "result = receiver.transform(argument)", "transform")

      assert plan.accepted?, plan.reason

      calls = []
      receiver = Object.new
      receiver.define_singleton_method(:transform) do |value|
        calls << :transform
        value
      end
      argument = Object.new.tap { calls << :argument }
      result = nil
      example = sandbox(plan.updated_source)
      result = example.value(receiver, argument)

      assert_equal(1, calls.count(:transform))
      assert_equal(argument, result)
    end

    def test_exception_propagates_from_helper
      source = <<~RUBY
        def value
          result = raise(StandardError, "boom")
          result
        end
      RUBY
      plan = extract(source, "result = raise(StandardError, \"boom\")", "calculate")

      assert plan.accepted?, plan.reason
      example = sandbox(plan.updated_source)
      assert_raises(StandardError, match: "boom") { example.value }
    end

    def test_rejects_incomplete_syntax_selection
      source = <<~RUBY
        def value
          result = 1
        end
      RUBY
      start_char = source.index("result =")
      plan = SyntaxTree.extract_private_method(source, start_char...(start_char + 7), "helper")

      assert plan.rejected?
      assert_equal("selection does not contain complete syntax nodes", plan.reason)
      assert_equal(start_char, plan.location[:start_char])
    end

    def test_rejects_return
      assert_rejects(
        <<~RUBY,
          def value
            result = 1
            return result
          end
        RUBY
        "result = 1\n  return result",
        "selection changes the owner of control flow or yield"
      )
    end

    def test_rejects_yield
      assert_rejects(
        <<~RUBY,
          def value
            result = yield
            result
          end
        RUBY
        "result = yield\n  result",
        "selection changes the owner of control flow or yield"
      )
    end

    def test_rejects_break
      assert_rejects(
        <<~RUBY,
          def value(items)
            items.each do |item|
              break if item
            end
          end
        RUBY
        "break if item",
        "selection changes the owner of control flow or yield"
      )
    end

    def test_rejects_rescue_boundary
      source = <<~RUBY
        def value
          begin
            result = 1
          rescue StandardError
            error = 2
          end
          [result, error]
        end
      RUBY
      start_char = source.index("result = 1")
      end_char = source.index("error = 2") + "error = 2".length
      plan = SyntaxTree.extract_private_method(source, start_char...end_char, "helper")

      assert plan.rejected?
      assert_equal("selection crosses a rescue or ensure boundary", plan.reason)
      assert(plan.location[:start_char] <= source.index("rescue"))
    end

    def test_rejects_ensure_boundary
      source = <<~RUBY
        def value
          begin
            result = 1
          ensure
            cleanup
          end
          result
        end
      RUBY
      start_char = source.index("result = 1")
      end_char = source.index("cleanup") + "cleanup".length
      plan = SyntaxTree.extract_private_method(source, start_char...end_char, "helper")

      assert plan.rejected?
      assert_equal("selection crosses a rescue or ensure boundary", plan.reason)
    end

    def test_rejects_binding_dependency
      assert_rejects(
        <<~RUBY,
          def value
            binding.local_variable_get(:result)
          end
        RUBY
        "binding.local_variable_get(:result)",
        "selection depends on scope that cannot be safely moved"
      )
    end

    def test_rejects_eval_dependency
      assert_rejects(
        <<~RUBY,
          def value
            eval("1 + 1")
          end
        RUBY
        'eval("1 + 1")',
        "selection depends on scope that cannot be safely moved"
      )
    end

    def test_passes_explicit_block_argument
      source = <<~RUBY
        def total(items, &block)
          items.map(&block)
        end
      RUBY
      plan = extract(source, "items.map(&block)", "map_items")

      assert(plan.accepted?, plan.inspect)
      assert_equal(%w[items block], plan.arguments)
      assert_includes(plan.updated_source, "private def map_items(items, &block)")
      assert_includes(plan.updated_source, "__send__(:map_items, items, &block)")

      example = sandbox(plan.updated_source)
      block = ->(item) { item + 1 }
      assert_equal([2, 3], example.total([1, 2], &block))
    end

    def test_preserves_keyword_and_rest_arguments
      source = <<~RUBY
        def total(*items, label:, **options)
          calculate(items, label, options)
        end
      RUBY
      plan = extract(source, "calculate(items, label, options)", "calculate_items")

      assert(plan.accepted?, plan.inspect)
      assert_includes(plan.updated_source, "private def calculate_items(*items, label:, **options)")
      assert_includes(
        plan.updated_source,
        "__send__(:calculate_items, items, label: label, **options)"
      )
    end

    private

    def extract(source, selected, name)
      start_char = source.index(selected)
      SyntaxTree.extract_private_method(
        source,
        start_char...(start_char + selected.length),
        name
      )
    end

    def assert_rejects(source, selected, reason)
      start_char = source.index(selected)
      plan = SyntaxTree.extract_private_method(
        source,
        start_char...(start_char + selected.length),
        "helper"
      )

      assert(plan.rejected?, plan.inspect)
      assert_equal(reason, plan.reason)
      assert(plan.location[:start_char])
    end

    def assert_behavior(source, updated)
      original = sandbox(source)
      transformed = sandbox(updated)
      assert_equal(yield(original), yield(transformed))
    end

    def sandbox(source)
      name = "ExtractExample#{object_id}_#{@sandbox_index = (@sandbox_index || 0) + 1}"
      Object.class_eval("class #{name}; #{source}; end")
      Object.const_get(name).new
    end
  end
end
