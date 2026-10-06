# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/syntax_tree/safe_navigation"

module SyntaxTree
  class SafeNavigationTest < Minitest::Test
    class CallTarget
      attr_reader :value, :calls, :setters

      def initialize(value = nil)
        @value = value
        @calls = 0
        @setters = []
      end

      def value=(value)
        @setters << value
        @value = value
      end

      def ping(argument = nil)
        @calls += 1
        argument || :pong
      end

      def with_block(argument = nil, &block)
        @calls += 1
        block.call(argument)
      end

      def child
        @calls += 1
        self
      end

      def raise!(_argument = nil)
        raise "argument was evaluated"
      end
    end

    class RaisingReceiver
      def self.calls
        @calls ||= 0
      end

      def self.value
        @calls = calls + 1
        raise "receiver raised"
      end

      def self.reset
        @calls = 0
      end
    end

    def test_chain_calls_receiver_once_and_keeps_false_working
      receiver = CallTarget.new(7)
      receiver_count = 0
      _make_receiver = -> do
        receiver_count += 1
        receiver
      end

      result = transform_and_eval("_make_receiver.call&.value.succ", binding)

      assert_equal(8, result)
      assert_equal(1, receiver_count)
      assert_equal(0, receiver.calls)
      assert_equal("false", transform_and_eval("false&.to_s", binding))
    end

    def test_basic_object_receiver_does_not_require_nil_predicate
      _receiver = BasicObject.new

      result = transform_and_eval("_receiver&.equal?(_receiver)", binding)

      assert_equal(true, result)
    end

    def test_nil_returns_nil_without_evaluating_arguments_or_blocks
      _receiver = nil
      arguments = []

      result =
        transform_and_eval(
          "_receiver&.ping(arguments << :argument) { arguments << :block }",
          binding
        )

      assert_nil(result)
      assert_empty(arguments)
    end

    def test_non_nil_evaluates_arguments_and_raises_argument_exceptions
      receiver = CallTarget.new

      assert_raises(RuntimeError, match: "argument was evaluated") do
        transform_and_eval(
          "receiver&.raise!(raise 'argument was evaluated')",
          binding
        )
      end

      assert_equal(0, receiver.calls)
    end

    def test_false_still_invokes_arguments
      arguments = []

      result =
        transform_and_eval(
          "false&.respond_to?(:to_s, arguments << :argument)",
          binding
        )

      assert_equal(true, result)
      assert_equal([:argument], arguments)
    end

    def test_block_call_is_guarded_and_receiver_is_evaluated_once
      receiver = CallTarget.new
      receiver_counts = { calls: 0 }

      result = transform_and_eval(<<~RUBY, binding)
          receiver&.with_block(:value) do |value|
            receiver_counts[:calls] += 1
            [value, receiver.calls]
          end
        RUBY

      assert_equal([:value, 1], result)
      assert_equal(1, receiver.calls)
      assert_equal(1, receiver_counts[:calls])
    end

    def test_raising_receiver_is_evaluated_once
      RaisingReceiver.reset

      error =
        assert_raises(RuntimeError) do
          transform_and_eval("RaisingReceiver&.value.ignored", binding)
        end

      assert_equal("receiver raised", error.message)
      assert_equal(1, RaisingReceiver.calls)
    end

    def test_setter_and_compound_assignment
      receiver = CallTarget.new(10)

      assert_equal(11, transform_and_eval("receiver&.value += 1", binding))
      assert_equal(11, receiver.value)
      assert_equal([11], receiver.setters)
      assert_nil(transform_and_eval("nil&.not_a_real_setter = 99", binding))
      def false.transformed_safe_navigation_setter=(value)
        value
      end
      assert_equal(
        99,
        transform_and_eval(
          "false&.transformed_safe_navigation_setter = 99",
          binding
        )
      )
    end

    def test_nil_setter_does_not_evaluate_rhs_or_call_setter
      _receiver = nil
      side_effects = []

      result =
        transform_and_eval(
          "_receiver&.value = (side_effects << :assigned; 1)",
          binding
        )

      assert_nil(result)
      assert_empty(side_effects)
    end

    def test_supported_compound_assignment_operators
      receiver = CallTarget.new(nil)

      assert_equal(42, transform_and_eval("receiver&.value ||= 42", binding))
      assert_equal(99, transform_and_eval("receiver&.value &&= 99", binding))
      assert_equal(99, receiver.value)

      receiver.value = false
      assert_nil(transform_and_eval("receiver&.value &&= 99", binding))
      assert_equal(false, receiver.value)
    end

    def test_temporary_variables_avoid_locals_and_closure_bindings
      _syntax_tree_safe_navigation_0 = :local
      transformed = transform("_syntax_tree_safe_navigation_0&.child")

      refute_includes(transformed, "_syntax_tree_safe_navigation_0 =")

      result =
        transform_and_eval(
          "1.tap { |_syntax_tree_safe_navigation_1| " \
            "_syntax_tree_safe_navigation_1 }",
          binding
        )

      assert_equal(1, result)
    end

    def test_unsupported_safe_navigation_in_multiple_assignment_target
      error =
        assert_raises(SafeNavigation::UnsupportedSyntax) do
          transform("a, b&.c = values")
        end

      assert_match("multiple assignment", error.message)
    end

    def test_unsupported_block_attached_to_indexed_continuation
      error =
        assert_raises(SafeNavigation::UnsupportedSyntax) do
          transform("receiver&.value[1] {}")
        end

      assert_match("indexed safe-navigation continuations", error.message)
    end

    private

    def transform(source)
      tree = SafeNavigation.transform(SyntaxTree.parse(source))
      output = SyntaxTree.format_node(source, tree)
      refute_includes(JSON.parse(tree.to_json).to_s, "&.")
      output
    end

    def transform_and_eval(source, context)
      transformed = transform(source)
      refute_includes(transformed, "&.")
      context.eval(transformed) # rubocop:disable Security/Eval
    end
  end
end
