# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class ConstantResolverTest < Minitest::Test
    def test_nested_definition_uses_outer_lexical_scope
      resolver = build_resolver("a.rb" => <<~RUBY)
          VALUE = :top

          class A
            VALUE = :a

            class B
              def value
                VALUE
              end
            end
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 8))

      assert_predicate resolution, :resolved?
      assert_predicate resolution, :certain?
      assert_equal %i[A VALUE], resolution.target.path
      assert_equal(
        [%i[A B], [:A]],
        resolution.steps.select { |step| step.kind == :lexical }.map(&:scope)
      )
    end

    def test_compact_definition_skips_outer_lexical_scope
      resolver = build_resolver("a.rb" => <<~RUBY)
          VALUE = :top

          class A
            VALUE = :a
          end

          class A::B
            def value
              VALUE
            end
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 9))

      assert_predicate resolution, :resolved?
      assert_equal [:VALUE], resolution.target.path

      lexical = resolution.steps.select { |step| step.kind == :lexical }
      assert_equal [%i[A B]], lexical.map(&:scope)
      refute_includes resolution.steps.map(&:scope), [:A]
    end

    def test_same_reference_resolves_differently_by_definition_style
      sources = {
        "constants.rb" => <<~RUBY,
          VALUE = :top

          class A
            VALUE = :a
          end
        RUBY
        "nested.rb" => <<~RUBY,
          class A
            class B
              def value
                VALUE
              end
            end
          end
        RUBY
        "compact.rb" => <<~RUBY
          class A::B
            def value
              VALUE
            end
          end
        RUBY
      }

      resolver = build_resolver(sources)

      nested = resolver.resolve(reference_at(resolver, "nested.rb", 4))
      compact = resolver.resolve(reference_at(resolver, "compact.rb", 3))

      assert_equal %i[A VALUE], nested.target.path
      assert_equal [:VALUE], compact.target.path
    end

    def test_absolute_path_starts_at_top_level
      resolver = build_resolver("a.rb" => <<~RUBY)
          VALUE = :top

          class A
            VALUE = :a

            def value
              ::VALUE
            end
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 7))

      assert_predicate resolution, :certain?
      assert_equal [:VALUE], resolution.target.path
      assert_equal 1, resolution.steps.length
      assert_equal :toplevel, resolution.steps.first.kind
    end

    def test_qualified_path
      resolver = build_resolver("a.rb" => <<~RUBY)
          class A
            VALUE = :a
          end

          def value
            A::VALUE
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 6))

      assert_predicate resolution, :certain?
      assert_equal %i[A VALUE], resolution.target.path
      assert_equal %i[toplevel qualified], resolution.steps.map(&:kind)
    end

    def test_superclass_chain_is_searched
      resolver = build_resolver("a.rb" => <<~RUBY)
          class Parent
            VALUE = :parent
          end

          class Child < Parent
            def value
              VALUE
            end
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 7))

      assert_predicate resolution, :certain?
      assert_equal %i[Parent VALUE], resolution.target.path
      assert_includes resolution.steps.map(&:kind), :ancestor
    end

    def test_included_modules_are_searched_last_included_first
      resolver = build_resolver("a.rb" => <<~RUBY)
          module First
            VALUE = :first
          end

          module Second
            VALUE = :second
          end

          class C
            include First
            include Second

            def value
              VALUE
            end
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 14))

      assert_predicate resolution, :certain?
      assert_equal %i[Second VALUE], resolution.target.path
    end

    def test_qualified_lookup_searches_ancestors
      resolver = build_resolver("a.rb" => <<~RUBY)
          class Parent
            VALUE = :parent
          end

          class Child < Parent
          end

          def value
            Child::VALUE
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 9))

      assert_predicate resolution, :certain?
      assert_equal %i[Parent VALUE], resolution.target.path
    end

    def test_const_missing_preserves_uncertainty
      resolver = build_resolver("a.rb" => <<~RUBY)
          class A
            def self.const_missing(name)
            end
          end

          MISSING
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 6))

      refute_predicate resolution, :resolved?
      refute_predicate resolution, :certain?
      assert_includes resolution.reasons.join, "const_missing"
    end

    def test_dynamic_const_set_preserves_uncertainty
      resolver = build_resolver("a.rb" => <<~RUBY)
          const_set(:DYNAMIC, 1)

          DYNAMIC
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 3))

      refute_predicate resolution, :resolved?
      assert_includes resolution.reasons.join, "const_set"
    end

    def test_conditional_definition_is_uncertain
      resolver = build_resolver("a.rb" => <<~RUBY)
          if RUBY_VERSION
            VALUE = :conditional
          end

          def value
            VALUE
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 6))

      assert_predicate resolution, :resolved?
      refute_predicate resolution, :certain?
      assert_includes resolution.reasons.join, "conditional"
    end

    def test_conditional_require_preserves_uncertainty
      resolver = build_resolver("a.rb" => <<~RUBY)
          if RUBY_VERSION
            require "maybe_defines_it"
          end

          UNDEFINED
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 5))

      refute_predicate resolution, :resolved?
      assert_includes resolution.reasons.join, "conditional require"
    end

    def test_multiple_definitions_are_uncertain
      resolver = build_resolver("a.rb" => <<~RUBY)
          VALUE = 1
          VALUE = 2

          def value
            VALUE
          end
        RUBY

      resolution = resolver.resolve(reference_at(resolver, "a.rb", 5))

      assert_predicate resolution, :resolved?
      refute_predicate resolution, :certain?
      assert_includes resolution.reasons.join, "multiple definitions"
    end

    def test_resolution_never_executes_code
      resolver = build_resolver("a.rb" => <<~RUBY)
          raise "boom"
          VALUE = 1
        RUBY

      assert resolver.definitions.key?([:VALUE])
    end

    def test_example_files
      directory = File.expand_path("../examples/constant_resolution", __dir__)
      resolver = Index::ConstantResolver.new

      Dir[File.join(directory, "*.rb")].each do |file|
        resolver.index_file(file) unless File.basename(file) == "demo.rb"
      end

      nested = File.join(directory, "nested.rb")
      compact = File.join(directory, "compact.rb")

      nested_resolution = resolver.resolve(reference_at(resolver, nested, 9))
      compact_resolution = resolver.resolve(reference_at(resolver, compact, 8))

      assert_equal %i[A VALUE], nested_resolution.target.path
      assert_equal [:VALUE], compact_resolution.target.path
    end

    private

    def build_resolver(files)
      resolver = Index::ConstantResolver.new
      files.each { |name, source| resolver.index_source(source, file: name) }
      resolver
    end

    def reference_at(resolver, file, line)
      reference =
        resolver.references.find do |candidate|
          candidate.file == file && candidate.line == line
        end

      flunk "no reference at #{file}:#{line}" unless reference
      reference
    end
  end
end
