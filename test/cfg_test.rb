# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class CFGTest < Minitest::Test
    def test_read_only_graph
      graph = build_graph("def m; foo; end")

      assert_kind_of CFG::Graph, graph
      assert_predicate graph, :frozen?
      assert_predicate graph.blocks.to_a.first, :frozen?
      assert_predicate graph.edges.to_a.first, :frozen?
    end

    def test_conditions_and_short_circuit
      graph =
        build_graph(<<~RUBY)
          def m
            if a
              b
            elsif c
              d
            else
              e
            end
            x && y
          end
        RUBY

      assert_includes edge_types(graph), :branch_true
      assert_includes edge_types(graph), :branch_false
      assert_includes edge_types(graph), :short_circuit
    end

    def test_loop_jumps
      graph =
        build_graph(<<~RUBY)
          def m
            while ready
              break if stopping
              next if skipping
              redo if repeating
            end
          end
        RUBY

      assert_includes edge_types(graph), :loop_back
      assert_jump_target(graph, :break) { |edge| graph[edge.to].kind == :join }
      assert_jump_target(graph, :next) { |edge| graph[edge.to].kind == :test }
      assert_jump_target(graph, :redo) { |edge| graph[edge.to].node.is_a?(Statements) }
    end

    def test_modifier_loops
      graph =
        build_graph(<<~RUBY)
          def m
            work while ready
            play until done
          end
        RUBY

      work_test = graph.find { |block| block.kind == :test }
      work_edges = graph.successors(work_test.id).map(&:type)
      assert_includes work_edges, :branch_true
      assert_includes work_edges, :branch_false
    end

    def test_case_matcher_has_conservative_exception_edges
      graph =
        build_graph(<<~RUBY)
          def m
            case value
            when custom_match
              matched
            end
          rescue StandardError
            recovered
          end
        RUBY

      matcher_edges =
        graph.edges.select do |edge|
          edge.type == :call_exception &&
            graph[edge.to].node.is_a?(Rescue)
        end

      refute_empty matcher_edges
      assert(matcher_edges.all? { |edge| edge.reason == :exception })
    end

    def test_block_entry_and_jumps
      graphs =
        CFG.for_source(
          <<~RUBY
            def m
              values.each do |value|
                break if stopping(value)
                next if skipping(value)
                redo if repeating(value)
              end
            end
          RUBY
        )

      assert_equal 2, graphs.length
      block_graph = graphs.last
      assert_kind_of BlockNode, block_graph.entry_node
      assert_includes edge_types(block_graph), :break
      assert_includes edge_types(block_graph), :next
      assert_includes edge_types(block_graph), :redo
    end

    def test_rescue_else_ensure_and_conservative_call_edges
      graph =
        build_graph(<<~RUBY)
          def m
            work
          rescue custom_error
            recovered
          else
            completed
          ensure
            cleanup
          end
        RUBY

      assert_includes edge_types(graph), :call_exception
      assert_includes edge_types(graph), :exception_match
      assert_includes edge_types(graph), :exception_mismatch
      assert_includes edge_types(graph), :ensure_exit
      assert graph.edges.all? { |edge| edge.location.is_a?(Location) }
    end

    def test_ensure_return_replaces_exception_path
      source = <<~RUBY
        def example(log)
          log << :before
          raise "boom"
        rescue StandardError => error
          log << [:rescue, error.message]
          raise
        ensure
          log << :ensure
          return :ensured
        end
      RUBY

      runtime_log = []
      result = evaluate(source, runtime_log, :example)

      assert_equal :ensured, result
      assert_equal [:before, [:rescue, "boom"], :ensure], runtime_log

      graph = build_graph(source)
      path = find_replaced_return_path(graph)

      labels = path_labels(path, graph)
      assert_equal [:before, :rescue, :raise, :ensure, :return], labels
      assert_equal :exception, path.fetch(:edge).reason
      assert path.fetch(:return_edge).replaces?
      assert_equal :return, path.fetch(:return_edge).type
    end

    private

    def build_graph(source)
      program = SyntaxTree.parse(source)
      entry = program.statements.body.find { |node| node.is_a?(DefNode) }
      CFG.build(entry)
    end

    def edge_types(graph)
      graph.edges.map(&:type).uniq
    end

    def assert_jump_target(graph, type, &block)
      assert graph.edges.any? { |edge| edge.type == type && block.call(edge) }, type.to_s
    end

    def evaluate(source, log, method_name)
      mod = Module.new
      mod.module_eval(source, __FILE__, __LINE__)
      Object.new.extend(mod).public_send(method_name, log)
    end

    def find_replaced_return_path(graph)
      queue = [[graph.entry, [], nil, nil, false]]
      until queue.empty?
        id, labels, incoming, return_edge, rescued = queue.shift
        graph.successors(id).each do |successor|
          next_labels = labels + [[successor, graph[successor.to].node]]
          next_return = return_edge
          next_incoming = incoming
          next_rescued = rescued

          next_rescued = true if successor.type == :exception_match
          source_node = graph[successor.from].node
          reraised = source_node.is_a?(VCall) && source_node.value.value == "raise"
          if successor.type == :call_exception && rescued && reraised
            next_incoming = successor
          elsif successor.type == :return && successor.replaces?
            next_return = successor
          end

          if successor.to == graph.exit && next_incoming && next_return
            return {
              labels: next_labels,
              edge: next_incoming,
              return_edge: next_return
            }
          end
          queue << [successor.to, next_labels, next_incoming, next_return, next_rescued]
        end
      end

      flunk("expected an exception path replaced by an ensure return")
    end

    def path_labels(path, graph)
      path.fetch(:labels).filter_map do |edge, node|
        next unless node.is_a?(VCall) || node.is_a?(Command) || node.is_a?(ReturnNode) ||
                      (node.is_a?(Binary) && node.operator == :<<)

        case node
        when ReturnNode
          :return
        when Command
          node.message.value.to_sym
        when VCall
          node.value.value == "raise" ? :raise : node.value.value.to_sym
        when Binary
          label_binary(node)
        end
      end
    end

    def label_binary(node)
      right = node.right
      if right.is_a?(ArrayLiteral)
        :rescue
      elsif right.is_a?(SymbolLiteral)
        right.value.value.to_sym
      end
    end
  end
end
