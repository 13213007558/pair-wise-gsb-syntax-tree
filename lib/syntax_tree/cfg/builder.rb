# frozen_string_literal: true

module SyntaxTree
  module CFG
    class Builder
      CALL_NODES = %i[CallNode Command CommandCall Super ZSuper YieldNode XStringLiteral VCall].freeze
      SHORT_CIRCUIT_OPERATORS = %i[&& || and or].freeze

      Frame = Struct.new(:kind, :block, :continuation, :next_target, :return_target, keyword_init: true)
      def initialize(program, source, method_name)
        @program = program
        @source = source
        @method_name = method_name
        @instruction_sequence = 0
        @region_sequence = 0
        @built_lambda_nodes = {}
        @current = nil
        @frames = []
        @exception_target = nil
      end

      def build
        method = find_method
        raise ArgumentError, "method #{@method_name.inspect} was not found" unless method

        @graph = Graph.new(method_name(method))
        entry = graph.add_block(:entry, location: location(method.location))
        normal = graph.add_block(:normal_exit, location: nil)
        return_exit = graph.add_block(:return_exit, location: nil)
        exception_exit = graph.add_block(:exception_exit, location: nil)
        graph.entry = entry
        graph.exit = normal
        graph.exits = { normal: normal, return: return_exit, exception: exception_exit }

        @current = entry
        push_frame(:method, nil, return_target: return_exit)
        previous_exception_target = @exception_target
        @exception_target = exception_exit
        continuation = build_bodystmt(method.bodystmt)
        connect(continuation, normal)
        @exception_target = previous_exception_target
        pop_frame

        prune_unreachable_blocks
        graph
      end
      private

      attr_reader :graph

      def find_method
        methods = []
        walk(@program) do |node|
          methods << node if node.is_a?(DefNode)
        end

        if @method_name.nil?
          methods.first
        else
          methods.find { |method| @method_name.nil? || method.name.value == @method_name.to_s }
        end
      end

      def prune_unreachable_blocks
        reachable = {}
        roots = graph.regions.values.flat_map do |region|
          [region[:entry], *region[:exits].values]
        end
        queue = [graph.entry, *graph.exits.values, *roots]
        until queue.empty?
          block = queue.shift
          next unless block.respond_to?(:id)
          next if reachable[block]

          reachable[block] = true
          graph.outgoing(block).each { |edge| queue << edge.to }
        end

        graph.blocks.select! { |block| reachable[block] }
        graph.edges.select! { |edge| reachable[edge.from] && reachable[edge.to] }
      end

      def method_name(method)
        method.name.value
      end

      def walk(node, &block)
        return unless node.respond_to?(:child_nodes)

        yield(node)
        node.child_nodes.compact.each { |child| walk(child, &block) }
      end

      def new_block(first = :basic, second = nil)
        if first.is_a?(Symbol)
          kind = first
          node = second
        else
          kind = :basic
          node = first
        end
        graph.add_block(kind, location: node.respond_to?(:location) ? location(node.location) : node)
      end

      def location(node_location)
        SourceLocation.new(
          start_line: node_location.start_line,
          start_column: node_location.start_column,
          end_line: node_location.end_line,
          end_column: node_location.end_column
        )
      end

      def source_for(node)
        @source[node.location.start_char...node.location.end_char]
      end

      def emit(node, type: underscore_name(node.class).to_sym, effects: [])
        @instruction_sequence += 1
        Instruction.new(
          id: "insn_#{@instruction_sequence}",
          type: type,
          source: source_for(node),
          location: location(node.location),
          effects: effects
        )
      end

      def underscore_name(klass)
        name = klass.name.split("::").last
        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
          .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
          .downcase
      end

      def close(block = @current)
        @current = new_block
        block
      end

      def connect(from, to, type = :fallthrough, node = nil, label: nil, **metadata)
        return unless from && to

        graph.add_edge(from, to, type, location: node && location(node.location), label: label, **metadata)
      end

      def push_frame(kind, continuation = nil, block: nil, next_target: nil, return_target: nil)
        @frames << Frame.new(
          kind: kind,
          block: block,
          continuation: continuation,
          next_target: next_target,
          return_target: return_target
        )
      end

      def pop_frame
        @frames.pop
      end

      def frame(kind)
        @frames.reverse.find { |candidate| frame_kind(candidate) == kind }
      end

      def frame_kind(candidate)
        candidate.is_a?(Hash) ? candidate[:kind] : candidate.kind
      end

      def frame_value(candidate, name)
        candidate.is_a?(Hash) ? candidate[name] : candidate.public_send(name)
      end

      def ensure_frames
        @frames.select { |candidate| frame_kind(candidate) == :ensure }
      end

      def build_bodystmt(bodystmt, continuation: nil)
        continuation ||= new_block
        build_protected_body(bodystmt, continuation: continuation)
      end

      def build_statements(statements, continuation: nil)
        continuation ||= new_block
        statements.body.reject { |statement| statement.is_a?(VoidStmt) }.each do |statement|
          terminal = terminal?(statement)
          @current = build_statement(statement)
          return continuation if terminal
        end

        connect(@current, continuation)
        continuation
      end

      def build_statement(node)
        case node
        when Statements
          build_statements(node)
        when Begin
          build_bodystmt(node.bodystmt)
        when IfNode, UnlessNode
          build_if(node, inverse: node.is_a?(UnlessNode))
        when IfOp
          build_ternary(node)
        when Case
          build_case(node)
        when WhileNode, UntilNode
          build_while(node)
        when For
          build_for(node)
        when Binary
          build_binary(node)
        when RescueMod
          build_rescue_mod(node)
        when MethodAddBlock
          build_block_call(node)
        when CallNode, Command, CommandCall, Super, ZSuper, YieldNode, XStringLiteral, VCall
          build_call_statement(node)
        when ReturnNode
          build_return(node)
        when Break
          build_break(node)
        when Next
          build_next(node)
        when Redo
          build_redo(node)
        when Retry
          build_retry(node)
        when Lambda
          build_lambda_expression(node)
        else
          build_generic_statement(node)
        end
      end

      def terminal?(node)
        node.is_a?(ReturnNode) || node.is_a?(Break) || node.is_a?(Next) ||
          node.is_a?(Redo) || node.is_a?(Retry)
      end

      def build_generic_statement(node)
        if node.is_a?(CallNode) && node.receiver.is_a?(Lambda)
          build_direct_lambda_call(node)
        else
          append_expression(node, @current)
          @current
        end
      end

      def build_call_statement(node)
        return build_direct_lambda_call(node) if node.is_a?(CallNode) && node.receiver.is_a?(Lambda)

        continuation = new_block
        from = close
        target = external_call_target(node)
        from.instructions << emit(node, type: :call, effects: [unknown_effect(node, target)])
        target_block = new_block(:call_target, node)
        connect(from, target_block, :call, node, target: target)
        connect(from, continuation, :call_return, node, target: target)
        add_exception_edges(from, node)
        @current = continuation
      end

      def build_direct_lambda_call(node)
        existing = @built_lambda_nodes[node.receiver]
        if existing
          continuation = new_block
          close
          connect(existing[:exits][:normal], continuation, :lambda_exit, node)
          connect(existing[:exits][:return], continuation, :lambda_return, node)
          @current = continuation
          return
        end

        continuation = new_block
        region = build_lambda_region(node.receiver, continuation)
        call_block = close
        lambda_effect = { kind: :lambda, lambda: region[:id], location: location(node.receiver.location) }
        call_block.instructions << emit(node.receiver, type: :lambda, effects: [lambda_effect])
        call_block.instructions << emit(node, type: :call, effects: [unknown_effect(node, :lambda)])
        connect(call_block, region[:entry], :call, node, target: :lambda, lambda: region[:id])
        connect(region[:exits][:normal], continuation, :lambda_exit, node)
        connect(region[:exits][:return], continuation, :lambda_return, node)
        add_exception_edges(call_block, node)
        @current = continuation
      end

      def append_expression(node, block)
        nested_blocks(node, block)
        block.instructions << emit(node, effects: effects_for(node))
        add_exception_edges(block, node)
        block
      end


      def nested_blocks(node, block)
        each_nested(node) do |child|
          next unless child.is_a?(MethodAddBlock)

          @current = block
          block = build_block_call(child)
        end
        @current = block
      end

      def each_nested(node, &block)
        return unless node.respond_to?(:child_nodes)

        node.child_nodes.compact.each do |child|
          block.call(child)
          each_nested(child, &block)
        end
      end

      def effects_for(node)
        call_node?(node) ? [unknown_effect(node)] : []
      end

      def build_expression(node, continuation, *effects)
        from = close
        effects = effects.flatten
        effects << unknown_effect(node) if call_node?(node)
        from.instructions << emit(node, effects: effects.compact)
        connect(from, continuation)
        add_exception_edges(from, node)
        from
      end

      def add_exception_edges(block, node)
        return unless may_raise?(node)

        connect(block, @exception_target, :exception, node, outcome: exception_outcome)
      end

      def exception_outcome
        { kind: :exception }
      end

      def may_raise?(node)
        contains_call?(node)
      end

      def contains_call?(node)
        found = false
        walk(node) do |child|
          found = true if call_node?(child)
        end
        found
      end

      def call_node?(node)
        CALL_NODES.any? { |name| node.is_a?(SyntaxTree.const_get(name)) } ||
          (node.is_a?(Command) && node.block)
      end

      def unknown_effect(node, target = call_target(node))
        {
          kind: :unknown_effect,
          call: call_name(node),
          target: target,
          location: location(node.location)
        }
      end

      def call_name(node)
        case node
        when CallNode then node.message == :call ? :call : node.message.value
        when Command, CommandCall then node.message.value
        when Super, ZSuper then :super
        when YieldNode then :yield
        when XStringLiteral then :system
        when VCall then node.value.value
        end
      end

      def call_target(node)
        case node
        when YieldNode then :yield
        when Super, ZSuper then :super
        when CallNode
          if node.receiver.is_a?(Lambda)
            :lambda
          elsif call_name(node).to_s == @method_name.to_s
            "call:#{@method_name}"
          else
            CFG::UNKNOWN_CALL_TARGET
          end
        else
          call_name(node).to_s == @method_name.to_s ? "call:#{@method_name}" : CFG::UNKNOWN_CALL_TARGET
        end
      end

      def external_call_target(node)
        target = call_target(node)
        target == :lambda ? CFG::UNKNOWN_CALL_TARGET : target
      end

      def build_if(node, inverse: false)
        join = new_block(node)
        truthy = new_block
        falsy = new_block
        predicate_end = build_predicate(node.predicate, truthy, falsy)
        predicate_end.instructions << emit(node.predicate, type: :branch, effects: [])
        connect(predicate_end, truthy, :branch, node, label: inverse ? :falsy : :truthy)
        connect(predicate_end, falsy, :branch, node, label: inverse ? :truthy : :falsy)

        @current = truthy
        truthy_end = build_statements(node.statements)
        connect(truthy_end, join)
        build_if_consequent(node.consequent, falsy, join)
        @current = join
      end

      def build_if_consequent(consequent, falsy, join)
        case consequent
        when nil
          connect(falsy, join)
        when Else
          @current = falsy
          end_block = build_statements(consequent.statements)
          connect(end_block, join)
        when Elsif
          @current = falsy
          elsif_node = IfNode.new(
            predicate: consequent.predicate,
            statements: consequent.statements,
            consequent: consequent.consequent,
            location: consequent.location
          )
          end_block = build_if(elsif_node)
          connect(end_block, join)
        end
      end

      def build_ternary(node)
        join = new_block(node)
        truthy = new_block
        falsy = new_block
        predicate_end = build_predicate(node.predicate, truthy, falsy)
        predicate_end.instructions << emit(node.predicate, type: :branch, effects: [])
        connect(predicate_end, truthy, :branch, node, label: :truthy)
        connect(predicate_end, falsy, :branch, node, label: :falsy)

        @current = truthy
        truthy_end = build_expression(node.truthy, join)
        @current = falsy
        falsy_end = build_expression(node.falsy, join)
        @current = join
        [truthy_end, falsy_end].first
      end

      def build_predicate(node, truthy, falsy)
        if node.is_a?(Binary) && SHORT_CIRCUIT_OPERATORS.include?(node.operator)
          build_short_circuit(node, truthy, falsy)
        else
          block = new_block(node)
          connect(@current, block)
          @current = block
          build_generic_subexpressions(node, block)
          block
        end
      end

      def build_generic_subexpressions(node, block)
        node.child_nodes.compact.each do |child|
          next unless expression_child?(child)

          child_block = new_block(child)
          connect(block, child_block)
          child_block.instructions << emit(child, effects: call_effects(child))
          add_exception_edges(child_block, child)
          block = child_block
        end
        connect(block, @current) unless graph.edges.any? { |edge| edge.from == block }
        @current = block
      end

      def expression_child?(node)
        !node.is_a?(Symbol) && node.respond_to?(:location)
      end

      def call_effects(node)
        contains_call?(node) ? [unknown_effect(find_call(node))] : []
      end

      def find_call(node)
        result = nil
        walk(node) do |child|
          result ||= child if call_node?(child)
        end
        result
      end

      def build_binary(node)
        return build_generic_statement(node) unless SHORT_CIRCUIT_OPERATORS.include?(node.operator)

        join = new_block(node)
        build_short_circuit(node, join, join)
        @current = join
      end

      def build_short_circuit(node, truthy, falsy)
        left_block = new_block(node.left)
        connect(@current, left_block)
        build_predicate_value(node.left, left_block, :short_circuit_left)

        right_block = new_block(node.right)
        if node.operator == :"&&" || node.operator == :and
          connect(left_block, right_block, :branch, node, label: :truthy)
          connect(left_block, falsy, :branch, node, label: :falsy)
        else
          connect(left_block, truthy, :branch, node, label: :truthy)
          connect(left_block, right_block, :branch, node, label: :falsy)
        end

        @current = right_block
        build_short_circuit_value(node.right, truthy, falsy)
      end

      def build_short_circuit_value(node, truthy, falsy)
        if node.is_a?(Binary) && SHORT_CIRCUIT_OPERATORS.include?(node.operator)
          return build_short_circuit(node, truthy, falsy)
        end

        build_predicate_value(node, @current)
        connect(@current, truthy)
        @current
      end

      def build_predicate_value(node, block, type = :short_circuit_value)
        block.instructions << emit(node, type: type, effects: call_effects(node))
        add_exception_edges(block, node)
        block
      end

      def build_value_subexpressions(node, block)
        block.instructions << emit(node, effects: call_effects(node))
        add_exception_edges(block, node)
        block
      end

      def build_while(node)
        check = new_block(node.predicate)
        body = new_block(node)
        join = new_block(node)
        connect(@current, check)
        @current = check
        build_predicate(node.predicate, body, join)
        @current.instructions << emit(node.predicate, type: :branch, effects: [])
        connect(@current, body, :branch, node, label: :truthy)
        connect(@current, join, :branch, node, label: :falsy)

        push_frame(:loop, join, block: body, next_target: check)
        @current = body
        body_end = build_statements(node.statements, continuation: check)
        connect(body_end, check, :loop_back, node)
        pop_frame
        @current = join
      end

      def build_for(node)
        check = new_block(node)
        body = new_block(node)
        join = new_block(node)
        continuation = new_block
        @current = build_expression(node.collection, continuation)
        @current = continuation
        connect(@current, check)
        check.instructions << emit(node, type: :iteration, effects: [])
        connect(check, body, :branch, node, label: :truthy)
        connect(check, join, :branch, node, label: :falsy)
        push_frame(:loop, join, block: body, next_target: check)
        @current = body
        body_end = build_statements(node.statements, continuation: check)
        connect(body_end, check, :loop_back, node)
        pop_frame
        @current = join
      end

      def build_case(node)
        join = new_block(node)
        if node.value
          continuation = new_block
          @current = build_expression(node.value, continuation)
          @current = continuation
        end
        build_when_chain(node.consequent, join)
        @current = join
      end

      def build_when_chain(consequent, join)
        case consequent
        when nil
          connect(@current, join)
        when Else
          body = new_block
          connect(@current, body)
          @current = body
          end_block = build_statements(consequent.statements, continuation: join)
          connect(end_block, join)
        when When, In
          match = new_block(consequent)
          body = new_block
          next_chain = new_block
          connect(@current, match)
          match_type = consequent.is_a?(When) ? :when_match : :pattern_match
          match.instructions << emit(consequent, type: match_type, effects: [])
          connect(match, body, :match, consequent, label: :match)
          connect(match, next_chain, :match, consequent, label: :no_match)
          @current = body
          end_block = build_statements(consequent.statements, continuation: join)
          connect(end_block, join)
          @current = next_chain
          build_when_chain(consequent.consequent, join)
        end
      end

      def build_rescue_mod(node)
        join = new_block(node)
        value = new_block(node.value)
        end_block = build_generic_statement(node.statement)
        connect(end_block, join)
        previous_target = @exception_target
        @exception_target = value
        @current = value
        value_end = build_expression(node.value, join)
        @exception_target = previous_target
        @current = join
        value_end
      end

      def build_protected_body(bodystmt, continuation:)
        body_block = new_block
        connect(@current, body_block)
        ensure_frame = nil
        if bodystmt.ensure_clause
          ensure_frame = build_ensure_setup(bodystmt.ensure_clause, continuation)
          ensure_frame[:retry_body] = body_block
        end
        retry_target = ensure_frame ? ensure_frame[:entries][:retry] : body_block
        push_frame(:retry, retry_target) if bodystmt.rescue_clause

        outer_exception_target = @exception_target
        rescue_entry = bodystmt.rescue_clause ? new_block(bodystmt.rescue_clause) : nil
        body_exception_target =
          ensure_frame ? ensure_frame[:entries][:exception] : rescue_entry || outer_exception_target

        previous_exception = @exception_target
        @exception_target = body_exception_target
        @current = body_block
        @frames << ensure_frame if ensure_frame
        after_normal = new_block
        build_statements(bodystmt.statements, continuation: after_normal)
        if bodystmt.else_clause
          else_block = new_block
          connect(after_normal, else_block)
          @current = else_block
          target = ensure_frame ? ensure_frame[:entries][:normal] : continuation
          build_statements(bodystmt.else_clause, continuation: target)
        else
          target = ensure_frame ? ensure_frame[:entries][:normal] : continuation
          connect(after_normal, target)
        end
        @exception_target = previous_exception
        pop_frame if ensure_frame

        finish_ensure_frame(ensure_frame, bodystmt.ensure_clause, rescue_entry, continuation, outer_exception_target)

        if bodystmt.rescue_clause
          @exception_target = outer_exception_target
          build_rescue_node(
            bodystmt.rescue_clause, rescue_entry, continuation, outer_exception_target,
            !ensure_frame.nil?
          )
        end
        pop_frame if bodystmt.rescue_clause
        continuation
      end

      def build_rescue_node(rescue_node, matcher, continuation, outer_target, has_ensure)
        handler = new_block(rescue_node)
        next_matcher = new_block if rescue_node.consequent
        matcher.instructions << emit(rescue_node, type: :rescue_match, effects: [])
        connect(matcher, handler, :rescue_match, rescue_node, label: :match)
        if rescue_node.consequent
          connect(matcher, next_matcher, :rescue_match, rescue_node, label: :no_match)
          build_rescue_node(rescue_node.consequent, next_matcher, continuation, outer_target, has_ensure)
        else
          destination = has_ensure ? outer_target : outer_target
          connect(matcher, destination, :rescue_match, rescue_node, label: :no_match)
        end

        @current = handler
        build_statements(rescue_node.statements, continuation: continuation)
      end

      def build_ensure_setup(ensure_node, continuation)
        entries = {}
        dispatchers = {}
        shared_entry = new_block(:ensure_shared_entry, ensure_node)
        body_block = new_block(:ensure_body, ensure_node)
        dispatch = new_block(:ensure_dispatch, ensure_node)
        %i[normal exception return break next redo retry].each do |kind|
          entry = new_block("ensure_#{kind}_entry".to_sym, ensure_node)
          dispatcher = new_block("ensure_#{kind}_dispatch".to_sym, ensure_node)
          entries[kind] = entry
          dispatchers[kind] = dispatcher
        entry.instructions << emit(ensure_node, type: :ensure_enter, effects: [])
        connect(entry, shared_entry, :ensure_enter, ensure_node, outcome: { kind: kind })
        end
        connect(shared_entry, body_block)

        frame = { kind: :ensure, continuation: continuation, block: shared_entry, entries: entries, executing: true }
        frame[:dispatchers] = dispatchers
        @current = body_block
        @frames << frame
        build_statements(ensure_node.statements, continuation: dispatch)
        frame[:executing] = false
        dispatchers.each do |kind, dispatcher|
          connect(dispatch, dispatcher, :ensure_dispatch, ensure_node, outcome: { kind: kind })
        end
        frame
      end

      def finish_ensure_frame(current_frame, ensure_node, rescue_entry, continuation, outer_exception_target)
        return unless current_frame

        current_frame[:dispatchers].each do |kind, dispatcher|
          case kind
          when :normal
            connect(dispatcher, continuation, :ensure_exit, ensure_node, outcome: { kind: :normal })
          when :exception
            destination = rescue_entry || outer_exception_target
            connect(dispatcher, destination, :exception, ensure_node, outcome: { kind: :exception })
          when :return
            destination = frame_value(nearest_return_frame, :return_target)
            active = outer_ensure_frames(current_frame)
            if active.empty?
              connect(dispatcher, destination, :return, ensure_node, outcome: { kind: :return })
            else
              connect(dispatcher, active.last[:entries][:return], :return, ensure_node,
                       outcome: { kind: :return, destination: destination&.id })
            end
          when :break
            target = frame(:block) || frame(:loop)
            destination = target && frame_value(target, :continuation)
            route_outer_exit(current_frame, dispatcher, :break, destination, ensure_node)
          when :next
            route_outer_exit(current_frame, dispatcher, :next, frame(:loop)&.next_target, ensure_node)
          when :redo
            route_outer_exit(current_frame, dispatcher, :redo, frame(:loop)&.block, ensure_node)
          when :retry
            target = current_frame[:retry_body] || frame(:retry)&.continuation
            connect(dispatcher, target, :retry, ensure_node, outcome: { kind: :retry })
          end
        end
      end

      def outer_ensure_frames(current_frame)
        ensure_frames.reject { |candidate| candidate[:executing] || candidate == current_frame }
      end

      def route_outer_exit(current_frame, from, kind, destination, node)
        active = outer_ensure_frames(current_frame)
        if active.empty?
          connect(from, destination, kind, node, outcome: { kind: kind })
        else
          connect(from, active.last[:entries][kind], kind, node,
                   outcome: { kind: kind, destination: destination&.id })
        end
      end

      def build_return(node)
        terminal = close
        terminal.instructions << emit(node, effects: [])
        target_frame = nearest_return_frame
        destination = frame_value(target_frame, :return_target) || frame(:method)&.return_target
        route_exit(terminal, :return, destination, node)
        @current = new_block
      end

      def nearest_return_frame
        lambda_frame = frame(:lambda)
        return lambda_frame if lambda_frame&.return_target

        @frames.reverse.find { |candidate| %i[method block].include?(frame_kind(candidate)) }
      end

      def build_break(node)
        terminal = close
        terminal.instructions << emit(node, effects: [])
        target = frame(:block) || frame(:loop)
        destination = target && frame_value(target, :continuation)
        route_exit(terminal, :break, destination, node)
        @current = new_block
      end

      def build_next(node)
        terminal = close
        terminal.instructions << emit(node, effects: [])
        route_exit(terminal, :next, frame(:loop)&.next_target, node)
        @current = new_block
      end

      def build_redo(node)
        terminal = close
        terminal.instructions << emit(node, effects: [])
        route_exit(terminal, :redo, frame(:loop)&.block, node)
        @current = new_block
      end

      def build_retry(node)
        terminal = close
        terminal.instructions << emit(node, effects: [])
        connect(terminal, frame(:retry)&.continuation, :retry, node, outcome: { kind: :retry })
        @current = new_block
      end

      def route_exit(from, kind, destination, node)
        active_ensures = ensure_frames.reject { |candidate| candidate[:executing] }
        if active_ensures.empty?
          connect(from, destination, kind, node, outcome: { kind: kind })
        else
          target = active_ensures.last[:entries][kind]
          connect(from, target, kind, node, outcome: { kind: kind, destination: destination&.id })
        end
      end

      def build_block_call(node)
        continuation = new_block
        method_return_target = frame(:method)&.return_target
        region = build_block_region(node.block, :block, continuation, method_return_target)
        after_call = new_block(node.call)
        call_block = close
        effects = [unknown_effect(node.call), block_effect(node.block, region)]
        call_block.instructions << emit(node.call, type: :call, effects: effects)
        connect(call_block, region[:entry], :block_entry, node.block, invoke: true)
        connect(call_block, after_call, :call, node.call, target: CFG::UNKNOWN_CALL_TARGET)
        connect(region[:exits][:normal], after_call, :block_exit, node.block)
        connect(region[:exits][:next], after_call, :block_next, node.block)
        connect(region[:exits][:break], after_call, :break_exit, node.block)
        add_exception_edges(call_block, node.call)
        connect(after_call, continuation)
        @current = continuation
      end

      def block_effect(node, region)
        {
          kind: :block,
          block: region[:id],
          location: location(node.location),
          nonlocal: :break
        }
      end

      def build_block_region(block_node, kind, continuation, method_return_target = nil)
        @region_sequence += 1
        id = "#{kind}_#{@region_sequence}"
        entry = new_block(:region_entry, block_node)
        exits = {}
        %i[normal return break next redo].each do |name|
          exits[name] = new_block(:region_exit)
        end
        saved_current = @current
        @current = entry
        body_entry = new_block(:region_body, block_node)
        connect(entry, body_entry)
        @current = body_entry
        frame_kind = kind == :block ? :block : :lambda
        return_target = kind == :block ? method_return_target : exits[:return]
        push_frame(frame_kind, kind == :block ? continuation : nil, block: entry, return_target: return_target)
        end_block = build_region_body(block_node, kind)
        connect(end_block, exits[:normal])
        pop_frame
        @current = saved_current
        region = { id: id, entry: entry, exits: exits }
        graph.regions[id] = region
        if kind == :lambda
          connect(exits[:normal], continuation, :lambda_exit, block_node)
          connect(exits[:break], continuation, :lambda_break, block_node)
          connect(exits[:next], continuation, :lambda_next, block_node)
        end
        region
      end

      def build_region_body(node, kind)
        body = kind == :block ? node.bodystmt : node.statements
        if body.is_a?(BodyStmt)
          build_bodystmt(body)
        else
          build_statements(body)
        end
      end

      def build_lambda_expression(node)
        continuation = new_block
        region = build_lambda_region(node, continuation)
        from = close
        effect = { kind: :lambda, lambda: region[:id], location: location(node.location) }
        from.instructions << emit(node, type: :lambda, effects: [effect])
        connect(from, continuation)
        from
      end

      def build_lambda_region(node, continuation)
        return @built_lambda_nodes[node] if @built_lambda_nodes[node]

        @region_sequence += 1
        id = "lambda_#{@region_sequence}"
        entry = new_block(:region_entry, node)
        exits = {}
        %i[normal return break next redo].each { |name| exits[name] = new_block(:region_exit) }
        saved_current = @current
        @current = entry
        body_entry = new_block(:lambda_body, node)
        connect(entry, body_entry)
        @current = body_entry
        push_frame(:lambda, block: entry, return_target: exits[:return])
        end_block = build_region_body(node, :lambda)
        connect(end_block, exits[:normal])
        pop_frame
        @current = saved_current
        region = { id: id, entry: entry, exits: exits }
        graph.regions[id] = region
        @built_lambda_nodes[node] = region
        connect(exits[:normal], continuation, :lambda_exit, node)
        connect(exits[:return], continuation, :lambda_return, node)
        region
      end
    end
  end
end
