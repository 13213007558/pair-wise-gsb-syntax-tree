# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class IndexTest < Minitest::Test
    def test_module
      index_each("module Foo; end") do |entry|
        assert_equal :Foo, entry.name
        assert_equal [[:Foo]], entry.nesting
      end
    end

    def test_module_nested
      index_each("module Foo; module Bar; end; end") do |entry|
        assert_equal :Bar, entry.name
        assert_equal [[:Foo], [:Bar]], entry.nesting
      end
    end

    def test_module_comments
      index_each("# comment1\n# comment2\nmodule Foo; end") do |entry|
        assert_equal :Foo, entry.name
        assert_equal ["# comment1", "# comment2"], entry.comments.to_a
      end
    end

    def test_class
      index_each("class Foo; end") do |entry|
        assert_equal :Foo, entry.name
        assert_equal [[:Foo]], entry.nesting
      end
    end

    def test_class_paths_2
      index_each("class Foo::Bar; end") do |entry|
        assert_equal :Bar, entry.name
        assert_equal [%i[Foo Bar]], entry.nesting
      end
    end

    def test_class_paths_3
      index_each("class Foo::Bar::Baz; end") do |entry|
        assert_equal :Baz, entry.name
        assert_equal [%i[Foo Bar Baz]], entry.nesting
      end
    end

    def test_class_nested
      index_each("class Foo; class Bar; end; end") do |entry|
        assert_equal :Bar, entry.name
        assert_equal [[:Foo], [:Bar]], entry.nesting
      end
    end

    def test_class_paths_nested
      index_each("class Foo; class Bar::Baz::Qux; end; end") do |entry|
        assert_equal :Qux, entry.name
        assert_equal [[:Foo], %i[Bar Baz Qux]], entry.nesting
      end
    end

    def test_class_superclass
      index_each("class Foo < Bar; end") do |entry|
        assert_equal :Foo, entry.name
        assert_equal [[:Foo]], entry.nesting
        assert_equal [:Bar], entry.superclass
      end
    end

    def test_class_path_superclass
      index_each("class Foo::Bar < Baz::Qux; end") do |entry|
        assert_equal :Bar, entry.name
        assert_equal [%i[Foo Bar]], entry.nesting
        assert_equal %i[Baz Qux], entry.superclass
      end
    end

    def test_class_comments
      index_each("# comment1\n# comment2\nclass Foo; end") do |entry|
        assert_equal :Foo, entry.name
        assert_equal ["# comment1", "# comment2"], entry.comments.to_a
      end
    end

    def test_method
      index_each("def foo; end") do |entry|
        assert_equal :foo, entry.name
        assert_empty entry.nesting
      end
    end

    def test_method_nested
      index_each("class Foo; def foo; end; end") do |entry|
        assert_equal :foo, entry.name
        assert_equal [[:Foo]], entry.nesting
      end
    end

    def test_method_comments
      index_each("# comment1\n# comment2\ndef foo; end") do |entry|
        assert_equal :foo, entry.name
        assert_equal ["# comment1", "# comment2"], entry.comments.to_a
      end
    end

    def test_singleton_method
      index_each("def self.foo; end") do |entry|
        assert_equal :foo, entry.name
        assert_empty entry.nesting
      end
    end

    def test_singleton_method_nested
      index_each("class Foo; def self.foo; end; end") do |entry|
        assert_equal :foo, entry.name
        assert_equal [[:Foo]], entry.nesting
      end
    end

    def test_singleton_method_comments
      index_each("# comment1\n# comment2\ndef self.foo; end") do |entry|
        assert_equal :foo, entry.name
        assert_equal ["# comment1", "# comment2"], entry.comments.to_a
      end
    end

    def test_alias_method
      index_each("alias foo bar") do |entry|
        assert_equal :foo, entry.name
        assert_empty entry.nesting
      end
    end

    def test_attr_reader
      index_each("attr_reader :foo") do |entry|
        assert_equal :foo, entry.name
        assert_empty entry.nesting
      end
    end

    def test_attr_writer
      index_each("attr_writer :foo") do |entry|
        assert_equal :foo=, entry.name
        assert_empty entry.nesting
      end
    end

    def test_attr_accessor
      index_each("attr_accessor :foo") do |entry|
        assert_equal :foo=, entry.name
        assert_empty entry.nesting
      end
    end

    def test_constant
      index_each("FOO = 1") do |entry|
        assert_equal :FOO, entry.name
        assert_empty entry.nesting
      end
    end

    def test_this_file
      entries = Index.index_file(__FILE__, backend: Index::ParserBackend.new)

      if defined?(RubyVM::InstructionSequence)
        entries += Index.index_file(__FILE__, backend: Index::ISeqBackend.new)
      end

      entries.map { |entry| entry.comments.to_a }
    end

    def test_constant_resolution_lexical_nesting
      result = resolve_fixture_constants("nested_definition.rb").last

      assert_equal [%i[A X]], result.definitions.map(&:path)
      assert_equal([[:lexical, %i[A B]], [:lexical, [:A]]], result.lookup_path)
      assert_predicate result, :certain?
    end

    def test_constant_resolution_path_definition_is_not_lexically_nested
      result = resolve_fixture_constants("path_definition.rb").last

      assert_equal [[:X]], result.definitions.map(&:path)
      assert_equal([[:lexical, %i[A B]], [:lexical, []]], result.lookup_path)
      assert_predicate result, :certain?
    end

    def test_path_definition_does_not_find_outer_nested_constant
      source = <<~SOURCE
        class A
          X = :a
        end

        class A::B
          X
        end
      SOURCE
      result = Index.resolve_constants(Index.static_index(source)).last

      assert_equal [], result.definitions
      assert_equal :unresolved, result.uncertainties.first.reason
    end

    def test_constant_resolution_inheritance_and_include
      result = resolve_fixture_constants("ancestors.rb").last

      assert_equal [%i[Included VALUE]], result.definitions.map(&:path)
      assert_equal(
        [[:lexical, [:Child]], [:lexical, [:Included]]],
        result.lookup_path
      )
    end

    def test_constant_resolution_class_inheritance
      source = <<~SOURCE
        class Parent
          VALUE = :parent
        end

        class Child < Parent
          VALUE
        end
      SOURCE
      result = Index.resolve_constants(Index.static_index(source)).last

      assert_equal [%i[Parent VALUE]], result.definitions.map(&:path)
      assert_equal(
        [[:lexical, [:Child]], [:lexical, [:Parent]]],
        result.lookup_path
      )
    end

    def test_constant_resolution_explicit_root
      index = Index.static_index("X = 1; module A; X = 2; ::X; end")
      result = Index.resolve_constants(index).last

      assert_equal [[:X]], result.definitions.map(&:path)
      assert_equal [[:root, []]], result.lookup_path
    end

    def test_constant_resolution_preserves_uncertainty
      results = resolve_fixture_constants("uncertain.rb")

      conditional =
        results.find { |result| result.reference.path == [:Conditional] }
      assert_includes conditional.uncertainties.map(&:reason), :conditional_load

      dynamic = results.find { |result| result.reference.path == [:Dynamic] }
      assert_includes dynamic.uncertainties.map(&:reason), :const_set

      missing = results.find { |result| result.reference.path == [:Missing] }
      assert_includes missing.uncertainties.map(&:reason), :const_missing
    end

    private

    def index_each(source)
      yield Index.index(source, backend: Index::ParserBackend.new).last

      if defined?(RubyVM::InstructionSequence)
        yield Index.index(source, backend: Index::ISeqBackend.new).last
      end
    end

    def resolve_fixture_constants(fixture)
      filepath = File.join(__dir__, "fixtures", "constants", fixture)
      Index.resolve_constants(Index.static_index_file(filepath))
    end
  end
end
