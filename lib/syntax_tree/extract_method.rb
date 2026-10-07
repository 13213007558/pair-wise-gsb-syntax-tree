# frozen_string_literal: true

module SyntaxTree
  # ExtractMethod analyzes and performs a conservative extract-method
  # refactoring on a contiguous range of statements inside an ordinary method.
  module ExtractMethod
    Variable = Struct.new(:name, :kind, :location, keyword_init: true)
    Issue = Struct.new(:type, :message, :location, keyword_init: true)
    Plan = Struct.new(
      :method_name,
      :parameters,
      :return_values,
      :unsafe_control_flow,
      :unsafe_closures,
      :start_line,
      :end_line,
      keyword_init: true
    ) do
      def safe?
        unsafe_control_flow.empty? && unsafe_closures.empty?
      end
    end

    Result = Struct.new(:source, :plan, keyword_init: true)

    METHOD_NAME_PATTERN = /\A[a-z_][a-zA-Z0-9_]*[!?=]?\z/
    RESULT_VARIABLE = "__syntax_tree_extract_result__"
    LOOP_NODES = [For, WhileNode, UntilNode].freeze
    PROC_FACTORIES = %w[proc lambda Proc.new].freeze
    IMMEDIATE_BLOCK_METHODS =
      %w[
        all?
        any?
        collect
        collect_concat
        detect
        each
        each_cons
        each_entry
        each_slice
        each_with_index
        each_with_object
        filter
        filter_map
        find
        find_all
        flat_map
        inject
        map
        none?
        one?
        reduce
        reject
        reverse_each
        select
        sort_by
        sum
        tap
        times
        upto
      ].freeze

    def self.analyze(source, start_line:, end_line:, method_name: "extracted_method")
      Analyzer
        .new(source, start_line, end_line, method_name)
        .analyze
    end

    def self.extract(source, start_line:, end_line:, method_name: "extracted_method")
      analyzer = Analyzer.new(source, start_line, end_line, method_name)
      plan = analyzer.analyze
      unless plan.safe?
        messages = plan.unsafe_control_flow + plan.unsafe_closures
        raise InvalidExtraction, messages.map(&:message).join("; ")
      end

      Result.new(source: analyzer.transform, plan: plan)
    end

    class InvalidExtraction < StandardError; end

    class Analyzer # :nodoc:
      def initialize(source, start_line, end_line, method_name)
        @source = source
        @start_line = start_line
        @end_line = end_line
        @method_name = method_name
        @program = SyntaxTree.parse(source)
        @parents = build_parent_map(@program)
        @frames_by_node = {}
        @frames = []
        @events = []
      end

      def analyze
        validate_request!
        build_scopes!

        parameters = determine_parameters
        return_values = determine_return_values
        unsafe_control_flow = control_flow_issues
        unsafe_closures =
          existing_closure_issues +
          created_closure_issues +
          ordinary_block_issues

        Plan.new(
          method_name: method_name,
          parameters: parameters,
          return_values: return_values,
          unsafe_control_flow: unsafe_control_flow,
          unsafe_closures: unsafe_closures,
          start_line: first_statement.location.start_line,
          end_line: last_statement.location.end_line
        )
      end

      def transform
        plan = analyze
        unless plan.safe?
          raise InvalidExtraction, issue_messages(plan)
        end

        replacement = build_replacement(plan)
        replaced = replace_selected_source(replacement)
        insertion = enclosing_def.location.end_char + (replaced.length - source.length)
        insert_extracted_method(replaced, plan, insertion)
      end

      private

      def issue_messages(plan)
        (plan.unsafe_control_flow + plan.unsafe_closures)
          .map(&:message)
          .join("; ")
      end

      attr_reader :source, :start_line, :end_line, :method_name, :program,
                  :parents, :frames_by_node, :frames, :events,
                  :selected_statements, :enclosing_def, :statements_node,
                  :root_frame

      def validate_request!
        raise ArgumentError, "start line must be positive" unless start_line.positive?
        raise ArgumentError, "end line must precede start line" if end_line < start_line
        unless method_name.match?(METHOD_NAME_PATTERN)
          raise ArgumentError, "invalid method name: #{method_name}"
        end

        find_selected_statements!
        @enclosing_def = lexical_ancestor(selected_statements.first, DefNode)
        @root_frame = nil
        unless enclosing_def
          raise InvalidExtraction, "selection must be inside an ordinary method"
        end

        if existing_definition_names.include?(method_name)
          raise ArgumentError, "method name already exists: #{method_name}"
        end
      end

      def find_selected_statements!
        candidates = []
        each_node(program) do |node|
          next unless node.is_a?(Statements)
          executable = executable_statements(node)
          next if executable.empty?

          matching = node.body.select { |statement| statement_contained_in_request?(statement) }
          next if matching.empty?
          indexes = matching.map { |statement| node.body.index(statement) }
          next unless indexes.each_cons(2).all? { |left, right| right == left + 1 }

          candidates << [node, matching.reject { |statement| statement.is_a?(VoidStmt) }]
        end

        raise InvalidExtraction, "selection must contain complete statements" if candidates.empty?
        @statements_node, @selected_statements = choose_candidate(candidates)
        ensure_no_partial_tokens!
        ensure_requested_tokens_are_covered!
      end

      def choose_candidate(candidates)
        candidates.min_by do |node, matching|
          span = matching.last.location.end_char - matching.first.location.start_char
          [-span, parents.keys.count { |child| parents[child] == node }]
        end
      end

      def ensure_no_partial_tokens!
        range_start = selected_statements.first.location.start_char
        range_end = selected_statements.last.location.end_char

        selected_text = source[range_start...range_end].to_s
        return if selected_text =~ /\S/
        raise InvalidExtraction, "selection must contain complete statements"
      end

      def ensure_requested_tokens_are_covered!
        request_start = line_offsets.fetch(start_line - 1)
        request_end = line_offsets.fetch(end_line, source.length)
        ranges = selected_statements.map do |statement|
          [statement.location.start_char, statement.location.end_char]
        end
        each_node(program) do |node|
          next unless node.is_a?(Comment)
          next unless node.location.start_char >= request_start &&
            node.location.end_char <= request_end
          ranges << [node.location.start_char, node.location.end_char]
        end

        source[request_start...request_end].each_char.with_index(request_start) do |char, index|
          next if char =~ /\s/
          next if ranges.any? { |start_position, end_position| index >= start_position && index < end_position }

          raise InvalidExtraction, "selection must contain complete statements"
        end
      end

      def statement_contained_in_request?(node)
        start_offset = line_offsets.fetch(start_line - 1)
        end_offset = line_offsets.fetch(end_line, source.length)
        node.location.start_char >= start_offset &&
          node.location.end_line <= end_line &&
          node.location.end_char <= end_offset
      end

      def line_offsets
        @line_offsets ||=
          begin
            offsets = [0]
            source.each_line { |line| offsets << offsets.last + line.length }
            offsets
          end
      end

      def executable_statements(node)
        node.body.reject { |statement| statement.is_a?(VoidStmt) }
      end

      def first_statement
        selected_statements.first
      end

      def last_statement
        selected_statements.last
      end

      def build_parent_map(node, parent = nil)
        mapping = {}
        stack = [[node, parent]]

        while (current, current_parent = stack.pop)
          next unless current
          mapping[current] = current_parent
          current.child_nodes.each { |child| stack << [child, current] }
        end

        mapping
      end

      def each_node(node, &block)
        return enum_for(:each_node, node) unless block

        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless current
          yield(current)
          stack.concat(current.child_nodes)
        end
      end

      def lexical_ancestor(node, *types)
        current = node
        while current
          return current if types.include?(current.class)
          current = parents[current]
        end
        nil
      end

      def lexical_ancestors(node)
        ancestors = []
        current = parents[node]
        while current
          ancestors << current
          current = parents[current]
        end
        ancestors
      end

      def existing_definition_names
        names = []
        each_node(program) do |node|
          next unless node.is_a?(DefNode)
          names << node.name.value
        end
        names
      end

      def build_scopes!
        visit_scope(enclosing_def)
        @root_frame = frame_for_nearest_lexical_context(selected_statements.first)
      end

      def frame_for_nearest_lexical_context(node)
        current = node
        while current
          frame = frames_by_node[current]
          return frame if frame
          current = parents[current]
        end
      end

      def visit_scope(node, parent_frame = nil)
        case node
        when DefNode
          frame = new_frame(:method, parent_frame, node)
          with_frame(node, frame) do
            declare_parameters(node.params, frame_kind: :parameter)
            visit_child_scopes(node.bodystmt)
          end
        when ClassDeclaration, ModuleDeclaration, SClass
          frame = new_frame(:isolated, parent_frame, node)
          with_frame(node, frame) do
            visit_child_scopes(node.bodystmt)
          end
        when Lambda
          frame = new_frame(:lambda, parent_frame, node)
          with_frame(node, frame) do
            declare_parameters(node.params, frame_kind: :parameter)
            visit_child_scopes(node.statements)
          end
        when BlockNode
          kind = proc_block?(node) ? :proc : :block
          frame = new_frame(kind, parent_frame, node)
          with_frame(node, frame) do
            if node.block_var
              declare_parameters(node.block_var.params, frame_kind: :parameter)
              node.block_var.locals.each do |identifier|
                declare_forced(identifier, :block_local, node)
              end
            end
            visit_child_scopes(node.bodystmt)
          end
        when Rescue
          frame = new_frame(:rescue, parent_frame, node)
          with_frame(node, frame) do
            exception = node.exception&.variable
            if exception.is_a?(VarField) && exception.value.is_a?(Ident)
              declare_forced(exception.value, :rescue_variable, node)
            end
            visit_child_scopes(node.statements)
            visit_scope(node.consequent, current_frame) if node.consequent
          end
        when For
          visit_child_scopes(node.collection)
          declare_for_target(node.index, :for_variable, node)
          visit_child_scopes(node.statements)
        else
          visit_child_scopes(node)
        end
      end

      def visit_child_scopes(node)
        return unless node

        node.child_nodes.each do |child|
          case child
          when DefNode, ClassDeclaration, ModuleDeclaration, SClass, Lambda,
               BlockNode, Rescue, For
            visit_scope(child, current_frame)
          else
            visit_child_scopes(child)
            record_variables(child)
          end
        end
      end

      def record_variables(node)
        case node
        when VarRef, VCall
          identifier = node.value
          return unless identifier.is_a?(Ident)
          record_event(identifier, :read)
        when VarField
          identifier = node.value
          return unless identifier.is_a?(Ident)
          return if forced_location?(identifier)

          record_event(identifier, :write)
        when OpAssign
          target = node.target
          if target.is_a?(VarField) && target.value.is_a?(Ident)
            record_event(target.value, :read)
          end
        end
      end

      def new_frame(kind, parent, node)
        frame = {
          kind: kind,
          parent: parent,
          node: node,
          forced: {},
          raws: []
        }
        frames_by_node[node] = frame
        frame
      end

      def with_frame(node, frame)
        frames.push(frame)
        yield
      ensure
        frames.pop
      end

      def current_frame
        frames.last
      end

      def declare_parameters(params, frame_kind:)
        return unless params
        params = params.contents if params.is_a?(Paren)
        return unless params.is_a?(Params)

        params.requireds.each { |param| declare_parameter(param, frame_kind) }
        params.posts.each { |param| declare_parameter(param, frame_kind) }
        params.optionals.each do |name, _default|
          declare_forced(name, frame_kind, current_frame[:node])
        end
        params.keywords.each do |name, _default|
          declare_forced(name, frame_kind, current_frame[:node])
        end

        rest = params.rest
        if rest.is_a?(RestParam) && rest.name
          declare_forced(rest.name, frame_kind, current_frame[:node])
        end
        block = params.block
        declare_forced(block.name, :block_parameter, current_frame[:node]) if block&.name
      end

      def declare_parameter(param, frame_kind)
        case param
        when Ident
          declare_forced(param, frame_kind, current_frame[:node])
        when MLHSParen
          each_identifier(param) do |identifier|
            declare_forced(identifier, frame_kind, current_frame[:node])
          end
        when ArgStar
          declare_forced(param.name, frame_kind, current_frame[:node]) if param.name
        end
      end

      def declare_for_target(target, kind, node)
        case target
        when VarField
          declare_forced(target.value, kind, node) if target.value.is_a?(Ident)
        when MLHS, MLHSParen
          each_identifier(target) { |identifier| declare_forced(identifier, kind, node) }
        end
      end

      def declare_forced(identifier, kind, owner_node)
        frame = frame_for_node(owner_node)
        frame[:forced][identifier.value] = {
          kind: kind,
          location: identifier.location
        }
      end

      def frame_for_node(node)
        frames_by_node.fetch(node)
      end

      def forced_location?(identifier)
        current_frame && current_frame[:forced].key?(identifier.value) &&
          current_frame[:forced][identifier.value][:location] == identifier.location
      end

      def each_identifier(node, &block)
        return enum_for(:each_identifier, node) unless block
        each_node(node) { |child| yield(child) if child.is_a?(Ident) }
      end

      def record_event(identifier, kind)
        frame = current_frame
        frame = resolve_event_frame(identifier, kind, frame) unless
          forced_location?(identifier)
        event = {
          name: identifier.value,
          kind: kind,
          location: identifier.location,
          frame: frame
        }
        @events << event
        frame[:raws] << event if frame && kind == :write
        event
      end

      def resolve_event_frame(identifier, kind, frame)
        return frame unless frame

        name = identifier.value
        search = frame
        while search
          case search[:kind]
          when :method, :lambda, :isolated
            return search if known_local?(search, name, identifier)
            return search if kind == :write && search[:kind] == :method && search == frame
          when :block, :proc
            return search if known_local?(search, name, identifier)
            return search if kind == :write && search == frame
          when :rescue
            # Rescue variables are tracked as forced locals; ordinary locals
            # continue to resolve through the surrounding scope.
          end
          search = search[:parent]
        end
        frame
      end

      def known_local?(frame, name, identifier)
        return true if frame[:forced].key?(name)
        frame[:raws].any? do |event|
          event[:name] == name &&
            event[:location].start_char < identifier.location.start_char
        end
      end

      def ancestor_frame?(frame, candidate)
        current = frame
        while current
          return true if current == candidate
          current = current[:parent]
        end
        false
      end

      def proc_block?(block_node)
        method_add_block = parents[block_node]
        return false unless method_add_block.is_a?(MethodAddBlock)
        method_name_for_call(method_add_block.call) == "proc" ||
          method_name_for_call(method_add_block.call) == "lambda" ||
          method_name_for_call(method_add_block.call) == "Proc.new"
      end

      def method_name_for_call(call)
        case call
        when CallNode
          if call.receiver.nil? && call.message.is_a?(Ident)
            call.message.value
          elsif call.receiver&.is_a?(VarRef) && call.receiver.value.is_a?(Const) &&
                  call.message.is_a?(Ident)
            "#{call.receiver.value.value}.#{call.message.value}"
          end
        end
      end

      def region_start_char
        first_statement.location.start_char
      end

      def region_boundary_char
        last_statement.location.end_char
      end

      def replacement_end_char
        char = last_statement.location.end_char
        char -= 1 while char > first_statement.location.start_char && source[char - 1] == "\n"
        char
      end

      def inside_region?(location)
        location.start_char >= region_start_char &&
          location.start_char <= region_boundary_char
      end

      def before_region?(location)
        location.start_char < region_start_char
      end

      def after_region?(location)
        location.start_char > region_boundary_char
      end

      def external_frame?(frame)
        frame && frame != root_frame && ancestor_frame?(root_frame, frame)
      end

      def lexical_event?(event)
        event[:frame] == root_frame || external_frame?(event[:frame])
      end

      def determine_parameters
        reads = events.select do |event|
          event[:kind] == :read && inside_region?(event[:location]) && lexical_event?(event)
        end

        names = {}
        reads.each do |event|
          name = event[:name]
          next if names.key?(name)
          next if written_before_read_in_owner?(event)
          next unless defined_before_region?(event)
          forced = event[:frame][:forced][name]
          if forced && frame_is_root_block?(event[:frame])
            next if before_region?(forced[:location]) == false
          end
          names[name] = variable_for_event(event)
        end

        if passes_block?
          parameter = enclosing_def.params
          parameter = parameter.contents if parameter.is_a?(Paren)
          block = parameter&.block
          if block&.name
            names[block.name.value] ||= Variable.new(
              name: block.name.value,
              kind: :block_parameter,
              location: block.name.location
            )
          end
        end

        values = names.values.sort_by { |variable| [variable.location.start_char, variable.name] }
        block_parameters, regular_parameters =
          values.partition { |variable| variable.kind == :block_parameter }
        regular_parameters + block_parameters
      end

      def frame_is_root_block?(frame)
        frame == root_frame && frame[:kind] == :block
      end

      def written_before_read_in_owner?(read_event)
        events.any? do |event|
          event[:kind] == :write && event[:frame] == read_event[:frame] &&
            event[:name] == read_event[:name] &&
            event[:location].start_char < read_event[:location].start_char &&
            inside_region?(event[:location])
        end
      end

      def defined_before_region?(event)
        frame = event[:frame]
        name = event[:name]
        forced = frame[:forced][name]
        if forced
          return true if frame[:kind] == :method
          return before_region?(forced[:location]) if frame == root_frame
          return true if external_frame?(frame)
        end

        frame[:raws].any? do |write|
          write[:name] == name && before_region?(write[:location])
        end
      end

      def variable_for_event(event)
        forced = event[:frame][:forced][event[:name]]
        kind = forced ? forced[:kind] : :local
        location = forced ? forced[:location] : event[:location]
        Variable.new(name: event[:name], kind: kind, location: location)
      end

      def determine_return_values
        result =
          Variable.new(
            name: RESULT_VARIABLE,
            kind: :result,
            location: first_statement.location
          )
        lexical_end = lexical_frame_end
        post_region_reads = events.select do |occurrence|
            occurrence[:kind] == :read &&
            occurrence[:location].start_char > region_boundary_char &&
            occurrence[:location].end_char <= lexical_end &&
            occurrence[:frame] == root_frame
        end.map { |occurrence| occurrence[:name] }.uniq

        writes = events.select do |event|
          event[:kind] == :write && inside_region?(event[:location]) &&
            lexical_event?(event) && post_region_reads.include?(event[:name])
        end

        values = {}
        writes.each do |event|
          values[event[:name]] ||= variable_for_event(event)
        end

        ordered = values.values.sort_by do |variable|
          [variable.location.start_char, variable.name]
        end
        [result, *ordered]
      end


      def lexical_frame_end
        case root_frame[:node]
        when BlockNode
          post_frame_statement_end(root_frame[:node])
        when Lambda
          post_frame_statement_end(root_frame[:node])
        when DefNode
          frame_statement_end(root_frame[:node])
        else
          root_frame[:node].location.end_char
        end
      end

      def statements_for_frame(node)
        body = node.is_a?(BlockNode) || node.is_a?(DefNode) ? node.bodystmt : node.statements
        body.is_a?(BodyStmt) ? body.statements : body
      end

      def frame_statement_end(node)
        statements = statements_for_frame(node)
        executable = executable_statements(statements)
        executable.empty? ? statements.location.end_char : executable.last.location.end_char
      end

      def post_frame_statement_end(node)
        statements = statements_for_frame(node)
        after = executable_statements(statements).drop_while do |statement|
          statement.location.end_char <= region_boundary_char
        end
        after.empty? ? region_boundary_char : frame_statement_end(node)
      end

      def passes_block?
        each_selected_node do |node|
          return true if node.is_a?(YieldNode)
        end
        false
      end

      def each_selected_node
        return enum_for(:each_selected_node) unless block_given?
        selected_statements.each { |statement| each_node(statement) { |node| yield(node) } }
      end

      def control_flow_issues
        issues = []
        each_selected_node do |node|
          next if nested_definition_or_lambda?(node)
          case node
          when ReturnNode
            unless return_contained?(node)
              issues << issue(
                :return,
                "return targets a method outside the selected region",
                node.location
              )
            end
          when Break
            unless flow_target_contained?(node)
              issues << issue(
                :break,
                "break escapes the selected region",
                node.location
              )
            end
          when Next
            unless flow_target_contained?(node)
              issues << issue(
                :next,
                "next escapes the selected region",
                node.location
              )
            end
          when Redo
            unless flow_target_contained?(node)
              issues << issue(
                :redo,
                "redo escapes the selected region",
                node.location
              )
            end
          when Retry
            rescue_node = lexical_ancestor(node, Rescue)
            unless rescue_node && within_selected_statement?(rescue_node)
              issues << issue(
                :retry,
                "retry targets a rescue clause outside the selected region",
                node.location
              )
            end
          when YieldNode
            issues << issue(
              :yield,
              "implicit block yield requires an explicit block parameter",
              node.location
            )
          when Super, ZSuper
            issues << issue(
              :super,
              "super cannot be moved because it depends on the receiver method",
              node.location
            )
          end
        end
        issues
      end

      def return_contained?(node)
        target = lexical_ancestors(node).find do |ancestor|
          case ancestor
          when DefNode, Lambda
            true
          end
        end

        (target.is_a?(DefNode) || target.is_a?(Lambda)) &&
          within_selected_statement?(target)
      end

      def flow_target_contained?(node)
        target = lexical_ancestors(node).find do |ancestor|
          case ancestor
          when *LOOP_NODES
            true
          when BlockNode, DefNode, Lambda
            true
          end
        end

        case target
        when nil, DefNode
          false
        when Lambda
          within_selected_statement?(target)
        when BlockNode
          if block_kind(target) == :proc
            false
          else
            within_selected_statement?(method_call_for_block(target))
          end
        else
          within_selected_statement?(target)
        end
      end

      def block_kind(block_node)
        frame = frames_by_node[block_node]
        frame ? frame[:kind] : :block
      end

      def method_call_for_block(block_node)
        node = parents[block_node]
        node.is_a?(MethodAddBlock) ? node : block_node
      end

      def within_selected_statement?(node)
        selected_statements.any? do |statement|
          node.location.start_char >= statement.location.start_char &&
            node.location.end_char <= statement.location.end_char
        end
      end

      def issue(type, message, location)
        Issue.new(
          type: type,
          message: message,
          location: {
            start_line: location.start_line,
            start_column: location.start_column,
            end_line: location.end_line,
            end_column: location.end_column
          }
        )
      end

      def existing_closure_issues
        first_class_closures_before_region.flat_map do |closure|
          names = captured_external_names(closure)
          next [] if (names & moved_variable_names).empty?

          [
            issue(
              :closure_capture,
              "existing closure captures #{names.to_a.join(", ")} " \
                "and may be called during extraction",
              closure.location
            )
          ]
        end
      end

      def created_closure_issues
        created_first_class_closures.flat_map do |closure|
          next [] unless closure_escapes?(closure)
          names = captured_external_names(closure)
          next [] if names.empty?

          [
            issue(
              :closure_capture,
              "escaping closure captures #{names.to_a.join(", ")}",
              closure.location
            )
          ]
        end
      end

      def ordinary_block_issues
        issues = []
        each_selected_node do |node|
          next unless node.is_a?(BlockNode)
          next if first_class_block?(node)
          next if nested_definition_or_lambda?(node)
          call = parents[node]
          next unless call.is_a?(MethodAddBlock)
          name = method_name_for_call(call.call)
          next if name && IMMEDIATE_BLOCK_METHODS.include?(name)
          next if captured_external_names(node).empty?

          issues << issue(
            :closure_capture,
            "block passed to #{name || "an unknown method"} captures local state and may escape",
            node.location
          )
        end
        issues
      end

      def first_class_closures_before_region
        closures = []
        walk_excluding_nested_definitions(enclosing_def) do |node|
          next unless before_region?(node.location)
          closures << node if node.is_a?(Lambda) || first_class_block?(node)
        end
        closures
      end

      def created_first_class_closures
        closures = []
        each_selected_node do |node|
          closures << node if node.is_a?(Lambda) || first_class_block?(node)
        end
        closures
      end

      def nested_definition_or_lambda?(node)
        target =
          lexical_ancestors(node).find do |ancestor|
            ancestor.is_a?(DefNode) || ancestor.is_a?(Lambda)
          end
        target && target != enclosing_def
      end

      def walk_excluding_nested_definitions(node)
        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless current
          if current != node &&
               (current.is_a?(DefNode) || current.is_a?(Lambda))
            next
          end
          yield(current)
          stack.concat(current.child_nodes)
        end
      end

      def first_class_block?(node)
        node.is_a?(BlockNode) && proc_block?(node)
      end

      def captured_external_names(closure)
        closure_frame = frames_by_node[closure]
        names = []
        walk_closure(closure) do |node|
          identifier = case node
          when VarRef, VCall
            node.value if node.value.is_a?(Ident)
          end
          next unless identifier
          event = event_for_identifier(identifier)
          next unless event
          next unless external_frame?(event[:frame]) || event[:frame] == root_frame
          next if event[:frame] == closure_frame
          names << event[:name]
        end
        names.uniq
      end

      def walk_closure(node)
        stack = [node]
        until stack.empty?
          current = stack.pop
          next unless current
          yield(current)
          next if current != node && (current.is_a?(DefNode) || current.is_a?(Lambda))
          stack.concat(current.child_nodes)
        end
      end

      def event_for_identifier(identifier)
        events.find { |event| event[:location] == identifier.location }
      end

      def moved_variable_names
        (determine_parameters.map(&:name) + determine_return_values.drop(1).map(&:name)).uniq
      end

      def closure_escapes?(closure)
        parent = parents[closure]
        return true if parent.is_a?(ArgBlock)
        return true if parent.is_a?(ReturnNode) || parent.is_a?(Args)

        case parent
        when Assign, MAssign
          target_name = assignment_target_name(parent.target)
          outputs = determine_return_values.drop(1).map(&:name)
          return true if target_name && outputs.include?(target_name)
        when CallNode
          return parent.message.is_a?(Ident) && parent.message.value == "call"
        when MethodAddBlock
          return ESCAPING_BLOCK_METHODS.include?(method_name_for_call(parent.call))
        end

        true
      end

      def assignment_target_name(target)
        case target
        when VarField
          target.value.value if target.value.is_a?(Ident)
        when MLHS, MLHSParen
          first = target.parts.find { |part| part.is_a?(VarField) || part.is_a?(Ident) }
          first.is_a?(VarField) ? first.value.value : first&.value
        end
      end

      def build_replacement(plan)
        call = "#{plan.method_name}(#{argument_names(plan.parameters).join(", ")})"
        indent = source_indent(first_statement.location.start_char)
        outputs = plan.return_values.drop(1)

        if outputs.empty?
          return "#{indent}#{call}\n"
        end

        names = [RESULT_VARIABLE, *outputs.map(&:name)].join(", ")
        "#{indent}#{names} = (\n" \
          "#{indent}  #{call}\n" \
          "#{indent})\n"
      end

      def argument_names(parameters)
        parameters.map do |parameter|
          if parameter.kind == :block_parameter
            "&#{parameter.name}"
          else
            parameter.name
          end
        end
      end

      def source_indent(char_position)
        line_start = source.rindex(/\n/, char_position - 1)&.+(1) || 0
        source[line_start...char_position].to_s[/\A[ \t]*/].to_s
      end

      def replace_selected_source(replacement)
        before = source[0...line_start_for_char(first_statement.location.start_char)].to_s
        after = source[replacement_end_char..].to_s
        result = "#{before}#{replacement}#{after}"
        SyntaxTree.parse(result)
        result
      rescue Parser::ParseError
        raise InvalidExtraction, "generated replacement was syntactically invalid"
      end

      def line_start_for_char(char_position)
        source.rindex(/\n/, char_position - 1)&.+(1) || 0
      end


      def insert_extracted_method(current_source, plan, original_def_end)
        method_source = build_extracted_method(plan)
        insertion = original_def_end
        before = current_source[0...insertion].to_s
        after = current_source[insertion..].to_s
        result = "#{before}\n\n#{method_source}\n#{after}"
        SyntaxTree.parse(result)
        result
      rescue Parser::ParseError
        raise InvalidExtraction, "generated method was syntactically invalid"
      end

      def build_extracted_method(plan)
        indent = source_indent(enclosing_def.location.start_char)
        body_indent = "#{indent}  "
        content_indent = body_indent
        selected_start = line_start_for_char(first_statement.location.start_char)
        selected = source[selected_start...last_statement.location.end_char]
        selected = dedent_selected_source(selected, content_indent)
        parameters = argument_names(plan.parameters).join(", ")
        outputs = plan.return_values.drop(1).map(&:name)
        tuple = [RESULT_VARIABLE, *outputs].join(", ")

        "#{indent}def #{method_name}(#{parameters})\n" \
          "#{body_indent}#{RESULT_VARIABLE} = (\n" \
          "#{selected}\n#{body_indent})\n" \
          "#{body_indent}[#{tuple}]\n#{indent}end\n"
      end

      def dedent_selected_source(selected, body_indent)
        lines = selected.split("\n")
        indented = lines.reject { |line| line.strip.empty? }
        minimum = indented.map { |line| line[/\A[ \t]*/].length }.min || 0
        removal = minimum - body_indent.length
        removal = 0 if removal.negative?
        stripped = lines.map do |line|
          line.strip.empty? ? line.chomp : line[removal..].to_s.chomp
        end
        stripped.map { |line| line.empty? ? "" : "#{body_indent}#{line}" }.join("\n")
      end
    end
  end
end
