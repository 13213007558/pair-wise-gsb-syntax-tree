# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class NavigationTest < Minitest::Test
    def test_refinements_are_lexical_at_the_call_site
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end
        end

        module R
          refine(Foo) do
            def bar
              "refined"
            end
          end
        end

        object = Foo.new
        object.bar
        using R
        object.bar
      SOURCE

      before_using, after_using = calls_named(source, :bar)
      before_result = Navigation.method_candidates(source, before_using)
      after_result = Navigation.method_candidates(source, after_using)

      assert_equal(%i[normal], before_result.candidates.map(&:kind))
      assert_equal(%i[refinement normal], after_result.candidates.map(&:kind))
      assert_equal(%i[Foo], before_result.receiver_type)
      assert_equal(%i[Foo], after_result.receiver_type)

      refinement_candidate = after_result.candidates.first
      assert_equal(:refinement_method, refinement_candidate.basis.kind)
      assert_equal(%i[refine using], refinement_candidate.evidence.map(&:kind))
      assert_includes(refinement_candidate.basis.description, "R")
    end

    def test_using_does_not_affect_previous_statements_or_previous_methods
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end
        end

        module R
          refine(Foo) do
            def bar
              "refined"
            end
          end
        end

        class A
          Foo.new.bar

          def before_using
            Foo.new.bar
          end

          using R

          Foo.new.bar

          def after_using
            Foo.new.bar
          end
        end
      SOURCE

      direct_before, method_before, direct_after, method_after = calls_named(source, :bar)

      assert_equal(%i[normal], Navigation.method_candidates(source, direct_before).candidates.map(&:kind))
      assert_equal(%i[normal], Navigation.method_candidates(source, method_before).candidates.map(&:kind))
      assert_equal(%i[refinement normal], Navigation.method_candidates(source, direct_after).candidates.map(&:kind))
      assert_equal(
        %i[refinement normal],
        Navigation.method_candidates(source, method_after).candidates.map(&:kind)
      )
    end

    def test_refinements_apply_through_static_superclasses
      source = <<~SOURCE
        class Parent
          def name
            "parent"
          end
        end

        class Child < Parent
        end

        module R
          refine(Parent) do
            def name
              "refined"
            end
          end
        end

        class A
          using R

          def call
            Child.new.name
          end
        end
      SOURCE

      call = calls_named(source, :name).last
      result = Navigation.method_candidates(source, call)

      assert_equal(%i[refinement normal], result.candidates.map(&:kind))
      assert_equal(%i[Parent], result.candidates.first.path)
      assert_equal(%i[Parent], result.candidates.last.path)
    end

    def test_constants_resolve_through_lexical_namespaces
      source = <<~SOURCE
        module Outer
          class Foo
            def bar
              "normal"
            end
          end

          module R
            refine(Foo) do
              def bar
                "refined"
              end
            end
          end

          object = Foo.new
          object.bar
          using R
          object.bar
        end
      SOURCE

      before_using, after_using = calls_named(source, :bar)
      before_result = Navigation.method_candidates(source, before_using)
      after_result = Navigation.method_candidates(source, after_using)

      assert_equal(%i[Outer Foo], before_result.receiver_type)
      assert_equal(%i[normal], before_result.candidates.map(&:kind))
      assert_equal(%i[Outer Foo], after_result.receiver_type)
      assert_equal(%i[refinement normal], after_result.candidates.map(&:kind))
    end

    def test_dynamically_constructed_refinement_modules_are_unknown
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end
        end

        M = Module.new do
          refine(Foo) do
            def bar
              "dynamic"
            end
          end
        end

        using M
        Foo.new.bar
      SOURCE

      call = calls_named(source, :bar).last
      result = Navigation.method_candidates(source, call)

      assert_predicate(result, :unknown)
      assert_equal(%i[Foo], result.receiver_type)
      assert_includes(result.reasons.map(&:description).join, "dynamically constructed module")
    end

    def test_non_static_refine_targets_are_unknown
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end
        end

        target = Foo

        module R
          refine(target) do
            def bar
              "dynamic"
            end
          end
        end

        using R
        Foo.new.bar
      SOURCE

      call = calls_named(source, :bar).last
      result = Navigation.method_candidates(source, call)

      assert_predicate(result, :unknown)
      assert_includes(result.reasons.map(&:description).join, "non-static refinements")
    end

    def test_refinement_blocks_are_snapshotted_when_using_activates_a_module
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end
        end

        module R
        end

        module S
          using R

          refine(Foo) do
            def call
              self.bar
            end
          end
        end

        module R
          refine(Foo) do
            def bar
              "later"
            end
          end
        end

        class A
          using S

          def go
            Foo.new.call
          end
        end
      SOURCE

      bar_call = calls_named(source, :bar).first
      result = Navigation.method_candidates(source, bar_call)

      assert_equal(%i[normal], result.candidates.map(&:kind))
    end

    def test_using_in_blocks_uses_the_enclosing_declaration_scope
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end
        end

        module R
          refine(Foo) do
            def bar
              "refined"
            end
          end
        end

        class A
          [1].each do
            using R
            Foo.new.bar
          end

          def invalid_using
            [1].each do
              using R
              Foo.new.bar
            end
          end
        end
      SOURCE

      class_body_call, method_body_call = calls_named(source, :bar)
      class_body_result = Navigation.method_candidates(source, class_body_call)
      method_body_result = Navigation.method_candidates(source, method_body_call)

      assert_equal(%i[refinement normal], class_body_result.candidates.map(&:kind))
      assert_predicate(method_body_result, :unknown)
      assert_includes(method_body_result.reasons.map(&:description).join, "not statically valid")
    end

    def test_unknown_receiver_does_not_produce_resolved_candidates
      source = <<~SOURCE
        object.fetch
      SOURCE

      call = calls_named(source, :fetch).last
      result = Navigation.method_candidates(source, call)

      assert_predicate(result, :unknown)
      assert_empty(result.candidates)
      assert_includes(result.reasons.map(&:description).join, "receiver type")
    end

    def test_implicit_vcall_uses_the_method_definition_scope
      source = <<~SOURCE
        class Foo
          def bar
            "normal"
          end

          def call
            bar
          end
        end
      SOURCE

      call = vcalls_named(source, :bar).last
      result = Navigation.method_candidates(source, call)

      assert_equal(%i[Foo], result.receiver_type)
      assert_equal(%i[normal], result.candidates.map(&:kind))
    end

    private

    def calls_named(source, name)
      calls = []
      visitor =
        Class.new(Visitor) do
          define_method(:visit_call) do |node|
            if node.message.respond_to?(:value) && node.message.value.to_sym == name
              calls << node
            end

            super(node)
          end
        end.new

      SyntaxTree.parse(source).accept(visitor)
      calls
    end

    def vcalls_named(source, name)
      calls = []
      visitor =
        Class.new(Visitor) do
          define_method(:visit_vcall) do |node|
            calls << node if node.value.value.to_sym == name
            super(node)
          end
        end.new

      SyntaxTree.parse(source).accept(visitor)
      calls
    end
  end
end
