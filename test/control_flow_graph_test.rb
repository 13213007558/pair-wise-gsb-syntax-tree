# frozen_string_literal: true

require_relative "test_helper"

module SyntaxTree
  class ControlFlowGraphTest < Minitest::Test
    def build(source)
      program = SyntaxTree.parse(source)
      ControlFlowGraph.build(program.statements.body.first)
    end

    def vertex_for(graph, node)
      graph.vertices.find { |vertex| vertex.node.equal?(node) }
    end

    def edge_between(graph, from, to, kind)
      graph
        .successors(from)
        .find { |edge| edge.to.equal?(to) && edge.kind == kind }
    end

    def test_if_else
      program = SyntaxTree.parse(<<~RUBY)
        def foo(x)
          if x
            a
          else
            b
          end
        end
      RUBY
      def_node = program.statements.body.first
      if_node = def_node.bodystmt.statements.body.first
      graph = ControlFlowGraph.build(def_node)

      predicate = vertex_for(graph, if_node.predicate)
      truthy = vertex_for(graph, if_node.statements.body.first)
      falsy = vertex_for(graph, if_node.consequent.statements.body.first)

      true_edge = edge_between(graph, predicate, truthy, :true)
      assert(true_edge, "expected a :true edge from the predicate")
      assert_equal(if_node.predicate.location, true_edge.location)

      false_edge = edge_between(graph, predicate, falsy, :false)
      assert(false_edge, "expected a :false edge from the predicate")
      assert_equal(if_node.predicate.location, false_edge.location)
    end

    def test_unless
      program = SyntaxTree.parse(<<~RUBY)
        def foo(x)
          unless x
            a
          end
        end
      RUBY
      def_node = program.statements.body.first
      unless_node = def_node.bodystmt.statements.body.first
      graph = ControlFlowGraph.build(def_node)

      predicate = vertex_for(graph, unless_node.predicate)
      body = vertex_for(graph, unless_node.statements.body.first)

      assert(edge_between(graph, predicate, body, :false))
      assert(edge_between(graph, predicate, graph.exit, :true))
    end

    def test_while_loop_with_break_next_redo
      program = SyntaxTree.parse(<<~RUBY)
        def foo
          while cond
            work
            break if done
            next if skip
            redo if again
          end
          after
        end
      RUBY
      def_node = program.statements.body.first
      while_node = def_node.bodystmt.statements.body.first
      after_node = def_node.bodystmt.statements.body.last
      body = while_node.statements.body
      graph = ControlFlowGraph.build(def_node)

      predicate = vertex_for(graph, while_node.predicate)
      work = vertex_for(graph, body[0])
      break_node = vertex_for(graph, body[1].statements.body.first)
      next_node = vertex_for(graph, body[2].statements.body.first)
      redo_node = vertex_for(graph, body[3].statements.body.first)
      after = vertex_for(graph, after_node)

      assert(edge_between(graph, predicate, work, :true))
      assert(edge_between(graph, predicate, after, :false))
      assert(edge_between(graph, break_node, after, :break))
      assert(edge_between(graph, next_node, predicate, :next))
      assert(edge_between(graph, redo_node, work, :redo))

      loop_backs =
        graph.predecessors(predicate).select { |edge| edge.kind == :loop }
      refute_empty(loop_backs, "expected a back edge to the predicate")
    end

    def test_short_circuit_operators
      program = SyntaxTree.parse(<<~RUBY)
        def foo
          a && b
          c || d
        end
      RUBY
      def_node = program.statements.body.first
      and_node, or_node = def_node.bodystmt.statements.body
      graph = ControlFlowGraph.build(def_node)

      a = vertex_for(graph, and_node.left)
      b = vertex_for(graph, and_node.right)
      c = vertex_for(graph, or_node.left)
      d = vertex_for(graph, or_node.right)

      assert(edge_between(graph, a, b, :true))
      assert(edge_between(graph, a, c, :false))
      assert(edge_between(graph, c, d, :false))
      assert(edge_between(graph, c, graph.exit, :true))
    end

    def test_rescue_else_ensure
      program = SyntaxTree.parse(<<~RUBY)
        def foo
          call
        rescue
          handle
        else
          ok
        ensure
          cleanup
        end
      RUBY
      def_node = program.statements.body.first
      bodystmt = def_node.bodystmt
      graph = ControlFlowGraph.build(def_node)

      call = vertex_for(graph, bodystmt.statements.body.first)
      rescue_clause = vertex_for(graph, bodystmt.rescue_clause)
      handle = vertex_for(graph, bodystmt.rescue_clause.statements.body.first)
      ok = vertex_for(graph, bodystmt.else_clause.body.first)

      exception_edge = edge_between(graph, call, rescue_clause, :exception)
      assert(exception_edge, "expected a conservative exception edge")
      assert(exception_edge.conservative?)
      assert_equal(
        bodystmt.statements.body.first.location,
        exception_edge.location
      )

      assert(edge_between(graph, rescue_clause, handle, :rescue))
      assert(edge_between(graph, call, ok, :else))

      # The ensure clause is compiled once per pending exit reason, so
      # look at the ensure edges across the whole graph.
      ensure_edges = graph.edges.select { |edge| edge.kind == :ensure }
      refute_empty(ensure_edges)
      pendings = ensure_edges.map(&:pending)
      assert_includes(pendings, :normal)
      assert_includes(pendings, :exception)

      cleanup_node = bodystmt.ensure_clause.statements.body.first
      cleanups =
        graph.vertices.select { |vertex| vertex.node.equal?(cleanup_node) }
      assert(
        cleanups.any? do |cleanup|
          edge_between(graph, cleanup, graph.exit, :sequential)
        end,
        "expected the ensure body to flow to the exit"
      )
    end

    def test_ensure_return_overrides_pending_return
      program = SyntaxTree.parse(<<~RUBY)
        def foo
          return :early
        ensure
          return :late
        end
      RUBY
      def_node = program.statements.body.first
      bodystmt = def_node.bodystmt
      graph = ControlFlowGraph.build(def_node)

      early = vertex_for(graph, bodystmt.statements.body.first)
      late = vertex_for(graph, bodystmt.ensure_clause.statements.body.first)

      ensure_edge = graph.successors(early).find { |edge| edge.kind == :ensure }
      assert(ensure_edge, "expected an :ensure edge into the ensure body")
      assert_equal(:return, ensure_edge.pending)

      override_edge = edge_between(graph, late, graph.exit, :override)
      assert(override_edge, "expected an :override edge out of ensure")
      assert_equal(:return, override_edge.overrides)

      # The overriding exit must not be a plain sequential edge, and the
      # overridden return must not reach the exit directly.
      assert_nil(edge_between(graph, late, graph.exit, :sequential))
      assert_nil(edge_between(graph, early, graph.exit, :return))
    end

    def test_block_entry
      program = SyntaxTree.parse(<<~RUBY)
        foo do |x|
          break if x
          next if x
        end
      RUBY
      block = program.statements.body.first.block
      graph = ControlFlowGraph.build(block)

      break_node =
        vertex_for(
          graph,
          block.bodystmt.statements.body[0].statements.body.first
        )
      next_node =
        vertex_for(
          graph,
          block.bodystmt.statements.body[1].statements.body.first
        )

      assert(edge_between(graph, break_node, graph.exit, :break))
      assert(edge_between(graph, next_node, graph.exit, :next))
    end

    def test_case_when
      program = SyntaxTree.parse(<<~RUBY)
        def foo(x)
          case x
          when 1
            one
          else
            other
          end
        end
      RUBY
      def_node = program.statements.body.first
      case_node = def_node.bodystmt.statements.body.first
      graph = ControlFlowGraph.build(def_node)

      when_clause = vertex_for(graph, case_node.consequent)
      one = vertex_for(graph, case_node.consequent.statements.body.first)
      other =
        vertex_for(graph, case_node.consequent.consequent.statements.body.first)

      assert(edge_between(graph, when_clause, one, :true))
      assert(edge_between(graph, when_clause, other, :false))
    end

    def test_every_edge_has_a_source_location
      graph = build(<<~RUBY)
        def foo
          call
        rescue
          handle
        ensure
          cleanup
        end
      RUBY

      graph.edges.each do |edge|
        assert_instance_of(
          Location,
          edge.location,
          "edge #{edge.inspect} is missing an AST location"
        )
      end
    end

    def test_graph_is_read_only
      graph = build("def foo\n  call\nend\n")

      assert(graph.frozen?)
      assert(graph.vertices.frozen?)
      assert(graph.edges.frozen?)
      assert(graph.vertices.all?(&:frozen?))
      assert(graph.edges.all?(&:frozen?))
      assert_raises(FrozenError) { graph.vertices << :nope }
      assert_raises(FrozenError) { graph.edges << :nope }
      refute_respond_to(graph, :add_edge)
      refute_respond_to(graph, :add_vertex)
    end

    def test_invalid_entry_point
      program = SyntaxTree.parse("1 + 1")
      assert_raises(ArgumentError) do
        ControlFlowGraph.build(program.statements.body.first)
      end
    end

    # A small function that records its execution order. The exception
    # raised in the body is turned into a return by the ensure clause.
    DEMO_SOURCE = <<~RUBY
      def demo(log)
        log << :begin
        raise "boom"
        log << :unreachable
      ensure
        log << :ensure
        return :value
      end
    RUBY

    # Maps source lines of DEMO_SOURCE to the trace symbols they record.
    TRACE_LINES = { 2 => :begin, 4 => :unreachable, 6 => :ensure }.freeze

    def test_ensure_turning_exception_into_return_matches_ruby
      # First, run the method for real and record the execution order.
      log = []
      receiver = Object.new
      receiver.instance_eval(DEMO_SOURCE, "demo.rb", 1)
      result = receiver.demo(log)

      assert_equal(:value, result)
      assert_equal(%i[begin ensure], log)

      # Next, build the control-flow graph for the same source.
      program = SyntaxTree.parse(DEMO_SOURCE)
      graph = ControlFlowGraph.build(program.statements.body.first)

      # Walk every path through the graph and collect the trace of
      # recorded symbols along each one.
      paths = []
      walk =
        lambda do |vertex, edges|
          if vertex.equal?(graph.exit)
            paths << edges
            next
          end

          graph
            .successors(vertex)
            .each do |edge|
              next if edges.include?(edge)

              walk.call(edge.to, edges + [edge])
            end
        end
      walk.call(graph.entry, [])

      traces =
        paths.map do |edges|
          edges.filter_map { |edge| TRACE_LINES[edge.to.location&.start_line] }
        end

      # The graph must contain the path that Ruby actually took.
      matching = paths.select.with_index { |_, index| traces[index] == log }
      refute_empty(
        matching,
        "no CFG path reproduces the real execution trace #{log.inspect}"
      )

      # That path enters the ensure clause with a pending exception and
      # leaves it through an override edge, not a plain sequential edge.
      path =
        matching.find do |edges|
          edges.any? do |edge|
            edge.kind == :ensure && edge.pending == :exception &&
              edge.from.location.start_line == 3
          end
        end
      assert(path, "expected a path entering ensure with a pending exception")

      ensure_edge = path.find { |edge| edge.kind == :ensure }
      assert(ensure_edge.conservative?)

      final_edge = path.last
      assert_equal(:override, final_edge.kind)
      assert_equal(:exception, final_edge.overrides)
      assert_equal(graph.exit, final_edge.to)
      refute_equal(:sequential, final_edge.kind)
    end
  end
end
