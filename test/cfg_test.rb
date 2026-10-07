# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class CFGTest < Minitest::Test
    def test_builds_basic_blocks_with_locations
      graph = graph_for(<<~RUBY)
        def demo
          value
        end
      RUBY

      assert_equal :entry, graph.entry.kind
      instruction = graph.instructions.find { |candidate| candidate.source == "value" }
      assert_equal :call, instruction.type
      assert_equal 2, instruction.location.start_line
      assert_equal 2, instruction.location.end_line
    end

    def test_conditional_and_short_circuit_edges
      graph = graph_for(<<~RUBY)
        def demo
          if ready && value
            work
          end
        end
      RUBY

      labels = graph.edges.map(&:label).compact
      assert_includes labels, :truthy
      assert_includes labels, :falsy
      assert_includes graph.instructions.map(&:type), :short_circuit_left
    end

    def test_unknown_call_has_effect_call_and_exception_edges
      graph = graph_for(<<~RUBY)
        def demo
          recursive_value
        end
      RUBY

      call_edge = graph.edges.find { |edge| edge.type == :call }
      assert_equal CFG::UNKNOWN_CALL_TARGET, call_edge.metadata[:target]
      assert graph.edges.any? { |edge| edge.type == :exception }
      assert graph.instructions.flat_map(&:effects).any? { |effect| effect[:kind] == :unknown_effect }
    end

    def test_recursive_call_is_a_call_edge_but_not_expanded
      graph = graph_for(<<~RUBY)
        def demo
          demo
        end
      RUBY

      call_edge = graph.edges.find { |edge| edge.type == :call }
      assert_equal "call:demo", call_edge.metadata[:target]
      assert_equal 0, graph.regions.size
    end

    def test_return_runs_ensure_before_return_exit
      source = <<~RUBY
        def demo
          begin
            return 1
          ensure
            cleanup
          end
        end
      RUBY
      result = CFG.check_path(source, method_name: :demo)

      types = result[:events].map { |event| event[:type] }
      assert_equal [:return_node, :ensure_enter, :call, :exit], types
      assert_equal :return, result[:exit]
    end

    def test_exception_rescue_else_and_ensure_have_distinct_edges
      graph = graph_for(<<~RUBY)
        def demo
          begin
            body
          rescue Error
            handled
          else
            complete
          ensure
            cleanup
          end
        end
      RUBY

      assert graph.edges.any? { |edge| edge.type == :rescue_match }
      assert graph.instructions.any? { |instruction| instruction.type == :ensure_enter }
    end

    def test_exception_path_runs_ensure_then_rescue_and_continues
      source = <<~RUBY
        def demo
          begin
            body
          rescue Error
            handled
          ensure
            cleanup
          end
          after
        end
      RUBY
      result = CFG.check_path(source, method_name: :demo, choices: { "body" => :exception })

      types = result[:events].map { |event| event[:type] }
      sources = result[:events].map { |event| event[:source] }
      assert_equal :call, types[0]
      assert_equal :ensure_enter, types[1]
      assert_equal "cleanup", sources[2]
      assert_equal :rescue_match, types[3]
      assert_equal "handled", sources[4]
      assert_equal "after", sources[5]
      assert_equal :normal, result[:exit]
    end

    def test_nested_ensure_uses_shared_bodies_and_preserves_order
      source = <<~RUBY
        def demo
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
      graph = CFG.build(source, method_name: :demo)
      ensure_bodies =
        graph.instructions.select do |instruction|
          %w[inner outer].include?(instruction.source)
        end
      assert_equal 1, ensure_bodies.count { |instruction| instruction.source == "inner" }
      assert_equal 1, ensure_bodies.count { |instruction| instruction.source == "outer" }

      result = CFG.check_path(source, method_name: :demo)
      calls = result[:events].select { |event| event[:type] == :call }.map { |event| event[:source] }
      assert_equal %w[inner outer], calls
      assert_equal :return, result[:exit]
    end

    def test_return_inside_ensure_overrides_original_exit
      source = <<~RUBY
        def demo
          begin
            return 1
          ensure
            return 2
          end
        end
      RUBY
      result = CFG.check_path(source, method_name: :demo)

      returns = result[:events].select { |event| event[:type] == :return_node }.map { |event| event[:source] }
      assert_equal ["return 1", "return 2"], returns
      assert_equal :return, result[:exit]
    end

    def test_exception_inside_ensure_overrides_original_exception
      source = <<~RUBY
        def demo
          begin
            body
          ensure
            fail
          end
        end
      RUBY
      result = CFG.check_path(
        source,
        method_name: :demo,
        choices: { "body" => :exception, "fail" => :exception }
      )

      calls = result[:events].select { |event| event[:type] == :call }.map { |event| event[:source] }
      assert_equal %w[body fail], calls
      assert_equal :exception, result[:exit]
    end

    def test_block_break_is_nonlocal_to_invocation
      source = <<~RUBY
        def demo
          items.each do
            break
          end
          after
        end
      RUBY
      result = CFG.check_path(source, method_name: :demo)

      types = result[:events].map { |event| event[:type] }
      assert_includes types, :region_enter
      assert_includes types, :break
      assert_includes types, :call
      assert_equal :normal, result[:exit]
    end

    def test_lambda_return_is_local
      source = <<~RUBY
        def demo
          -> { return 1 }.call
          after
        end
      RUBY
      result = CFG.check_path(source, method_name: :demo)

      types = result[:events].map { |event| event[:type] }
      assert(types.any? { |type| type == :lambda || type == :call })
      assert_includes types, :return_node
      assert_includes types, :call
      assert_includes types, :call
      assert_equal :normal, result[:exit]
    end

    def test_loop_has_next_redo_and_back_edges
      graph = graph_for(<<~RUBY)
        def demo
          while ready
            next if paused
            redo
          end
        end
      RUBY

      types = graph.edges.map(&:type)
      assert_includes types, :loop_back
      assert graph.edges.any? { |edge| edge.type == :next }
      assert graph.edges.any? { |edge| edge.type == :redo }
    end

    def test_retry_routes_to_rescue_body
      graph = graph_for(<<~RUBY)
        def demo
          begin
            body
          rescue
            retry
          end
        end
      RUBY

      assert graph.edges.any? { |edge| edge.type == :retry }
    end

    def test_retry_runs_ensure_before_restarting_body
      graph = graph_for(<<~RUBY)
        def demo
          begin
            body
          rescue
            retry
          ensure
            cleanup
          end
        end
      RUBY

      retry_edges = graph.edges.select { |edge| edge.type == :retry }
      retry_edges.each do |edge|
        refute_equal edge.to, graph.blocks.find do |block|
          block.instructions.any? { |instruction| instruction.source == "body" }
        end
      end
      assert graph.instructions.one? { |instruction| instruction.source == "cleanup" }
    end

    private

    def graph_for(source)
      SyntaxTree::CFG.build(source, method_name: :demo)
    end
  end
end
