# frozen_string_literal: true

require_relative "test_helper"

class LocalVariableRenameTest < Minitest::Test
  def test_renames_method_argument_without_block_local
    source = <<~RUBY
      def rename(token)
        tap do |; token|
          token = "\#{token} token :token"
        end
        token
      end
    RUBY

    result = rename(source, "token", :value)

    assert_predicate(result, :success?)
    assert_equal(2, result.edits.length)
    assert_equal(<<~RUBY, result.apply(source))
      def rename(value)
        tap do |; token|
          token = "\#{token} token :token"
        end
        value
      end
    RUBY
  end

  def test_renames_block_local_and_its_references
    source = <<~RUBY
      value.tap do |; token|
        token = "\#{token} token :token"
      end
    RUBY

    result = rename(source, "token", :value)

    assert_predicate(result, :success?)
    assert_equal(3, result.edits.length)
    assert_equal(<<~RUBY, result.apply(source))
      value.tap do |; value|
        value = "\#{value} token :token"
      end
    RUBY
  end

  def test_distinguishes_block_arguments_lambda_and_outer_scope
    source = <<~RUBY
      token = :outer
      items.each { |token| token }
      values.each do |; token|
        token
      end
      arrow = ->(token) { token }
      token
    RUBY

    [1, 2, 3, 4].each_cons(2) do |(first, second), _|
      refute_equal(first, second)
    end

    block_result = rename_at(source, offset(source, "token", 2), :other)
    assert_equal(2, block_result.edits.length)

    lambda_result = rename_at(source, offset(source, "token", 6), :other)
    assert_equal(2, lambda_result.edits.length)

    outer_result = rename_at(source, offset(source, "token", 1), :other)
    assert_equal(2, outer_result.edits.length)
  end

  def test_renames_destructured_and_keyword_parameters
    source = <<~RUBY
      def rename((token, *rest), keyword:)
        [token, rest, keyword]
      end
    RUBY

    result = rename(source, "token", :value)

    assert_predicate(result, :success?)
    assert_equal(2, result.edits.length)
    assert_includes(result.apply(source), "def rename((value, *rest), keyword:)")
    assert_includes(result.apply(source), "[value, rest, keyword]")
  end

  def test_renames_lambda_local_declared_after_semicolon
    source = <<~RUBY
      ->(;token) { token = 1; token }.call
    RUBY

    result = rename(source, "token", :value)

    assert_predicate(result, :success?)
    assert_equal(3, result.edits.length)
    assert_equal(<<~RUBY, result.apply(source))
      ->(;value) { value = 1; value }.call
    RUBY
  end

  def test_renames_pattern_matching_bindings
    source = <<~RUBY
      case value
      in { token:, **rest } if token
        [token, rest]
      end
    RUBY

    result = rename(source, "token", :other)

    assert_predicate(result, :success?)
    expected = <<~RUBY
      case value
      in { other:, **rest } if other
        [other, rest]
      end
    RUBY
    assert_equal(expected, result.apply(source))
  end

  def test_renames_named_regex_capture_and_multiline_interpolation
    source = <<~RUBY
      if /中文\n(?<token>x)\n/ =~ string
        "前\n\#{token}\n后"
      end
    RUBY

    result = rename(source, "token", :值)

    assert_predicate(result, :success?)
    expected = <<~RUBY
      if /中文\n(?<值>x)\n/ =~ string
        "前\n\#{值}\n后"
      end
    RUBY
    assert_equal(expected, result.apply(source))
    assert_equal(2, result.edits.length)
  end

  def test_conflicts_on_numbered_parameters
    source = "[1].map { _1 + _1 }\n"

    result = rename(source, "_1", :value)

    refute_predicate(result, :success?)
    messages = result.conflicts.map(&:message)
    assert_equal(["Numbered parameter cannot be renamed"], messages)
    assert_equal(offset(source, "_1", 1), result.conflicts.first.range.start_byte)
    assert_empty(result.edits)
  end

  def test_conflicts_on_existing_binding_in_same_scope
    source = <<~RUBY
      token = 1
      value = 2
      tap { |value| value }
    RUBY

    result = rename(source, "token", :value)

    refute_predicate(result, :success?)
    messages = result.conflicts.map(&:message)
    assert_equal(["New name already exists in scope"], messages)
    assert_equal(offset(source, "value", 1), result.conflicts.first.range.start_byte)
  end

  def test_conflicts_when_method_call_would_become_local
    source = <<~RUBY
      value
      token = 1
    RUBY

    result = rename(source, "token", :value)

    refute_predicate(result, :success?)
    messages = result.conflicts.map(&:message)
    assert_equal(["Rename would capture another reference"], messages)
    assert_equal(0, result.conflicts.first.range.start_byte)
  end

  def test_does_not_rename_method_definitions_symbols_or_plain_text
    source = <<~RUBY
      def token
        :token
        "token"
      end
    RUBY

    result = rename(source, "token", :value)

    refute_predicate(result, :success?)
    assert_equal(["No local variable at cursor"], result.conflicts.map(&:message))
  end

  def test_def_class_and_module_are_separate_scopes
    source = <<~RUBY
      token = :outer
      class Container
        token = :class
      end
      module Namespace
        token = :module
      end
      def method_scope
        token
      end
    RUBY

    result = rename_at(source, offset(source, "token", 2), :value)
    assert_predicate(result, :success?)
    assert_equal(1, result.edits.length)

    method_result = rename_at(source, offset(source, "token", 4), :value)
    refute_predicate(method_result, :success?)
  end

  private

  def rename(source, target, new_name)
    rename_at(source, offset(source, target), new_name)
  end

  def rename_at(source, position, new_name)
    SyntaxTree.rename_local_variable(source, position, new_name)
  end

  def ranges(result)
    result.edits.sort_by(&:start_byte).map do |edit|
      [edit.start_byte, edit.end_byte]
    end
  end

  def offset(source, target, occurrence = 1)
    index = nil
    occurrence.times do
      index = source.index(target, (index || -1) + 1)
    end
    source[0, index].bytesize
  end

  def offset_after(source, target, occurrence = 1)
    offset(source, target, occurrence) + target.bytesize
  end
end
