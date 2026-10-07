# frozen_string_literal: true

module SyntaxTree
  # ControlFlowGraph builds a read-only control-flow graph (CFG) for a
  # method, block, or lambda. The graph covers:
  #
  # * conditionals (+if+/+unless+/+elsif+/+else+, ternary, +case/when+,
  #   +case/in+)
  # * loops (+while+/+until+ including modifier and "begin ... end while"
  #   forms, +for+)
  # * short-circuit operators (+&&+, +||+, +and+, +or+)
  # * exception handling (+begin/rescue/else/ensure+, modifier +rescue+)
  # * non-local exits (+return+, +break+, +next+, +redo+, +retry+)
  #
  # A few design notes:
  #
  # * Every edge carries the location of the AST node that caused it, so
  #   the graph can always be traced back to the original source.
  # * Calls (and operators, which are calls in Ruby) may raise in ways
  #   that cannot be determined statically. Those are represented with
  #   *conservative* exception edges to the innermost "rescue" handler
  #   (or to the exceptional exit of the graph when there is no handler).
  # * An "ensure" clause runs on every way out of its body. When the
  #   "ensure" clause itself exits abruptly (for example a +return+ or
  #   an exception raised inside the "ensure"), that new exit reason
  #   *overrides* whatever was in flight before. This is modeled with an
  #   explicit +:override+ edge rather than a plain sequential edge,
  #   because the previous exit reason (e.g. a pending exception) is
  #   discarded and replaced.
  #
  # The graph is read-only: once built, vertices and edges are frozen
  # and no mutation API is exposed.
  class ControlFlowGraph
    # A single vertex in the control-flow graph. Each vertex corresponds
    # to one AST node (a statement or a significant sub-expression),
    # except for synthetic vertices such as the entry and exit of the
    # graph.
    class Vertex
      # [Integer] a unique identifier for the vertex within the graph
      attr_reader :id

      # [nil | Node] the AST node this vertex was generated from
      attr_reader :node

      # [String] a human-readable label for the vertex
      attr_reader :label

      def initialize(id, node, label)
        @id = id
        @node = node
        @label = label
        freeze
      end

      # The location of the underlying AST node, if any.
      def location
        node&.location
      end

      # Whether this vertex was synthesized by the graph (entry/exit)
      # rather than generated from an AST node.
      def synthetic?
        node.nil?
      end

      def inspect
        "#<#{self.class.name} id=#{id} label=#{label.inspect}>"
      end

      alias to_s inspect
    end

    # A single directed edge in the control-flow graph.
    class Edge
      # [Vertex] the vertex the edge starts from
      attr_reader :from

      # [Vertex] the vertex the edge points to
      attr_reader :to

      # [Symbol] the kind of control flow this edge represents. One of
      # :sequential, :true, :false, :loop, :else, :rescue, :ensure,
      # :exception, :return, :break, :next, :redo, :retry, or :override.
      attr_reader :kind

      # [nil | Node] the AST node that caused this edge
      attr_reader :node

      # [nil | Symbol] for :ensure edges, the exit reason that was in
      # flight when control entered the ensure clause (:normal, :return,
      # :break, :next, :redo, :retry, or :exception)
      attr_reader :pending

      # [nil | Symbol] for :override edges, the exit reason that was
      # discarded by the new exit raised inside the ensure clause
      attr_reader :overrides

      def initialize(
        from,
        to,
        kind,
        node,
        pending: nil,
        overrides: nil,
        conservative: false
      )
        @from = from
        @to = to
        @kind = kind
        @node = node
        @pending = pending
        @overrides = overrides
        @conservative = conservative
        freeze
      end

      # The location of the AST node that caused this edge. Every edge
      # is attached to a source location.
      def location
        node&.location
      end

      # Whether this edge represents control flow that cannot be
      # determined statically (for example, an exception that a call may
      # or may not raise).
      def conservative?
        @conservative
      end

      def inspect
        "#<#{self.class.name} #{from.id} -> #{to.id} kind=#{kind}>"
      end

      alias to_s inspect
    end

    # [Vertex] the synthetic entry vertex of the graph
    attr_reader :entry

    # [Vertex] the synthetic exit vertex of the graph (normal
    # termination, including return/break/next out of the entry point)
    attr_reader :exit

    # [Vertex] the synthetic vertex where uncaught exceptions leave the
    # graph
    attr_reader :exceptional_exit

    # [Vertex[]] all vertices in the graph
    attr_reader :vertices

    # [Edge[]] all edges in the graph
    attr_reader :edges

    def initialize(entry, exit, exceptional_exit, vertices, edges)
      @entry = entry
      @exit = exit
      @exceptional_exit = exceptional_exit
      @vertices = vertices.freeze
      @edges = edges.freeze

      outgoing = Hash.new { |hash, key| hash[key] = [] }
      incoming = Hash.new { |hash, key| hash[key] = [] }
      edges.each do |edge|
        outgoing[edge.from] << edge
        incoming[edge.to] << edge
      end

      @successors = outgoing.transform_values(&:freeze).freeze
      @predecessors = incoming.transform_values(&:freeze).freeze
      freeze
    end

    # Build a control-flow graph from the given AST node. The node must
    # be a method definition (+def+), a block, a lambda, a +begin+ node,
    # or a statements list.
    def self.build(node)
      Builder.new.build(node)
    end

    # The edges leaving the given vertex.
    def successors(vertex)
      @successors.fetch(vertex, EMPTY_EDGES)
    end

    # The edges entering the given vertex.
    def predecessors(vertex)
      @predecessors.fetch(vertex, EMPTY_EDGES)
    end

    EMPTY_EDGES = [].freeze
    private_constant :EMPTY_EDGES

    # The internal builder that walks the AST and produces the graph.
    # This is kept separate from the graph itself so that the resulting
    # graph object exposes no mutation API.
    class Builder
      # A pending exit from a fragment of the graph. While the graph is
      # being built, exits are collected and then connected to whatever
      # comes next.
      #
      # [vertex] the vertex control is leaving from
      # [kind] the edge kind to use when this exit is connected onward
      # [reason] the exit reason (:normal, :return, :break, :next,
      #   :redo, :retry, or :exception) used for ensure routing
      # [node] the AST node that caused this exit
      # [conservative] whether this exit cannot be determined statically
      # [overrides] the exit reason this exit overrides, if any
      Exit =
        Struct.new(:vertex, :kind, :reason, :node, :conservative, :overrides)

      # A compiled fragment of the graph: a set of entry vertices and a
      # set of pending exits.
      Fragment = Struct.new(:entries, :exits)

      # Node types whose evaluation performs a call and therefore may
      # raise in ways we cannot statically rule out.
      CALL_LIKE = [
        ARef,
        Binary,
        CallNode,
        Command,
        CommandCall,
        MethodAddBlock,
        Super,
        Unary,
        VCall,
        YieldNode,
        ZSuper
      ].freeze

      SHORT_CIRCUIT = %i[&& || and or].freeze

      def build(node)
        fragment = compile_entry(node)

        entry = add_vertex(nil, "entry")
        exit = add_vertex(nil, "exit")
        exceptional_exit = add_vertex(nil, "exceptional exit")

        if fragment.entries.empty?
          add_edge(entry, exit, :sequential, node)
        else
          fragment.entries.each do |vertex|
            add_edge(entry, vertex, :sequential, node)
          end
        end

        fragment.exits.each do |pending|
          case pending.reason
          when :normal, :return, :break, :next
            add_edge(
              pending.vertex,
              exit,
              pending.kind,
              pending.node,
              overrides: pending.overrides,
              conservative: pending.conservative
            )
          when :exception
            add_edge(
              pending.vertex,
              exceptional_exit,
              pending.kind,
              pending.node,
              overrides: pending.overrides,
              conservative: pending.conservative
            )
          when :redo, :retry
            # Invalid outside of a loop or rescue clause; model
            # conservatively as an abnormal exit.
            add_edge(
              pending.vertex,
              exceptional_exit,
              pending.kind,
              pending.node,
              conservative: true
            )
          end
        end

        ControlFlowGraph.new(
          entry,
          exit,
          exceptional_exit,
          @vertices || [],
          @edges || []
        )
      end

      private

      def compile_entry(node)
        case node
        when DefNode
          compile(node.bodystmt, nil)
        when BlockNode
          compile(node.bodystmt, nil)
        when Lambda
          compile(node.statements, nil)
        when Begin, Statements
          compile(node, nil)
        when Program
          compile(node.statements, nil)
        else
          raise ArgumentError,
                "cannot build a control-flow graph from #{node.class}"
        end
      end

      def compile(node, ctx)
        case node
        when nil
          fragment_for_empty
        when Statements
          compile_list(node.body, ctx)
        when BodyStmt
          compile_body_stmt(node, ctx)
        when Begin
          compile(node.bodystmt, ctx)
        when IfNode
          compile_conditional(node, ctx, negate: false)
        when UnlessNode
          compile_conditional(node, ctx, negate: true)
        when Elsif
          compile_conditional(node, ctx, negate: false)
        when WhileNode
          compile_loop(node, ctx, negate: false)
        when UntilNode
          compile_loop(node, ctx, negate: true)
        when For
          compile_for(node, ctx)
        when Case
          compile_case(node, ctx)
        when RescueMod
          compile_rescue_mod(node, ctx)
        when ReturnNode
          compile_jump(node, node.arguments, ctx, :return)
        when Break
          compile_jump(node, node.arguments, ctx, :break)
        when Next
          compile_jump(node, node.arguments, ctx, :next)
        when Redo
          compile_jump(node, nil, ctx, :redo)
        when Retry
          compile_jump(node, nil, ctx, :retry)
        when VoidStmt, EmbDoc
          fragment_for_empty
        else
          compile_expression(node, ctx)
        end
      end

      def compile_list(nodes, ctx)
        fragment = Fragment.new([], [])
        nodes.each do |statement|
          fragment = sequence(fragment, compile(statement, ctx))
        end
        fragment
      end

      def sequence(first, second)
        leftover = connect(first.exits, second.entries)
        Fragment.new(
          first.entries.empty? ? second.entries : first.entries,
          leftover + second.exits
        )
      end

      # Connect pending exits to the entry vertices of the next fragment.
      # Only exits whose reason is :normal are connected (unless force is
      # given); every other exit reason propagates outward and is returned.
      def connect(exits, entries, kind: nil, force: false)
        return exits if entries.empty?

        remaining = []
        exits.each do |exit|
          if force || exit.reason == :normal
            entries.each do |entry|
              add_edge(
                exit.vertex,
                entry,
                kind || exit.kind,
                exit.node,
                conservative: exit.conservative
              )
            end
          else
            remaining << exit
          end
        end
        remaining
      end

      def fragment_for_empty
        Fragment.new([], [])
      end

      def compile_conditional(node, ctx, negate:)
        entries, trues, falses, others =
          condition_parts(node.predicate, ctx, negate)

        body = compile(node.statements, ctx)
        leftover = connect(trues, body.entries)

        falsy_exits =
          case (consequent = node.consequent)
          when nil
            falses
          when Else
            else_fragment = compile(consequent.statements, ctx)
            connect(falses, else_fragment.entries) + else_fragment.exits
          when Elsif
            elsif_fragment = compile_conditional(consequent, ctx, negate: false)
            connect(falses, elsif_fragment.entries) + elsif_fragment.exits
          else
            falses
          end

        Fragment.new(entries, leftover + body.exits + falsy_exits + others)
      end

      # Compile a predicate into entry vertices plus the pending exits on
      # which the value is known to be truthy or falsy. Short-circuit
      # operators produce exits that are already tagged :true or :false;
      # anything else is split into both.
      def condition_parts(node, ctx, negate)
        fragment = compile_expression(node, ctx)
        trues = []
        falses = []
        others = []

        fragment.exits.each do |exit|
          if exit.reason != :normal
            others << exit
            next
          end

          case exit.kind
          when :sequential
            trues << rekind(exit, negate ? :false : :true)
            falses << rekind(exit, negate ? :true : :false)
          when :true
            (negate ? falses : trues) << exit
          when :false
            (negate ? trues : falses) << exit
          end
        end

        [fragment.entries, trues, falses, others]
      end

      def rekind(exit, kind)
        Exit.new(exit.vertex, kind, exit.reason, exit.node, exit.conservative)
      end

      def compile_loop(node, ctx, negate:)
        post_condition =
          node.modifier? && node.statements.is_a?(Statements) &&
            node.statements.body.length == 1 &&
            node.statements.body.first.is_a?(Begin)

        if post_condition
          # "begin ... end while predicate" runs the body at least once.
          body = compile(node.statements, ctx)
          entries, trues, falses, others =
            condition_parts(node.predicate, ctx, negate)
          normal, breaks, nexts, redos, rest = partition_loop_exits(body.exits)

          connect(normal, entries, kind: :loop)
          connect(nexts, entries, force: true)
          connect(redos, body.entries, force: true)
          connect(trues, body.entries, kind: :loop)

          exits = falses + normalize_breaks(breaks) + rest + others
          Fragment.new(body.entries, exits)
        else
          entries, trues, falses, others =
            condition_parts(node.predicate, ctx, negate)
          body = compile(node.statements, ctx)
          normal, breaks, nexts, redos, rest = partition_loop_exits(body.exits)

          connect(normal, entries, kind: :loop)
          connect(nexts, entries, force: true)
          connect(redos, body.entries, force: true)

          leftover =
            if body.entries.empty?
              # An empty body re-tests the predicate directly.
              connect(trues, entries, kind: :loop)
            else
              connect(trues, body.entries)
            end

          exits = leftover + falses + normalize_breaks(breaks) + rest + others
          Fragment.new(entries, exits)
        end
      end

      def partition_loop_exits(exits)
        normal = []
        breaks = []
        nexts = []
        redos = []
        rest = []

        exits.each do |exit|
          case exit.reason
          when :normal
            normal << exit
          when :break
            breaks << exit
          when :next
            nexts << exit
          when :redo
            redos << exit
          else
            rest << exit
          end
        end

        [normal, breaks, nexts, redos, rest]
      end

      # A break absorbed by a loop becomes a normal exit of the loop
      # itself, keeping its :break (or :override) edge kind.
      def normalize_breaks(breaks)
        breaks.map do |exit|
          Exit.new(
            exit.vertex,
            exit.kind,
            :normal,
            exit.node,
            exit.conservative,
            exit.overrides
          )
        end
      end

      def compile_for(node, ctx)
        collection = compile_expression(node.collection, ctx)
        body = compile(node.statements, ctx)
        leftover = connect(collection.exits, body.entries)

        normal, breaks, nexts, redos, rest = partition_loop_exits(body.exits)
        connect(normal, body.entries, kind: :loop)
        connect(nexts, body.entries, force: true)
        connect(redos, body.entries, force: true)

        # A for loop terminates when its collection is exhausted, which
        # cannot be determined statically, so the end of the body also
        # flows onward to whatever comes after the loop.
        exhausted = normal.map { |exit| rekind(exit, :sequential) }

        Fragment.new(
          collection.entries,
          leftover + exhausted + normalize_breaks(breaks) + rest
        )
      end

      def compile_case(node, ctx)
        value = node.value ? compile_expression(node.value, ctx) : nil
        entries, exits = compile_clauses(node.consequent, ctx)
        leftover = value ? connect(value.exits, entries) : []

        Fragment.new(
          value && !value.entries.empty? ? value.entries : entries,
          leftover + exits
        )
      end

      def compile_clauses(clause, ctx)
        case clause
        when nil
          [[], []]
        when When
          compile_match_clause(clause, ctx, no_match: :normal)
        when In
          compile_match_clause(clause, ctx, no_match: :exception)
        end
      end

      def compile_match_clause(clause, ctx, no_match:)
        vertex = add_vertex(clause)
        exits = []
        conservative = conservative_exit(vertex, clause, ctx)
        exits << conservative if conservative

        body = compile(clause.statements, ctx)
        leftover =
          connect([Exit.new(vertex, :true, :normal, clause)], body.entries)
        exits.concat(leftover).concat(body.exits)

        case (consequent = clause.consequent)
        when nil
          if no_match == :exception
            # case/in without an else raises NoMatchingPatternError.
            exits << Exit.new(vertex, :exception, :exception, clause)
          else
            exits << Exit.new(vertex, :false, :normal, clause)
          end
        when Else
          else_fragment = compile(consequent.statements, ctx)
          exits.concat(
            connect(
              [Exit.new(vertex, :false, :normal, clause)],
              else_fragment.entries
            )
          )
          exits.concat(else_fragment.exits)
        else
          entries, clause_exits = compile_clauses(consequent, ctx)
          connect([Exit.new(vertex, :false, :normal, clause)], entries)
          exits.concat(clause_exits)
        end

        [[vertex], exits]
      end

      def compile_rescue_mod(node, ctx)
        value = compile_expression(node.value, ctx)
        statement_ctx = value.entries.empty? ? ctx : value.entries
        statement = compile(node.statement, statement_ctx)
        Fragment.new(statement.entries, statement.exits + value.exits)
      end

      def compile_body_stmt(node, ctx)
        # Degenerate case: an empty body with only an ensure clause. The
        # ensure clause always runs, so it is effectively the body.
        if node.statements.empty? && !node.rescue_clause && !node.else_clause &&
             node.ensure_clause
          return compile(node.ensure_clause.statements, ctx)
        end

        # Create the vertices for the rescue clauses first so that
        # conservative exception edges raised inside the body have
        # somewhere to go.
        rescue_clauses = []
        clause = node.rescue_clause
        while clause
          rescue_clauses << clause
          clause = clause.consequent
        end
        rescue_vertices = rescue_clauses.map { |c| add_vertex(c) }
        rescue_vertices
          .each_cons(2)
          .with_index do |(from, to), index|
            add_edge(from, to, :exception, rescue_clauses[index])
          end

        inner_ctx = rescue_vertices.empty? ? ctx : rescue_vertices
        body = compile(node.statements, inner_ctx)
        body_exits = absorb_retries(body, body.entries)

        rescue_exits = []
        rescue_clauses.each_with_index do |rescue_clause, index|
          vertex = rescue_vertices[index]
          handled = compile(rescue_clause.statements, ctx)
          leftover =
            connect(
              [Exit.new(vertex, :rescue, :normal, rescue_clause)],
              handled.entries
            )
          rescue_exits.concat(leftover)
          rescue_exits.concat(absorb_retries(handled, body.entries))
        end

        if (last = rescue_vertices.last)
          # The exception matched no rescue clause; it propagates outward.
          rescue_exits << Exit.new(
            last,
            :exception,
            :exception,
            rescue_clauses.last
          )
        end

        if (else_clause = node.else_clause)
          else_fragment = compile(else_clause, ctx)
          normal, other = body_exits.partition { |e| e.reason == :normal }
          leftover = connect(normal, else_fragment.entries, kind: :else)
          body_exits = other + leftover + else_fragment.exits
        end

        exits = body_exits + rescue_exits
        if node.ensure_clause
          exits = route_through_ensure(exits, node.ensure_clause, ctx)
        end
        Fragment.new(body.entries, exits)
      end

      def absorb_retries(fragment, begin_entries)
        retries, rest =
          fragment.exits.partition { |exit| exit.reason == :retry }
        connect(retries, begin_entries, force: true)
        rest
      end

      # Route every exit of a begin body through its ensure clause. The
      # ensure clause is compiled once per pending exit reason (mirroring
      # how CRuby duplicates ensure bodies). If the ensure clause itself
      # exits abruptly, that new exit reason overrides the pending one,
      # which is modeled with an :override exit rather than a plain
      # sequential edge.
      def route_through_ensure(exits, ensure_node, ctx)
        routed = []

        exits
          .group_by(&:reason)
          .each do |reason, group|
            fragment = compile(ensure_node.statements, ctx)

            if fragment.entries.empty?
              routed.concat(group)
              next
            end

            group.each do |exit|
              fragment.entries.each do |entry|
                add_edge(
                  exit.vertex,
                  entry,
                  :ensure,
                  ensure_node,
                  pending: reason,
                  conservative: exit.conservative
                )
              end
            end

            fragment.exits.each do |exit|
              if exit.reason == :normal
                # The ensure clause completed normally; the exit reason
                # that was in flight before continues on its way.
                routed << Exit.new(
                  exit.vertex,
                  exit_kind_for(reason),
                  reason,
                  exit.node,
                  exit.conservative
                )
              else
                # The ensure clause itself exits abruptly. This overrides
                # whatever exit reason was in flight before; it is not a
                # plain sequential edge.
                routed << Exit.new(
                  exit.vertex,
                  :override,
                  exit.reason,
                  exit.node,
                  exit.conservative,
                  reason
                )
              end
            end
          end

        routed
      end

      def exit_kind_for(reason)
        case reason
        when :return
          :return
        when :break
          :break
        when :next
          :next
        when :redo
          :redo
        when :retry
          :retry
        when :exception
          :exception
        else
          :sequential
        end
      end

      def compile_jump(node, arguments, ctx, reason)
        fragment =
          case arguments
          when nil
            fragment_for_empty
          when Args
            compile_list(arguments.parts, ctx)
          else
            compile_expression(arguments, ctx)
          end

        vertex = add_vertex(node)
        leftover = connect(fragment.exits, [vertex])
        Fragment.new(
          fragment.entries.empty? ? [vertex] : fragment.entries,
          leftover + [Exit.new(vertex, reason, reason, node)]
        )
      end

      def compile_expression(node, ctx)
        case node
        when IfOp
          compile_if_op(node, ctx)
        when Binary
          if SHORT_CIRCUIT.include?(node.operator)
            compile_short_circuit(node, ctx)
          else
            compile_leaf(node, ctx)
          end
        when RescueMod
          compile_rescue_mod(node, ctx)
        when Paren
          node.contents ? compile(node.contents, ctx) : fragment_for_empty
        when Not, Unary
          operand =
            if node.statement
              compile_expression(node.statement, ctx)
            else
              fragment_for_empty
            end
          vertex = add_vertex(node)
          leftover = connect(operand.exits, [vertex])
          exits = [Exit.new(vertex, :sequential, :normal, node)]
          conservative = conservative_exit(vertex, node, ctx)
          exits << conservative if conservative
          Fragment.new(
            operand.entries.empty? ? [vertex] : operand.entries,
            leftover + exits
          )
        else
          compile_leaf(node, ctx)
        end
      end

      def compile_if_op(node, ctx)
        entries, trues, falses, others =
          condition_parts(node.predicate, ctx, false)
        truthy = compile_expression(node.truthy, ctx)
        falsy = compile_expression(node.falsy, ctx)
        leftover =
          connect(trues, truthy.entries) + connect(falses, falsy.entries)
        Fragment.new(entries, leftover + truthy.exits + falsy.exits + others)
      end

      def compile_short_circuit(node, ctx)
        entries, trues, falses, others = condition_parts(node.left, ctx, false)
        right = compile_expression(node.right, ctx)

        if %i[&& and].include?(node.operator)
          leftover = connect(trues, right.entries)
          exits = falses + leftover + right.exits
        else
          leftover = connect(falses, right.entries)
          exits = trues + leftover + right.exits
        end

        Fragment.new(entries, exits + others)
      end

      def compile_leaf(node, ctx)
        vertex = add_vertex(node)
        exits = [Exit.new(vertex, :sequential, :normal, node)]
        if may_raise?(node)
          conservative = conservative_exit(vertex, node, ctx)
          exits << conservative if conservative
        end
        Fragment.new([vertex], exits)
      end

      def may_raise?(node)
        contains_call?(node)
      end

      def contains_call?(node)
        return false unless node.is_a?(Node)
        return true if CALL_LIKE.any? { |type| node.is_a?(type) }

        node.child_nodes.any? do |child|
          case child
          when Node
            contains_call?(child)
          when Array
            child.any? { |element| contains_call?(element) }
          else
            false
          end
        end
      end

      # A call may raise in ways we cannot statically rule out. If there
      # is a rescue handler in scope, draw a conservative edge to it right
      # away; otherwise produce a pending exception exit that propagates
      # outward (through any ensure clauses) to the exceptional exit.
      def conservative_exit(vertex, node, ctx)
        if ctx
          ctx.each do |target|
            add_edge(vertex, target, :exception, node, conservative: true)
          end
          nil
        else
          Exit.new(vertex, :exception, :exception, node, true)
        end
      end

      def add_vertex(node, label = nil)
        vertex =
          Vertex.new(
            next_id,
            node,
            label || (node ? node.class.name.split("::").last : nil)
          )
        @vertices ||= []
        @vertices << vertex
        vertex
      end

      def add_edge(
        from,
        to,
        kind,
        node,
        pending: nil,
        overrides: nil,
        conservative: false
      )
        edge =
          Edge.new(
            from,
            to,
            kind,
            node,
            pending: pending,
            overrides: overrides,
            conservative: conservative
          )
        @edges ||= []
        @edges << edge
        edge
      end

      def next_id
        id = @next_id || 0
        @next_id = id + 1
        id
      end
    end
  end
end
