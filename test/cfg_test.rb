# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class CFGTest < Minitest::Test
    def test_blocks_edges_and_locations
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          if ready?
            work
          end
        end
      RUBY

      assert_equal :example, graph.method_name
      assert graph.entry_block
      assert(graph.blocks.all? { |block| block.location.is_a?(Location) })
      assert_includes(
        graph
          .blocks
          .flat_map(&:instructions)
          .map do |node|
            graph.source[node.location.start_char...node.location.end_char]
          end,
        "work"
      )
      assert(
        graph.edges.any? do |edge|
          edge.type == :branch && edge.condition == :truthy
        end
      )
      assert(
        graph.edges.any? do |edge|
          edge.type == :branch && edge.condition == :falsy
        end
      )
    end

    def test_short_circuit
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          a && b || c
        end
      RUBY

      branches = graph.edges.select { |edge| edge.type == :branch }
      assert(branches.any? { |edge| edge.condition == :truthy })
      assert(branches.any? { |edge| edge.condition == :falsy })
      assert graph.effects.empty? || graph.effects.any?
    end

    def test_unknown_call_has_explicit_effect_and_edges
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          possible_raise
        end
      RUBY

      effect = graph.effects.find { |item| item.method_name == :possible_raise }
      assert effect
      assert(
        graph.edges.any? do |edge|
          edge.type == :exception && edge.metadata[:effect] == effect.id
        end
      )
      assert(graph.edges.any? { |edge| edge.type == :return_from_call })
      assert(graph.edges.any? { |edge| edge.type == :nonlocal_return })
    end

    def test_assigned_local_variable_is_not_unknown_call
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          value = 1
          value
        end
      RUBY

      assert_empty graph.effects
      assert(
        graph.blocks.flat_map(&:instructions).any? { |node| node.is_a?(VarRef) }
      )
    end

    def test_recursive_call_is_call_edge
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          example
        end
      RUBY

      effect = graph.effects.first
      assert effect
      assert effect.metadata[:recursive]
    end

    def test_return_runs_ensure_and_overrides_exit
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          begin
            return 1
          ensure
            cleanup
          end
        end
      RUBY

      result = graph.check_path
      kinds = result.events.map { |event| event[:type] || event[:kind] }
      assert_includes kinds, "ReturnNode"
      assert_includes kinds, "VCall"
      assert_equal :normal, exit_kind(result)
    end

    def test_nested_ensure_uses_shared_blocks
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          begin
            begin
              return 1
            ensure
              inner
            end
          ensure
            outer
          end
        end
      RUBY

      ensure_blocks = graph.blocks.count { |block| block.kind == :ensure }
      assert_equal 2, ensure_blocks
      result = graph.check_path
      calls =
        result
          .events
          .select { |event| event[:type] == "VCall" }
          .map { |event| event[:location][:start_line] }
      assert_equal [6, 9], calls
    end

    def test_rescue_match_else_and_ensure
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          begin
            risky
          rescue SpecificError
            handled
          else
            untouched
          ensure
            always
          end
        end
      RUBY

      assert(graph.blocks.any? { |block| block.kind == :rescue_guard })
      assert(graph.blocks.any? { |block| block.kind == :rescue_handler })
      assert(graph.blocks.any? { |block| block.label == "begin else" })
      assert(graph.blocks.one? { |block| block.kind == :ensure })
      assert(graph.edges.any? { |edge| edge.type == :rescue_match })
    end

    def test_path_choice_for_exception_and_ensure
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          begin
            risky
          rescue StandardError
            handled
          ensure
            always
          end
        end
      RUBY

      effect = graph.effects.find { |item| item.method_name == :risky }
      result = graph.check_path(effects: { effect.id => :exception })

      sequence = result.events.map { |event| event[:type] || event[:kind].to_s }
      assert_includes sequence, "VCall"
      assert_includes sequence, "exception"
      assert_includes sequence, "VCall"
      assert_includes sequence, "VCall"
      assert_equal :normal, exit_kind(result)
    end

    def test_return_inside_ensure_overrides_original_return
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          begin
            return 1
          ensure
            return 2
          end
        end
      RUBY

      result = graph.check_path
      returns = result.events.count { |event| event[:type] == "ReturnNode" }
      assert_equal 2, returns
      assert_equal :normal, exit_kind(result)
    end

    def test_exception_inside_ensure_overrides_original_return
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          begin
            return 1
          ensure
            cleanup
          end
        end
      RUBY

      effect = graph.effects.find { |item| item.method_name == :cleanup }
      result = graph.check_path(effects: { effect.id => :exception })

      assert_equal :exception, exit_kind(result)
    end

    def test_plain_block_break_is_local_to_block
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          values.each do
            break :done
          end
          after
        end
      RUBY

      region = graph.regions.find { |item| item.kind == :block }
      assert region
      assert(
        graph.edges.any? do |edge|
          edge.type == :invoke_block && edge.metadata[:region] == region.id
        end
      )
      assert(graph.edges.any? { |edge| edge.type == :break })
      result = graph.check_path
      assert_includes event_kinds(result), :invoke_block
      assert_equal :normal, exit_kind(result)
    end

    def test_block_nonlocal_return
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          values.each do
            return :done
          end
          after
        end
      RUBY

      assert(graph.edges.any? { |edge| edge.type == :nonlocal_return })
      assert(graph.regions.any? { |region| region.kind == :block })
    end

    def test_lambda_return_is_local
      graph = SyntaxTree.cfg(<<~RUBY)
        def example
          callback = -> { return 1 }
          callback.call
          after
        end
      RUBY

      region = graph.regions.find { |item| item.kind == :lambda }
      assert region
      assert(
        graph.edges.any? do |edge|
          edge.type == :invoke_lambda && edge.metadata[:region] == region.id
        end
      )
      assert(graph.edges.any? { |edge| edge.type == :lambda_return })
      refute(
        graph.edges.any? do |edge|
          edge.type == :nonlocal_return && edge.metadata[:region] == region.id
        end
      )
      result = graph.check_path
      assert_includes event_kinds(result), :invoke_lambda
      assert_equal :normal, exit_kind(result)
    end

    def test_loop_next_redo_and_retry
      source = <<~RUBY
        def example
          while ready?
            redo if restart?
            next if skip?
            begin
              work
            rescue
              retry
            end
          end
        end
      RUBY
      graph = SyntaxTree.cfg(source)

      assert(graph.edges.any? { |edge| edge.type == :redo })
      assert(graph.edges.any? { |edge| edge.type == :next })
      assert(graph.edges.any? { |edge| edge.type == :retry })
      assert(graph.blocks.any? { |block| block.kind == :loop_predicate })
      assert(graph.blocks.any? { |block| block.kind == :rescue_guard })
    end

    private

    def event_kinds(result)
      result.events.map { |event| event[:kind] }
    end

    def exit_kind(result)
      result.exit[:kind] || :unknown
    end
  end
end
