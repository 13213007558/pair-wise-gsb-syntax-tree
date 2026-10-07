# frozen_string_literal: true

module SyntaxTree
  class << self
    def extract_private_method(source, selection = nil, method_name = nil, **options)
      ExtractPrivateMethod.new(
        source,
        selection || (options[:start_char]..options[:end_char]),
        method_name || options[:name]
      ).call
    end
  end

  class ExtractPrivateMethod
    Rejection = Struct.new(:reason, :location, :details, keyword_init: true) do
      def rejected?
        true
      end

      def accepted?
        false
      end
    end

    Edit = Struct.new(:start_char, :end_char, :replacement, keyword_init: true)

    Plan = Struct.new(
      :source,
      :method_name,
      :target_method,
      :selection,
      :statements,
      :arguments,
      :returned_variables,
      :edits,
      :updated_source,
      keyword_init: true
    ) do
      def reason
        nil
      end

      def location
        nil
      end

      def rejected?
        false
      end

      def accepted?
        true
      end
    end

    Variable = Struct.new(
      :name,
      :kind,
      :node,
      :initialized,
      :keyword,
      keyword_init: true
    )

    FORBIDDEN_CONTROL = [ReturnNode, YieldNode, Break, Next, Redo, Retry].freeze
    FORBIDDEN_MESSAGES = %w[
      binding eval instance_eval module_eval class_eval instance_exec
      module_exec class_exec local_variables block_given? __method__
      __callee__ caller caller_locations set_trace_func trace_var untrace_var
    ].freeze

    def initialize(source, selection, method_name)
      @source = source
      @selection = selection
      @method_name = method_name
      @rejections = []
    end

    def call
      return reject("selection is required", selection_location) unless valid_selection?
      return reject("method name is required", selection_location) unless valid_method_name?

      locate
      return result unless accepted?

      validate_selection
      return result unless accepted?

      analyze
      return result unless accepted?

      build_plan
      result
    end

    private

    attr_reader :source, :selection, :method_name, :rejections

    def program
      @program ||= SyntaxTree.parse(source)
    end

    def valid_selection?
      selection.is_a?(Range) &&
        selection.begin.is_a?(Integer) &&
        selection.end.is_a?(Integer) &&
        selection.begin >= 0 &&
        selection.end <= source.length &&
        selection.begin <= selection.end
    end

    def valid_method_name?
      method_name.is_a?(String) &&
        method_name.match?(/\A[a-z_][a-zA-Z0-9_]*[!?]?\z/) &&
        !%w[end begin do if unless case when while until for def class module].include?(method_name)
    end

    def locate
      context = Locator.new(program, selection).call
      @rejections << context if context.is_a?(Rejection)
      @context = context unless context.is_a?(Rejection)
    end

    def validate_selection
      rejection = SafetyChecker.new(@context, selection).call
      @rejections << rejection if rejection
      return unless accepted?

      check_incomplete_nodes
    end

    def analyze
      @analysis = Analyzer.new(@context).call
      @rejections.concat(@analysis.rejections)
    end

    def build_plan
      plan = Builder.new(source, @context, @analysis, method_name).call
      if plan.is_a?(Rejection)
        @rejections << plan
      else
        @plan = plan
      end
    end

    def check_incomplete_nodes
      incomplete = []
      traverse(program) do |node|
        next if node.location.start_char == node.location.end_char
        next unless overlaps?(node)
        next unless !contains?(node) || incomplete_group?(node)
        next if node.is_a?(Comment) || punctuation?(node)
        next if @context && contains_selected_statement?(node)

        incomplete << node
      end
      return if incomplete.empty?

      node = incomplete.min_by { |candidate| candidate.location.end_char - candidate.location.start_char }
      reject(
        "selection does not contain complete syntax nodes",
        location_for(node),
        node_class: node.class.name
      )
    end

    def traverse(node, &block)
      return unless node.is_a?(Node)

      yield(node)
      node.child_nodes.each { |child| traverse(child, &block) }
    end

    def contains?(node)
      selection.begin <= node.location.start_char && node.location.end_char <= selection.end
    end

    def overlaps?(node)
      node.location.start_char < selection.end && selection.begin < node.location.end_char
    end

    def incomplete_group?(node)
      node.equal?(@context.statements_node) &&
        node.body.reject { |child| child.is_a?(VoidStmt) }.any? { |child| !contains?(child) }
    end

    def contains_selected_statement?(node)
      @context.statements.any? do |statement|
        node != statement &&
          node.location.start_char <= statement.location.start_char &&
          statement.location.end_char <= node.location.end_char
      end
    end

    def punctuation?(node)
      [
        LParen,
        RParen,
        LBracket,
        RBracket,
        LBrace,
        RBrace,
        Comma,
        Period,
        Op,
        Kw,
        LabelEnd
      ].any? { |type| node.is_a?(type) }
    end

    def location_for(node)
      {
        start_char: node.location.start_char,
        end_char: node.location.end_char,
        start_line: node.location.start_line,
        start_column: node.location.start_column,
        end_line: node.location.end_line,
        end_column: node.location.end_column
      }
    end

    def selection_location
      { start_char: selection.begin, end_char: selection.end }
    end

    def reject(reason, location, details = nil)
      @rejections << Rejection.new(reason: reason, location: location, details: details)
      nil
    end

    def accepted?
      @rejections.empty?
    end

    def result
      @plan || @rejections.first
    end

    class Locator
      def initialize(program, selection)
        @program = program
        @selection = selection
      end

      def call
        candidates = []
        walk(@program, []) do |node, parents|
          next unless node.is_a?(Statements)

          statements = node.body.reject { |child| child.is_a?(VoidStmt) }
          selected = statements.select { |statement| covered?(statement) }
          if selected.empty?
            selected = statements.select { |statement| intersects?(statement) }
          else
            next unless contiguous?(statements, selected)
          end
          next if selected.empty?

          definition = parents.reverse.find { |parent| parent.is_a?(DefNode) }
          next unless definition

          candidates << Context.new(
            definition: definition,
            statements_node: node,
            statements: selected,
            parents: parents,
            selection: @selection
          )
        end

        return missing_method if candidates.empty?

        candidates.min_by(&:depth)
      end

      private

      def covered?(node)
        @selection.begin <= node.location.start_char && node.location.end_char <= @selection.end
      end

      def intersects?(node)
        node.location.start_char < @selection.end && @selection.begin < node.location.end_char
      end

      def contiguous?(statements, selected)
        indexes = selected.map { |item| statements.index(item) }
        indexes == (indexes.min..indexes.max).to_a
      end

      def missing_method
        Rejection.new(
          reason: "selection must contain contiguous statements inside a method",
          location: { start_char: @selection.begin, end_char: @selection.end }
        )
      end

      def walk(node, parents, &block)
        return unless node.is_a?(Node)

        yield(node, parents)
        node.child_nodes.each { |child| walk(child, parents + [node], &block) }
      end
    end

    class Context
      attr_reader :definition, :statements_node, :statements, :parents, :selection

      def initialize(definition:, statements_node:, statements:, parents:, selection:)
        @definition = definition
        @statements_node = statements_node
        @statements = statements
        @parents = parents
        @selection = selection
      end

      def depth
        parents.count
      end

      def first
        statements.first
      end

      def last
        statements.last
      end

      def enclosing_container
        parents.reverse.find do |parent|
          [ClassDeclaration, ModuleDeclaration, SClass, Program].any? { |type| parent.is_a?(type) }
        end.compact
      end
    end

    class SafetyChecker
      def initialize(context, selection)
        @context = context
        @selection = selection
      end

      def call
        control_rejection || boundary_rejection || scope_rejection || call_rejection
      end

      private

      def control_rejection
        forbidden = nil
        each_selected_node do |node|
          if FORBIDDEN_CONTROL.any? { |type| node.is_a?(type) }
            forbidden = node
            break
          end
        end
        forbidden ? reject("selection changes the owner of control flow or yield", forbidden) : nil
      end

      def boundary_rejection
        boundary = nil
        traverse(@context.definition) do |node|
          next unless [Rescue, Ensure, RescueMod].any? { |type| node.is_a?(type) }
          next if fully_inside_selection?(node)
          next unless overlaps?(node)

          boundary = node
          break
        end
        boundary ? reject("selection crosses a rescue or ensure boundary", boundary) : nil
      end

      def scope_rejection
        forbidden = nil
        each_selected_node do |node|
          if [DefNode, ClassDeclaration, ModuleDeclaration, SClass].any? { |type| node.is_a?(type) }
            forbidden = node
            break
          end
        end
        forbidden ? reject("selection introduces a nested lexical scope", forbidden) : nil
      end

      def call_rejection
        unsafe = nil
        each_selected_node do |node|
          if unsafe_call?(node) ||
               [Super, ZSuper, XStringLiteral, BEGINBlock, ENDBlock].any? { |type| node.is_a?(type) }
            unsafe = node
            break
          end
        end
        unsafe ? reject("selection depends on scope that cannot be safely moved", unsafe) : nil
      end

      def unsafe_call?(node)
        message =
          case node
          when CallNode
            node.message.is_a?(Ident) ? node.message.value : nil
          when Command, CommandCall
            node.message.is_a?(Ident) ? node.message.value : nil
          when VCall
            node.value.is_a?(Ident) ? node.value.value : nil
          end
        message && FORBIDDEN_MESSAGES.include?(message)
      end

      def each_selected_node(&block)
        @context.statements.each { |statement| walk(statement, &block) }
      end

      def walk(node, &block)
        return unless node.is_a?(Node)

        yield(node)
        node.child_nodes.each { |child| walk(child, &block) }
      end

      def traverse(node, &block)
        return unless node.is_a?(Node)

        yield(node)
        node.child_nodes.each { |child| traverse(child, &block) }
      end

      def fully_inside_selection?(node)
        @selection.begin <= node.location.start_char && node.location.end_char <= @selection.end
      end

      def overlaps?(node)
        node.location.start_char < @selection.end && @selection.begin < node.location.end_char
      end

      def reject(reason, node)
        Rejection.new(
          reason: reason,
          location: {
            start_char: node.location.start_char,
            end_char: node.location.end_char,
            start_line: node.location.start_line,
            start_column: node.location.start_column,
            end_line: node.location.end_line,
            end_column: node.location.end_column
          },
          details: { node_class: node.class.name }
        )
      end
    end

    class Analyzer
      attr_reader :rejections

      def initialize(context)
        @context = context
        @rejections = []
        @frames = {}
        @events = []
        @inputs = []
        @outputs = []
        @write_nodes = {}
      end

      def call
        collect_declarations
        collect_events
        classify
        self
      end

      def inputs
        @inputs ||= []
      end

      def outputs
        @outputs ||= []
      end

      def write_nodes
        @write_nodes ||= {}
      end

      private

      def collect_declarations
        root_frame = frame(@context.definition, :method, nil)
        add_parameters(root_frame, @context.definition.params)

        walk_declarations(@context.definition.bodystmt, root_frame)
      end

      def collect_events
        @event_frame_nodes = [@context.definition]
        @event_frames = [@frames[@context.definition]]
        walk_events(@context.definition)
      end

      def walk_declarations(node, parent_frame)
        return unless node.is_a?(Node)

        case node
        when DefNode
          return if node.equal?(@context.definition)

          frame(node, :method, nil)
          add_parameters(frame(node, :method, nil), node.params)
          walk_declarations(node.bodystmt, frame(node, :method, nil))
        when ClassDeclaration, ModuleDeclaration, SClass
          return
        when MethodAddBlock
          walk_declarations(node.call, parent_frame)
          block_frame = frame(node.block, :block, parent_frame)
          add_block_variables(block_frame, node.block.block_var)
          walk_declarations(node.block.bodystmt, block_frame)
        when BlockNode
          block_frame = frame(node, :block, parent_frame)
          add_block_variables(block_frame, node.block_var)
          node.child_nodes.each { |child| walk_declarations(child, block_frame) }
        when For
          add_targets(node.index, parent_frame, node.location)
          node.child_nodes.each { |child| walk_declarations(child, parent_frame) }
        when Rescue
          rescue_frame = frame(node, :rescue, parent_frame)
          add_targets(node.exception&.variable, rescue_frame, node.location)
          walk_declarations(node.statements, rescue_frame)
          walk_declarations(node.consequent, parent_frame) if node.consequent
        when Assign
          add_assignment_target(node.target, parent_frame, node.location)
          walk_declarations(node.value, parent_frame)
        when OpAssign
          add_assignment_target(node.target, parent_frame, node.location)
          node.child_nodes.each { |child| walk_declarations(child, parent_frame) }
        when MAssign
          add_targets(node.target, parent_frame, node.location)
          walk_declarations(node.value, parent_frame)
        when AryPtn, HshPtn, FndPtn, In
          @rejections << reject("pattern-bound variables require unsupported data-flow analysis", node)
          node.child_nodes.each { |child| walk_declarations(child, parent_frame) }
        else
          node.child_nodes.each { |child| walk_declarations(child, parent_frame) }
        end
      end

      def walk_events(node)
        return unless node.is_a?(Node)

        case node
        when VarRef
          record_read(node.value, node) if node.value.is_a?(Ident)
        when VCall
          record_read(node.value, node) if node.value.is_a?(Ident)
        when PinnedVarRef
          record_read(node.value, node) if node.value.is_a?(Ident)
        when Assign
          record_write(node.target, node.target, node) if local_field?(node.target)
        when OpAssign
          record_read_field(node.target, node) if local_field?(node.target)
          record_write(node.target, node.target, node) if local_field?(node.target)
        when MAssign
          record_multi_writes(node.target, node)
        when Rescue
          walk_rescue_events(node)
          return
        end

        record_read_field(node.target, node.target) if node.is_a?(OpAssign) && local_field?(node.target)

        enter_event_scope(node)
        node.child_nodes.each { |child| walk_events(child) }
        leave_event_scope(node)
      end

      def walk_rescue_events(node)
        walk_events(node.keyword)
        walk_events(node.exception)
        enter_event_scope(node)
        walk_events(node.statements)
        leave_event_scope(node)
        walk_events(node.consequent) if node.consequent
      end

      def classify
        selected_reads = []
        selected_writes = []

        @events.each do |event|
          next unless inside_selection?(event[:node])

          selected_reads << event if event[:kind] == :read
          selected_writes << event if event[:kind] == :write
        end

        input_names = {}
        selected_reads.each do |event|
          declaration = declaration_for(event[:name], event[:frames])
          next unless declaration

          input_names[event[:name]] = declaration
        end

        selected_writes.each do |event|
          declaration = declaration_for(event[:name], event[:frames])
          next unless declaration
          next unless read_after?(event)

          add_output(event, declaration)
        end

        @outputs.each do |variable|
          input_names.delete(variable.name)
        end

        @inputs = input_names.values.map { |declaration| variable_for(declaration) }.uniq(&:name)
        check_dynamic_initialization
      end

      def check_dynamic_initialization
        @inputs.each do |variable|
          next if variable.initialized

          @rejections << Rejection.new(
            reason: "variable may not be initialized before the extracted call",
            location: variable.location,
            details: { variable: variable.name }
          )
        end
      end

      def add_output(event, declaration)
        return if @outputs.any? { |variable| variable.name == event[:name] }

        variable = variable_for(declaration)
        @outputs << variable
        @write_nodes[event[:name]] ||= []
        @write_nodes[event[:name]] << event[:assignment]
      end

      def read_after?(write_event)
        @events.any? do |event|
            event[:kind] == :read &&
            event[:name] == write_event[:name] &&
            event[:node].location.start_char > write_event[:node].location.start_char &&
            event[:node].location.start_char >= @context.last.location.end_char &&
            declaration_for(event[:name], event[:frames])&.dig(:frame)&.equal?(
              declaration_for(write_event[:name], write_event[:frames])&.dig(:frame)
            )
        end
      end

      def variable_for(declaration)
        frame = declaration[:frame]
        parameter = frame[:parameters][declaration[:name]]
        kind = parameter ? parameter[:kind] : :local
        keyword = parameter ? parameter[:keyword] : false
        initialized = initialized?(declaration)
        Variable.new(
          name: declaration[:name],
          kind: kind,
          node: declaration[:node],
          initialized: initialized,
          keyword: keyword
        )
      end

      def initialized?(declaration)
        frame = declaration[:frame]
        name = declaration[:name]
        return true if frame[:parameters].key?(name)
        return true if frame[:kind] == :rescue

        frame[:writes][name].any? do |node|
          location = node.is_a?(Node) ? node.location : node
          location.end_char <= @context.first.location.start_char
        end
      end

      def declaration_for(name, frames)
        frames.reverse_each do |frame|
          return frame[:declarations][name] if frame[:declarations].key?(name)
        end
        nil
      end

      def record_read(identifier, node)
        @events << {
          name: identifier.value,
          kind: :read,
          node: node,
          frames: @event_frames.dup
        }
      end

      def record_read_field(target, node)
        value = target.value
        return unless local_field_name(target)
        return unless value.is_a?(Ident)

        @events << {
          name: value.value,
          kind: :read,
          node: node,
          frames: @event_frames.dup
        }
      end

      def record_write(target, node, assignment)
        return unless target.is_a?(VarField)
        return unless local_field_name(target)

        @events << {
          name: local_field_name(target),
          kind: :write,
          node: node,
          assignment: assignment,
          frames: @event_frames.dup
        }
      end

      def record_multi_writes(target, assignment)
        each_local_target(target) do |field|
          @events << {
            name: local_field_name(field),
            kind: :write,
            node: field,
            assignment: assignment,
            frames: @event_frames.dup
          }
        end
      end

      def enter_event_scope(node)
        return if @event_frame_nodes.include?(node)

        frame = @frames[node]
        if frame
          @event_frame_nodes.push(node)
          @event_frames.push(frame)
        end
      end

      def leave_event_scope(node)
        if @frames.key?(node) && @event_frame_nodes.last.equal?(node)
          @event_frame_nodes.pop
          @event_frames.pop
        end
      end

      def local_field?(target)
        target.is_a?(VarField)
      end

      def local_identifier(target)
        value = target.value
        value.is_a?(Ident) ? value.value : value
      end

      def local_field_name(target)
        value = target.value
        if value.is_a?(Ident)
          value.value
        elsif value.is_a?(::String)
          value
        end
      end

      def local_identifier(target)
        value = target.value
        value.is_a?(Ident) ? value.value : value
      end

      def each_local_target(target, &block)
        case target
        when VarField
          yield(target)
        when MLHS
          target.parts.each { |part| each_local_target(part, &block) }
        when MLHSParen
          each_local_target(target.contents, &block)
        when ArgStar
          each_local_target(target.value, &block) if target.value
        end
      end

      def add_assignment_target(target, frame, node)
        return unless target.is_a?(VarField)

        add_declaration(identifier(target), frame, target)
      end

      def add_targets(target, frame, node)
        each_local_target(target) { |field| add_declaration(identifier(field), frame, field) }
      end

      def identifier(field)
        value = field.value
        value.is_a?(Ident) ? value.value : value
      end

      def add_declaration(identifier, frame, node)
        name = identifier.is_a?(Ident) ? identifier.value : identifier
        frame[:declarations][name] ||= {
          name: name,
          node: node,
          frame: frame
        }
        frame[:writes][name] << node
      end

      def add_parameters(frame, params)
        params = params.contents if params.is_a?(Paren)
        return unless params.is_a?(Params)

        params.requireds.each { |ident| add_parameter(ident, frame, :required, false) }
        params.posts.each { |ident| add_parameter(ident, frame, :required, false) }
        params.optionals.each { |ident, _| add_parameter(ident, frame, :optional, false) }
        params.keywords.each { |label, _| add_keyword_parameter(label, frame) }
        add_rest_parameter(params.rest, frame)
        add_keyword_rest_parameter(params.keyword_rest, frame)
        add_block_parameter(params.block, frame)
      end

      def add_parameter(identifier, frame, kind, keyword)
        return unless identifier.is_a?(Ident)

        frame[:parameters][identifier.value] = { kind: kind, keyword: keyword }
        add_declaration(identifier, frame, identifier)
      end

      def add_keyword_parameter(label, frame)
        name = label.value.delete_suffix(":")
        identifier = Ident.new(
          value: name,
          location: label.location
        )
        frame[:parameters][name] = { kind: :required, keyword: true }
        add_declaration(identifier, frame, label)
      end

      def add_rest_parameter(rest, frame)
        return unless rest.is_a?(RestParam) && rest.name

        frame[:parameters][rest.name.value] = { kind: :rest, keyword: false }
        add_declaration(rest.name, frame, rest)
      end

      def add_keyword_rest_parameter(rest, frame)
        return unless rest.is_a?(KwRestParam) && rest.name

        frame[:parameters][rest.name.value] = { kind: :keyword_rest, keyword: false }
        add_declaration(rest.name, frame, rest)
      end

      def add_block_parameter(block_arg, frame)
        return unless block_arg.is_a?(BlockArg) && block_arg.name

        frame[:parameters][block_arg.name.value] = { kind: :block, keyword: false }
        add_declaration(block_arg.name, frame, block_arg)
      end

      def add_block_variables(frame, block_var)
        return unless block_var

        add_parameters(frame, block_var.params)
        block_var.locals.each do |identifier|
          add_declaration(identifier, frame, identifier)
        end
      end

      def frame(node, kind, parent)
        @frames[node] ||= {
          kind: kind,
          parent: parent,
          declarations: {},
          writes: Hash.new { |hash, key| hash[key] = [] },
          parameters: {}
        }
      end

      def inside_selection?(node)
        @context.selection.begin <= node.location.start_char &&
          node.location.end_char <= @context.selection.end
      end

      def reject(reason, node)
        Rejection.new(
          reason: reason,
          location: {
            start_char: node.location.start_char,
            end_char: node.location.end_char
          },
          details: { node_class: node.class.name }
        )
      end
    end

    class Builder
      def initialize(source, context, analysis, method_name)
        @source = source
        @context = context
        @analysis = analysis
        @method_name = method_name
        @rejections = []
        @temporary_index = 0
      end

      def call
        validate_target
        return @rejections.first unless @rejections.empty?

        edits = [insertion_edit, replacement_edit].sort_by(&:start_char).reverse
        updated = apply_edits(edits)
        SyntaxTree.parse(updated)

        Plan.new(
          source: source,
          method_name: method_name,
          target_method: context.definition.name.value,
          selection: context.selection,
          statements: context.statements.map { |node| source_text(node) },
          arguments: analysis.inputs.map(&:name),
          returned_variables: analysis.outputs.map(&:name),
          edits: edits,
          updated_source: updated
        )
      rescue Parser::ParseError => error
        Rejection.new(
          reason: "generated source is invalid Ruby",
          location: { start_char: context.selection.begin, end_char: context.selection.end },
          details: { parser_error: error.message, generated_source: updated }
        )
      end

      private

      attr_reader :source, :context, :analysis, :method_name

      def validate_target
        target = context.definition.target
        return if target.nil? || self_target?(target) || constant_target?(target)

        @rejections << Rejection.new(
          reason: "cannot place a private helper on a dynamic singleton receiver",
          location: location_for(target),
          details: { target_class: target.class.name }
        )
      end

      def self_target?(target)
        target.is_a?(VarRef) && target.value.is_a?(Kw) && target.value.value == "self"
      end

      def constant_target?(target)
        (target.is_a?(VarRef) && target.value.is_a?(Const)) ||
          [ConstPathRef, TopConstRef].any? { |type| target.is_a?(type) }
      end

      def replacement_edit
        end_char = context.last.location.end_char
        end_char += 1 if source[end_char] == "\n"
        Edit.new(
          start_char: context.first.location.start_char,
          end_char: end_char,
          replacement: call_source
        )
      end

      def insertion_edit
        Edit.new(start_char: insertion_location, end_char: insertion_location, replacement: helper_insertion)
      end

      def call_source
        indent = ""
        call = "__send__(:#{method_name}"
        args = argument_values
        call += ", #{args.join(", ")}" unless args.empty?
        call += keyword_arguments
        call += ", #{block_argument}" if block_argument
        call += ")"
        return "#{indent}#{call}\n" if analysis.outputs.empty?

        "#{result_variable} = #{call}\n#{assignment_source(base_indent)}"
      end

      def argument_values
        ordered_positional_arguments.concat(ordered_keyword_arguments).map do |variable|
          if variable.kind == :block
            next
          elsif variable.kind == :keyword_rest
            "**#{variable.name}"
          elsif variable.keyword
            "#{variable.name}: #{variable.name}"
          else
            variable.name
          end
        end.compact
      end

      def keyword_arguments
        uninitialized = analysis.outputs.reject(&:initialized)
        return "" if uninitialized.empty?

        ", " + uninitialized.map { |variable| "#{variable.name}: nil" }.join(", ")
      end

      def block_argument
        variable = analysis.inputs.find { |item| item.kind == :block }
        variable ? "&#{variable.name}" : nil
      end

      def assignment_source(indent)
        lines = analysis.outputs.each_with_index.map do |variable, index|
          value = analysis.outputs.one? ? "#{result_variable}[0]" : "#{result_variable}[0][#{index}]"
          "#{indent}#{variable.name} = #{result_variable}[1][#{variable.name.to_sym.inspect}] ? " \
            "#{value} : #{variable.name}\n"
        end
        lines.join + "#{indent}#{result_variable}[0]\n"
      end

      def helper_insertion
        definition = helper_definition(insertion_indent)
        "\n#{definition}\n"
      end

      def helper_definition(indent)
        body = helper_body(indent + "  ")
        if context.definition.target
          "#{indent}class << #{target_source}\n#{indent}  private def #{method_name}(#{parameter_list})\n#{body}\n#{indent}  end\n#{indent}end"
        else
          "#{indent}private def #{method_name}(#{parameter_list})\n#{body}\n#{indent}end"
        end
      end

      def target_source
        target = context.definition.target
        source[target.location.start_char...target.location.end_char]
      end

      def helper_body(indent)
        selected = transformed_selection(indent)
        return selected if analysis.outputs.empty?

        status = analysis.outputs.map do |variable|
          "#{indent}#{status_variable}[#{variable.name.to_sym.inspect}] = false"
        end.join("\n")
        "#{indent}#{status_variable} = {}\n#{status}\n" \
          "#{indent}#{result_variable} = begin\n#{selected}\n#{indent}end\n" \
          "#{indent}[#{result_variable}, #{status_variable}]"
      end

      def transformed_selection(indent)
        selected_source = source[context.first.location.start_char...context.last.location.end_char]
        adjusted = apply_relative_edits(selected_source, assignment_rewrites)
        reindent(adjusted, indent, 0, base_indent.length)
      end

      def assignment_rewrites
        base = context.first.location.start_char
        analysis.write_nodes.values.flatten.uniq.map do |node|
          next unless [Assign, OpAssign, MAssign].any? { |type| node.is_a?(type) }

          rewrite = rewrite_assignment(node)
          Edit.new(
            start_char: [node.location.start_char - base, 0].max,
            end_char: [node.location.end_char - base, 0].max,
            replacement: rewrite
          )
        end.compact.sort_by(&:start_char).reverse
      end

      def rewrite_assignment(node)
        case node
        when Assign
          rewrite_simple_assignment(node, "=", node.value)
        when OpAssign
          rewrite_simple_assignment(node, node.operator.value.delete_suffix("="), node.value)
        when MAssign
          rewrite_multi_assignment(node)
        end
      end

      def rewrite_simple_assignment(node, operator, value_node)
        value = source[value_node.location.start_char...value_node.location.end_char]
        temporary = unique(:__stree_value)
        name = local_target_name(node.target)
        expression = "(#{temporary} = #{value}; #{status_variable}[#{name.to_sym.inspect}] = true; #{temporary})"
        target = source[node.target.location.start_char...node.target.location.end_char]
        core = "(#{target} #{operator} #{expression})"
        modifier = modifier_source(node)
        modifier ? "(#{core} #{modifier})" : core
      end

      def rewrite_multi_assignment(node)
        value = source[node.value.location.start_char...node.value.location.end_char]
        temporary = unique(:__stree_values)
        marks = analysis.outputs.map do |variable|
          "#{status_variable}[#{variable.name.to_sym.inspect}] = true"
        end
        lhs = source[node.target.location.start_char...node.target.location.end_char]
        core = "(#{temporary} = #{value}; #{marks.join("; ")}; #{lhs} = #{temporary}; #{temporary})"
        modifier = modifier_source(node)
        modifier ? "(#{core} #{modifier})" : core
      end

      def local_target_name(target)
        target.value.is_a?(Ident) ? target.value.value : target.value
      end

      def modifier_source(node)
        value = node.value
        unless [IfNode, UnlessNode, WhileNode, UntilNode, RescueMod].any? { |type| value.is_a?(type) }
          return nil
        end

        keyword =
          if value.is_a?(RescueMod)
            "rescue"
          else
            value.class.name.split("::").last.sub("Node", "").downcase
          end
        predicate = value.is_a?(RescueMod) ? value.value : value.predicate
        "#{keyword} #{source[predicate.location.start_char...predicate.location.end_char]}"
      end

      def parameter_list
        parameters = ordered_positional_arguments.map { |variable| parameter_for(variable) }
        analysis.outputs.reject(&:initialized).each { |variable| parameters << "#{variable.name}: nil" }
        parameters.concat(ordered_keyword_arguments.map { |variable| parameter_for(variable) })
        block_input = analysis.inputs.find { |variable| variable.kind == :block }
        parameters << "&#{block_input.name}" if block_input
        parameters.join(", ")
      end

      def ordered_positional_arguments
        analysis.inputs.select do |variable|
          !variable.keyword && [:required, :optional, :rest].include?(variable.kind)
        end.sort_by { |variable| %i[required optional rest].index(variable.kind) }
      end

      def ordered_keyword_arguments
        analysis.inputs.select do |variable|
          variable.keyword || variable.kind == :keyword_rest
        end.sort_by { |variable| variable.kind == :keyword_rest ? 1 : 0 }
      end

      def parameter_for(variable)
        case variable.kind
        when :rest
          "*#{variable.name}"
        when :keyword_rest
          "**#{variable.name}"
        when :block
          "&#{variable.name}"
        else
          variable.keyword ? "#{variable.name}:" : variable.name
        end
      end

      def insertion_location
        location = context.definition.location.end_char
        source[location] == "\n" ? location + 1 : location
      end

      def insertion_indent
        " " * context.definition.location.start_column
      end

      def base_indent
        line = source.rindex(/\n/, context.first.location.start_char)
        line_start = line ? line + 1 : 0
        " " * (context.first.location.start_char - line_start)
      end

      def reindent(code, indent, detected_base = 0, preserved_base = 0)
        lines = code.lines(chomp: true)
        detected = detected_base ||
          (lines.reject(&:empty?).map { |line| line[/\A */].length }.min || 0)
        lines.each_with_index.map do |line, index|
          next "" if line.empty?

          current = line[/\A */].length
          relative = index.zero? ? 0 : [current - detected - preserved_base, 0].max
          "#{indent}#{' ' * relative}#{line.lstrip}"
        end.join("\n")
      end

      def apply_edits(edits)
        edits.sort_by(&:start_char).each_with_index.inject(source) do |current, (edit, index)|
          offset = edits.sort_by(&:start_char)[0...index].sum do |previous|
            previous.replacement.length - (previous.end_char - previous.start_char)
          end
          start_char = edit.start_char + offset
          end_char = edit.end_char + offset
          current[0...start_char] + edit.replacement + current[end_char..]
        end
      end

      def apply_relative_edits(code, edits)
        edits.reduce(code) do |current, edit|
          current[0...edit.start_char] + edit.replacement + current[edit.end_char..]
        end
      end

      def unique(prefix)
        @temporary_index += 1
        base = "#{prefix}_#{@temporary_index}"
        source.include?(base) ? "#{base}_" : base
      end

      def result_variable
        @result_variable ||= unique(:__stree_result)
      end

      def status_variable
        @status_variable ||= unique(:__stree_status)
      end

      def source_text(node)
        source[node.location.start_char...node.location.end_char]
      end

      def location_for(node)
        {
          start_char: node.location.start_char,
          end_char: node.location.end_char,
          start_line: node.location.start_line,
          start_column: node.location.start_column,
          end_line: node.location.end_line,
          end_column: node.location.end_column
        }
      end
    end
  end
end
