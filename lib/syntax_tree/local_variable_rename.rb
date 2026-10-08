# frozen_string_literal: true

module SyntaxTree
  class LocalVariableRename
    NUMBERED_NAME = /\A_\d+\z/
    LOCAL_NAME = /\A[a-z_\p{Ll}\p{Lo}][\p{Word}]*\z/

    def self.rename(source, position, new_name)
      new(source.dup).rename(position, new_name)
    end

    def initialize(source)
      @source = source
    end

    def rename(position, new_name)
      analyzer = ScopeAnalyzer.new(SyntaxTree.parse(@source), @source).analyze
      char_position = byte_to_char(@source, position)
      occurrence = occurrence_at(analyzer, char_position)
      return failure("No local variable at cursor") unless occurrence

      new_name = new_name.to_s
      unless new_name.match?(LOCAL_NAME) && new_name !~ NUMBERED_NAME
        return failure("Invalid local variable name", occurrence.range)
      end

      target = occurrence.binding
      if target.is_a?(ScopeAnalyzer::NumberedBinding)
        return failure("Numbered parameter cannot be renamed", occurrence.range)
      end
      if target.scope.bindings.key?(new_name)
        conflicting = target.scope.bindings[new_name].locations.first
        return failure(
          "New name already exists in scope",
          range_for(analyzer, conflicting)
        )
      end

      edits = edits_for(analyzer, target, new_name)
      candidate = apply_edits(edits)
      verify(candidate, analyzer, occurrence, target, new_name, edits)
    rescue Parser::ParseError => error
      failure(error.message)
    end

    private

    def byte_to_char(source, byte_offset)
      prefix = source.byteslice(0, byte_offset)
      prefix ? prefix.length : source.length
    end

    def occurrence_at(analyzer, char_offset)
      analyzer.occurrences.find do |occurrence|
        occurrence.location.start_char <= char_offset &&
          char_offset < occurrence.location.end_char
      end
    end

    def potential_occurrence_at(analyzer, char_offset)
      analyzer.potential_occurrences.find do |occurrence|
        occurrence.location.start_char <= char_offset &&
          char_offset < occurrence.location.end_char
      end
    end

    def matching_occurrence?(
      candidate,
      original,
      target,
      new_name,
      candidate_potential
    )
      return false unless original

      if candidate_potential
        original.binding.scope.id == candidate.binding.scope.id &&
          original.binding.name == candidate.binding.name
      elsif candidate.binding.name == new_name
        original.binding.scope.id == candidate.binding.scope.id
      else
        original.binding.scope.id == candidate.binding.scope.id &&
          original.binding.name == candidate.binding.name
      end
    end

    def range_for(analyzer, location)
      analyzer.ranges.find { |range| range.start_char == location.start_char }
    end

    def edits_for(analyzer, target, new_name)
      analyzer
        .occurrences
        .select { |occurrence| occurrence.binding == target }
        .map do |occurrence|
          Edit.new(range_for(analyzer, occurrence.location), new_name)
        end
    end

    def apply_edits(edits)
      sorted = edits.sort_by { |edit| edit.range.start_char }
      pieces = []
      cursor = 0
      sorted.each do |edit|
        pieces << @source[cursor...edit.range.start_char]
        pieces << edit.new_name
        cursor = edit.range.end_char
      end
      pieces << @source[cursor..]
      pieces.join.force_encoding(@source.encoding)
    end

    def verify(candidate, original_analyzer, original_occurrence, target,
               new_name, edits)
      parsed = SyntaxTree.parse(candidate)
      candidate_analyzer = ScopeAnalyzer.new(parsed, candidate).analyze
      candidate_position =
        forward_position(edits, original_occurrence.location.start_char)
      candidate_occurrence = occurrence_at(candidate_analyzer, candidate_position)

      unless candidate_occurrence &&
               candidate_occurrence.binding.scope.id == target.scope.id &&
               candidate_occurrence.binding.name == new_name
        return failure("Rename would change a binding", edits.first&.range)
      end

      original_analyzer.occurrences.each do |occurrence|
        mapped = forward_position(edits, occurrence.location.start_char)
        changed = occurrence_at(candidate_analyzer, mapped)
        expected_name =
          renamed?(occurrence, target) ? new_name : occurrence.binding.name
        unless changed && changed.binding.scope.id == occurrence.binding.scope.id &&
                 changed.binding.name == expected_name
          return failure("Rename would change a binding", edits.first&.range)
        end
      end

      (candidate_analyzer.occurrences + candidate_analyzer.potential_occurrences)
        .uniq { |occurrence| occurrence.location.start_char }
        .each do |occurrence|
          start_char = occurrence.location.start_char
          original_position = backward_position(edits, start_char)
          next unless original_position
          original_occurrence =
            occurrence_at(original_analyzer, original_position) ||
              potential_occurrence_at(original_analyzer, original_position)
          candidate_potential =
            candidate_analyzer.potential_occurrences.any? do |potential|
              potential.location.start_char == occurrence.location.start_char
            end
          unless matching_occurrence?(
                   occurrence,
                   original_occurrence,
                   target,
                   new_name,
                   candidate_potential
                 )
            return failure(
              "Rename would capture another reference",
              occurrence.range
            )
          end
        end

      Result.new(edits: edits)
    end

    def renamed?(occurrence, target)
      occurrence.binding == target
    end

    def forward_position(edits, position)
      offset = 0
      edits.sort_by { |edit| edit.range.start_char }.each do |edit|
        next if position < edit.range.start_char

        range_start = edit.range.start_char + offset
        range_end = edit.range.end_char + offset

        if position < edit.range.end_char
          return range_start
        end

        offset += edit.new_name.length - edit.range.length
      end
      position + offset
    end

    def backward_position(edits, position)
      offset = 0
      edits.sort_by { |edit| edit.range.start_char }.each do |edit|
        new_end = edit.range.start_char + edit.new_name.length
        next if position < edit.range.start_char
        return edit.range.start_char if position < new_end
        offset += edit.range.length - edit.new_name.length
      end
      position + offset
    end

    def failure(message, range = nil)
      Result.new(conflicts: [Conflict.new(message: message, range: range)])
    end

  end

  class LocalVariableRename
    class Range
      attr_reader :start_byte, :end_byte, :start_char, :end_char,
                  :start_line, :start_column

      def self.from_location(location, source)
        new(
          start_char: location.start_char,
          end_char: location.end_char,
          start_byte: source[0, location.start_char].bytesize,
          end_byte: source[0, location.end_char].bytesize,
          start_line: location.start_line,
          start_column: location.start_column
        )
      end

      def initialize(start_byte:, end_byte:, start_char:, end_char:,
                     start_line:, start_column:)
        @start_byte = start_byte
        @end_byte = end_byte
        @start_char = start_char
        @end_char = end_char
        @start_line = start_line
        @start_column = start_column
      end

      def length
        end_char - start_char
      end
    end

    class Edit
      attr_reader :range, :new_name

      def initialize(range, new_name)
        @range = range
        @new_name = new_name
      end

      def start_byte
        range.start_byte
      end

      def end_byte
        range.end_byte
      end
    end

    class Conflict
      attr_reader :message, :range

      def initialize(message:, range: nil)
        @message = message
        @range = range
      end
    end

    class Result
      attr_reader :edits, :conflicts

      def initialize(edits: [], conflicts: [])
        @edits = edits
        @conflicts = conflicts
      end

      def success?
        conflicts.empty?
      end

      def apply(source)
        sorted = edits.sort_by { |edit| edit.range.start_char }
        pieces = []
        cursor = 0
        sorted.each do |edit|
          pieces << source[cursor...edit.range.start_char]
          pieces << edit.new_name
          cursor = edit.range.end_char
        end
        pieces << source[cursor..]
        pieces.join.force_encoding(source.encoding)
      end
    end
  end

  class ScopeAnalyzer
      Occurrence = Struct.new(
        :binding,
        :location,
        :range,
        :definition,
        keyword_init: true
      )

      class Scope
        attr_reader :id, :kind, :parent, :ordinary, :bindings, :numbered

        def initialize(id:, kind:, parent:, ordinary:)
          @id = id
          @kind = kind
          @parent = parent
          @ordinary = ordinary
          @bindings = {}
          @numbered = {}
        end

        def find(name)
          bindings[name] || parent&.find(name)
        end
      end

      class Binding
        attr_reader :scope, :name, :locations

        def initialize(scope, name)
          @scope = scope
          @name = name
          @locations = []
          @forced = false
        end

        def force!
          @forced = true
        end

        def forced?
          @forced
        end

        def unforce!
          @forced = false
        end
      end

      class NumberedBinding
        attr_reader :scope, :name

        def initialize(scope, name)
          @scope = scope
          @name = name
        end
      end

      attr_reader :occurrences, :potential_occurrences, :ranges

      def initialize(root_node, source)
        @root_node = root_node
        @source = source
        @occurrences = []
        @potential_occurrences = []
        @ranges = []
      end

      def analyze
        first_pass
        second_pass
        populate_definitions
        range_occurrences = occurrences + potential_occurrences
        @ranges =
          range_occurrences
            .uniq { |occurrence| occurrence.location.start_char }
            .map do |occurrence|
              LocalVariableRename::Range.from_location(occurrence.location, @source)
            end
        (occurrences + potential_occurrences).each do |occurrence|
          occurrence[:range] = @ranges.find do |range|
            range.start_char == occurrence.location.start_char
          end
        end
        self
      end

      private

      def first_pass
        @id = 0
        @scopes = []
        @scope_nodes = {}
        @phase = :definitions
        root_scope = new_scope(@root_node, nil, :root, false)
        @scopes << root_scope
        visit(@root_node, root_scope)
      end

      def second_pass
        @phase = :uses
        @occurrences = []
        @potential_occurrences = []
        @scope_stack = [@scopes.first]
        @active = Hash.new { |hash, key| hash[key] = [] }
        @numbered_uses = {}
        visit(@root_node, @scopes.first)
      end

      def new_scope(node, parent, kind, ordinary)
        scope = Scope.new(id: @id, kind: kind, parent: parent, ordinary: ordinary)
        @id += 1
        @scope_nodes[node.object_id] = scope
        scope
      end

      def visit(node, scope)
        return unless node

        if node.is_a?(Array)
          node.each { |child| visit(child, scope) }
          return
        end

        case node
        when ClassDeclaration, ModuleDeclaration, SClass
          visit(node.respond_to?(:target) ? node.target : node.constant, scope)
          visit(node.respond_to?(:superclass) ? node.superclass : nil, scope)
          isolated(node.bodystmt, scope) { visit(node.bodystmt, _1) }
        when DefNode
          visit(node.target, scope)
          visit(node.operator, scope)
          visit(node.name, scope)
            isolated(node, scope) do
              visit_params(unwrap(node.params), _1)
              visit(node.bodystmt, _1)
            end
        when MethodAddBlock
          visit(node.call, scope)
            block_scope =
              scope_for(node.block, scope, :block, ordinary_block?(node.block))
            visit(node.block.opening, scope)
            visit_block_var(node.block.block_var, block_scope)
            visit(node.block.bodystmt, block_scope)
        when Lambda
          lambda_scope =
            scope_for(node, scope, :lambda, ordinary_lambda?(node.params))
          visit_lambda_var(node.params, lambda_scope)
          visit(node.statements, lambda_scope)
        when In
          visit_in_pattern(node, scope)
        when HshPtn
          visit_hash_pattern(node, scope)
        when Binary
          if defining? && node.operator == :=~ && node.left.is_a?(RegexpLiteral)
            define_regex_captures(node.left, scope)
          end
          visit(node.left, scope)
          visit(node.operator, scope)
          visit(node.right, scope)
        when VarField
          if defining? && node.value.is_a?(Ident)
            force_assignment = scope.bindings[node.value.value]&.forced?
            define(node.value, scope, forced: force_assignment == true)
          end
          use(node.value, scope)
        when VarRef
          mark_numbered(node.value, scope) if defining?
          use(node.value, scope)
        when VCall
          use(node.value, scope, potential: true)
        when PinnedVarRef
          use(node.value, scope)
        else
          if node.respond_to?(:child_nodes)
            node.child_nodes.each { |child| visit(child, scope) }
          end
        end
      end

      def defining?
        @phase == :definitions
      end

      def isolated(node, parent)
        if defining?
          scope = new_scope(node, parent, :isolated, true)
          @scopes << scope
        else
          scope = @scope_nodes.fetch(node.object_id)
        end
        with_scope(scope) { yield(scope) }
      end

      def scope_for(node, parent, kind, ordinary)
        if defining?
          scope = new_scope(node, parent, kind, ordinary)
          @scopes << scope
          scope
        else
          @scope_nodes.fetch(node.object_id)
        end
      end

      def with_scope(scope)
        @scope_stack << scope if !defining?
        yield scope
      ensure
        @scope_stack.pop if !defining?
      end

        def ordinary_block?(block)
          return false unless (block_var = block.block_var)
          !block_var.params.empty?
      end

        def ordinary_lambda?(params)
          params = params.contents if params.is_a?(Paren)
          params = params.params if params.is_a?(LambdaVar)
          !params.empty?
      end

      def unwrap(params)
        params.is_a?(Paren) ? params.contents : params
      end

        def visit_block_var(block_var, scope)
          return unless block_var
          visit_params(block_var.params, scope)
          declare_variable_locals(block_var.locals, block_var.location, scope)
        end

      def visit_lambda_var(params, scope)
        params = params.contents if params.is_a?(Paren)
        if params.is_a?(LambdaVar)
          visit_params(params.params, scope)
          declare_variable_locals(params.locals, params.location, scope)
        else
          visit_params(params, scope)
        end
      end

      def declare_variable_locals(idents, enclosing_location, scope)
        idents.each do |identifier|
          source_location =
            @source.index(identifier.value, enclosing_location.start_char)
          next unless source_location
          location =
            Location.new(
              start_line: enclosing_location.start_line,
              start_char: source_location,
              start_column: source_location,
              end_line: enclosing_location.start_line,
              end_char: source_location + identifier.value.length,
              end_column: source_location + identifier.value.length
            )
          define(Ident.new(value: identifier.value, location: location), scope)
        end
      end

      def visit_params(params, scope)
        return unless params.is_a?(Params)

        params.requireds.each { |param| visit_required_param(param, scope) }
        params.optionals.each do |name, default|
          define(name, scope)
          visit(default, scope)
        end
        visit_rest(params.rest, scope)
        params.posts.each { |param| visit_required_param(param, scope) }
        params.keywords.each do |name, default|
          define(name, scope)
          visit(default, scope)
        end
        visit_keyword_rest(params.keyword_rest, scope)
        visit(params.block, scope)
      end

      def visit_required_param(node, scope)
        case node
        when Ident
          define(node, scope)
        when MLHSParen
          visit_required_param(node.contents, scope)
        when MLHS
          node.parts.each { |part| visit_required_param(part, scope) }
        when ArgStar
          define(node.value, scope) if node.value
        else
          visit(node, scope)
        end
      end

      def visit_rest(node, scope)
        define(node.name, scope) if node.is_a?(RestParam) && node.name
        visit(node, scope)
      end

      def visit_keyword_rest(node, scope)
        define(node.name, scope) if node.is_a?(KwRestParam) && node.name
        visit(node, scope)
      end

      def visit_hash_pattern(node, scope)
        visit(node.constant, scope)
            node.keywords.each do |label, value|
              define(label, scope) if value.nil?
          visit(label, scope)
          visit(value, scope)
        end
        visit(node.keyword_rest, scope)
      end

      def visit_in_pattern(node, scope)
        pattern = node.pattern
        if pattern.is_a?(IfNode) || pattern.is_a?(UnlessNode)
          visit(pattern.statements, scope)
          visit(pattern.predicate, scope)
        else
          visit(pattern, scope)
        end
        visit(node.statements, scope)
        visit(node.consequent, scope)
      end

      def define(identifier, scope, forced: true, trim_label: true)
        return if !defining? || identifier.nil?
        name = identifier_name(identifier)
        return unless local_name?(name)
        binding =
          scope.bindings[name] ||
            (!forced && find_reusable_binding(scope, name)) ||
            scope.bindings[name] = Binding.new(scope, name)
        forced ? binding.force! : binding.unforce!
        location = identifier_location(identifier, trim_label)
        binding.locations << location unless binding.locations.any? do |existing|
          same?(existing, location)
        end
      end

      def find_reusable_binding(scope, name)
        current = scope
        while current
          binding = current.bindings[name]
          return binding unless binding.nil? || binding.forced?
          break if current.kind == :isolated
          current = current.parent
        end
        nil
      end

      def use(identifier, scope, potential: false)
        return if defining? || !identifier.is_a?(Ident)

        name = identifier.value
        if name =~ LocalVariableRename::NUMBERED_NAME
          numbered_scope = nearest_numbered_scope(scope)
          binding = numbered_scope&.numbered&.[](name)
        else
          binding = find_active_binding(scope, name, identifier.location.start_char)
        end
        unless binding
          if potential
            static_binding = find_static_binding(scope, name)
            @potential_occurrences << Occurrence.new(
              binding: static_binding,
              location: identifier.location,
              definition: false
            ) if static_binding
          end
          return
        end

        definition =
          binding.respond_to?(:locations) &&
            binding.locations.any? do |location|
              same?(location, identifier.location)
            end
        @occurrences << Occurrence.new(
          binding: binding,
          location: identifier.location,
          definition: definition
        )
      end

      def mark_numbered(identifier, scope)
        numbered_name =
          defining? &&
            identifier.is_a?(Ident) &&
            identifier.value =~ LocalVariableRename::NUMBERED_NAME
        return unless numbered_name
        target = nearest_numbered_scope(scope)
        return unless target
        target.numbered[identifier.value] ||=
          NumberedBinding.new(target, identifier.value)
      end

      def nearest_numbered_scope(scope)
        return nil if scope.nil? || scope.kind == :isolated
        return scope unless scope.ordinary
        nearest_numbered_scope(scope.parent)
      end

      def find_active_binding(scope, name, position)
        current = scope
        while current
          binding = current.bindings[name]
          defined = binding&.locations&.any? do |location|
            location.start_char < position
          end
          return binding if defined
          break if current.kind == :isolated
          current = current.parent
        end
        nil
      end

      def find_static_binding(scope, name)
        current = scope
        while current
          binding = current.bindings[name]
          return binding if binding
          break if current.kind == :isolated
          current = current.parent
        end
        nil
      end

      def populate_definitions
        @scopes.each do |scope|
          scope.bindings.each_value do |binding|
            binding.locations.each do |location|
              already = @occurrences.any? do |occurrence|
                same?(occurrence.location, location)
              end
              next if already
              @occurrences << Occurrence.new(
                binding: binding,
                location: location,
                definition: true
              )
            end
          end
        end
      end

      def identifier_name(identifier)
        if identifier.is_a?(Label)
          identifier.value.delete_suffix(":")
        else
          identifier.value
        end
      end

      def identifier_location(identifier, trim_label = true)
        return identifier.location unless identifier.is_a?(Label)
        return identifier.location unless trim_label

        location = identifier.location
        Location.new(
          start_line: location.start_line,
          start_char: location.start_char,
          start_column: location.start_column,
          end_line: location.end_line,
          end_char: location.end_char - 1,
          end_column: location.end_column - 1
        )
      end

      def same?(left, right)
        left.start_char == right.start_char && left.end_char == right.end_char
      end

      def define_regex_captures(regex, scope)
        regex.parts.each do |part|
          next unless part.is_a?(TStringContent)
          named_captures(part.value).each do |name, offset|
            next unless local_name?(name)
            identifier = Ident.new(
              value: name,
              location: capture_location(part, name, offset)
            )
            define(identifier, scope)
          end
        end

        def parameter_label?(label)
          label.value.delete_suffix(":") =~ LocalVariableRename::LOCAL_NAME &&
            label.location.end_char - label.location.start_char == label.value.length
        end
      end

      def named_captures(content)
        captures = []
        index = 0
        escaped = false
        character_class = false

        while index < content.length
          character = content[index]
          if escaped
            escaped = false
          elsif character == "\\"
            escaped = true
          elsif character == "["
            character_class = true
          elsif character == "]"
            character_class = false
          elsif !character_class && content[index, 3] == "(?<"
            closing = content.index(">", index + 3)
            captures << [content[(index + 3)...closing], index + 3]
            index = closing
          end
          index += 1
        end

        captures
      end

      def capture_location(part, name, offset)
        prefix = @source[part.location.start_char, offset] || ""
        start_char = part.location.start_char + offset
        line = part.location.start_line + prefix.count("\n")
        column =
          if prefix.include?("\n")
            prefix.length - prefix.rindex("\n") - 1
          else
            part.location.start_column + offset
          end

        Location.new(
          start_line: line,
          start_char: start_char,
          start_column: column,
          end_line: line,
          end_char: start_char + name.length,
          end_column: column + name.length
        )
      end

      def local_name?(name)
        name.match?(LocalVariableRename::LOCAL_NAME) &&
        name !~ LocalVariableRename::NUMBERED_NAME
      end
    end
  end
