# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class RenameTest < Minitest::Test
    def test_method_parameter_and_string_interpolation
      source = <<~'RUBY'
        def demo(token)
          [1].each do |token|
            puts token
          end
          "result: #{token}"
        end
      RUBY

      expected = <<~'RUBY'
        def demo(value)
          [1].each do |token|
            puts token
          end
          "result: #{value}"
        end
      RUBY

      assert_renamed(expected, source, "value", line: 1, column: 10)
      assert_renamed(expected, source, "value", line: 5, column: 14)
    end

    def test_block_parameter
      source = <<~'RUBY'
        def demo(token)
          [1].each do |token|
            puts token
          end
        end
      RUBY

      assert_renamed(<<~'RUBY', source, "item", line: 2, column: 16)
        def demo(token)
          [1].each do |item|
            puts item
          end
        end
      RUBY
    end

    def test_block_local_variable
      source = <<~'RUBY'
        y = 1
        [1].each do |x; y|
          y = x
          puts y
        end
        puts y
      RUBY

      assert_renamed(<<~'RUBY', source, "z", line: 2, column: 16)
        y = 1
        [1].each do |x; z|
          z = x
          puts z
        end
        puts y
      RUBY
    end

    def test_lambda_parameter
      source = <<~'RUBY'
        scale = 2
        double = ->(value) { value * scale }
        value = 1
        puts value
      RUBY

      assert_renamed(<<~'RUBY', source, "amount", line: 2, column: 14)
        scale = 2
        double = ->(amount) { amount * scale }
        value = 1
        puts value
      RUBY
    end

    def test_lambda_creates_a_new_scope
      source = <<~'RUBY'
        run = -> { temp = 1; temp }
        temp = 2
        puts temp
      RUBY

      assert_renamed(<<~'RUBY', source, "inner", line: 1, column: 14)
        run = -> { inner = 1; inner }
        temp = 2
        puts temp
      RUBY

      assert_renamed(<<~'RUBY', source, "outer", line: 2, column: 1)
        run = -> { temp = 1; temp }
        outer = 2
        puts outer
      RUBY
    end

    def test_pattern_matching
      source = <<~'RUBY'
        case point
        in [x, { k: }]
          x + k
        end
      RUBY

      assert_renamed(<<~'RUBY', source, "a", line: 2, column: 4)
        case point
        in [a, { k: }]
          a + k
        end
      RUBY

      expected = <<~'RUBY'
        case point
        in [x, { key: }]
          x + key
        end
      RUBY

      assert_renamed(expected, source, "key", line: 2, column: 9)
      assert_renamed(expected, source, "key", line: 3, column: 6)
    end

    def test_pinned_variable_in_pattern
      source = <<~'RUBY'
        x = 1
        case 1
        in ^x
          x
        end
      RUBY

      assert_renamed(<<~'RUBY', source, "y", line: 3, column: 4)
        y = 1
        case 1
        in ^y
          y
        end
      RUBY
    end

    def test_destructured_parameters
      source = <<~'RUBY'
        def distance((x1, y1), (x2, y2))
          Math.hypot(x2 - x1, y2 - y1)
        end
      RUBY

      assert_renamed(<<~'RUBY', source, "left", line: 1, column: 14)
        def distance((left, y1), (x2, y2))
          Math.hypot(x2 - left, y2 - y1)
        end
      RUBY
    end

    def test_destructured_block_parameters
      source = <<~'RUBY'
        [[1, 2]].each { |(a, b)| a + b }
        [[[3, 4]]].each { |((c, d))| c + d }
      RUBY

      assert_renamed(<<~'RUBY', source, "first", line: 1, column: 18)
        [[1, 2]].each { |(first, b)| first + b }
        [[[3, 4]]].each { |((c, d))| c + d }
      RUBY

      assert_renamed(<<~'RUBY', source, "third", line: 2, column: 21)
        [[1, 2]].each { |(a, b)| a + b }
        [[[3, 4]]].each { |((third, d))| third + d }
      RUBY
    end

    def test_keyword_parameter
      source = <<~'RUBY'
        def foo(count: 1)
          count
        end
      RUBY

      assert_renamed(<<~'RUBY', source, "total", line: 1, column: 9)
        def foo(total: 1)
          total
        end
      RUBY
    end

    def test_regexp_named_capture
      source = <<~'RUBY'
        /(?<word>\w+)/ =~ "abc"
        puts word
      RUBY

      expected = <<~'RUBY'
        /(?<token>\w+)/ =~ "abc"
        puts token
      RUBY

      assert_renamed(expected, source, "token", line: 1, column: 5)
      assert_renamed(expected, source, "token", line: 2, column: 6)
    end

    def test_regexp_named_capture_with_multibyte_name
      source = <<~'RUBY'
        /(?<第二>b)/ =~ "ab"
        puts 第二
      RUBY

      expected = <<~'RUBY'
        /(?<第三>b)/ =~ "ab"
        puts 第三
      RUBY

      assert_renamed(expected, source, "第三", line: 1, column: 5)
      assert_renamed(expected, source, "第三", line: 2, column: 6)
    end

    def test_regexp_on_the_right_side_does_not_define
      source = <<~'RUBY'
        "abc" =~ /(?<word>\w+)/
      RUBY

      assert_error(source, "token", line: 1, column: 15)
    end

    def test_regexp_with_not_match_does_not_define
      source = <<~'RUBY'
        /(?<word>\w+) !~ "abc"
      RUBY

      assert_error(source, "token", line: 1, column: 5)
    end

    def test_def_class_module_and_singleton_class_scopes
      source = <<~'RUBY'
        x = 1
        def foo
          x = 2
        end
        class C
          x = 3
        end
        module M
          x = 4
        end
        class << self
          x = 5
        end
      RUBY

      renamed = rename(source, "y", line: 1, column: 0)
      assert renamed.success?
      assert_equal "y = 1", renamed.renamed.lines[0].chomp
      assert_equal source.lines.drop(1).join,
        renamed.renamed.lines.drop(1).join

      renamed = rename(source, "y", line: 3, column: 2)
      assert renamed.success?
      assert_equal "  y = 2", renamed.renamed.lines[2].chomp
      assert_equal 13, renamed.renamed.lines.length

      renamed = rename(source, "y", line: 12, column: 2)
      assert renamed.success?
      assert_equal "  y = 5", renamed.renamed.lines[11].chomp
    end

    def test_for_loop_variable
      source = <<~'RUBY'
        for i in [1, 2]
          puts i
        end
        puts i
      RUBY

      assert_renamed(<<~'RUBY', source, "n", line: 1, column: 4)
        for n in [1, 2]
          puts n
        end
        puts n
      RUBY
    end

    def test_assignment_inside_block_belongs_to_outer_scope
      source = <<~'RUBY'
        x = 1
        [1].each { x = 2 }
        puts x
      RUBY

      assert_renamed(<<~'RUBY', source, "y", line: 2, column: 12)
        y = 1
        [1].each { y = 2 }
        puts y
      RUBY
    end

    def test_methods_symbols_and_strings_are_untouched
      source = <<~'RUBY'
        x = 1
        x
        :x
        "x"
        "#{x}"
        def x; end
        x()
      RUBY

      assert_renamed(<<~'RUBY', source, "y", line: 1, column: 0)
        y = 1
        y
        :x
        "x"
        "#{y}"
        def x; end
        x()
      RUBY
    end

    def test_multibyte_characters_and_multiline_interpolation
      source = <<~'RUBY'
        名字 = "值"
        文本 = "前缀#{名字}
        跨行 #{名字} 后缀"
      RUBY

      expected = <<~'RUBY'
        变量 = "值"
        文本 = "前缀#{变量}
        跨行 #{变量} 后缀"
      RUBY

      result = assert_renamed(expected, source, "变量", line: 1, column: 1)
      assert_equal 0, result.edits.first.start_byte
      assert_equal 6, result.edits.first.end_byte
      assert_equal source.encoding, result.renamed.encoding

      assert_renamed(expected, source, "变量", line: 3, column: 6)
    end

    def test_edits_are_byte_ranges
      source = <<~'RUBY'
        名字 = 1
        名字
      RUBY

      result = rename(source, "变量", line: 1, column: 0)

      assert result.success?
      assert_equal 2, result.edits.length
      assert_equal [0, 6],
        [result.edits[0].start_byte, result.edits[0].end_byte]
      assert_equal [11, 17],
        [result.edits[1].start_byte, result.edits[1].end_byte]

      applied = source.b
      result.edits.reverse_each do |edit|
        applied[edit.start_byte...edit.end_byte] = edit.replacement.b
      end
      applied.force_encoding(source.encoding)

      assert_equal result.renamed, applied
    end

    def test_position_can_be_a_character_offset
      source = <<~'RUBY'
        token = 1
        puts token
      RUBY

      result = rename(source, "value", offset: source.index("token"))

      assert result.success?
      assert_equal <<~'RUBY', result.renamed
        value = 1
        puts value
      RUBY
    end

    def test_round_trip
      source = <<~'RUBY'
        def demo(token)
          [1].each do |token|
            token
          end
          token
        end
      RUBY

      first = rename(source, "value", line: 1, column: 10)
      assert first.success?

      second = rename(first.renamed, "token", line: 1, column: 10)
      assert second.success?
      assert_equal source, second.renamed
    end

    def test_renaming_to_the_same_name_is_a_noop
      source = <<~'RUBY'
        x = 1
      RUBY

      result = rename(source, "x", line: 1, column: 0)

      assert result.success?
      assert_empty result.edits
      assert_equal source, result.renamed
    end

    def test_conflict_when_name_is_taken_in_the_same_scope
      source = <<~'RUBY'
        x = 1
        y = 2
        puts x
      RUBY

      result = assert_conflict(source, "y", line: 1, column: 0)
      assert_includes result.conflicts.first.message, "already defined"
      assert_equal 2, result.conflicts.first.location.start_line
    end

    def test_conflict_when_rename_captures_an_outer_reference
      source = <<~'RUBY'
        y = 1
        [1].each do |x|
          puts y
        end
      RUBY

      result = assert_conflict(source, "y", line: 2, column: 14)
      assert_includes result.conflicts.first.message, "capture"
      assert_equal 3, result.conflicts.first.location.start_line
    end

    def test_conflict_when_rename_captures_an_outer_assignment
      source = <<~'RUBY'
        y = 1
        [1].each do |x|
          y = 2
        end
      RUBY

      assert_conflict(source, "y", line: 2, column: 14)
    end

    def test_conflict_when_an_inner_binding_would_capture_a_reference
      source = <<~'RUBY'
        x = 1
        [1].each do |y|
          puts x
        end
      RUBY

      result = assert_conflict(source, "y", line: 1, column: 0)
      assert_includes result.conflicts.first.message, "inner scope"
      assert_equal 3, result.conflicts.first.location.start_line
    end

    def test_no_conflict_when_the_inner_name_is_not_in_the_way
      source = <<~'RUBY'
        x = 1
        [1].each { |y| y }
        puts x
      RUBY

      assert_renamed(<<~'RUBY', source, "y", line: 1, column: 0)
        y = 1
        [1].each { |y| y }
        puts y
      RUBY
    end

    def test_conflict_with_numbered_parameters
      source = <<~'RUBY'
        total = 1
        [1, 2].each { _1 + total }
      RUBY

      result = assert_conflict(source, "_1", line: 1, column: 0)
      assert_includes result.conflicts.first.message, "numbered parameter"
      assert_equal 2, result.conflicts.first.location.start_line
    end

    def test_numbered_parameters_cannot_be_renamed
      source = <<~'RUBY'
        [1, 2].each { _1 * 2 }
      RUBY

      result = assert_error(source, "n", line: 1, column: 15)
      assert_includes result.error, "numbered parameter"
    end

    def test_conflict_when_a_method_call_would_become_a_variable
      source = <<~'RUBY'
        def m
          x = 1
          foo
        end
      RUBY

      result = assert_conflict(source, "foo", line: 2, column: 2)
      assert_includes result.conflicts.first.message, "method call"
      assert_equal 3, result.conflicts.first.location.start_line
    end

    def test_no_conflict_when_the_call_comes_before_the_definition
      source = <<~'RUBY'
        def m
          foo
          x = 1
        end
      RUBY

      assert_renamed(<<~'RUBY', source, "foo", line: 3, column: 2)
        def m
          foo
          foo = 1
        end
      RUBY
    end

    def test_error_when_there_is_no_local_at_the_position
      source = <<~'RUBY'
        x = 1
        :x
        "x"
        def x; end
        x()
        1
      RUBY

      assert_error(source, "y", line: 2, column: 1)
      assert_error(source, "y", line: 3, column: 1)
      assert_error(source, "y", line: 4, column: 5)
      assert_error(source, "y", line: 5, column: 0)
      assert_error(source, "y", line: 6, column: 0)
    end

    def test_error_when_the_position_is_invalid
      source = <<~'RUBY'
        x = 1
      RUBY

      assert_error(source, "y", line: 99, column: 0)
      assert_error(source, "y", line: 1, column: 99)
      assert_error(source, "y", line: 1, column: -1)
    end

    def test_error_when_the_new_name_is_invalid
      source = <<~'RUBY'
        x = 1
      RUBY

      assert_error(source, "Foo", line: 1, column: 0)
      assert_error(source, "class", line: 1, column: 0)
      assert_error(source, "1x", line: 1, column: 0)
      assert_error(source, "x?", line: 1, column: 0)
      assert_error(source, "", line: 1, column: 0)
    end

    def test_error_when_the_source_does_not_parse
      result = rename("def foo(", "y", line: 1, column: 0)

      refute result.success?
      refute_nil result.error
    end

    def test_top_level_api
      source = <<~'RUBY'
        x = 1
        x
      RUBY

      result = SyntaxTree.rename_local(source, "y", line: 2, column: 0)

      assert result.success?
      assert_equal <<~'RUBY', result.renamed
        y = 1
        y
      RUBY
    end

    private

    def rename(source, new_name, **position)
      SyntaxTree::Rename.rename(source, new_name, **position)
    end

    def assert_renamed(expected, source, new_name, **position)
      result = rename(source, new_name, **position)

      assert(
        result.success?,
        "expected rename to succeed, got error: #{result.error.inspect}, " +          "conflicts: #{result.conflicts.map(&:message).inspect}"
      )

      assert_equal expected, result.renamed
      assert_equal result.edits.sort_by(&:start_byte), result.edits
      result
    end

    def assert_conflict(source, new_name, **position)
      result = rename(source, new_name, **position)

      refute result.success?
      assert_nil result.error
      assert_nil result.renamed
      assert_empty result.edits
      refute_empty result.conflicts
      result
    end

    def assert_error(source, new_name, **position)
      result = rename(source, new_name, **position)

      refute result.success?
      refute_nil result.error
      assert_empty result.edits
      result
    end
  end
end
