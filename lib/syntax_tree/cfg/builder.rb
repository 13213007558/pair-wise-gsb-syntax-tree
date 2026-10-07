# frozen_string_literal: true

module SyntaxTree
  class CFG
    class Builder
      SAFE_NODES = %i[
        Args
        ArgStar
        ArrayLiteral
        Assoc
        AssocSplat
        BareAssocHash
        BlockVar
        CHAR
        Const
        DynaSymbol
        False
        FloatLiteral
        GVar
        Hash
        IVar
        Ident
        Imaginary
        Int
        Kw
        Label
        LambdaVar
        Nil
        Params
        RationalLiteral
        RegexpLiteral
        Self
        StringLiteral
        SymbolLiteral
        True
        VarField
        VarRef
        VoidStmt
      ].freeze

      def initialize(program, requested_name, source = nil)
        @program = program
        @requested_name = requested_name
        @source = source
        @next_id = 0
        @blocks = []
        @edges = []
        @exits = []
        @effects = []
        @regions = []
        @frames = []
        @local_variables = []
        @lambda_by_variable = {}
      end

      def build
        definition = find_definition
        raise ArgumentError, "no method definition found" unless definition

        name = node_name(definition.name)
        entry = block!(:entry, "entry", definition.location)
        @entry = entry
        exit_block = block!(:method_exit, "method exit", definition.location)
        unresolved =
          block!(:unresolved_exit, "unresolved exit", definition.location)
        exception_exit =
          block!(:exception_exit, "exception exit", definition.location)

        @cfg =
          CFG.new(
            method_name: name,
            source_location: definition.location,
            entry_block: entry.id,
            source: @source
          )

        @current = entry
        push_frame(
          kind: :method,
          entry: entry.id,
          normal_exit: exit_block.id,
          return_exit: exit_block.id,
          break_exit: unresolved.id,
          next_exit: unresolved.id,
          exception_exit: exception_exit.id,
          node: definition
        )
        register_exit(:normal, exit_block.id, definition.location)
        register_exit(:exception, exception_exit.id, definition.location)
        register_exit(:unresolved, unresolved.id, definition.location)

        gather_local_variables(definition)
        prebuild_lambdas(definition)
        @current = entry
        compile_statements(
          body_statements(definition),
          normal: proc { connect(exit_block.id, :fallthrough) }
        )
        connect_if_current(exit_block.id, :fallthrough)
        finish_cfg
      end

      private

      def find_definition
        methods = []
        scan(@program) { |node| methods << node if node.is_a?(DefNode) }
        if @requested_name
          methods.find do |node|
            node_name(node.name) == @requested_name.to_sym
          end || methods.first
        else
          methods.first
        end
      end

      def body_statements(definition)
        body = definition.bodystmt
        body.is_a?(BodyStmt) ? body.statements : expression_statements(body)
      rescue StandardError
        expression_statements(body)
      end

      def expression_statements(node)
        Statements.new(body: [node], location: node.location)
      end

      def prebuild_lambdas(root)
        root.bodystmt.statements.body.each do |node|
          next unless node.is_a?(Assign) && node.value.is_a?(Lambda)

          variable = variable_name(node.target)
          if variable
            @current = @entry
            @lambda_by_variable[variable] = build_lambda(node.value)
          end
        end
      end

      def scan(node, &block)
        return unless node.respond_to?(:child_nodes)

        yield node
        node.child_nodes.compact.each { |child| scan(child, &block) }
      end

      def scan_skipping(node, skipped_types, &block)
        return unless node.respond_to?(:child_nodes)

        yield node
        return if skipped_types.any? { |type| node.is_a?(type) }

        node.child_nodes.compact.each do |child|
          scan_skipping(child, skipped_types, &block)
        end
      end

      def gather_local_variables(definition)
        scan_skipping(definition.params, []) do |node|
          register_local_variable(node) if node.is_a?(Ident)
        end

        scan_skipping(definition.bodystmt, [DefNode, Lambda]) do |node|
          case node
          when Assign
            register_local_variable(node.target)
          when MAssign
            register_local_variable(node.target)
          when For
            register_local_variable(node.index)
          end
        end
      end

      def register_local_variable(node)
        node = node.value while node.respond_to?(:value) &&
          node.value.respond_to?(:value)
        if node.respond_to?(:value) && node.value.is_a?(Symbol)
          unless @local_variables.include?(node.value)
            @local_variables << node.value
          end
        end
      end

      def block!(kind, label, location = nil)
        id = "bb#{@next_id += 1}"
        block =
          BasicBlock.new(
            id: id,
            label: label,
            kind: kind,
            location: location,
            source: @source
          )
        @blocks << block
        block
      end

      def split!(kind, label = kind.to_s, location = nil)
        block = block!(kind, label, location)
        connect_if_current(block.id, :fallthrough)
        @current = block
        block
      end

      def new_target(kind, label, location = nil)
        block!(kind, label, location || Location.default).id
      end

      def connect(target, type = :fallthrough, **metadata)
        raise ArgumentError, "no current block" unless @current

        connect_from(@current.id, target, type, **metadata)
      end

      def connect_from(source, target, type = :fallthrough, **metadata)
        location = metadata.delete(:location)
        condition = metadata.delete(:condition)
        edge =
          Edge.new(
            source: source,
            target: target,
            type: type,
            condition: condition,
            location: location,
            metadata: metadata
          )
        @edges << edge unless duplicate_edge?(edge)
        edge
      end

      def duplicate_edge?(edge)
        @edges.any? do |existing|
          existing.source == edge.source && existing.target == edge.target &&
            existing.type == edge.type &&
            existing.condition == edge.condition &&
            existing.metadata == edge.metadata
        end
      end

      def connect_if_current(target, type = :fallthrough, **metadata)
        connect(target, type, **metadata) if @current
      end

      def terminate!
        @current = nil
      end

      def current_id
        @current && @current.id
      end

      def push_frame(**attributes)
        id = "r#{@regions.length + 1}"
        frame = { **attributes, id: id }
        @frames << frame
        region =
          Region.new(
            id: frame[:id],
            kind: frame[:kind],
            location: frame[:node]&.location,
            entry: frame[:entry],
            exception_exit: frame[:exception_exit],
            normal_exit: frame[:normal_exit],
            return_exit: frame[:return_exit],
            break_exit: frame[:break_exit],
            next_exit: frame[:next_exit],
            iterator_continue: frame[:iterator_continue],
            metadata: { name: frame[:name] }.compact
          )
        @regions << region
        frame
      end

      def pop_frame
        @frames.pop
      end

      def frame_index(frame)
        @frames.index(frame)
      end

      def register_exit(kind, block, location = nil, metadata = nil)
        @exits << Exit.new(
          kind: kind,
          block: block,
          location: location,
          metadata: metadata
        )
      end

      def finish_cfg
        @cfg.blocks.replace(@blocks)
        @cfg.edges.replace(@edges)
        @cfg.exits.replace(@exits)
        @cfg.effects.replace(@effects)
        @cfg.regions.replace(@regions)
        @cfg
      end

      def node_name(node)
        node.respond_to?(:value) ? node.value.to_sym : :anonymous
      end

      def variable_name(node)
        node = node.value if node.respond_to?(:value) &&
          node.value.respond_to?(:value)
        node.respond_to?(:value) ? node.value.to_sym : nil
      end

      def source_location(node = nil)
        node&.location
      end

      def compile_statements(statements, normal: nil)
        statements.body.each_with_index do |statement, index|
          next if statement.is_a?(VoidStmt)
          next unless @current

          is_last = index == statements.body.length - 1
          next_normal = is_last ? normal : nil
          compile_statement(statement, normal: next_normal)
        end
      end

      def compile_statement(node, normal: nil)
        return unless @current

        case node
        when Statements
          compile_statements(node, normal: normal)
        when Begin
          compile_body(node.bodystmt, node.location, normal: normal)
        when BodyStmt
          compile_body(node, node.location, normal: normal)
        when IfNode, UnlessNode
          compile_if(node, normal: normal)
        when IfOp
          compile_if_op(node, normal: normal)
        when RescueMod
          compile_rescue_mod(node, normal: normal)
        when WhileNode, UntilNode
          compile_loop(node, normal: normal)
        when For
          compile_for(node, normal: normal)
        when Case
          compile_case(node, normal: normal)
        when ReturnNode
          compile_return(node)
        when Break
          compile_break(node)
        when Next
          compile_next(node)
        when Redo
          compile_redo(node)
        when Retry
          compile_retry(node)
        when DefNode
          # Nested method definitions only add a method object; their body is a
          # separate interprocedural graph and is not executed at definition.
          normal&.call
        when Lambda
          normal&.call
        when MethodAddBlock
          compile_method_add_block(node, normal: normal)
        when Assign
          compile_assign(node, normal: normal)
        else
          emit_expression(node)
          normal&.call
        end
      end

      def emit_expression(node, child: false)
        return nil unless @current

        if node.is_a?(VCall) && local_variable?(node)
          return emit_local_variable(node)
        end

        case node
        when nil, VoidStmt, Params, BlockVar, LambdaVar
          nil
        when Args, BareAssocHash, Paren
          emit_container_children(node)
        when Binary
          @current.push(node) unless child
          emit_binary(node)
        when IfOp
          @current.push(node) unless child
          emit_if_op(node)
        when Assign
          @current.push(node) unless child
          emit_assign(node)
        when Lambda
          nil
        when MethodAddBlock
          @current.push(node) unless child || @method_add_block_call
          compile_method_add_block(node, normal: nil)
        when CallNode, Command, CommandCall, Super, ZSuper, YieldNode,
             XStringLiteral, VCall
          @current.push(node) unless child
          compile_call(node)
        when DefNode
          nil
        else
          @current.push(node) if !child && node.respond_to?(:location)
          if node.respond_to?(:child_nodes)
            node.child_nodes.compact.each do |child_node|
              emit_expression(child_node, child: true)
            end
          end
          add_exception_edge(node) unless safe_node?(node)
        end
        @current&.id
      end

      def emit_container_children(node)
        case node
        when Paren
          emit_expression(node.contents, child: true)
        when Args
          node.parts.each { |part| emit_expression(part, child: true) }
        when BareAssocHash
          node.assocs.each { |assoc| emit_expression(assoc, child: true) }
        end
      end

      def emit_local_variable(node)
        @current.push(node)
        @current.id
      end

      def emit_binary(node)
        case node.operator
        when :"&&"
          emit_short_circuit(node, truthy_right: true)
        when :"||"
          emit_short_circuit(node, truthy_right: false)
        else
          emit_expression(node.left)
          emit_expression(node.right)
          add_exception_edge(node) unless safe_node?(node)
        end
      end

      def emit_short_circuit(node, truthy_right:)
        emit_expression(node.left)
        return unless @current

        merge = new_target(:merge, "short-circuit merge", node.location)
        right = new_target(:expression, "right operand", node.right.location)
        branch(
          node.left.location,
          right,
          merge,
          truthy_right ? :truthy : :falsy,
          node.location
        )
        saved = @current
        @current = @blocks.find { |block| block.id == right }
        emit_expression(node.right)
        connect_if_current(merge, :fallthrough)
        @current = @blocks.find { |block| block.id == merge }
      end

      def emit_if_op(node)
        emit_expression(node.predicate)
        return unless @current

        merge = new_target(:merge, "ternary merge", node.location)
        truthy =
          new_target(:expression, "truthy expression", node.truthy.location)
        falsy = new_target(:expression, "falsy expression", node.falsy.location)
        branch(node.predicate.location, truthy, falsy, :branch, node.location)
        compile_operand_to(node.truthy, truthy, merge)
        compile_operand_to(node.falsy, falsy, merge)
        @current = @blocks.find { |block| block.id == merge }
      end

      def compile_operand_to(node, start_id, merge_id)
        @current = @blocks.find { |block| block.id == start_id }
        emit_expression(node)
        connect_if_current(merge_id, :fallthrough)
      end

      def emit_assign(node)
        saved = @current
        emit_expression(node.value)
        @current = saved
        add_exception_edge(node) unless safe_node?(node)
      end

      def compile_assign(node, normal:)
        emit_assign(node)
        normal&.call
      end

      def compile_if(node, normal:)
        emit_expression(node.predicate)
        return unless @current

        merge = new_target(:merge, "conditional merge", node.location)
        truthy = new_target(:branch, "truthy branch", node.statements.location)
        falsy = new_target(:branch, "falsy branch", node.consequent&.location)
        truthy_condition = node.is_a?(UnlessNode) ? :falsy : :truthy
        falsy_condition = node.is_a?(UnlessNode) ? :truthy : :falsy
        branch(node.predicate.location, truthy, falsy, :branch, node.location)

        compile_branch_body(node.statements, truthy, merge, normal)
        compile_conditional_consequent(node.consequent, falsy, merge, normal)
        @current = @blocks.find { |block| block.id == merge }
        normal&.call
      end

      def compile_conditional_consequent(node, start_id, merge, normal)
        case node
        when nil
          connect_from(start_id, merge, :fallthrough)
        when Else
          compile_branch_body(node.statements, start_id, merge, normal)
        when Elsif
          @current = @blocks.find { |block| block.id == start_id }
          compile_elsif(node, merge, normal)
        end
      end

      def compile_elsif(node, merge, normal)
        emit_expression(node.predicate)
        return unless @current

        truthy =
          new_target(:branch, "elsif truthy branch", node.statements.location)
        falsy =
          new_target(:branch, "elsif falsy branch", node.consequent&.location)
        branch(node.predicate.location, truthy, falsy, :branch, node.location)
        compile_branch_body(node.statements, truthy, merge, normal)
        compile_conditional_consequent(node.consequent, falsy, merge, normal)
      end

      def compile_branch_body(statements, start_id, merge, normal)
        @current = @blocks.find { |block| block.id == start_id }
        compile_statements(
          statements,
          normal: proc { connect_if_current(merge, :fallthrough) }
        )
        connect_if_current(merge, :fallthrough)
      end

      def compile_if_op(node, normal:)
        emit_if_op(node)
        normal&.call
      end

      def compile_rescue_mod(node, normal:)
        compile_body(
          BodyStmt.new(
            statements: expression_statements(node.statement),
            rescue_clause:
              Rescue.new(
                keyword: Kw.new(value: "rescue", location: node.location),
                exception: nil,
                statements: expression_statements(node.value),
                consequent: nil,
                location: node.location
              ),
            else_keyword: nil,
            else_clause: nil,
            ensure_clause: nil,
            location: node.location
          ),
          node.location,
          normal: normal
        )
      end

      def branch(location, truthy, falsy, condition, edge_location)
        connect(
          truthy,
          :branch,
          condition: :truthy,
          location: location || edge_location
        )
        connect_from(
          current_id,
          falsy,
          :branch,
          condition: :falsy,
          location: location || edge_location
        )
      end

      def safe_node?(node)
        (
          SAFE_NODES.map(&:to_s).include?(node.class.name.split("::").last) ||
            (node.is_a?(VCall) && local_variable?(node))
        ) || node.is_a?(Node) && !node.respond_to?(:child_nodes)
      end

      def local_variable?(node)
        node.is_a?(VCall) && @local_variables.include?(node.value.value.to_sym)
      end

      def add_exception_edge(node, target = current_exception_target(node))
        return unless target

        connect(target, :exception, location: node.location, exception: true)
      end

      def current_exception_target(node)
        rescue_frame =
          @frames.reverse.find do |frame|
            frame[:kind] == :rescue && frame[:mode] == :body
          end
        handler_frame =
          @frames.reverse.find do |frame|
            frame[:kind] == :rescue && frame[:mode] == :handler
          end
        ensure_frame =
          @frames.reverse.find do |frame|
            frame[:kind] == :ensure && frame[:active]
          end
        if rescue_frame &&
             (
               !ensure_frame ||
                 frame_index(ensure_frame) > frame_index(rescue_frame)
             )
          rescue_frame[:guard]
        elsif handler_frame && ensure_frame &&
              frame_index(ensure_frame) > frame_index(handler_frame)
          ensure_frame[:entry]
        elsif handler_frame
          outer_rescue =
            @frames.reverse.find do |frame|
              frame[:kind] == :rescue && frame[:mode] == :body &&
                frame_index(frame) < frame_index(handler_frame)
            end
          outer_rescue ? outer_rescue[:guard] : method_frame[:exception_exit]
        elsif ensure_frame
          ensure_frame[:entry]
        else
          method_frame[:exception_exit]
        end
      end

      def method_frame
        @frames.find { |frame| frame[:kind] == :method }
      end

      def compile_body(body, outer_location, normal:)
        result = block!(:merge, "begin merge", outer_location)
        rescue_frame = nil
        ensure_frame = nil

        if body.ensure_clause
          ensure_entry =
            block!(:ensure, "ensure entry", body.ensure_clause.location)
          ensure_frame = {
            kind: :ensure,
            entry: ensure_entry.id,
            node: body.ensure_clause,
            active: true,
            normal_target: ensure_entry.id,
            result_target: result.id
          }
        else
          ensure_entry = nil
        end

        if body.rescue_clause
          guard =
            block!(:rescue_guard, "rescue guard", body.rescue_clause.location)
          rescue_frame = {
            kind: :rescue,
            guard: guard.id,
            node: body.rescue_clause,
            mode: :body,
            result: result.id
          }
        end

        @frames << rescue_frame if rescue_frame
        @frames << ensure_frame if ensure_frame

        else_entry =
          body.else_clause &&
            block!(:branch, "begin else", body.else_clause.location).id
        normal_after_protected = ensure_entry&.id || result.id
        outer_ensure_for_inner =
          @frames.reverse.find do |frame|
            frame[:kind] == :ensure && frame[:entry] != ensure_frame[:entry]
          end
        inner_normal_target =
          if ensure_frame && outer_ensure_for_inner
            outer_ensure_for_inner[:entry]
          else
            normal_after_protected
          end
        ensure_frame[:normal_target] = inner_normal_target if ensure_frame
        ensure_frame[:result_target] = result.id if ensure_frame

        rescue_frame[:mode] = :body if rescue_frame

        if body.else_clause
          compile_statements(
            body.statements,
            normal: proc { connect(else_entry, :fallthrough) }
          )
          rescue_frame && rescue_frame[:mode] = :else
          @current = @blocks.find { |block| block.id == else_entry }
          compile_statements(
            body.else_clause,
            normal: proc { connect(inner_normal_target, :fallthrough) }
          )
        else
          compile_statements(
            body.statements,
            normal: proc { connect(inner_normal_target, :fallthrough) }
          )
        end

        unmatched_target = ensure_entry&.id || method_frame[:exception_exit]
        if body.rescue_clause
          compile_rescue_chain(
            body.rescue_clause,
            rescue_frame[:guard],
            unmatched_target
          )
        end

        if body.ensure_clause
          rescue_frame && rescue_frame[:mode] = :ensure
          ensure_frame[:active] = false
          saved_current = @current
          @current = ensure_entry
          compile_statements(body.ensure_clause.statements, normal: nil)
          ensure_end = @current || ensure_entry
          ensure_frame[:active] = true
          connect_ensure_outcomes(
            ensure_end.id,
            result.id,
            ensure_frame[:result_target] || result.id
          )
          @current = saved_current
        end

        while @frames.last == ensure_frame || @frames.last == rescue_frame
          @frames.pop
        end
        @current = result
        normal&.call
      end

      def compile_rescue_chain(clause, guard_id, unmatched_target)
        frame = @frames.reverse.find { |item| item[:kind] == :rescue }
        @current = @blocks.find { |block| block.id == guard_id }
        frame[:mode] = :matching

        handler =
          block!(:rescue_handler, "rescue handler", clause.statements.location)
        if clause.exception
          Array(clause.exception.exceptions).each do |exception|
            emit_expression(exception)
          end
          next_guard =
            clause.consequent &&
              block!(
                :rescue_guard,
                "rescue guard",
                clause.consequent.location
              ).id
          connect(
            handler.id,
            :rescue_match,
            condition: :truthy,
            location: clause.location
          )
          connect_from(
            guard_id,
            next_guard || unmatched_target,
            :rescue_match,
            condition: :falsy,
            location: clause.location,
            unmatched: clause.consequent.nil?
          )
        else
          connect(
            handler.id,
            :rescue_match,
            condition: :truthy,
            location: clause.location
          )
        end

        frame[:mode] = :handler
        @current = handler
        ensure_frame = @frames.reverse.find { |item| item[:kind] == :ensure }
        normal_target = ensure_frame ? ensure_frame[:entry] : frame[:result]
        normal_target ||= method_frame[:exception_exit]
        compile_statements(
          clause.statements,
          normal: proc { connect(normal_target, :fallthrough, rescued: true) }
        )

        return unless clause.consequent

        next_guard =
          @blocks
            .find do |block|
              block.kind == :rescue_guard &&
                block.location == clause.consequent.location
            end
            &.id
        compile_rescue_chain(clause.consequent, next_guard, unmatched_target)
      end

      def connect_ensure_outcomes(
        source,
        result_target,
        protected_normal_target = nil
      )
        current_ensure =
          @frames.reverse.find { |frame| frame[:kind] == :ensure }
        outer_ensure = @frames.reverse.find { |frame| frame[:kind] == :ensure }
        outer_ensure = nil if outer_ensure == current_ensure

        connect_ensure_exit(
          source,
          :normal,
          protected_normal_target || result_target,
          outer_ensure
        )
        connect_ensure_exit(
          source,
          :exception,
          ensure_exception_target(current_ensure),
          outer_ensure
        )
        connect_ensure_exit(
          source,
          :return,
          method_frame[:return_exit],
          outer_ensure_for_end
        )
        break_target = nearest_break_target
        if break_target
          connect_ensure_exit(source, :break, break_target, outer_ensure)
        end
        next_target = nearest_next_target
        if next_target
          connect_ensure_exit(source, :next, next_target, outer_ensure)
        end
        redo_target = nearest_redo_target
        if redo_target
          connect_ensure_exit(
            source,
            :redo,
            redo_target[:predicate] || redo_target[:entry],
            outer_ensure
          )
        end
        retry_target = nearest_retry_target
        if retry_target
          connect_ensure_exit(
            source,
            :retry,
            retry_target[:guard],
            outer_ensure
          )
        end
      end

      def connect_ensure_exit(source, trigger, target, outer_ensure)
        if outer_ensure && trigger != :normal
          connect_from(
            source,
            outer_ensure[:entry],
            :ensure_exit,
            trigger: trigger,
            terminal_trigger: trigger,
            terminal_target: target
          )
        else
          connect_from(source, target, :ensure_exit, trigger: trigger)
        end
      end

      def outer_ensure_for_end
        current_ensure =
          @frames.reverse.find { |frame| frame[:kind] == :ensure }
        @frames.reverse.find do |frame|
          frame[:kind] == :ensure &&
            frame[:entry] != current_ensure&.dig(:entry)
        end
      end

      def ensure_exception_target(_ensure_frame)
        outer_rescue =
          @frames.reverse.find do |frame|
            frame[:kind] == :rescue &&
              %i[body matching handler].include?(frame[:mode])
          end
        current_rescue =
          @frames.reverse.find { |frame| frame[:kind] == :rescue }
        if outer_rescue && outer_rescue != current_rescue
          outer_rescue[:guard]
        else
          method_frame[:exception_exit]
        end
      end

      def compile_return(node)
        @current&.push(node)
        Array(node.arguments&.parts).each do |argument|
          emit_expression(argument)
        end
        target = nearest_return_target
        if target.is_a?(Hash)
          route_terminal(target[:return_exit], :return, node, :return)
        else
          route_terminal(target, :return, node, :return)
        end
        terminate!
      end

      def compile_break(node)
        @current&.push(node)
        Array(node.arguments&.parts).each do |argument|
          emit_expression(argument)
        end
        target = nearest_break_target
        route_terminal(target, :break, node, :break)
        terminate!
      end

      def compile_next(node)
        @current&.push(node)
        Array(node.arguments&.parts).each do |argument|
          emit_expression(argument)
        end
        target = nearest_next_target
        route_terminal(target, :next, node, :next)
        terminate!
      end

      def compile_redo(node)
        @current&.push(node)
        target = nearest_redo_target
        route_terminal(target, :redo, node, :redo)
        terminate!
      end

      def compile_retry(node)
        @current&.push(node)
        target = nearest_retry_target
        route_terminal(target[:guard] || target[:entry], :retry, node, :retry)
        terminate!
      end

      def route_terminal(target, type, node, trigger)
        ensure_frame =
          @frames.reverse.find do |frame|
            frame[:kind] == :ensure && frame[:active]
          end
        if ensure_frame
          connect(
            ensure_frame[:entry],
            type,
            location: node.location,
            terminal_trigger: trigger,
            terminal_target: target
          )
        else
          connect(target, type, location: node.location)
        end
      end

      def nearest_return_target
        frame =
          @frames.reverse.find do |item|
            %i[method block lambda].include?(item[:kind])
          end
        frame[:kind] == :lambda ? frame : frame[:return_exit]
      end

      def nearest_break_target
        frame =
          @frames.reverse.find do |item|
            %i[method block loop lambda].include?(item[:kind])
          end
        return nil unless frame

        frame[:break_exit]
      end

      def nearest_next_target
        frame =
          @frames.reverse.find do |item|
            %i[method block loop].include?(item[:kind])
          end
        frame[:kind] == :block ? frame[:next_exit] : frame[:iterator_continue]
      end

      def nearest_redo_target
        frame = @frames.reverse.find { |item| item[:kind] == :loop }
        frame && frame[:predicate] || frame && frame[:entry]
      end

      def nearest_retry_target
        @frames.reverse.find { |item| item[:kind] == :rescue }
      end

      def compile_loop(node, normal:)
        predicate =
          new_target(:loop_predicate, "loop predicate", node.predicate.location)
        body = new_target(:loop_body, "loop body", node.statements.location)
        continuation = new_target(:merge, "loop continuation", node.location)
        connect(predicate, :fallthrough)
        @current = @blocks.find { |block| block.id == predicate }
        emit_expression(node.predicate)
        truthy = node.is_a?(UntilNode) ? continuation : body
        falsy = node.is_a?(UntilNode) ? body : continuation
        connect(
          body,
          :branch,
          condition: :truthy,
          location: node.predicate.location
        )
        connect_from(
          predicate,
          continuation,
          :branch,
          condition: :falsy,
          location: node.predicate.location
        )

        frame =
          push_frame(
            kind: :loop,
            entry: predicate,
            predicate: predicate,
            body: body,
            normal_exit: continuation,
            return_exit: method_frame[:return_exit],
            break_exit: continuation,
            next_exit: predicate,
            iterator_continue: predicate,
            exception_exit: method_frame[:exception_exit],
            node: node
          )
        @current = @blocks.find { |block| block.id == body }
        compile_statements(
          node.statements,
          normal: proc { connect(predicate, :fallthrough) }
        )
        connect_if_current(predicate, :fallthrough)
        pop_frame
        @current = @blocks.find { |block| block.id == continuation }
        normal&.call
      end

      def compile_for(node, normal:)
        emit_expression(node.collection)
        predicate =
          new_target(:loop_predicate, "for predicate", node.collection.location)
        body = new_target(:loop_body, "for body", node.statements.location)
        continuation = new_target(:merge, "for continuation", node.location)
        connect(predicate, :fallthrough)
        connect_from(
          predicate,
          body,
          :branch,
          condition: :truthy,
          location: node.collection.location
        )
        connect_from(
          predicate,
          continuation,
          :branch,
          condition: :falsy,
          location: node.collection.location
        )
        push_frame(
          kind: :loop,
          entry: predicate,
          predicate: predicate,
          body: body,
          normal_exit: continuation,
          return_exit: method_frame[:return_exit],
          break_exit: continuation,
          next_exit: predicate,
          iterator_continue: predicate,
          exception_exit: method_frame[:exception_exit],
          node: node
        )
        @current = @blocks.find { |block| block.id == body }
        compile_statements(
          node.statements,
          normal: proc { connect(predicate, :fallthrough) }
        )
        connect_if_current(predicate, :fallthrough)
        pop_frame
        @current = @blocks.find { |block| block.id == continuation }
        normal&.call
      end

      def compile_case(node, normal:)
        emit_expression(node.value) if node.value
        merge = new_target(:merge, "case merge", node.location)
        compile_case_clause(
          node.consequent,
          merge,
          node.value,
          pattern_match: false,
          normal: normal
        )
        @current = @blocks.find { |block| block.id == merge }
        normal&.call
      end

      def compile_case_clause(node, merge, case_value, pattern_match:, normal:)
        case node
        when nil
          if pattern_match
            connect(
              method_frame[:exception_exit],
              :exception,
              location: nil,
              exception_class: "NoMatchingPatternError"
            )
          else
            connect(merge, :fallthrough)
          end
        when Else
          target = new_target(:branch, "case else", node.statements.location)
          connect(target, :branch, condition: :truthy)
          @current = @blocks.find { |block| block.id == target }
          compile_statements(
            node.statements,
            normal: proc { connect(merge, :fallthrough) }
          )
        when When
          target = new_target(:branch, "when body", node.statements.location)
          next_clause =
            new_target(:rescue_guard, "next when", node.consequent&.location)
          connect(
            target,
            :branch,
            condition: :truthy,
            location: node.arguments.location
          )
          connect_from(
            current_id,
            next_clause,
            :branch,
            condition: :falsy,
            location: node.arguments.location
          )
          @current = @blocks.find { |block| block.id == target }
          compile_statements(
            node.statements,
            normal: proc { connect(merge, :fallthrough) }
          )
          @current = @blocks.find { |block| block.id == next_clause }
          compile_case_clause(
            node.consequent,
            merge,
            case_value,
            pattern_match: false,
            normal: normal
          )
        when In
          target = new_target(:branch, "in body", node.statements.location)
          next_clause =
            new_target(:rescue_guard, "next in", node.consequent&.location)
          emit_expression(node.pattern)
          connect(
            target,
            :branch,
            condition: :truthy,
            location: node.pattern.location
          )
          connect_from(
            current_id,
            next_clause,
            :branch,
            condition: :falsy,
            location: node.pattern.location
          )
          @current = @blocks.find { |block| block.id == target }
          compile_statements(
            node.statements,
            normal: proc { connect(merge, :fallthrough) }
          )
          @current = @blocks.find { |block| block.id == next_clause }
          compile_case_clause(
            node.consequent,
            merge,
            case_value,
            pattern_match: true,
            normal: normal
          )
        end
      end

      def compile_call(node)
        @call_node = true
        lambda_frame = known_lambda_frame(node)
        if lambda_frame
          begin
            return compile_known_lambda(node, lambda_frame)
          ensure
            @call_node = false
          end
        end

        compile_call_operands(node)
        effect = emit_effect(node, :call)
        post = split!(:merge, "after call", node.location)
        connect_from(
          effect[:block],
          post.id,
          :return_from_call,
          location: node.location,
          effect: effect[:id]
        )
        connect_from(
          effect[:block],
          current_exception_target(node),
          :exception,
          location: node.location,
          effect: effect[:id]
        )
        target = nearest_nonlocal_return_target
        if target
          connect_from(
            effect[:block],
            target,
            :nonlocal_return,
            location: node.location,
            effect: effect[:id]
          )
        end
        @call_node = false
        @current
      end

      def compile_call_operands(node)
        @call_node = true if node.is_a?(CallNode)
        case node
        when CallNode
          emit_expression(node.receiver)
          emit_arguments(node.arguments)
        when Command, CommandCall
          emit_expression(node.receiver) if node.respond_to?(:receiver)
          emit_arguments(node.arguments)
        when Super, YieldNode
          emit_arguments(node.arguments)
        end
      end

      def emit_arguments(arguments)
        return unless arguments
        return emit_expression(arguments.contents) if arguments.is_a?(Paren)
        return emit_expression(arguments) if arguments.is_a?(Args)
      end

      def emit_effect(node, kind, metadata: nil)
        block = split!(:effect, "#{kind} #{call_name(node)}", node.location)
        id = "ef#{@effects.length + 1}"
        effect =
          Effect.new(
            id: id,
            kind: kind,
            location: node.location,
            node: node,
            method_name: call_name(node),
            metadata: (metadata || {}).merge(recursive: recursive_call?(node))
          )
        @effects << effect
        { id: id, block: block.id }
      end

      def call_name(node)
        case node
        when CallNode
          if node.arguments.nil? && node.receiver.nil? &&
               node.message.respond_to?(:value)
            nil
          elsif node.message.is_a?(Symbol)
            node.message
          else
            node_name(node.message)
          end
        when Command, CommandCall
          node_name(node.message)
        when Super, ZSuper
          :super
        when YieldNode
          :yield
        when XStringLiteral
          :backtick
        when VCall
          node_name(node.value)
        when nil
          :unknown
        else
          :unknown
        end
      end

      def recursive_call?(node)
        call_name(node) == @cfg&.method_name
      end

      def known_lambda_frame(node)
        return nil unless node.is_a?(CallNode) && node.receiver.is_a?(VarRef)

        variable = variable_name(node.receiver)
        frame = @lambda_by_variable[variable]
        frame && node_name(node.message) == :call ? frame : nil
      end

      def compile_known_lambda(node, frame)
        compile_call_operands(node)
        effect =
          emit_effect(node, :lambda_call, metadata: { region: frame[:id] })
        post = block!(:merge, "after lambda call", node.location)
        connect(
          frame[:entry],
          :invoke_lambda,
          location: node.location,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          frame[:normal_exit],
          post.id,
          :return_from_call,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          frame[:return_exit],
          post.id,
          :lambda_return,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          frame[:exception_exit],
          method_frame[:exception_exit],
          :exception,
          effect: effect[:id],
          region: frame[:id]
        )
        @current = post
      end

      def nearest_nonlocal_return_target
        frame =
          @frames.reverse.find do |item|
            %i[method block lambda].include?(item[:kind])
          end
        return nil unless frame
        frame[:kind] == :lambda ? nil : method_frame[:return_exit]
      end

      def compile_method_add_block(node, normal:)
        @method_add_block_call = true
        compile_call_operands(node.call)
        block_node = node.block
        if lambda_block?(block_node)
          lambda =
            block_node.bodystmt.is_a?(Lambda) ? block_node.bodystmt : block_node
          compile_lambda_invoke(node, lambda, normal: normal)
        else
          compile_plain_block_invoke(node, normal: normal)
        end
        @method_add_block_call = false
      end

      def lambda_block?(_block)
        false
      end

      def compile_plain_block_invoke(node, normal:)
        effect = emit_effect(node.call, :call)
        invoke = block!(:invoke, "block invoke", node.block.location)
        decision =
          block!(:iterator_decision, "iterator decision", node.block.location)
        post = block!(:merge, "after block call", node.location)
        entry, normal_exit, next_exit, break_exit, frame =
          build_plain_block_frame(node.block)

        connect_from(
          effect[:block],
          invoke.id,
          :invoke_block,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(invoke.id, entry, :fallthrough)
        connect_from(
          normal_exit,
          decision.id,
          :block_normal,
          region: frame[:id]
        )
        connect_from(next_exit, decision.id, :next, region: frame[:id])
        connect_from(break_exit, post.id, :break, region: frame[:id])
        connect_from(
          decision.id,
          entry,
          :reinvoke_block,
          condition: :truthy,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          decision.id,
          post.id,
          :return_from_call,
          condition: :falsy,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          effect[:block],
          current_exception_target(node.call),
          :exception,
          location: node.location,
          effect: effect[:id]
        )
        target = nearest_nonlocal_return_target
        if target
          connect_from(
            effect[:block],
            target,
            :nonlocal_return,
            location: node.location,
            effect: effect[:id]
          )
        end
        @current = post
        normal&.call
      end

      def build_plain_block_frame(block_node)
        entry = block!(:block_entry, "block entry", block_node.location)
        normal_exit =
          block!(:block_exit, "block normal exit", block_node.location)
        next_exit = block!(:block_exit, "block next exit", block_node.location)
        break_exit =
          block!(:block_exit, "block break exit", block_node.location)
        frame =
          push_frame(
            kind: :block,
            entry: entry.id,
            normal_exit: normal_exit.id,
            return_exit: method_frame[:return_exit],
            break_exit: break_exit.id,
            next_exit: next_exit.id,
            exception_exit: method_frame[:exception_exit],
            node: block_node
          )
        @current = entry
        statements = block_body(block_node)
        compile_statements(
          statements,
          normal: proc { connect(normal_exit.id, :fallthrough) }
        )
        connect_if_current(normal_exit.id, :fallthrough)
        pop_frame
        [entry.id, normal_exit.id, next_exit.id, break_exit.id, frame]
      end

      def block_body(block_node)
        body = block_node.bodystmt
        body.is_a?(BodyStmt) ? body.statements : body
      end

      def build_lambda(lambda_node)
        entry = block!(:lambda_entry, "lambda entry", lambda_node.location)
        normal_exit =
          block!(:lambda_exit, "lambda normal exit", lambda_node.location)
        return_exit =
          block!(:lambda_exit, "lambda return exit", lambda_node.location)
        exception_exit =
          block!(
            :lambda_exception,
            "lambda exception exit",
            lambda_node.location
          )
        frame =
          push_frame(
            kind: :lambda,
            entry: entry.id,
            normal_exit: normal_exit.id,
            return_exit: return_exit.id,
            break_exit: method_frame[:break_exit],
            next_exit: method_frame[:next_exit],
            exception_exit: exception_exit.id,
            node: lambda_node
          )
        @current = entry
        statements = lambda_statements(lambda_node)
        compile_statements(
          statements,
          normal: proc { connect(normal_exit.id, :fallthrough) }
        )
        connect_if_current(normal_exit.id, :fallthrough)
        pop_frame
        connect_from(
          exception_exit.id,
          method_frame[:exception_exit],
          :exception,
          location: lambda_node.location,
          disconnected: true
        )
        yield if block_given?
        frame
      end

      def lambda_statements(lambda_node)
        body = lambda_node.statements
        body.is_a?(BodyStmt) ? body.statements : body
      end

      def compile_lambda_invoke(node, lambda_node, normal:)
        effect = emit_effect(node.call, :call)
        frame = build_lambda(lambda_node)
        post = split!(:merge, "after lambda call", node.location)
        connect_from(
          effect[:block],
          frame[:entry],
          :invoke_lambda,
          location: node.location,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          frame[:normal_exit],
          post.id,
          :return_from_call,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          frame[:return_exit],
          post.id,
          :lambda_return,
          location: node.location,
          effect: effect[:id],
          region: frame[:id]
        )
        connect_from(
          frame[:exception_exit],
          method_frame[:exception_exit],
          :exception,
          effect: effect[:id],
          region: frame[:id]
        )
        normal&.call
      end
    end
  end
end
