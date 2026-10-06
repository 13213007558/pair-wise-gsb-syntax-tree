# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class SafeNavigationTest < Minitest::Test
    class Explosion < StandardError
    end

    class Recorder
      def initialize(value = nil)
        @value = value
      end

      def self.build(value = nil)
        $safe_navigation_receivers << nil
        new(value)
      end

      def get
        $safe_navigation_events << :get
        @value
      end

      def set(value)
        $safe_navigation_events << :set
        @value = value
      end
      alias value= set

      def exploding_setter=(_value)
        raise Explosion, "setter"
      end

      def value
        $safe_navigation_events << :get
        @value
      end

      def call(*arguments, &block)
        $safe_navigation_events << [:call, arguments, block_given?]
        block ? block.call(self) : @value
      end
    end

    def test_chained_safe_navigation_evaluates_receiver_once
      assert_equivalent(<<~RUBY)
        Recorder.build(Recorder.new(Recorder.new(:ok)))&.get&.get&.get
      RUBY
    end

    def test_arguments_are_not_evaluated_when_receiver_is_nil
      assert_equivalent(<<~RUBY)
        Recorder.new(nil)&.call(bomb(:argument))
      RUBY
    end

    def test_block_is_not_called_when_receiver_is_nil
      assert_equivalent(<<~RUBY)
        Recorder.new(nil)&.call { bomb(:block) }
      RUBY
    end

    def test_block_argument_is_not_evaluated_when_receiver_is_nil
      assert_equivalent(<<~RUBY)
        Recorder.new(nil)&.call(1, &bomb_block)
      RUBY
    end

    def test_false_receiver_still_invokes_method
      assert_equivalent(<<~RUBY)
        false&.then { |value| value }
      RUBY
    end

    def test_command_call_arguments_and_block
      assert_equivalent(<<~RUBY)
        Recorder.new(:ok)&.call(1) { |recorder| recorder.get }
      RUBY
    end

    def test_setter_does_not_evaluate_rhs_for_nil
      assert_equivalent(<<~RUBY)
        Recorder.new(nil)&.value = bomb(:setter_rhs)
      RUBY
    end

    def test_setter_evaluates_receiver_once_and_calls_setter
      assert_equivalent(<<~RUBY)
        Recorder.build(:old)&.value = :new
      RUBY
    end

    def test_false_receiver_still_invokes_setter
      assert_equivalent(<<~RUBY)
        false&.itself = true
      RUBY
    end

    def test_setter_exception_propagates
      assert_equivalent(<<~RUBY)
        Recorder.new(:ok)&.exploding_setter = true
      RUBY
    end

    def test_chained_setter_guards_outer_receiver
      assert_equivalent(<<~RUBY)
        Recorder.build(nil)&.get&.value = bomb(:chained_rhs)
      RUBY
    end

    def test_chained_compound_assignment_guards_outer_receiver
      assert_equivalent(<<~RUBY)
        Recorder.build(Recorder.new(2))&.get&.value += 3
      RUBY
    end

    def test_supported_compound_assignments
      operators = %w[+= -= *= /= %= **= |= &= ^= <<= >>= ||= &&=]
      operators.each do |operator|
        initial = operator == "<<=" ? "\"ab\"" : "2"
        source = <<~RUBY
          recorder = Recorder.build(#{initial})
          recorder&.value #{operator} 3
        RUBY

        assert_equivalent(source, operator)
      end
    end

    def test_or_compound_assignment_skips_rhs_when_present
      assert_equivalent(<<~RUBY)
        recorder = Recorder.build(:present)
        recorder&.value ||= bomb(:or_rhs)
      RUBY
    end

    def test_and_compound_assignment_skips_rhs_when_absent
      assert_equivalent(<<~RUBY)
        recorder = Recorder.build(nil)
        recorder&.value &&= bomb(:and_rhs)
      RUBY
    end

    def test_throwing_receiver_is_evaluated_exactly_once
      assert_equivalent(<<~RUBY)
        throwing_receiver.call&.value
      RUBY
    end

    def test_temporary_name_avoids_locals_and_block_bindings
      source = <<~RUBY
        _safe_navigation_receiver = :local
        _safe_navigation_receiver_1 = :other
        [1].each do |_safe_navigation_receiver_2|
          Recorder.build(:ok)&.get
        end
        [_safe_navigation_receiver, _safe_navigation_receiver_1]
      RUBY

      assert_equivalent(source)
    end

    def test_unsafe_multiple_assignment_is_rejected
      source = "recorder&.value, other = 1, 2"
      error =
        assert_raises(SafeNavigation::UnsupportedSyntax) do
          transform_source(source)
        end

      assert_match(/multiple assignment/, error.message)
    end

    def test_structured_rewrite_uses_nil_check_and_plain_call
      transformed = transform_source("foo&.bar(1)")

      refute_includes(transformed, "&.")
      assert_includes(transformed, ".nil?")
      assert_includes(transformed, "_safe_navigation_receiver.bar(1)")
    end

    def test_structured_rewrite_keeps_block_inside_guarded_branch
      program = SyntaxTree::SafeNavigation.transform(
        SyntaxTree.parse("foo&.bar { |value| value }")
      )
      if_op = program.statements.body.first.contents
      truthy = if_op.truthy

      assert_kind_of(MethodAddBlock, truthy)
      assert_equal("bar", truthy.call.message.value)
    end

    private

    def assert_equivalent(source, *label)
      original = evaluate(source)
      transformed_source = transform_source(source)
      RubyVM::InstructionSequence.compile(transformed_source)
      transformed = evaluate(transformed_source)

      refute_includes(transformed_source, "&.", *label)
      assert_equal(original, transformed, *label)
    end

    def transform_source(source)
      SyntaxTree.transform_safe_navigation(source)
    end

    def evaluate(source)
      context = sandbox
      result = context.instance_eval(source)
      outcome(result: result)
    rescue => error
      outcome(result: nil, error: error)
    end

    def sandbox
      $safe_navigation_events = []
      $safe_navigation_receivers = []
      $safe_navigation_attempts = 0
      throwing_receiver = Object.new
      throwing_receiver.define_singleton_method(:call) do
        $safe_navigation_attempts += 1
        raise Explosion, "receiver"
      end

      context = Object.new
      context.instance_variable_set(:@Recorder, Recorder)
      context.define_singleton_method(:Recorder) { @Recorder }
      context.define_singleton_method(:bomb) { |label| raise Explosion, label.to_s }
      bomb_block = Object.new
      bomb_block.define_singleton_method(:to_proc) do
        raise Explosion, "block argument"
      end
      context.define_singleton_method(:bomb_block) { bomb_block }
      context.define_singleton_method(:throwing_receiver) { throwing_receiver }
      context
    end

    def outcome(result:, error: nil)
      {
        result: result,
        events: $safe_navigation_events.dup,
        receivers: $safe_navigation_receivers.size,
        attempts: $safe_navigation_attempts,
        error: error ? [error.class, error.message] : nil
      }
    end
  end
end
