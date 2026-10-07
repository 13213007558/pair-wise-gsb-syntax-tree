# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class ExtractMethodTest < Minitest::Test
    def test_plan_computes_params_and_returns
      source = <<~RUBY
        def compute(price, count, log)
          subtotal = price * count
          log << subtotal
          tax = (subtotal * 0.1).round
          log << tax
          grand = subtotal + tax
          log << grand
          grand
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 5)

      assert_predicate plan, :safe?
      assert_empty plan.problems
      assert_equal %i[price count log], plan.params
      assert_equal %i[subtotal tax], plan.returns
      assert_equal "  subtotal = price * count\n",
                   plan.selected_source.lines.first
    end

    def test_return_order_is_fixed_by_first_assignment
      source = <<~RUBY
        def pair(input)
          zeta = input + 1
          alpha = zeta + 1
          [alpha, zeta]
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 3)

      assert_equal %i[zeta alpha], plan.returns
    end

    def test_param_order_is_fixed_by_first_read
      source = <<~RUBY
        def combine(beta, alpha)
          gamma = alpha + beta
          gamma
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 2)

      assert_equal %i[alpha beta], plan.params
    end

    def test_block_scope_passes_block_params_as_params
      source = <<~RUBY
        def collect(items, log)
          items.each do |item|
            doubled = item * 2
            log << doubled
          end
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 4)

      assert_predicate plan, :safe?
      assert_equal %i[item log], plan.params
      assert_empty plan.returns
    end

    def test_local_assigned_before_selection_is_a_param
      source = <<~RUBY
        def compute(base)
          factor = base * 2
          result = factor + 1
          result
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 3)

      assert_equal %i[factor], plan.params
      assert_equal %i[result], plan.returns
    end

    def test_local_assigned_inside_before_use_is_not_a_param
      source = <<~RUBY
        def compute(base)
          factor = base * 2
          factor += 1
          factor
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 3)

      assert_equal %i[base], plan.params
      assert_equal %i[factor], plan.returns
    end

    def test_selection_must_align_to_whole_statements
      source = "def a\n  b = 1\n  c = 2\nend\n"

      assert_raises(ExtractMethod::SelectionError) do
        ExtractMethod.plan(source, 3, 4)
      end
    end

    def test_return_inside_selection_is_unsafe
      source = <<~RUBY
        def find_it(items)
          items.each do |item|
            return item if item > 1
          end
          nil
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 3)

      refute_predicate plan, :safe?
      assert_equal %i[return_escape], plan.problems.map(&:kind)
      assert_raises(ExtractMethod::UnsafeError) { plan.apply(:extracted) }
    end

    def test_break_escaping_selection_is_unsafe
      source = <<~RUBY
        def walk(items, log)
          items.each do |item|
            log << item
            break if item > 2
          end
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 4)

      assert_equal %i[break_escape], plan.problems.map(&:kind)
    end

    def test_next_escaping_selection_is_unsafe
      source = <<~RUBY
        def walk(items, log)
          items.each do |item|
            next if item.nil?
            log << item
          end
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 3)

      assert_equal %i[next_escape], plan.problems.map(&:kind)
    end

    def test_break_inside_included_loop_is_safe
      source = <<~RUBY
        def walk(items, log)
          items.each do |item|
            log << item
            break if item > 2
          end
          log
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 5)

      assert_predicate plan, :safe?
    end

    def test_retry_inside_included_begin_is_safe
      source = <<~RUBY
        def fetch(attempts)
          begin
            attempts -= 1
            raise "boom" if attempts > 1
          rescue
            retry if attempts > 0
          end
          attempts
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 7)

      assert_predicate plan, :safe?
    end

    def test_closure_write_read_after_selection_is_unsafe
      source = <<~RUBY
        def accumulate(items)
          total = 0
          items.each { |item| total += item }
          total
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 3)

      refute_predicate plan, :safe?
      assert_equal %i[closure_capture], plan.problems.map(&:kind)
    end

    def test_closure_read_of_later_assignment_is_unsafe
      source = <<~RUBY
        def build(flag)
          handler = -> { flag }
          flag = !flag
          handler.call
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 2)

      assert_equal %i[closure_capture], plan.problems.map(&:kind)
    end

    def test_outer_closure_writing_extracted_variable_is_unsafe
      source = <<~RUBY
        def counter
          count = 0
          increment = -> { count += 1 }
          increment.call
          count
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 2)

      assert_equal %i[closure_capture], plan.problems.map(&:kind)
    end

    def test_implicit_block_value_with_returns_is_unsafe
      source = <<~RUBY
        def compute(a, log)
          result = [a].map do |x|
            b = x * 2
            b + 1
          end
          log << b
          result
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 4)

      refute_predicate plan, :safe?
      assert_includes plan.problems.map(&:kind), :implicit_return
    end
  end
end

