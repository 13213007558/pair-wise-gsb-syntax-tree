# frozen_string_literal: true

module SyntaxTree
  # ExtractMethod analyzes a contiguous range of statements inside a method
  # or block body and builds a reviewable plan for extracting those
  # statements into a brand new method. The plan describes which values have
  # to be passed into the new method as parameters, which values have to be
  # returned back to the caller, and which constructs (escaping control flow
  # or closure captures) make the extraction unsafe to perform automatically.
  #
  # Once the plan has been reviewed and is safe, it can generate the new
  # method definition and replace the selected statements with a call to it.
  #
  #     plan = SyntaxTree::ExtractMethod.plan(source, 2, 4)
  #     plan.safe?   # => true
  #     plan.params  # => [:a]
  #     plan.returns # => [:b]
  #     plan.apply(:extracted) # => rewritten source
  #
  module ExtractMethod
    # Raised when the requested line range does not map onto a contiguous
    # sequence of whole statements.
    class SelectionError < StandardError
    end

    # Raised when code generation is attempted for an unsafe plan.
    class UnsafeError < StandardError
    end

    # A single reason why an extraction cannot be performed automatically.
    class Problem
      attr_reader :kind, :message, :line

      def initialize(kind, message, line)
        @kind = kind
        @message = message
        @line = line
      end

      def ==(other)
        other.is_a?(Problem) && kind == other.kind &&
          message == other.message && line == other.line
      end
    end

    # An ordered record of a local variable access inside a subtree. The
    # type is one of :read, :vread (a bare call that may actually be a
    # local variable read), or :write. closure is true when the access
    # happens inside a block or lambda nested within the walked subtree.
    class Event
      attr_reader :type, :name, :line, :closure

      def initialize(type, name, line, closure)
        @type = type
        @name = name
        @line = line
        @closure = closure
      end

      def read?
        type == :read || type == :vread
      end

      def write?
        type == :write
      end
    end

    # Walks a subtree and records local variable reads and writes in
    # encounter order. Block and lambda parameters (and block-locals)
    # shadow outer variables within their bodies. Method, class, and
    # module definitions are opaque boundaries because local variables do
    # not cross them.
    class EventCollector
      attr_reader :events

      def initialize
        @events = []
      end

      def collect(nodes, closure: false)
        Array(nodes).compact.each { |node| walk(node, [], closure) }
        @events
      end

      private

      def emit(type, name, node, closure)
        @events << Event.new(
          type,
          name.to_sym,
          node.location.start_line,
          closure
        )
      end

      # rubocop:disable Metrics/MethodLength
      def walk(node, shadow, closure)
        return if node.nil?

        case node
        when DefNode, ClassDeclaration, ModuleDeclaration, SClass
          # Local variables do not cross these boundaries, so the
          # subtree cannot read or write the locals being tracked.
        when VarRef
          value = node.value
          if value.is_a?(Ident) && !shadow.include?(value.value)
            emit(:read, value.value, node, closure)
          end
        when VCall
          value = node.value
          unless shadow.include?(value.value)
            emit(:vread, value.value, node, closure)
          end
        when PinnedVarRef
          value = node.value
          if value.is_a?(Ident) && !shadow.include?(value.value)
            emit(:read, value.value, node, closure)
          end
        when Assign
          walk(node.value, shadow, closure)
          write_target(node.target, shadow, closure)
        when OpAssign
          target = node.target
          value = target.value if target.is_a?(VarField)
          if value.is_a?(Ident) && !shadow.include?(value.value)
            emit(:read, value.value, target, closure)
          end
          walk(node.value, shadow, closure)
          write_target(target, shadow, closure)
        when VarField
          value = node.value
          if value.is_a?(Ident) && !shadow.include?(value.value)
            emit(:write, value.value, node, closure)
          end
        when BlockNode
          names, defaults = ExtractMethod.scope_locals(node.block_var)
          defaults.each { |default| walk(default, shadow, closure) }
          walk(node.bodystmt, shadow + names, true)
        when Lambda
          names, defaults = ExtractMethod.lambda_locals(node.params)
          defaults.each { |default| walk(default, shadow, closure) }
          walk(node.statements, shadow + names, true)
        when For
          walk(node.collection, shadow, closure)
          write_target(node.index, shadow, closure)
          walk(node.statements, shadow, closure)
        else
          node.child_nodes.each { |child| walk(child, shadow, closure) }
        end
      end
      # rubocop:enable Metrics/MethodLength

      def write_target(target, shadow, closure)
        case target
        when VarField
          value = target.value
          if value.is_a?(Ident) && !shadow.include?(value.value)
            emit(:write, value.value, target, closure)
          end
        when MLHS
          target.parts.each { |part| write_target(part, shadow, closure) }
        when MLHSParen
          write_target(target.contents, shadow, closure)
        else
          # Targets such as obj.attr or Const are not local variables,
          # but they can still contain reads (e.g. obj in obj.attr = 1).
          walk(target, shadow, closure)
        end
      end
    end

    # Walks the selected statements looking for control flow that would
    # escape the extracted method: return, break, next, redo, and retry
    # whose targets live outside of the selection.
    class ControlFlowChecker
      attr_reader :problems

      def initialize
        @problems = []
        @loops = 0
        @retries = 0
        @return_shields = 0
      end

      def check(nodes)
        Array(nodes).each { |node| walk(node) }
        @problems
      end

      private

      def problem(kind, keyword, node)
        line = node.location.start_line
        @problems << Problem.new(
          kind,
          "#{keyword} on line #{line} would escape the extracted method",
          line
        )
      end

      # rubocop:disable Metrics/MethodLength
      def walk(node)
        return if node.nil?

        case node
        when DefNode, ClassDeclaration, ModuleDeclaration, SClass
          # Control flow inside a nested definition never interacts
          # with the extracted method.
        when Lambda
          @return_shields += 1
          @loops += 1
          walk_children(node)
          @return_shields -= 1
          @loops -= 1
        when WhileNode, UntilNode, For
          @loops += 1
          walk_children(node)
          @loops -= 1
        when MethodAddBlock
          walk(node.call)
          @loops += 1
          walk(node.block)
          @loops -= 1
        when Begin, Rescue
          @retries += 1
          walk_children(node)
          @retries -= 1
        when BodyStmt
          @retries += 1 if node.rescue_clause
          walk_children(node)
          @retries -= 1 if node.rescue_clause
        when ReturnNode
          problem(:return_escape, "return", node) if @return_shields.zero?
          walk_children(node)
        when Break
          problem(:break_escape, "break", node) if @loops.zero?
          walk_children(node)
        when Next
          problem(:next_escape, "next", node) if @loops.zero?
          walk_children(node)
        when Redo
          problem(:redo_escape, "redo", node) if @loops.zero?
          walk_children(node)
        when Retry
          problem(:retry_escape, "retry", node) if @retries.zero?
          walk_children(node)
        else
          walk_children(node)
        end
      end
      # rubocop:enable Metrics/MethodLength

      def walk_children(node)
        node.child_nodes.each { |child| walk(child) }
      end
    end

    # The result of analyzing a selection: a reviewable description of
    # the extraction plus the ability to generate the rewritten source
    # once the plan has been confirmed safe.
    class Plan
      attr_reader :source, :start_line, :end_line, :params, :returns, :problems

      # rubocop:disable Metrics/ParameterLists
      def initialize(
        source:,
        start_line:,
        end_line:,
        column:,
        params:,
        returns:,
        problems:,
        enclosing_def:,
        top_statement:
      )
        @source = source
        @start_line = start_line
        @end_line = end_line
        @column = column
        @params = params
        @returns = returns
        @problems = problems
        @enclosing_def = enclosing_def
        @top_statement = top_statement
      end
      # rubocop:enable Metrics/ParameterLists

      def safe?
        problems.empty?
      end

      # The exact source text that will be moved into the new method.
      def selected_source
        source.lines[(start_line - 1)...end_line].join
      end

      # Generates the new method and replaces the selected statements
      # with a call to it. Returns the rewritten source. Raises
      # UnsafeError if the plan has not been confirmed safe.
      def apply(method_name)
        unless /\A[a-z_][a-zA-Z0-9_]*[?!=]?\z/.match?(method_name.to_s)
          raise ArgumentError, "invalid method name: #{method_name.inspect}"
        end

        unless safe?
          raise UnsafeError,
                "cannot extract: #{problems.map(&:message).join("; ")}"
        end

        lines = source.lines.map(&:chomp)
        call = "#{indent}#{call_source(method_name)}"
        definition = definition_source(method_name).split("\n")

        if @enclosing_def
          nesting = " " * @enclosing_def.location.start_column
          inserted =
            [""] +
              definition.map { |line| line.empty? ? line : "#{nesting}#{line}" }
          lines.insert(@enclosing_def.location.end_line, *inserted)
          lines[(start_line - 1)...end_line] = [call]
        else
          lines[(start_line - 1)...end_line] = [call]
          lines.insert(
            @top_statement.location.start_line - 1,
            *(definition + [""])
          )
        end

        new_source = lines.join("\n")
        new_source += "\n" if source.end_with?("\n")
        SyntaxTree.parse(new_source)
        new_source
      end

      private

      def indent
        " " * @column
      end

      def call_source(method_name)
        invocation =
          if params.empty?
            method_name.to_s
          else
            "#{method_name}(#{params.join(", ")})"
          end

        case returns.length
        when 0
          invocation
        when 1
          "#{returns.first} = #{invocation}"
        else
          "#{returns.join(", ")} = #{invocation}"
        end
      end

      def definition_source(method_name)
        header =
          if params.empty?
            "def #{method_name}"
          else
            "def #{method_name}(#{params.join(", ")})"
          end

        body = body_lines
        if returns.length == 1
          body << "  #{returns.first}"
        elsif returns.length > 1
          body << "  [#{returns.join(", ")}]"
        end

        ([header] + body + ["end"]).join("\n")
      end

      def body_lines
        selected = source.lines[(start_line - 1)...end_line].map(&:chomp)
        margin = " " * @column

        dedentable =
          selected.all? { |line| line.strip.empty? || line.start_with?(margin) }

        selected.map do |line|
          if line.strip.empty?
            ""
          elsif dedentable
            "  #{line[@column..]}"
          else
            "  #{line}"
          end
        end
      end
    end

    # The statements that were matched to the requested line range,
    # along with their ancestor nodes from the root of the tree.
    class Selection
      attr_reader :statements, :nodes, :ancestors

      def initialize(statements, nodes, ancestors)
        @statements = statements
        @nodes = nodes
        @ancestors = ancestors
      end
    end

    class << self
      # Analyzes +source+ and builds a plan for extracting the
      # statements on lines +start_line+ through +end_line+ (1-based,
      # inclusive) into a new method.
      def plan(source, start_line, end_line)
        program = SyntaxTree.parse(source)
        selection = find_selection(program, start_line, end_line)

        unless selection
          raise SelectionError,
                "lines #{start_line}..#{end_line} do not map onto a " \
                  "contiguous sequence of whole statements"
        end

        unless owns_lines?(source, selection)
          raise SelectionError,
                "lines #{start_line}..#{end_line} share source lines " \
                  "with syntax outside of the selection"
        end

        build_plan(source, program, selection)
      end

      # Returns [parameter names, default value nodes] for a BlockVar
      # or LambdaVar, which share the same shape.
      def scope_locals(var)
        return [], [] unless var

        names = []
        defaults = []
        collect_params(var.params, names, defaults)
        var.locals.each do |local|
          names << local.value.delete_suffix(":").to_sym
        end
        [names, defaults]
      end

      # Returns [parameter names, default value nodes] for the
      # parameter declaration of a lambda.
      def lambda_locals(params)
        case params
        when LambdaVar
          scope_locals(params)
        when Paren
          contents = params.contents
          if contents.is_a?(Params)
            names = []
            defaults = []
            collect_params(contents, names, defaults)
            [names, defaults]
          else
            scope_locals(contents)
          end
        else
          [[], []]
        end
      end

      private

      def find_selection(program, start_line, end_line)
        best = nil
        stack = []

        visit =
          lambda do |node|
            # The outermost match wins: when a line range is ambiguous
            # (a statement and one of its nested statements both cover
            # the exact same lines), the outermost statement is the one
            # that owns those source lines.
            if node.is_a?(Statements) && best.nil?
              run = match_run(node.body, start_line, end_line)
              best = Selection.new(node, run, stack.dup) if run
            end

            stack.push(node)
            node.child_nodes.each do |child|
              visit.call(child) if child.is_a?(Node)
            end
            stack.pop
          end

        visit.call(program)
        best
      end

      def match_run(body, start_line, end_line)
        body.each_with_index do |statement, index|
          next unless statement.location.start_line == start_line

          run = [statement]
          while run.last.location.end_line < end_line &&
                  body[index + run.length]
            run << body[index + run.length]
          end

          return run if run.last.location.end_line == end_line
        end

        nil
      end

      # The selected statements must be the only thing on their source
      # lines, otherwise replacing those lines with a call would
      # destroy surrounding syntax.
      def owns_lines?(source, selection)
        lines = source.lines
        first = selection.nodes.first.location
        last = selection.nodes.last.location

        before = lines[first.start_line - 1][0...first.start_column]
        after = lines[last.end_line - 1][last.end_column..]

        before.strip.empty? &&
          (after.nil? || after.strip.empty? || after.strip.start_with?("#"))
      end

      def build_plan(source, program, selection)
        ancestors = selection.ancestors
        first = selection.nodes.first
        start_line = first.location.start_line
        end_line = selection.nodes.last.location.end_line

        region =
          ancestors.reverse.find { |node| node.is_a?(DefNode) } || program
        outer = outer_names(region, ancestors)

        region_events = EventCollector.new.collect(region.child_nodes)
        region_events.each do |event|
          if event.write? && event.line < start_line &&
               !outer.include?(event.name)
            outer << event.name
          end
        end

        # When the selection itself is nested inside a block or lambda,
        # every access it makes is a closure capture.
        region_index = ancestors.rindex(region) || -1
        inside_closure =
          ancestors[(region_index + 1)..].any? do |ancestor|
            ancestor.is_a?(BlockNode) || ancestor.is_a?(Lambda)
          end

        inside_events =
          EventCollector.new.collect(selection.nodes, closure: inside_closure)

        params = []
        defined = []
        inside_events.each do |event|
          if event.read?
            if outer.include?(event.name) && !defined.include?(event.name) &&
                 !params.include?(event.name)
              params << event.name
            end
          elsif !defined.include?(event.name)
            defined << event.name
          end
        end

        known = outer + defined
        read_after = []
        written_after = []
        region_events.each do |event|
          next unless event.line > end_line

          if event.type == :read ||
               (event.type == :vread && known.include?(event.name))
            read_after << event.name unless read_after.include?(event.name)
          elsif event.write?
            written_after << event
          end
        end

        returns = defined.select { |name| read_after.include?(name) }

        problems = ControlFlowChecker.new.check(selection.nodes)
        problems.concat(
          closure_problems(inside_events, read_after, written_after, defined)
        )

        if returns.any? && implicit_return?(selection)
          problems << Problem.new(
            :implicit_return,
            "the selection produces the value of the enclosing method " \
              "or block, which would change when the call returns the " \
              "extracted values",
            end_line
          )
        end

        Plan.new(
          source: source,
          start_line: start_line,
          end_line: end_line,
          column: first.location.start_column,
          params: params,
          returns: returns,
          problems: problems.uniq,
          enclosing_def: region.is_a?(DefNode) ? region : nil,
          top_statement: top_statement(program, selection)
        )
      end

      # Variables assigned inside a block within the selection do not
      # propagate back if the block outlives the extracted call, variables
      # read inside a block within the selection go stale if they are
      # reassigned afterwards, and variables written by a block after the
      # selection cannot be propagated by returning them.
      def closure_problems(inside_events, read_after, written_after, defined)
        problems = []

        inside_events.each do |event|
          next unless event.closure

          if event.write? && read_after.include?(event.name)
            problems << Problem.new(
              :closure_capture,
              "`#{event.name}` is assigned inside a block on line " \
                "#{event.line} but is used after the selection",
              event.line
            )
          elsif event.read? &&
                written_after.any? { |after| after.name == event.name }
            problems << Problem.new(
              :closure_capture,
              "`#{event.name}` is read inside a block on line " \
                "#{event.line} but is reassigned after the selection",
              event.line
            )
          end
        end

        written_after.each do |event|
          next unless event.closure && defined.include?(event.name)

          problems << Problem.new(
            :closure_capture,
            "`#{event.name}` is assigned by a block on line " \
              "#{event.line} after the selection, which cannot be " \
              "propagated by returning it",
            event.line
          )
        end

        problems
      end

      # Walks up from the selection to determine whether the selected
      # statements produce the implicit value of the enclosing method or
      # block, which the generated call site could not preserve when
      # values also have to be returned.
      def implicit_return?(selection)
        statements = selection.statements
        return false unless selection.nodes.last.equal?(statements.body.last)

        child = statements
        selection.ancestors.reverse_each do |ancestor|
          case ancestor
          when DefNode
            return ancestor.bodystmt.equal?(child)
          when BlockNode, Lambda
            return true
          when Program
            return false
          when Statements
            return false unless ancestor.body.last.equal?(child)

            child = ancestor
          when BodyStmt
            return false unless ancestor.statements.equal?(child)

            child = ancestor
          when IfNode, UnlessNode, Elsif, When, In, Else
            if ancestor.statements.equal?(child) ||
                 (
                   ancestor.respond_to?(:consequent) &&
                     ancestor.consequent.equal?(child)
                 )
              child = ancestor
            else
              return false
            end
          when Begin
            return false unless ancestor.bodystmt.equal?(child)

            child = ancestor
          else
            return false
          end
        end

        false
      end

      def outer_names(region, ancestors)
        names = []

        collect_params(def_params(region), names, []) if region.is_a?(DefNode)

        region_index = ancestors.rindex(region) || -1
        ancestors[(region_index + 1)..].each do |ancestor|
          case ancestor
          when BlockNode
            names.concat(scope_locals(ancestor.block_var).first)
          when Lambda
            names.concat(lambda_locals(ancestor.params).first)
          when For
            names.concat(target_names(ancestor.index))
          end
        end

        names.uniq
      end

      def def_params(node)
        params = node.params
        params = params.contents if params.is_a?(Paren)
        params.is_a?(Params) ? params : nil
      end

      def target_names(target)
        case target
        when VarField
          target.value.is_a?(Ident) ? [target.value.value.to_sym] : []
        when MLHS
          target.parts.flat_map { |part| target_names(part) }
        when MLHSParen
          target_names(target.contents)
        else
          []
        end
      end

      def top_statement(program, selection)
        if selection.statements.equal?(program.statements)
          selection.nodes.first
        else
          selection.ancestors[2]
        end
      end

      # rubocop:disable Metrics/MethodLength
      def collect_params(params, names, defaults)
        return unless params.is_a?(Params)

        params.requireds.each { |param| collect_param(param, names, defaults) }
        params.optionals.each do |name, value|
          names << name.value.to_sym
          defaults << value
        end

        rest = params.rest
        case rest
        when RestParam
          names << rest.name.value.to_sym if rest.name
        when ArgStar
          names << rest.value.value.to_sym if rest.value
        end

        params.posts.each { |param| collect_param(param, names, defaults) }

        params.keywords.each do |label, value|
          names << label.value.delete_suffix(":").to_sym
          defaults << value if value
        end

        keyword_rest = params.keyword_rest
        case keyword_rest
        when KwRestParam
          names << keyword_rest.name.value.to_sym if keyword_rest.name
        when ArgStar
          names << keyword_rest.value.value.to_sym if keyword_rest.value
        when VarField
          value = keyword_rest.value
          names << value.value.to_sym if value.is_a?(Ident)
        end

        block = params.block
        names << block.name.value.to_sym if block.is_a?(BlockArg) && block.name
      end
      # rubocop:enable Metrics/MethodLength

      def collect_param(param, names, defaults)
        case param
        when Ident
          names << param.value.to_sym
        when MLHSParen
          collect_params(param.contents, names, defaults)
        end
      end
    end
  end
end
