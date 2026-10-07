# frozen_string_literal: true

module SyntaxTree
  # Extract a consecutive run of statements from an instance method into a
  # private method on the same class or module.
  class ExtractMethod
    Selection = Struct.new(:start_char, :end_char, keyword_init: true)

    Change = Struct.new(:start_char, :end_char, :replacement, keyword_init: true)

    Variable = Struct.new(:name, :kind, keyword_init: true) do
      def input?
        kind == :input || kind == :inout
      end

      def output?
        kind == :output || kind == :inout
      end
    end

    Plan = Struct.new(
      :source,
      :method_name,
      :target_method,
      :selection,
      :variables,
      :changes,
      :new_source,
      keyword_init: true
    )

    Rejection = Struct.new(:reason, :message, :locations, keyword_init: true)

    def self.call(source:, selection:, method_name:)
      new(source, normalize_selection(selection), method_name).call
    end

    def self.normalize_selection(selection)
      case selection
      when Selection
        selection
      when Hash
        start_char = selection[:start_char] || selection["start_char"]
        end_char = selection[:end_char] || selection["end_char"]
        Selection.new(start_char: start_char, end_char: end_char)
      when Range
        Selection.new(
          start_char: selection.begin,
          end_char: selection.exclude_end? ? selection.end : selection.end + 1
        )
      else
        if selection.respond_to?(:start_char) && selection.respond_to?(:end_char)
          Selection.new(
            start_char: selection.start_char,
            end_char: selection.end_char
          )
        else
          Selection.new(start_char: nil, end_char: nil)
        end
      end
    end

    private_class_method :new

    def initialize(source, selection, method_name)
      @source = source
      @selection = selection
      @method_name = method_name.to_s
      @rejections = []
    end

    def call
      return reject_invalid_selection unless valid_selection?
      return parse_rejection unless (root = SyntaxTree.parse(@source))
      return method_name_rejection unless valid_method_name?

      @root = root
      @parents = build_parents(root)
      @selected_statements = find_selected_statements
      return @rejections.first unless @rejections.empty?
      return @rejections.first unless @selected_statements

      @target_method = nearest(@selected_statements.first, DefNode)
      validate_target!
      return @rejections.first unless @rejections.empty?

      validate_semantics!
      return @rejections.first unless @rejections.empty?

      analysis = analyze_variables
      variables = build_variables(analysis)
      plan = build_plan(variables, analysis)
      return @rejections.first unless @rejections.empty?

      plan
    end

    private

    def valid_selection?
      @selection.start_char.is_a?(Integer) &&
        @selection.end_char.is_a?(Integer) &&
        @selection.start_char >= 0 &&
        @selection.end_char > @selection.start_char &&
        @selection.end_char <= @source.length
    end

    def reject_invalid_selection
      reject(
        :invalid_selection,
        "Selection must be a non-empty character range inside the source.",
        [Location.default]
      )
    end

    def parse_rejection
      reject(:parse_error, "Source contains a syntax error.", [])
    end

    def valid_method_name?
      @method_name.match?(/\A[a-z_]\w*[!?=]?\z/) ||
        @method_name.match?(/\A[A-Z]\w*[!?]?\z/)
    end

    def method_name_rejection
      reject(
        :invalid_method_name,
        "#{@method_name.inspect} is not a valid private method name.",
        [Location.default]
      )
    end

    def build_parents(root)
      parents = {}
      walk(root) do |node, parent|
        parents[node] = parent
      end
      parents
    end

    def walk(node, parent = nil, &block)
      return unless node.is_a?(Node)

      yield(node, parent)
      node.child_nodes.compact.each { |child| walk(child, node, &block) }
    end

    def nearest(node, *classes, &block)
      matcher = block || proc { |current| classes.any? { |klass| current.is_a?(klass) } }
      current = node

      while current
        return current if matcher.call(current)

        current = @parents[current]
      end

      nil
    end

    def ancestors(node)
      ancestors = []
      current = @parents[node]

      while current
        ancestors << current
        current = @parents[current]
      end

      ancestors
    end

    def find_selected_statements
      all_statements = []
      walk(@root) do |node|
        next unless node.is_a?(Statements)

        statements = node.body.reject { |statement| statement.is_a?(VoidStmt) }
        next if statements.empty?

        indices = statements.each_index.select do |index|
          statement = statements[index]
          statement.start_char >= trimmed_start && statement.end_char <= trimmed_end
        end
        next unless indices.any?
        next unless indices == (indices.first..indices.last).to_a
        next unless statements[indices.first].start_char == trimmed_start
        next unless statements[indices.last].end_char == trimmed_end

        all_statements << {
          node: node,
          statements: statements[indices.first..indices.last],
          depth: ancestors(node).count
        }
      end

      candidates = all_statements

      if candidates.empty?
        rescue_boundary_rejection_for_selection
        return nil if @rejections.any? { |rejection| rejection.reason == :rescue_boundary }

        overlapping = overlapping_statement
        location = overlapping&.location || Location.default
        reject(
          :incomplete_syntax_selection,
          "Selection does not contain complete statements. A statement boundary starts or ends inside #{location_text(location)}.",
          [location]
        )
        return nil
      end

      return nil if candidates.empty?

      candidates.min_by { |candidate| candidate[:depth] }[:statements]
    end

    def overlapping_statement
      statement = nil
      walk(@root) do |node|
        next unless node.respond_to?(:location)
        next if [Statements, Program, BodyStmt].any? { |klass| node.is_a?(klass) }
        next unless overlaps_selection?(node)

        statement = node if statement.nil? || node.start_char >= statement.start_char
      end
      statement
    end

    def trimmed_start
      @trimmed_start ||= @source.index(/\S/, @selection.start_char) || @selection.start_char
    end

    def trimmed_end
      @trimmed_end ||= (@source.rindex(/\S/, @selection.end_char - 1) || @selection.end_char - 1) + 1
    end

    def overlaps_selection?(node)
      node.start_char < @selection.end_char && node.end_char > @selection.start_char
    end

    def location_text(location)
      "line #{location.start_line}, column #{location.start_column + 1}"
    end

    def candidate_range(statements)
      statements.first.location.to(statements.last.location)
    end

    def validate_target!
      unless @target_method
        reject(
          :outside_method,
          "Selection must be inside an instance method definition.",
          selected_locations
        )
        return
      end

      if @target_method.endless?
        reject(
          :endless_method,
          "Extraction from endless methods is not supported.",
          [@target_method.location]
        )
      end

      if @target_method.target
        reject(
          :singleton_method,
          "Only instance methods can be extracted to a private method on the same class.",
          [@target_method.target.location]
        )
      end

      if method_already_defined?
        reject(
          :method_already_defined,
          "A method named #{@method_name} is already defined in the enclosing scope.",
          [@target_method.location]
        )
      end

      validate_rescue_boundaries!
    end

    def method_already_defined?
      container = nearest(@target_method, ClassDeclaration, ModuleDeclaration, Program)
      defined = []
      walk(container) do |node|
        next unless node.is_a?(DefNode)
        next unless node.name.respond_to?(:value) && node.name.value == @method_name

        defined << node
      end
      defined.any?
    end

    def validate_rescue_boundaries!
      range = candidate_range(@selected_statements)

      walk(combined_selected_node) do |node|
        next unless node.is_a?(Rescue) || node.is_a?(Ensure)

        keyword = node.is_a?(Rescue) ? node.keyword : node.keyword
        next unless keyword.start_char >= range.start_char && keyword.end_char <= range.end_char

        enclosing = nearest(node, DefNode, Begin)
        next if enclosing && enclosing.start_char >= range.start_char && enclosing.end_char <= range.end_char

        reject(
          :rescue_boundary,
          "Selection crosses a #{node.is_a?(Rescue) ? "rescue" : "ensure"} boundary at #{location_text(keyword.location)}.",
          [keyword.location]
        )
      end
    end

    def rescue_boundary_rejection_for_selection
      walk(@root) do |node|
        next unless node.is_a?(Rescue) || node.is_a?(Ensure)

        keyword = node.keyword
        next unless keyword.start_char >= @selection.start_char && keyword.end_char <= @selection.end_char

        enclosing = nearest(keyword, Begin, DefNode)
        fully_selected =
          enclosing.is_a?(Begin) && enclosing.start_char >= @selection.start_char &&
            enclosing.end_char <= @selection.end_char
        next if fully_selected

        reject(
          :rescue_boundary,
          "Selection crosses a #{node.is_a?(Rescue) ? "rescue" : "ensure"} boundary at #{location_text(keyword.location)}.",
          [keyword.location]
        )
      end
    end

    def combined_selected_node
      @selected_statements.length == 1 ? @selected_statements.first : @parents[@selected_statements.first]
    end

    def validate_semantics!
      walk(combined_selected_node) do |node|
        case node
        when ReturnNode
          reject_control(node, "return")
        when Break
          reject_control(node, "break")
        when Next
          reject_control(node, "next")
        when Redo
          reject_control(node, "redo")
        when Retry
          reject_control(node, "retry")
        when YieldNode
          reject_control(node, "yield")
        when Super, ZSuper
          reject_control(node, "super")
        when DefNode
          reject(
            :nested_method_definition,
            "Selection contains a nested method definition at #{location_text(node.location)}.",
            [node.location]
          )
        when Command
          message = node.message.value
          reject_dynamic_dependency(message, node) if unsafe_message?(message)
        when VCall
          message = node.value.value
          reject_dynamic_dependency(message, node) if unsafe_message?(message)
        when CommandCall, CallNode
          message = node.message
          if message.respond_to?(:value) && unsafe_message?(message.value)
            implicit_unsafe = %w[binding eval].include?(message.value) && node.receiver.nil?
            qualified_unsafe = %w[instance_eval class_eval module_eval eval].include?(message.value)
            reject_dynamic_dependency(message.value, node) if implicit_unsafe || qualified_unsafe
          end
        end
      end
    end

    def reject_control(node, keyword)
      reject(
        :control_flow_ownership,
        "Selection moves the ownership of #{keyword} at #{location_text(node.location)}.",
        [node.location]
      )
    end

    def unsafe_message?(message)
      %w[binding eval instance_eval class_eval module_eval eval].include?(message.to_s)
    end

    def reject_dynamic_dependency(message, node)
      reject(
        :unsafe_dynamic_dependency,
        "Selection depends on #{message} at #{location_text(node.location)}, whose binding cannot be safely transferred.",
        [node.location]
      )
    end

    def analyze_variables
      first = @selected_statements.first
      container = @parents[first]
      index = container.body.index(first)
      prefix = container.body[0...index]
      parameter_names = method_parameter_names
      definite_before = DefiniteBeforeAnalyzer.analyze(prefix, parameter_names)

      fragment = Statements.new(
        body: @selected_statements,
        location: candidate_range(@selected_statements)
      )
      fragment_analysis = VariableAnalyzer.analyze(
        fragment,
        definite_before.each_with_object({}) { |name, states| states[name] = :outer }
      )

      live_after = live_variables(fragment_analysis.writes)
      {
        definite_before: definite_before,
        reads: fragment_analysis.reads,
        writes: fragment_analysis.writes,
        live_after: live_after
      }
    end

    def method_parameter_names
      params = @target_method.params
      params = params.contents if params.is_a?(Paren)
      return Set.new unless params.is_a?(Params)

      names = []
      params.requireds.each { |param| collect_parameter_names(param, names) }
      params.posts.each { |param| collect_parameter_names(param, names) }
      params.optionals.each { |name, _default| names << name.value }
      params.keywords.each { |name, _default| names << name.value.delete_suffix(":") }
      [params.rest, params.keyword_rest, params.block].each do |param|
        name = param.respond_to?(:name) ? param.name : nil
        names << name.value if name.is_a?(Ident)
      end
      names.to_set
    end

    def collect_parameter_names(param, names)
      case param
      when Ident
        names << param.value
      when MLHSParen
        param.contents.parts.each { |part| collect_parameter_names(part, names) }
      when ArgStar, RestParam
        names << param.name.value if param.name.is_a?(Ident)
      end
    end

    def live_variables(writes)
      return Set.new if writes.empty?

      region = continuation_region
      VariableAnalyzer.live(region, writes)
    end

    def continuation_region
      nodes = []
      node = @selected_statements.last

      while node
        statements = nearest(node, Statements)
        if statements
          index = statements.body.index(node)
          if index
            nodes.concat(statements.body[(index + 1)..].reject { |item| item.is_a?(VoidStmt) })
          end
          body = @parents[statements]
          if body.is_a?(BodyStmt)
            nodes << body.rescue_clause if body.rescue_clause
            nodes << body.else_clause if body.else_clause
            nodes << body.ensure_clause if body.ensure_clause
            node = @parents[body]
          else
            node = body
          end
        else
          node = @parents[node]
        end

        node = nil if node.is_a?(DefNode)
      end

      Statements.new(
        body: nodes,
        location: Location.default
      )
    end

    def build_variables(analysis)
      outputs = analysis[:writes].select { |name| analysis[:live_after].include?(name) }
      output_set = outputs.to_set
      external_reads =
        analysis[:reads].reject do |name|
          output_set.include?(name) || !analysis[:definite_before].include?(name)
        end

      inouts = external_reads.select { |name| output_set.include?(name) }
      inputs = external_reads - inouts

      [
        *inputs.map { |name| Variable.new(name: name, kind: :input) },
        *outputs.map do |name|
          kind = inouts.include?(name) ? :inout : :output
          Variable.new(name: name, kind: kind)
        end
      ]
    end

    def build_plan(variables, analysis)
      @selected_range = candidate_range(@selected_statements)
      range = @selected_range
      outputs = variables.select(&:output?)
      inputs = variables.select(&:input?)
      state_name = unique_name("__syntax_tree_extract_state")
      result_name = unique_name("__syntax_tree_extract_result")
      fragment = rewritten_fragment(range, outputs.map(&:name), state_name)
      call = build_call(inputs, outputs, state_name)
      replacement = build_replacement(call, outputs, state_name, result_name, range, analysis)
      helper = build_helper(fragment, range, variables, inputs, outputs, state_name)
      insertion = insertion_change(helper)
      call_change = Change.new(
        start_char: indentation_start(range.start_char),
        end_char: range.end_char,
        replacement: replacement
      )

      changes = [insertion, call_change].sort_by(&:start_char).reverse
      new_source = apply_changes(changes)

      begin
        SyntaxTree.parse(new_source)
      rescue Parser::ParseError => error
        reject(:generated_source_error, error.message, [range])
        return
      end

      Plan.new(
        source: @source,
        method_name: @method_name,
        target_method: @target_method,
        selection: Selection.new(
          start_char: indentation_start(range.start_char),
          end_char: range.end_char
        ),
        variables: variables,
        changes: changes.reverse,
        new_source: new_source
      )
    end

    def unique_name(prefix)
      [nil, *1..99].each do |suffix|
        name = suffix ? "#{prefix}_#{suffix}" : prefix
        return name unless @source.match?(/#{Regexp.escape(name)}(?!\w)/)
      end
    end

    def rewritten_fragment(range, outputs, state_name)
      source = @source[range.start_char...range.end_char].strip.dup
      replacements = []
      output_set = outputs.to_set
      rewriter = LocalReferenceRewriter.new(output_set, state_name)
      fragment_node =
        Statements.new(
          body: @selected_statements,
          location: range
        )

      rewriter.collect(fragment_node).each do |start_char, end_char, name|
        local_start = start_char - range.start_char
        local_end = end_char - range.start_char
        replacements << [local_start, local_end, "#{state_name}[#{name.to_sym.inspect}]"]
      end

      replacements.sort_by { |start_char, _end_char, _value| -start_char }.each do |start_char, end_char, value|
        source[start_char...end_char] = value
      end
      source
    end

    def build_call(inputs, outputs, state_name)
      arguments = inputs.map(&:name)
      if outputs.any?
        arguments << "#{state_name}: #{state_name}"
      end
      "#{@method_name}(#{arguments.join(", ")})"
    end

    def build_replacement(call, outputs, state_name, result_name, range, analysis)
      indent = indentation_at(range.start_char)

      if outputs.empty?
        return "#{indent}#{call}"
      end

      output_names = outputs.map(&:name)
      lines = [
        *initial_state_lines(outputs, state_name, indent, analysis),
        "#{indent}#{state_name} = { #{state_pairs(outputs).join(", ")} }"
      ]

      if tail_selection?
        lines << "#{indent}#{result_name} = begin"
        lines << "#{indent}  #{call}"
        lines << "#{indent}ensure"
        lines << "#{indent}  #{output_names.join(", ")} = #{state_values(output_names, state_name)}"
        lines << "#{indent}end"
        lines << "#{indent}#{result_name}"
      else
        lines << "#{indent}begin"
        lines << "#{indent}  #{call}"
        lines << "#{indent}ensure"
        lines << "#{indent}  #{output_names.join(", ")} = #{state_values(output_names, state_name)}"
        lines << "#{indent}end"
      end

      lines.join("\n")
    end

    def tail_selection?
      statements = @parents[@selected_statements.last]
      last = statements.body.reject { |node| node.is_a?(VoidStmt) }.last
      return false unless last.equal?(@selected_statements.last)

      !@parents[statements].is_a?(Ensure)
    end

    def state_values(names, state_name)
      names.map { |name| "#{state_name}[#{name.to_sym.inspect}]" }.join(", ")
    end

    def initial_state_lines(outputs, state_name, indent, analysis)
      outputs.reject { |variable| analysis[:definite_before].include?(variable.name) }.map do |variable|
        name = variable.name
        "#{indent}#{name} = defined?(#{name}) ? #{name} : nil"
      end
    end

    def state_pairs(outputs)
      outputs.map { |variable| "#{variable.name}: #{variable.name}" }
    end

    def build_helper(fragment, range, variables, inputs, outputs, state_name)
      indent = indentation_at(@target_method.start_char)
      body_indent = "#{indent}  "
      fragment = indent_fragment(fragment, range, body_indent)
      parameters = inputs.map(&:name)
      if outputs.any?
        parameters << "#{state_name}:"
      end

      lines = [
        "#{indent}private def #{@method_name}(#{parameters.join(", ")})",
        fragment
      ]

      lines << "#{indent}end"

      "\n\n" + lines.join("\n")
    end

    def indent_fragment(fragment, range, indent)
      base = range.start_column
      fragment.lines.map do |line|
        next line if line.match?(/\A[ \t]*(?:\n)?\z/)

        "#{indent}#{base.zero? ? line : line.sub(/\A[ \t]{#{base}}/, "")}"
      end.join
    end

    def indentation_at(char)
      line_start = @source.rindex("\n", char) || -1
      @source[(line_start + 1)...char].to_s[/\A[ \t]*/] || ""
    end

    def indentation_start(char)
      line_start = @source.rindex("\n", char) || -1
      line_start + 1
    end

    def insertion_change(helper)
      Change.new(
        start_char: @target_method.end_char,
        end_char: @target_method.end_char,
        replacement: helper
      )
    end

    def apply_changes(changes)
      result = @source.dup
      changes.each do |change|
        result[change.start_char...change.end_char] = change.replacement
      end
      result
    end

    class DefiniteBeforeAnalyzer
      def self.analyze(nodes, parameter_names)
      analyzer = new
      states = parameter_names.each_with_object({}) { |name, state| state[name] = :assigned }
      nodes.each { |node| states = analyzer.analyze(node, states) }
      states.select { |_name, state| state == :assigned }.keys.to_set
      end

      def analyze(node, states)
        case node
        when Assign
          states = analyze(node.value, states)
          assign_target(node.target, states)
        when OpAssign
          states = read_target(node.target, states)
          states = analyze(node.value, states)
          assign_target(node.target, states)
        when MAssign
          states = analyze(node.value, states)
          assign_targets(node.target, states)
        when RAssign
          states = analyze(node.value, states)
          states
        when IfNode, UnlessNode
          states = analyze(node.predicate, states)
          truthy = analyze(node.statements, states)
          falsy = branch_state(node.consequent, states)
          intersect(truthy, falsy)
        when Elsif
          states = analyze(node.predicate, states)
          intersect(analyze(node.statements, states), branch_state(node.consequent, states))
        when Else
          analyze(node.statements, states)
        when IfOp
          states = analyze(node.predicate, states)
          intersect(analyze(node.truthy, states), analyze(node.falsy, states))
        when Case
          states = analyze(node.value, states)
          analyze_case_branch(node.consequent, states)
        when When
          states = analyze(node.arguments, states)
          states = intersect(analyze(node.statements, states), states)
          analyze_case_branch(node.consequent, states).then { |other| intersect(states, other) }
        when In
          states = analyze_pattern(node.pattern, states)
          states = intersect(analyze(node.statements, states), states)
          other = node.consequent ? analyze(node.consequent, states) : states
          intersect(states, other)
        else
          analyze_children(node, states)
        end
      end

      private

      def branch_state(node, states)
        case node
        when nil
          states
        when Else
          analyze(node.statements, states)
        when Elsif
          analyze(node, states)
        else
          analyze(node, states)
        end
      end

      def analyze_case_branch(node, states)
        case node
        when When, In
          analyze(node, states)
        when Else
          analyze(node.statements, states)
        else
          states
        end
      end

      def intersect(left, right)
        (left.keys | right.keys).each_with_object({}) do |name, states|
          if left[name] == :assigned && right[name] == :assigned
            states[name] = :assigned
          end
        end
      end

      def assign_target(target, states)
        case target
        when VarField
          states[target.value.value] = :assigned if target.value.is_a?(Ident)
        when MLHS, MLHSParen
          assign_targets(target, states)
        end
        states
      end

      def assign_targets(target, states)
        parts = target.is_a?(MLHS) ? target.parts : target.contents.parts
        parts.each do |part|
          if part.is_a?(VarField) && part.value.is_a?(Ident)
            states[part.value.value] = :assigned
          elsif part.is_a?(MLHSParen)
            assign_targets(part, states)
          end
        end
        states
      end

      def read_target(target, states)
        if target.is_a?(VarField) && target.value.is_a?(Ident)
          states[target.value.value] ||= :uninitialized
        end
        states
      end

      def analyze_pattern(node, states)
        analyze_children(node, states)
      end

      def analyze_children(node, states)
        return states unless node.respond_to?(:child_nodes)

        node.child_nodes.compact.each { |child| states = analyze(child, states) }
        states
      end
    end

    def selected_locations
      @selected_statements.map(&:location)
    end

    def reject(reason, message, locations)
      @rejections << Rejection.new(
        reason: reason,
        message: message,
        locations: locations
      )
    end
  end

  class VariableAnalyzer
    Analysis = Struct.new(:states, :reads, :writes, keyword_init: true)

    def self.analyze(nodes, initial = {})
      analyzer = new
      states = initial.dup
      reads = Set.new
      writes = Set.new
      Array(nodes).each { |node| states = analyzer.analyze(node, states, reads, writes) }
      Analysis.new(states: states, reads: reads, writes: writes)
    end

    def self.live(nodes, candidates)
      analyzer = new
      states = candidates.each_with_object({}) { |name, state| state[name.to_s] = :live }
      reads = Set.new
      writes = Set.new
      Array(nodes).each { |node| analyzer.analyze(node, states, reads, writes) }
      reads.map(&:to_s).to_set & candidates.map(&:to_s).to_set
    end

    def analyze(node, states, reads = Set.new, writes = Set.new)
      case node
      when Array
        node.each { |child| states = analyze(child, states, reads, writes) }
        states
      when nil
        states
      when Statements
        node.body.each { |child| states = analyze(child, states, reads, writes) }
        states
      when Assign
        states = analyze(node.value, states, reads, writes)
        assign(node.target, states, writes)
      when OpAssign
        read_local_target(node.target, states, reads)
        states = analyze(node.value, states, reads, writes)
        assign(node.target, states, writes)
      when MAssign
        states = analyze(node.value, states, reads, writes)
        targets(node.target).each { |target| assign(target, states, writes) }
      when RAssign
        states = analyze(node.value, states, reads, writes)
        assign_pattern(node.pattern, states, writes)
        states
      when VarRef, PinnedVarRef
        read_ref(node, states, reads)
        states
      when IfNode, UnlessNode
        states = analyze(node.predicate, states, reads, writes)
        truthy = analyze(node.statements, states, reads, writes)
        falsy = branch(node.consequent, states, reads, writes)
        merge_branches(states, truthy, falsy)
      when Elsif
        states = analyze(node.predicate, states, reads, writes)
        truthy = analyze(node.statements, states, reads, writes)
        falsy = branch(node.consequent, states, reads, writes)
        merge_branches(states, truthy, falsy)
      when Else
        analyze(node.statements, states, reads, writes)
      when IfOp
        states = analyze(node.predicate, states, reads, writes)
        truthy = analyze(node.truthy, states, reads, writes)
        falsy = analyze(node.falsy, states, reads, writes)
        merge_branches(states, truthy, falsy)
      when Case
        states = analyze(node.value, states, reads, writes)
        branch(node.consequent, states, reads, writes)
      when When
        states = analyze(node.arguments, states, reads, writes)
        truthy = analyze(node.statements, states, reads, writes)
        falsy = branch(node.consequent, states, reads, writes)
        merge_branches(states, truthy, falsy)
      when In
        states = analyze_pattern(node.pattern, states, reads, writes)
        truthy = analyze(node.statements, states, reads, writes)
        falsy = branch(node.consequent, states, reads, writes)
        merge_branches(states, truthy, falsy)
      when WhileNode, UntilNode
        states = analyze(node.predicate, states, reads, writes)
        analyze(node.statements, states, reads, writes)
        states
      when For
        states = analyze(node.collection, states, reads, writes)
        assign(node.index, states, writes)
        analyze(node.statements, states, reads, writes)
        states
      when BodyStmt
        states = analyze(node.statements, states, reads, writes)
        states = analyze(node.rescue_clause, states, reads, writes) if node.rescue_clause
        states = analyze(node.else_clause, states, reads, writes) if node.else_clause
        states = analyze(node.ensure_clause, states, reads, writes) if node.ensure_clause
        states
      when Rescue
        states = analyze(node.exception, states, reads, writes) if node.exception
        states = analyze(node.statements, states, reads, writes)
        states = analyze(node.consequent, states, reads, writes) if node.consequent
        states
      when RescueEx
        states
      when RescueMod
        states = analyze(node.statement, states, reads, writes)
        other = analyze(node.value, states, reads, writes)
        merge_branches(states, states, other)
      when MethodAddBlock
        states = analyze(node.call, states, reads, writes)
        analyze(node.block, states, reads, writes)
        states
      when BlockNode
        analyze_block(node, states, reads, writes)
      when Lambda, DefNode
        states
      else
        analyze_children(node, states, reads, writes)
      end
    end

    private

    def branch(node, states, reads, writes)
      return states if node.nil?

      node.is_a?(Else) ? analyze(node.statements, states, reads, writes) : analyze(node, states, reads, writes)
    end

    def merge_branches(initial, truthy, falsy)
      (initial.keys | truthy.keys | falsy.keys).each_with_object({}) do |name, states|
        left = truthy[name] || initial[name]
        right = falsy[name] || initial[name]
        states[name] = left == right ? left : :conditional
      end
    end

    def read_ref(node, states, reads)
      value = node.value
      return unless value.is_a?(Ident)

      name = value.value.to_s
      if %i[outer live].include?(states[name])
        reads << name
      elsif states[name].nil?
        states[name] = :uninitialized
      end
    end

    def read_local_target(target, states, reads)
      return unless target.is_a?(VarField) && target.value.is_a?(Ident)

      name = target.value.value.to_s
      reads << name if states[name] == :outer
      states[name] ||= :uninitialized
    end

    def assign(target, states, writes)
      case target
      when VarField
        if target.value.is_a?(Ident)
          name = target.value.value.to_s
          writes << name
          states[name] = :assigned
        end
      when MLHS, MLHSParen
        targets(target).each { |part| assign(part, states, writes) }
      end
      states
    end

    def assign_pattern(pattern, states, writes)
      case pattern
      when Binary
        assign_pattern(pattern.left, states, writes)
        assign_pattern(pattern.right, states, writes)
      when AryPtn
        pattern.requireds.each { |node| assign_pattern(node, states, writes) }
        assign_pattern(pattern.rest, states, writes)
        pattern.posts.each { |node| assign_pattern(node, states, writes) }
      when HshPtn
        pattern.keywords.each do |key, value|
          if value
            assign_pattern(value, states, writes)
          else
            name = key.value.delete_suffix(":")
            writes << name
            states[name] = :assigned
          end
        end
        assign_pattern(pattern.keyword_rest, states, writes)
      when VarField
        assign(pattern, states, writes)
      end
    end

    def targets(target)
      parts = target.is_a?(MLHS) ? target.parts : target.contents.parts
      parts.flat_map { |part| part.is_a?(MLHSParen) ? targets(part) : [part] }
    end

    def analyze_pattern(node, states, reads, writes)
      case node
      when Binary
        states = analyze(node.left, states, reads, writes)
        assign(node.right, states, writes)
      when AryPtn
        states = analyze(node.constant, states, reads, writes)
        states = analyze(node.requireds, states, reads, writes)
        states = analyze(node.rest, states, reads, writes)
        analyze(node.posts, states, reads, writes)
      when HshPtn
        states = analyze(node.constant, states, reads, writes)
        node.keywords.each do |key, value|
          name = key.value.delete_suffix(":")
          if value
            states = analyze(value, states, reads, writes)
          else
            writes << name
            states[name] = :assigned
          end
        end
        analyze(node.keyword_rest, states, reads, writes)
      when VarField
        assign(node, states, writes)
      else
        analyze(node, states, reads, writes)
      end
    end

    def analyze_block(node, states, reads, writes)
      local_names = block_local_names(node)
      scoped_states = states.dup
      local_names.each { |name| scoped_states[name] = :block_local }
      body = node.bodystmt
      body = body.statements if body.is_a?(BodyStmt)
      analyze(body, scoped_states, reads, writes)
      states
    end

    def block_local_names(node)
      return Set.new unless node.block_var

      params = node.block_var.params
      names = node.block_var.locals.map(&:value)
      names.concat(params.requireds.grep(Ident).map(&:value))
      names.concat(params.optionals.map { |name, _default| name.value })
      names.concat(params.keywords.map { |name, _default| name.value.delete_suffix(":") })
      [params.rest, params.block].each do |param|
        name = param.respond_to?(:name) ? param.name : nil
        names << name.value if name.is_a?(Ident)
      end
      names.to_set
    end

    def analyze_children(node, states, reads, writes)
      return states unless node.respond_to?(:child_nodes)

      node.child_nodes.compact.each do |child|
        states = analyze(child, states, reads, writes)
      end
      states
    end
  end

  class LocalReferenceRewriter
    def initialize(outputs, state_name)
      @outputs = outputs.to_set
      @state_name = state_name
    end

    def collect(node)
      references = []
      walk(node, [Set.new], references)
      references
    end

    private

    def walk(node, scopes, references)
      case node
      when DefNode, Lambda
        return
      when MethodAddBlock
        walk(node.call, scopes, references)
        block = node.block
        walk(block, scopes + [block_local_names(block)], references)
      when VarRef
        add_reference(node, scopes, references)
      when Assign
        walk(node.value, scopes, references)
        add_targets(node.target, scopes, references)
      when OpAssign
        add_targets(node.target, scopes, references)
        walk(node.value, scopes, references)
      when MAssign
        walk(node.value, scopes, references)
        add_targets(node.target, scopes, references)
      when RAssign
        walk(node.value, scopes, references)
        add_pattern_targets(node.pattern, scopes, references)
      when Binary
        if node.operator == :"=>"
          walk(node.left, scopes, references)
          add_targets(node.right, scopes, references)
        else
          walk_children(node, scopes, references)
        end
      when AryPtn
        walk(node.constant, scopes, references)
        node.requireds.each { |child| walk(child, scopes, references) }
        walk(node.rest, scopes, references)
        node.posts.each { |child| walk(child, scopes, references) }
      when HshPtn
        walk(node.constant, scopes, references)
        node.keywords.each { |_key, value| walk(value, scopes, references) if value }
        walk(node.keyword_rest, scopes, references)
      else
        walk_children(node, scopes, references)
      end
    end

    def walk_children(node, scopes, references)
      return unless node.respond_to?(:child_nodes)

      node.child_nodes.compact.each { |child| walk(child, scopes, references) }
    end

    def add_pattern_targets(node, scopes, references)
      case node
      when AryPtn
        (node.requireds + node.posts).each { |child| add_pattern_targets(child, scopes, references) }
        add_pattern_targets(node.rest, scopes, references)
      when HshPtn
        node.keywords.each { |_key, value| value ? add_pattern_targets(value, scopes, references) : add_targets(value, scopes, references) }
        add_pattern_targets(node.keyword_rest, scopes, references)
      else
        add_targets(node, scopes, references)
      end
    end

    def add_reference(node, scopes, references)
      value = node.value
      return unless value.is_a?(Ident) && @outputs.include?(value.value)
      return if scopes.any? { |scope| scope.include?(value.value) }

      references << [node.start_char, node.end_char, value.value]
    end

    def add_targets(target, scopes, references)
      case target
      when VarField
        add_reference(target, scopes, references) if target.value.is_a?(Ident)
      when MLHS, MLHSParen
        parts = target.is_a?(MLHS) ? target.parts : target.contents.parts
        parts.each { |part| add_targets(part, scopes, references) }
      end
    end

    def block_local_names(node)
      return Set.new unless node.block_var

      params = node.block_var.params
      names = node.block_var.locals.map(&:value)
      names.concat(params.requireds.grep(Ident).map(&:value))
      names.concat(params.optionals.map { |name, _value| name.value })
      names.concat(params.keywords.map { |name, _value| name.value.delete_suffix(":") })
      [params.rest, params.block].each do |param|
        name = param.respond_to?(:name) ? param.name : nil
        names << name.value if name.is_a?(Ident)
      end
      names.to_set
    end
  end
end