module SyntaxTree
  class ExtractMethodBehaviorTest < Minitest::Test
    def test_apply_generates_fixed_multi_return_order
      source = <<~RUBY
        def pair(input)
          zeta = input + 1
          alpha = zeta + 1
          [alpha, zeta]
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 3)
      extracted = plan.apply(:build_pair)

      assert_includes extracted, "zeta, alpha = build_pair(input)"
      assert_includes extracted, "[zeta, alpha]"

      invocation = "pair(5)"
      assert_equal evaluate(source, invocation), evaluate(extracted, invocation)
    end

    def test_apply_preserves_return_values_and_side_effects
      source = <<~RUBY
        def compute(price, count, log)
          subtotal = price * count
          log << subtotal
          tax = (subtotal * 0.1).round
          log << tax
          grand = subtotal + tax
          log << grand
          grand
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 5)
      assert_predicate plan, :safe?

      extracted = plan.apply(:calculate)

      assert_includes extracted, "subtotal, tax = calculate(price, count, log)"
      assert_match(/^def calculate\(price, count, log\)$/, extracted)
      assert_includes extracted, "[subtotal, tax]"

      [[10, 3], [7, 2], [0, 5]].each do |price, count|
        invocation = "log = []; [compute(#{price}, #{count}, log), log]"
        assert_equal evaluate(source, invocation),
                     evaluate(extracted, invocation)
      end

      assert_equal [33, [30, 3, 33]],
                   evaluate(extracted, "log = []; [compute(10, 3, log), log]")
    end

    def test_apply_inside_block_scope_preserves_behavior
      source = <<~RUBY
        def collect(items, log)
          items.each do |item|
            doubled = item * 2
            log << doubled
            doubled
          end
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 5)
      assert_predicate plan, :safe?
      assert_equal %i[item log], plan.params

      extracted = plan.apply(:process)

      invocation = "log = []; [collect([1, 2, 3], log), log]"
      assert_equal evaluate(source, invocation), evaluate(extracted, invocation)
      assert_equal [[1, 2, 3], [2, 4, 6]], evaluate(extracted, invocation)
    end

    def test_apply_preserves_block_value
      source = <<~RUBY
        def clamp_all(values, log)
          values.map do |value|
            clamped = value < 0 ? 0 : value
            log << clamped
            clamped
          end
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 5)
      assert_predicate plan, :safe?

      extracted = plan.apply(:clamp_one)

      invocation = "log = []; [clamp_all([-1, 2, -3, 4], log), log]"
      assert_equal evaluate(source, invocation), evaluate(extracted, invocation)
      assert_equal [[0, 2, 0, 4], [0, 2, 0, 4]], evaluate(extracted, invocation)
    end

    def test_apply_preserves_while_loop_with_break
      source = <<~RUBY
        def countdown(n, log)
          while n > 0
            log << n
            break if n == 2
            n -= 1
          end
          n
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 6)
      assert_predicate plan, :safe?
      assert_equal %i[n log], plan.params
      assert_equal %i[n], plan.returns

      extracted = plan.apply(:loop_down)

      invocation = "log = []; [countdown(5, log), log]"
      assert_equal evaluate(source, invocation), evaluate(extracted, invocation)
      assert_equal [2, [5, 4, 3, 2]], evaluate(extracted, invocation)
    end

    def test_apply_allows_closures_reading_stable_variables
      source = <<~RUBY
        def scale(values, factor)
          values.map { |value| value * factor }
        end
      RUBY

      plan = ExtractMethod.plan(source, 2, 2)
      assert_predicate plan, :safe?

      extracted = plan.apply(:scale_each)

      invocation = "scale([1, -2, 3], 2)"
      assert_equal evaluate(source, invocation), evaluate(extracted, invocation)
      assert_equal [2, -4, 6], evaluate(extracted, invocation)
    end

    def test_apply_at_top_level
      source = <<~RUBY
        log = []
        a = 1
        b = a + 1
        log << b
        c = b * 2
        log << c
        c
      RUBY

      plan = ExtractMethod.plan(source, 3, 5)
      assert_predicate plan, :safe?
      assert_equal %i[a log], plan.params
      assert_equal %i[c], plan.returns

      extracted = plan.apply(:compute)
      assert_match(/^def compute\(a, log\)/, extracted)

      before = Object.new.instance_eval("#{source}[log, c]")
      after = Object.new.instance_eval("#{extracted}[log, c]")
      assert_equal before, after
      assert_equal [[2, 4], 4], after
    end

    def test_apply_inside_class_inserts_sibling_method
      source = <<~RUBY
        class Calculator
          def compute(a, log)
            b = a * 2
            log << b
            b
          end
        end
      RUBY

      plan = ExtractMethod.plan(source, 3, 4)
      assert_predicate plan, :safe?

      extracted = plan.apply(:double_it)
      assert_match(/^  def double_it\(a, log\)$/, extracted)

      invocation = "log = []; [Calculator.new.compute(3, log), log]"
      assert_equal evaluate(source, invocation), evaluate(extracted, invocation)
      assert_equal [6, [6]], evaluate(extracted, invocation)
    end

    def test_apply_rejects_invalid_method_name
      source = "def a\n  b = 1\n  b\nend\n"
      plan = ExtractMethod.plan(source, 2, 2)

      assert_raises(ArgumentError) { plan.apply(:"not valid!") }
    end

    def test_problems_are_reviewable
      source = <<~RUBY
        def find_it(items)
          items.each do |item|
            return item if item > 1
          end
          nil
        end
      RUBY

      problem = ExtractMethod.plan(source, 3, 3).problems.first

      assert_equal :return_escape, problem.kind
      assert_equal 3, problem.line
      assert_includes problem.message, "return"
    end

    private

    def evaluate(source, invocation)
      context = Object.new
      context.instance_eval(source)
      context.instance_eval(invocation)
    end
  end
end
