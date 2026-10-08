# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class RefinementQueryTest < Minitest::Test
    def test_lexical_activation_does_not_affect_earlier_call
      source = <<~RUBY
        module Styling
          refine(String) do
            def title
            end
          end
        end

        class String
          def title
          end
        end

        class Document
          "x".title

          def before
            "x".title
          end

          using Styling

          "x".title

          def after
            "x".title
          end
        end

      RUBY

      query = RefinementQuery.for(source)
      before_call, _method_call, after_call, method_after_call =
        query.calls_named(:title)

      before = query.query(before_call)
      after = query.query(after_call)
      method_after = query.query(method_after_call)

      assert_equal :known, before.status
      assert_equal [[:String]], before.candidates.map { |candidate| candidate.owner }
      assert_equal [:ordinary], before.candidates.map(&:kind)
      assert_empty before.evidence

      assert_equal :known, after.status
      assert_equal [:refinement, :ordinary], after.candidates.map(&:kind)
      assert_equal [[:String], [:String]],
                   after.candidates.map { |candidate| candidate.owner }
      assert_equal ["using Styling"], after.evidence.map(&:description)
      assert_equal [:refinement, :ordinary], method_after.candidates.map(&:kind)
      assert_equal ["using Styling"], method_after.evidence.map(&:description)
    end

    def test_method_definition_position_freezes_lexical_refinements
      source = <<~RUBY
        class Document
          def render
            "x".title
          end

          using Styling
        end

        module Styling
          refine(String) do
            def title
            end
          end
        end
      RUBY

      query = RefinementQuery.for(source)
      result = query.query(query.calls_named(:title).first)

      assert_equal :known, result.status
      assert_empty result.candidates
      assert_empty result.evidence
    end

    def test_ordinary_methods_follow_declared_superclass_chain
      declarations =
        Index.index(
          <<~RUBY,
            class Parent
              def title
              end
            end

            class Child < Parent
            end
          RUBY
          backend: Index::ParserBackend.new
        )

      source = "child = Child.new\nchild.title\n"
      query = RefinementQuery.for(source)
      result = query.query(query.calls_named(:title).first, declarations: declarations)

      assert_equal [[:Parent]], result.candidates.map(&:owner)
      assert_equal ["ordinary method defined in Parent"],
                   result.candidates.flat_map(&:reasons).map(&:description)
    end

    def test_dynamically_constructed_refinement_module_is_unknown
      source = <<~RUBY
        styling = Module.new do
          refine(String) do
            def title
            end
          end
        end

        using styling
        "x".title
      RUBY

      query = RefinementQuery.for(source)
      result = query.query(query.calls_named(:title).first)

      assert_equal :unknown, result.status
      assert_empty result.candidates
      assert_match(/dynamically constructed module/, result.reason)
    end

    def test_parenthesized_using_is_lexically_scoped
      source = <<~RUBY
        module Styling
          refine(String) do
            def title
            end
          end
        end

        "x".title
        using(Styling)
        "x".title
      RUBY

      query = RefinementQuery.for(source)
      before_call, after_call = query.calls_named(:title)

      assert_empty query.query(before_call).evidence
      assert_equal ["using Styling"],
                   query.query(after_call).evidence.map(&:description)
    end

    def test_conditional_using_is_unknown
      source = <<~RUBY
        module Styling
          refine(String) do
            def title
            end
          end
        end

        if condition
          using Styling
        end

        "x".title
      RUBY

      query = RefinementQuery.for(source)
      result = query.query(query.calls_named(:title).first)

      assert_equal :unknown, result.status
      assert_match(/conditional lexical path/, result.reason)
    end

    private

  end
end
