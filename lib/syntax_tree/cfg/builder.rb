# frozen_string_literal: true

module SyntaxTree
  module CFG
    # Builds a conservative, read-only control flow graph for one entry point.
    class Builder
      Region = Struct.new(:bodystmt, :rescue, :shadow, :outer_count)
      Frame = Struct.new(:kind, :entry, :exit, :redo_target, keyword_init: true)
      Result = Struct.new(:entry, :terminal)

      def initialize(entry)
        @entry_node = entry
        @blocks = []
        @edges = []
        @regions = []
        @frames = []
        @ensure_entries = {}
        @rescue_entries = {}
        @rescue_decisions = {}
        @ensure_contexts = []
        @id = 0
      end

      def build
        graph_entry = block(nil, :entry)
        graph_exit = block(nil, :exit)

        body = entry_body
        start = build_params
        entry_frame = Frame.new(kind: entry_kind, entry: graph_entry.id, exit: graph_exit.id)
        @frames.push(entry_frame)
        terminal =
          if body.is_a?(BodyStmt)
            build_bodystmt(body, start)
          else
            build_contents(
              body,
              default_target: nil,
              with_params: false,
              initial: start
            ).terminal
          end
        entry_target = start || terminal || graph_exit.id

        connect(graph_entry.id, entry_target, :entry, entry_location)
        connect_normal_terminators(graph_exit)
        @frames.pop

        Graph.new(
          @entry_node,
          @blocks,
          @edges,
          graph_entry.id,
          graph_exit.id
        )
      end

      private

      def entry_kind
        case @entry_node
        when DefNode
          :method
        when Lambda
          :lambda
        else
          :block
        end
      end

      def entry_location
        case @entry_node
        when DefNode, BlockNode, Lambda
          @entry_node.location
        else
          unsupported!
        end
      end

      def entry_body
        case @entry_node
        when DefNode
          @entry_node.bodystmt
        when BlockNode
          @entry_node.bodystmt
        when Lambda
          @entry_node.statements
        else
          unsupported!
        end
      end

      def unsupported!
        raise ArgumentError, "unsupported CFG entry: #{@entry_node.class}"
      end

      def block(node, kind = :basic)
        id = @id
        @id += 1
        block = Block.new(id, node, kind)
        @blocks << block
        block
      end

      def join(node = nil)
        block(node, :join)
      end

      def connect(from, to, type, location, reason: nil, replaces: false)
        return if from == to && type == :sequence

        @edges << Edge.new(
          from,
          to,
          type,
          location,
          reason,
          replaces
        )
      end

      def connect_normal_terminators(graph_exit)
        targets = @blocks.map(&:id) - @edges.map(&:from)
        targets.each do |target|
          block = @blocks[target]
          next if block.kind == :exit
          connect(
            target,
            graph_exit.id,
            :normal,
            block.node&.location || entry_location
          )
        end
      end

      def build_contents(container, default_target: nil, with_params: true, initial: nil)
        statements = statements_for(container)
        start = initial || (with_params ? build_params : nil)

        first_result = nil
        last = nil
        statements.body.each do |statement|
          next if statement.is_a?(VoidStmt)
          cursor = last ? last.terminal : (start || default_target)
          result = build_statement(statement, cursor)
          first_result ||= result
          last = result
        end

        Result.new(start || first_result&.entry, last&.terminal || start)
      end

      def statements_for(container)
        case container
        when Statements
          container
        when BodyStmt
          container.statements
        else
          raise ArgumentError, "unexpected CFG body: #{container.class}"
        end
      end

      def build_params
        params =
          case @entry_node
          when DefNode
            params_node = @entry_node.params
            params_node.is_a?(Paren) ? params_node.contents : params_node
          when BlockNode
            @entry_node.block_var&.params
          when Lambda
            params_node = @entry_node.params
            params_node.is_a?(Paren) ? params_node.contents.params : params_node
          end

        return nil unless params

        defaults = params.optionals.map(&:last) + params.keywords.map(&:last).compact
        defaults.reduce(nil) do |current, default|
          build_expression(default, current)
        end
      end

      def build_statement(node, current)
        return Result.new(nil, current) if node.is_a?(VoidStmt)

        if control_node?(node)
          basic = block(node)
          connect(current, basic.id, :sequence, node.location) if current
          terminal = build_statement_body(node, basic.id)
          Result.new(basic.id, terminal)
        else
          basic = block(node)
          connect(current, basic.id, :sequence, node.location) if current
          terminal = build_statement_body(node, basic.id)
          Result.new(basic.id, terminal)
        end
      end

      def control_node?(node)
        node.is_a?(IfNode) || node.is_a?(UnlessNode) || node.is_a?(IfOp) ||
          node.is_a?(Case) || node.is_a?(WhileNode) ||
          node.is_a?(UntilNode) || node.is_a?(For) ||
          node.is_a?(Begin) || node.is_a?(BodyStmt)
      end

      def build_statement_body(node, entry)
        case node
        when ReturnNode, Break, Next, Redo
          terminal = build_executable_children(node, entry)
          dispatch_jump(node, terminal || entry)
          nil
        when IfNode, UnlessNode
          node.is_a?(UnlessNode) ? build_unless(node, entry) : build_if(node, entry)
        when IfOp
          build_if_op(node, entry)
        when Case
          build_case(node, entry)
        when WhileNode, UntilNode
          build_loop(node, entry)
        when For
          build_for(node, entry)
        when Begin
          build_bodystmt(node.bodystmt, entry)
        when BodyStmt
          build_bodystmt(node, entry)
        when MethodAddBlock, CallNode, Command, CommandCall, VCall,
             YieldNode, ZSuper, Super
          build_invocation(node, entry)
        when Binary
          build_binary(node, entry)
        when DefNode, BlockNode, Lambda
          entry
        else
          terminal = build_executable_children(node, entry)
          emit_potential_call(node, terminal || entry) if potential_non_call?(node)
          terminal || entry
        end
      end

      def dispatch_jump(node, current)
        type =
          case node
          when ReturnNode
            :return
          when Break
            :break
          when Next
            :next
          when Redo
            :redo
          end

        pending = pending_exit(type, node.location)
        connect(
          current,
          pending,
          type,
          node.location,
          reason: pending_reason(type),
          replaces: @ensure_contexts.any?
        )
      end

      def potential_non_call?(node)
        node.is_a?(Unary) || node.is_a?(ARef) || node.is_a?(OpAssign)
      end

      def pending_exit(type, location)
        index = @regions.rindex { |region| region.bodystmt.ensure_clause }
        return dispatch_jump_target(target_frame_for_type(type), type) unless index

        ensure_target(
          @regions[index],
          pending_reason(type),
          location
        )
      end

      def pending_reason(type)
        type
      end

      def graph_exit_id
        @blocks.find { |block| block.kind == :exit }.id
      end

      def target_frame_for_type(type)
        return @frames.first if type == :return

        @frames.reverse.find { |candidate| candidate.kind == :loop } ||
          @frames.last
      end

      def build_expression(node, current)
        return current unless node

        case node
        when VoidStmt
          current
        when IfNode, UnlessNode
          node.is_a?(UnlessNode) ? build_unless(node, current) : build_if(node, current)
        when IfOp
          build_if_op(node, current)
        when Case
          build_case(node, current)
        when WhileNode, UntilNode
          build_loop(node, current)
        when For
          build_for(node, current)
        when Begin
          build_bodystmt(node.bodystmt, current)
        when BodyStmt
          build_bodystmt(node, current)
        when MethodAddBlock, CallNode, Command, CommandCall, VCall,
             YieldNode, ZSuper, Super
          basic = block(node)
          connect(current, basic.id, :sequence, node.location) if current
          build_invocation(node, basic.id)
        when Binary
          basic = block(node)
          connect(current, basic.id, :sequence, node.location) if current
          build_binary(node, basic.id)
        else
          basic = block(node)
          connect(current, basic.id, :sequence, node.location) if current
          terminal = build_executable_children(node, basic.id)
          emit_potential_call(node, terminal || basic.id) if potential_non_call?(node)
          terminal || basic.id
        end
      end

      def build_executable_children(node, current)
        executable_children(node).reduce(current) do |cursor, child|
          build_expression(child, cursor)
        end
      end

      def executable_children(node)
        case node
        when ReturnNode, Break, Next
          node.arguments ? node.arguments.child_nodes.compact : []
        when Assign
          target_children(node.target) +
            [node.value].select { |child| executable?(child) }
        when OpAssign
          target_children(node.target) +
            [node.value].select { |child| executable?(child) }
        when MAssign
          node.child_nodes.compact.select { |child| executable?(child) }
        when BlockVar, LambdaVar, Params, DefNode, BlockNode, Lambda
          []
        when Paren
          paren_contents(node)
        when Statements
          node.body.reject { |child| child.is_a?(VoidStmt) }
        when Args, ArgParen
          node.child_nodes.compact
        when Binary, Unary
          node.child_nodes.compact.select { |child| executable?(child) }
        else
          node.child_nodes.compact.select { |child| executable?(child) }
        end
      end

      def target_children(target)
        case target
        when ARefField, Field, ConstPathField
          target.child_nodes.compact.select { |child| executable?(child) }
        else
          []
        end
      end

      def paren_contents(node)
        case node.contents
        when Statements
          node.contents.body.reject { |child| child.is_a?(VoidStmt) }
        when nil
          []
        else
          [node.contents]
        end
      end

      def executable?(node)
        return false unless node.is_a?(Node)

        case node
        when VoidStmt, DefNode, BlockNode, Lambda, Params, BlockVar, LambdaVar
          false
        when VarField, Field, ConstPathField, TopConstField, ARefField,
             BlockArg, Kw, Ident, Const, Label, Op, Period, ArgParen, Args,
             MRHS, ArrayLiteral, HashLiteral, StringLiteral, SymbolLiteral
          false
        else
          true
        end
      end

      def build_invocation(node, current)
        terminal = build_invocation_children(node, current)
        terminal ||= current
        emit_potential_call(node, terminal)
        current
      end

      def build_invocation_children(node, current)
        children =
          case node
          when CallNode
            [node.receiver, *call_arguments(node.arguments)].compact
          when Command, CommandCall
            call_arguments(node.arguments)
          when Super, YieldNode
            node.arguments ? call_arguments(node.arguments) : []
          when MethodAddBlock
            [node.call]
          when ZSuper, VCall
            []
          else
            node.child_nodes.compact.select { |child| executable?(child) }
          end

        children.reduce(current) do |cursor, child|
          build_expression(child, cursor)
        end
      end

      def call_arguments(arguments)
        return [] unless arguments

        case arguments
        when Args
          arguments.parts.select { |child| executable?(child) }
        when ArgParen
          call_arguments(arguments.arguments)
        else
          arguments.child_nodes.compact.select { |child| executable?(child) }
        end
      end

      def emit_potential_call(node, current)
        rescue_node, shadow = nearest_rescue
        if rescue_node
          connect(
            current,
            rescue_entry_for(rescue_node, shadow),
            :call_exception,
            node.location,
            reason: :exception
          )
        end

        ensure_region = @regions.reverse.find { |region| region.bodystmt.ensure_clause }
        return unless ensure_region

        connect(
          current,
          ensure_target(ensure_region, :exception, node.location),
          rescue_node ? :exception : :call_exception,
          node.location,
          reason: :exception
        )
      end

      def nearest_rescue
        @regions.reverse_each do |region|
          next unless region.rescue
          return [region.rescue, region.shadow]
        end
        nil
      end

      def build_binary(node, current)
        case node.operator
        when :"&&", :"and"
          build_short_circuit(node, current, true)
        when :"||", :"or"
          build_short_circuit(node, current, false)
        else
          terminal = build_executable_children(node, current)
          emit_potential_call(node, terminal || current)
          terminal || current
        end
      end

      def build_short_circuit(node, current, and_operator)
        after = join
        left = build_expression(node.left, current)

        right = block(node.right)
        connect(
          left,
          right.id,
          and_operator ? :branch_true : :branch_false,
          node.location
        )
        connect(
          left,
          after.id,
          and_operator ? :branch_false : :branch_true,
          node.location
        )

        terminal = build_expression(node.right, right.id)
        connect(terminal || right.id, after.id, :short_circuit, node.location)
        after.id
      end

      def build_if(node, current)
        return build_modifier_branch(node, current, true) if node.modifier?

        after = join
        build_if_chain(node, current, after)
        after.id
      end

      def build_predicate(predicate, current)
        expression = build_expression(predicate, current)
        test = block(predicate, :test)
        connect(expression || current, test.id, :sequence, predicate.location)
        test.id
      end

      def build_body_container(statements)
        block(statements).id
      end

      def build_statements_container(statements, current, regions: nil)
        previous_regions = @regions
        @regions = regions if regions
        terminal =
          build_contents(
            statements,
            default_target: nil,
            with_params: false,
            initial: current
          ).terminal
        @regions = previous_regions
        terminal
      ensure
        @regions = previous_regions
      end

      def build_if_chain(node, current, after)
        current = current.id if current.is_a?(Block)
        after = after.id if after.is_a?(Block)
        expression = build_expression(node.predicate, current)
        test = block(node.predicate, :test)
        connect(expression || current, test.id, :sequence, node.predicate.location)

        truthy = build_body_container(node.statements)
        consequent = prepare_conditional(node.consequent, after)
        connect(test.id, truthy, :branch_true, node.location)
        connect(test.id, consequent, :branch_false, node.location)
        terminal = build_statements_container(node.statements, truthy)
        connect(terminal || truthy, after, :sequence, node.location)
        test.id
      end

      def prepare_conditional(node, after)
        after = after.id if after.is_a?(Block)
        case node
        when nil
          after
        when Elsif
          build_if_chain(node, after, after)
        when Else
          target = block(node.statements).id
          terminal = build_statements_container(node.statements, target)
          connect(terminal || target, after, :sequence, node.location)
          target
        end
      end

      def build_unless(node, current)
        return build_modifier_branch(node, current, false) if node.modifier?

        after = join
        condition = build_predicate(node.predicate, current)
        truthy = build_body_container(node.statements)
        consequent = prepare_conditional(node.consequent, after.id)
        connect(condition, truthy, :branch_false, node.location)
        connect(condition, consequent, :branch_true, node.location)
        terminal = build_statements_container(node.statements, truthy)
        connect(terminal || truthy, after.id, :sequence, node.location)
        after.id
      end

      def build_modifier_branch(node, current, truthy_executes)
        after = join
        body = build_body_container(node.statements)
        connect(current, body, :sequence, node.location) if current
        terminal = build_statements_container(node.statements, body)
        condition = build_predicate(node.predicate, terminal || body)
        connect(condition, after.id, truthy_executes ? :branch_true : :branch_false, node.location)
        connect(condition, after.id, truthy_executes ? :branch_false : :branch_true, node.location)
        after.id
      end

      def build_if_op(node, current)
        condition = build_predicate(node.predicate, current)
        after = join
        truthy = block(node.truthy)
        falsy = block(node.falsy)
        connect(condition, truthy.id, :branch_true, node.location)
        connect(condition, falsy.id, :branch_false, node.location)
        truthy_terminal = build_expression(node.truthy, truthy.id)
        falsy_terminal = build_expression(node.falsy, falsy.id)
        connect(truthy_terminal || truthy.id, after.id, :sequence, node.location)
        connect(falsy_terminal || falsy.id, after.id, :sequence, node.location)
        after.id
      end

      def build_case(node, current)
        cursor = node.value ? build_expression(node.value, current) : current
        after = join
        build_when_chain(node.consequent, cursor || current, after.id, node.location)
        after.id
      end

      def build_when_chain(node, current, after, location)
        case node
        when nil
          connect(current, after, :branch_false, location)
        when Else
          target = build_body_container(node.statements)
          connect(current, target, :sequence, node.location)
          terminal = build_statements_container(node.statements, target)
          connect(terminal || target, after, :sequence, node.location)
        when When, In
          build_clause(node, current, after)
        end
      end

      def build_when_consequent(node, after, location)
        case node
        when Else
          target = build_body_container(node.statements)
          connect(after, target, :sequence, node.location)
          terminal = build_statements_container(node.statements, target)
          connect(terminal || target, after, :sequence, node.location)
          target
        else
          build_clause(node, after, after, nested: true)
        end
      end

      def build_clause(node, current, after, nested: false)
        cursor = current
        matcher = nil
        args = node.is_a?(When) ? node.arguments.parts : [node.pattern]
        args.each do |argument|
          matcher = block(node, :test)
          connect(cursor, matcher.id, :sequence, node.location)
          terminal = build_expression(argument, matcher.id)
          emit_potential_call(argument, terminal || matcher.id)
          cursor = matcher.id
        end

        target = build_body_container(node.statements)
        no_match = node.consequent ? build_when_consequent(node.consequent, after, node.location) : after
        connect(matcher.id, target, :branch_true, node.location)
        connect(matcher.id, no_match, :branch_false, node.location)
        terminal = build_statements_container(node.statements, target)
        connect(terminal || target, after, :sequence, node.location)
        nested ? matcher.id : after
      end

      def build_loop(node, current)
        return build_modifier_loop(node, current) if node.modifier?

        test = block(node.predicate, :test)
        connect(current, test.id, :sequence, node.location)

        body_entry = block(node.statements)
        after = join
        body_executes = node.is_a?(WhileNode)
        connect(
          test.id,
          body_entry.id,
          body_executes ? :branch_true : :branch_false,
          node.location
        )
        connect(
          test.id,
          after.id,
          body_executes ? :branch_false : :branch_true,
          node.location
        )

        @frames.push(
          Frame.new(
            kind: :loop,
            entry: test.id,
            exit: after.id,
            redo_target: body_entry.id
          )
        )
        terminal = build_statements_container(node.statements, body_entry.id)
        @frames.pop

        if !node.statements.empty? || node.modifier?
          connect(terminal || body_entry.id, test.id, :loop_back, node.location)
        end
        after.id
      end

      def build_modifier_loop(node, current)
        is_while = node.is_a?(WhileNode)
        test = block(node.predicate, :test)
        body_entry = block(node.statements)
        connect(current, body_entry.id, :sequence, node.location) if current

        @frames.push(
          Frame.new(
            kind: :loop,
            entry: test.id,
            exit: nil,
            redo_target: body_entry.id
          )
        )
        terminal = build_statements_container(node.statements, body_entry.id)
        after = join
        frame = @frames.pop
        frame.exit = after.id

        connect(terminal || body_entry.id, test.id, :loop_back, node.location)
        connect(test.id, body_entry.id, is_while ? :branch_true : :branch_false, node.location)
        connect(test.id, after.id, is_while ? :branch_false : :branch_true, node.location)
        after.id
      end

      def build_for(node, current)
        collection = build_expression(node.collection, current)
        test = block(node, :test)
        connect(collection || current, test.id, :sequence, node.location)
        emit_potential_call(node, test.id)

        body_entry = block(node.statements)
        after = join
        connect(test.id, body_entry.id, :branch_true, node.location)
        connect(test.id, after.id, :branch_false, node.location)

        @frames.push(
          Frame.new(
            kind: :loop,
            entry: test.id,
            exit: after.id,
            redo_target: body_entry.id
          )
        )
        terminal = build_statements_container(node.statements, body_entry.id)
        @frames.pop

        connect(terminal || body_entry.id, test.id, :loop_back, node.location)
        after.id
      end

      def dispatch_jump_target(frame, type)
        case type
        when :return
          graph_exit_id
        when :break
          frame&.exit || graph_exit_id
        when :next
          frame&.entry || graph_exit_id
        when :redo
          frame&.redo_target || frame&.entry || graph_exit_id
        end
      end

      def build_bodystmt(bodystmt, current)
        after = join
        first_entry = nil
        main_region =
          Region.new(
            bodystmt,
            bodystmt.rescue_clause,
            false,
            @regions.length
          )
        shadow_region =
          Region.new(
            bodystmt,
            nil,
            true,
            @regions.length
          )

        if bodystmt.rescue_clause
          prepare_rescue_matchers(bodystmt.rescue_clause, main_region)
        end

        @regions.push(main_region)
        terminal = current
        bodystmt.statements.body.each do |statement|
          result = build_statement(statement, terminal)
          first_entry ||= result.entry
          terminal = result.terminal
        end
        @regions.pop

        if bodystmt.rescue_clause || bodystmt.ensure_clause
          if terminal
            connect(
              terminal,
              normal_after_target(bodystmt, after.id),
              :sequence,
              bodystmt.location
            )
          end
        else
          connect(terminal || current, after.id, :sequence, bodystmt.location) if terminal || current
        end

        build_else_clause(bodystmt, after.id, shadow_region)
        build_rescue_chain(
          bodystmt,
          bodystmt.rescue_clause,
          main_region,
          false,
          after.id
        )
        first_entry || current || after.id
      end


      def build_rescue_chain(bodystmt, clause, region, shadow, continuation)
        unmatched = unmatched_target(bodystmt, region)
        while clause
          key = [region.bodystmt.object_id, clause.object_id, false]
          entry = @rescue_entries.fetch(key)
          build_rescue(bodystmt, clause, entry, shadow, continuation)
          next_clause = clause.consequent
          target =
            if next_clause
              @rescue_entries.fetch([region.bodystmt.object_id, next_clause.object_id, false])
            else
              unmatched
            end
          connect(entry, target, :exception_mismatch, clause.keyword.location)
          clause = next_clause
        end
      end

      def unmatched_target(bodystmt, region)
        if bodystmt.ensure_clause
          ensure_target(region, :exception, bodystmt.location, continuation: nil)
        else
          graph_exit_id
        end
      end

      def normal_after_target(bodystmt, after)
        return after unless bodystmt.ensure_clause

        ensure_target(
          Region.new(bodystmt, bodystmt.rescue_clause, false, @regions.length),
          :normal,
          bodystmt.location,
          continuation: after
        )
      end

      def build_else_clause(bodystmt, after, shadow_region)
        return unless bodystmt.else_clause

        entry = block(bodystmt.else_clause)
        connect(after, entry.id, :sequence, bodystmt.else_keyword.location)
        @regions.push(shadow_region)
        terminal = build_statements_container(bodystmt.else_clause, entry.id)
        @regions.pop

        if bodystmt.ensure_clause
          target = ensure_target(shadow_region, :normal, bodystmt.else_keyword.location, continuation: after)
          connect(terminal || entry.id, target, :sequence, bodystmt.else_keyword.location)
        elsif terminal
          connect(terminal, after, :sequence, bodystmt.else_keyword.location)
        end
      end

      def rescue_entry_for(rescue_node, _shadow)
        region =
          @regions.reverse.find do |current|
            current.rescue.equal?(rescue_node) ||
              chain_contains?(current.rescue, rescue_node)
        end
        key = [region.bodystmt.object_id, rescue_node.object_id, false]
        @rescue_entries[key] ||=
          @rescue_decisions[key] || block(rescue_node, :test).id
      end

      def prepare_rescue_matchers(clause, region)
        while clause
          key = [region.bodystmt.object_id, clause.object_id, false]
          decision = block(clause, :test).id
          @rescue_decisions[key] = decision
          @rescue_entries[key] = decision

          rescue_exception_expressions(clause.exception).each do |expression|
            terminal = build_expression(expression, nil)
            connect(terminal, decision, :sequence, expression.location)
            @rescue_entries[key] = terminal
          end

          clause = clause.consequent
        end
      end

      def rescue_exception_expressions(exception)
        return [] unless exception&.exceptions

        exception.exceptions.child_nodes.compact.flat_map do |node|
          node.is_a?(ArgStar) ? node.child_nodes.compact : node
        end.select do |node|
          node.is_a?(CallNode) || node.is_a?(Command) ||
            node.is_a?(CommandCall) || node.is_a?(VCall) ||
            node.is_a?(MethodAddBlock) || node.is_a?(Super) ||
            node.is_a?(ZSuper) || node.is_a?(YieldNode)
        end
      end

      def build_rescue(bodystmt, rescue_node, current, shadow, continuation)
        key = [bodystmt.object_id, rescue_node.object_id, false]
        matcher_entry = @rescue_entries.fetch(key)
        matcher_decision = @rescue_decisions.fetch(key)
        connect(current, matcher_entry, :sequence, rescue_node.keyword.location)

        body_entry = block(rescue_node.statements)
        outer_count = region_stack_outer_count(bodystmt)
        region = Region.new(bodystmt, nil, shadow, outer_count)
        connect(matcher_decision, body_entry.id, :exception_match, rescue_node.keyword.location)

        @regions.push(region)
        body_terminal = build_statements_container(rescue_node.statements, body_entry.id)
        @regions.pop

        if body_terminal
          bodystmt = region.bodystmt
          target =
            if bodystmt.ensure_clause
              ensure_target(region, :normal, rescue_node.keyword.location, continuation: continuation)
            else
              join.id
            end
          connect(body_terminal, target, :sequence, rescue_node.keyword.location)
        end
      end

      def region_stack_outer_count(bodystmt)
        @regions.index { |region| region.bodystmt.equal?(bodystmt) } || @regions.length
      end

      def chain_contains?(clause, target)
        while clause
          return true if clause.equal?(target)
          clause = clause.consequent
        end
        false
      end

      def ensure_target(region, reason, location, continuation: nil)
        ensure_clause = region.bodystmt.ensure_clause
        key = [:ensure, ensure_clause.object_id, reason, region.shadow, region.outer_count]
        @ensure_entries[key] ||= begin
          entry = block(ensure_clause)
          outer_regions = @regions.first(region.outer_count)
          previous_regions = @regions
          @regions = outer_regions
          @ensure_contexts.push(ensure_clause)
          terminal = build_statements_container(ensure_clause.statements, entry.id)
          @ensure_contexts.pop
          @regions = previous_regions

          after = join
          if terminal
            connect(terminal, after.id, :sequence, ensure_clause.location)
          else
            connect(entry.id, after.id, :sequence, ensure_clause.location)
          end
          dispatch_after_ensure(region, reason, after.id, location, continuation)
          entry.id
        end
      end

      def dispatch_after_ensure(region, reason, current, location, continuation)
        case reason
        when :normal
          if continuation
            connect(current, continuation, :ensure_exit, location, reason: :normal)
          else
            connect(current, graph_exit_id, :normal, location)
          end
        when :exception
          dispatch_outer_exception(region, current, location)
        when :return, :break, :next, :redo
          target =
            dispatch_jump_target(target_frame_for_type(reason), reason)
          connect(
            current,
            target,
            reason,
            location,
            reason: reason,
            replaces: true
          )
        end
      end

      def dispatch_outer_exception(region, current, location)
        regions = @regions.first(region.outer_count)
        rescue_region = regions.reverse.find(&:rescue)
        if rescue_region
          connect(
            current,
            rescue_entry_for(rescue_region.rescue, rescue_region.shadow),
            :exception,
            location,
            reason: :exception
          )
          return
        end

        ensure_region = regions.reverse.find { |candidate| candidate.bodystmt.ensure_clause }
        if ensure_region
          connect(
            current,
            ensure_target(ensure_region, :exception, location),
            :exception,
            location,
            reason: :exception
          )
        else
          connect(current, graph_exit_id, :exception_exit, location, reason: :exception)
        end
      end
    end
  end
end
