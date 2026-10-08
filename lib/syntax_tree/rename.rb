# frozen_string_literal: true

module SyntaxTree
  # Rename is a local-variable renaming refactoring. Given source code, a
  # cursor position, and a new name, it computes the ranges of the source
  # that have to change: the definitions of the local variable that owns the
  # position and every reference that resolves to the same binding.
  #
  # Only the occurrences of a single binding are rewritten. Method
  # parameters, block parameters, block-local variables declared after a
  # semicolon, lambda parameters, pattern matching bindings, destructured
  # parameters, and regular expression named captures are each resolved to
  # the binding they belong to, while +def+, +class+, +module+, and singleton
  # classes open a fresh scope. Method calls, symbols, and string contents
  # that happen to spell the same name are left untouched.
  #
  # When the rename would change the meaning of the program — because the
  # new name would capture references to another variable, clash with a
  # numbered parameter, or turn a method call into a local variable
  # reference — no edits are produced. Instead, the result lists the
  # conflicts and their locations.
  #
  # The resulting edits are byte ranges into the original source, so they
  # can be applied directly without disturbing the encoding of the file or
  # any unrelated formatting. Before the edits are returned, the renamed
  # source is parsed again to verify that every reference still resolves to
  # the same binding.
  #
  # Example:
  #
  #     result = SyntaxTree::Rename.rename(source, "item", line: 2, column: 4)
  #     if result.success?
  #       result.edits.each { |edit| ... }
  #     else
  #       result.conflicts.each { |conflict| ... }
  #     end
  #
  class Rename
    # A single replacement to apply to the original source.
    class Edit
      # [Integer] the byte offset at which the replaced text starts
      attr_reader :start_byte

      # [Integer] the byte offset at which the replaced text ends
      attr_reader :end_byte

      # [String] the text to insert in place of the replaced range
      attr_reader :replacement

      def initialize(start_byte:, end_byte:, replacement:)
        @start_byte = start_byte
        @end_byte = end_byte
        @replacement = replacement
      end

      # [Range] the byte range of the original source being replaced
      def range
        start_byte...end_byte
      end

      def ==(other)
        other.is_a?(Edit) && start_byte == other.start_byte &&
          end_byte == other.end_byte && replacement == other.replacement
      end
    end

    # A reason why a rename cannot be applied, tied to a source location.
    class Conflict
      # [String] a description of the conflict
      attr_reader :message

      # [Location] the location of the conflicting code
      attr_reader :location

      def initialize(message, location)
        @message = message
        @location = location
      end
    end

    # The outcome of a rename request.
    class Result
      # [Array[Edit]] the edits to apply; empty unless the rename succeeded
      attr_reader :edits

      # [Array[Conflict]] the conflicts that prevent the rename
      attr_reader :conflicts

      # [nil | String] the reason the rename could not be attempted
      attr_reader :error

      # [nil | String] the source with all of the edits applied
      attr_reader :renamed

      def initialize(edits: [], conflicts: [], error: nil, renamed: nil)
        @edits = edits
        @conflicts = conflicts
        @error = error
        @renamed = renamed
      end

      # Whether the rename was computed successfully.
      def success?
        error.nil? && conflicts.empty?
      end
    end

    # A lexical scope. The parent chain follows local variable visibility:
    # blocks and lambdas see the locals of their enclosing scopes, while
    # methods, classes, modules, and singleton classes do not.
    class Scope
      # [Symbol] the kind of construct that opened the scope
      attr_reader :kind

      # [nil | Scope] the scope that locals are inherited from
      attr_reader :parent

      # [Hash[String => Binding]] the locals defined directly in this scope
      attr_reader :locals

      def initialize(kind, parent)
        @kind = kind
        @parent = parent
        @locals = {}
      end

      # Finds the binding for the given name visible from this scope.
      def lookup(name)
        scope = self

        while scope
          binding = scope.locals[name]
          return binding if binding

          scope = scope.parent
        end

        nil
      end
    end

    # A single local variable binding: the set of definitions and references
    # that all resolve to the same variable.
    class Binding
      # [String] the name of the variable
      attr_reader :name

      # [Scope] the scope the variable is defined in
      attr_reader :scope

      # [Symbol] whether the variable is an :argument or a :variable
      attr_reader :type

      # [Array[Occurrence]] the places where the variable is defined
      attr_reader :definitions

      # [Array[Occurrence]] the places where the variable is referenced
      attr_reader :usages

      # [Boolean] whether the variable is defined by a regexp named capture
      attr_accessor :regex_defined

      def initialize(name, scope, type)
        @name = name
        @scope = scope
        @type = type
        @definitions = []
        @usages = []
        @regex_defined = false
      end

      # [Array[Occurrence]] every occurrence of the variable
      def occurrences
        definitions + usages
      end

      # [Integer] the earliest character offset at which the variable is
      # defined; from that point on the parser knows it as a local
      def defined_at
        definitions.map(&:start_char).min
      end
    end

    # One textual occurrence of a local variable, either a definition or a
    # reference. The character range covers exactly the characters of the
    # variable name (the trailing colon of a label is excluded).
    class Occurrence
      # [Scope] the scope the occurrence textually belongs to
      attr_reader :scope

      # [Location] the location of the occurrence in the source
      attr_reader :location

      # [Integer] the character offset where the variable name starts
      attr_reader :start_char

      # [Integer] the character offset where the variable name ends
      attr_reader :end_char

      def initialize(scope:, location:, start_char:, end_char:)
        @scope = scope
        @location = location
        @start_char = start_char
        @end_char = end_char
      end

      # Whether the given character offset lies within this occurrence.
      def contains?(char_offset)
        start_char <= char_offset && char_offset <= end_char
      end
    end

    # A bare method call (a +vcall+) that would be re-parsed as a local
    # variable reference if a variable with the same name came into scope.
    class MethodCall
      # [String] the name of the method being called
      attr_reader :name

      # [Location] the location of the call in the source
      attr_reader :location

      # [Scope] the scope the call textually belongs to
      attr_reader :scope

      # [Integer] the character offset where the method name starts
      attr_reader :start_char

      def initialize(name:, location:, scope:, start_char:)
        @name = name
        @location = location
        @scope = scope
        @start_char = start_char
      end
    end

    # ScopeVisitor walks the syntax tree and builds the scope tree with all
    # of the local variable bindings, following Ruby's scoping rules.
    class ScopeVisitor < Visitor
      attr_reader :bindings, :method_calls, :numbered_parameters

      def initialize(source)
        @line_offsets = Rename.line_offsets(source)
        @current_scope = Scope.new(:top, nil)
        @bindings = []
        @method_calls = []
        @numbered_parameters = []
      end

      # ------------------------------------------------------------------
      # Scope boundaries
      # ------------------------------------------------------------------

      def visit_class(node)
        visit(node.constant)
        visit(node.superclass)
        with_scope(:class, nil) { visit(node.bodystmt) }
      end

      def visit_module(node)
        visit(node.constant)
        with_scope(:module, nil) { visit(node.bodystmt) }
      end

      def visit_sclass(node)
        visit(node.target)
        with_scope(:sclass, nil) { visit(node.bodystmt) }
      end

      def visit_def(node)
        visit(node.target)

        with_scope(:def, nil) do
          visit(node.params)
          visit(node.bodystmt)
        end
      end

      def visit_method_add_block(node)
        visit(node.call)
        with_scope(:block, @current_scope) { visit(node.block) }
      end

      def visit_lambda(node)
        with_scope(:block, @current_scope) { super }
      end

      # ------------------------------------------------------------------
      # Parameters
      # ------------------------------------------------------------------

      def visit_params(node)
        add_parameters(node.requireds)
        add_parameters(node.posts)

        node.keywords.each do |label, _default|
          define(label, :argument, shadow: true)
        end

        node.optionals.each do |ident, _default|
          define(ident, :argument, shadow: true)
        end

        super
      end

      def visit_rest_param(node)
        define(node.name, :argument, shadow: true) if node.name
        super
      end

      def visit_kwrest_param(node)
        define(node.name, :argument, shadow: true) if node.name
        super
      end

      def visit_blockarg(node)
        define(node.name, :argument, shadow: true) if node.name
        super
      end

      def visit_block_var(node)
        node.locals.each { |local| define(local, :variable, shadow: true) }
        super
      end

      alias visit_lambda_var visit_block_var

      # ------------------------------------------------------------------
      # Definitions
      # ------------------------------------------------------------------

      def visit_var_field(node)
        value = node.value
        define(value, :variable, shadow: false) if value.is_a?(Ident)
        super
      end

      def visit_hshptn(node)
        node.keywords.each do |label, value|
          # A keyword without a value (like +k:+ in +in { k: }+) binds a new
          # local variable named after the key.
          define(label, :variable, shadow: false) if value.nil?
        end

        super
      end

      def visit_binary(node)
        extract_regexp_captures(node.left) if node.operator == :=~
        super
      end

      # ------------------------------------------------------------------
      # References
      # ------------------------------------------------------------------

      def visit_var_ref(node)
        value = node.value

        if value.is_a?(Ident)
          name = value.value
          binding = @current_scope.lookup(name)

          if binding
            binding.usages << occurrence(value)
          elsif name.match?(Rename::NUMBERED_PARAMETER)
            @numbered_parameters << occurrence(value)
          end
        end

        super
      end

      def visit_pinned_var_ref(node)
        value = node.value

        if value.is_a?(Ident)
          binding = @current_scope.lookup(value.value)
          binding.usages << occurrence(value) if binding
        end

        super
      end

      def visit_vcall(node)
        ident = node.value
        binding = @current_scope.lookup(ident.value)

        if binding && binding.regex_defined
          # The parser does not register locals defined by regexp named
          # captures, so references to them show up as method calls.
          binding.usages << occurrence(ident)
        else
          @method_calls << MethodCall.new(
            name: ident.value,
            location: ident.location,
            scope: @current_scope,
            start_char: ident.location.start_char
          )
        end

        super
      end

      # Finds the binding that owns the given character offset, if any.
      def binding_at(char_offset)
        @bindings.each do |binding|
          binding.occurrences.each do |occurrence|
            return binding if occurrence.contains?(char_offset)
          end
        end

        nil
      end

      # Finds a numbered parameter occurrence at the given offset, if any.
      def numbered_parameter_at(char_offset)
        @numbered_parameters.find do |occurrence|
          occurrence.contains?(char_offset)
        end
      end

      private

      def with_scope(kind, parent)
        previous_scope = @current_scope
        @current_scope = Scope.new(kind, parent)
        yield
      ensure
        @current_scope = previous_scope
      end

      def define(ident, type, shadow:)
        name = ident.value.delete_suffix(":")

        binding =
          if shadow
            @current_scope.locals[name] ||= build_binding(name, type)
          else
            @current_scope.lookup(name) ||
              (@current_scope.locals[name] = build_binding(name, type))
          end

        binding.definitions << occurrence(ident)
        binding
      end

      def build_binding(name, type)
        binding = Binding.new(name, @current_scope, type)
        @bindings << binding
        binding
      end

      # Builds an occurrence for an identifier-like node (an Ident or a
      # Label). Labels include their trailing colon in both their value and
      # their location; the colon is not part of the variable name.
      def occurrence(ident)
        location = ident.location
        end_char = location.end_char
        end_char -= 1 if ident.value.end_with?(":")

        Occurrence.new(
          scope: @current_scope,
          location: location,
          start_char: location.start_char,
          end_char: end_char
        )
      end

      def add_parameters(params)
        params.each do |param|
          case param
          when ArgStar
            define(param.value, :argument, shadow: true) if param.value
          when MLHSParen
            add_parameters(param.contents.parts)
          when MLHS
            add_parameters(param.parts)
          when Ident, Label
            define(param, :argument, shadow: true)
          end
        end
      end

      # Named captures of a regexp literal on the left-hand side of an =~
      # operator define local variables, as long as the regexp does not
      # contain any interpolation.
      def extract_regexp_captures(left)
        return unless left.is_a?(RegexpLiteral)
        return unless left.parts.length == 1

        content = left.parts.first
        return unless content.is_a?(TStringContent)

        value = content.value
        base = content.location.start_char

        Regexp.new(value, Regexp::FIXEDENCODING).names.each do |name|
          offset = value.index("(?<#{name}>") || value.index("(?'#{name}'")
          next unless offset

          define_regexp_capture(name, base + offset + 3)
        end
      rescue RegexpError
        # If the regexp cannot be compiled, its captures are ignored.
      end

      def define_regexp_capture(name, start_char)
        binding =
          @current_scope.lookup(name) ||
            (@current_scope.locals[name] = build_binding(name, :variable))

        binding.regex_defined = true
        binding.definitions << Occurrence.new(
          scope: @current_scope,
          location: location_for(start_char, start_char + name.length),
          start_char: start_char,
          end_char: start_char + name.length
        )
      end

      def location_for(start_char, end_char)
        start_line, start_column = line_and_column(start_char)
        end_line, end_column = line_and_column(end_char)

        Location.new(
          start_line: start_line,
          start_char: start_char,
          start_column: start_column,
          end_line: end_line,
          end_char: end_char,
          end_column: end_column
        )
      end

      def line_and_column(char_offset)
        index = @line_offsets.rindex { |offset| offset <= char_offset } || 0
        [index + 1, char_offset - @line_offsets[index]]
      end
    end

    # [Regexp] names that are reserved for numbered block parameters
    NUMBERED_PARAMETER = /\A_[1-9]\d*\z/

    class << self
      # Renames the local variable at the given position in the source to
      # the new name. The position can be given either as a line/column pair
      # (1-based line, 0-based column, both counted in characters) or as a
      # character offset. Returns a Result.
      def rename(source, new_name, line: nil, column: nil, offset: nil)
        new(source, new_name, line: line, column: column, offset: offset).rename
      end

      # [Array[Integer]] the character offset of the start of each line
      def line_offsets(source)
        offsets = [0]
        source.each_line { |line| offsets << offsets.last + line.length }
        offsets
      end
    end

    def initialize(source, new_name, line: nil, column: nil, offset: nil)
      @source = source
      @new_name = new_name
      @line = line
      @column = column
      @offset = offset
    end

    def rename
      program = parse(@source)

      unless program
        return Result.new(error: "the source could not be parsed")
      end

      analysis = ScopeVisitor.new(@source)
      analysis.visit(program)

      position = cursor_position

      unless position
        return Result.new(error: "the cursor position is invalid")
      end

      binding = analysis.binding_at(position)

      unless binding
        if analysis.numbered_parameter_at(position)
          return Result.new(error: "numbered parameters cannot be renamed")
        end

        return Result.new(
          error: "there is no local variable at the given position"
        )
      end

      return Result.new(renamed: @source) if binding.name == @new_name

      if @new_name.match?(NUMBERED_PARAMETER)
        return Result.new(
          conflicts: [numbered_parameter_conflict(analysis, binding)]
        )
      end

      unless valid_local_name?(@new_name)
        return Result.new(
          error: "#{@new_name.inspect} is not a valid local variable name"
        )
      end

      conflicts = find_conflicts(analysis, binding)
      return Result.new(conflicts: conflicts) unless conflicts.empty?

      edits = build_edits(binding)
      renamed = apply_edits(edits)

      error = verify(binding, renamed)
      return Result.new(error: error) if error

      Result.new(edits: edits, renamed: renamed)
    end

    private

    def parse(source)
      SyntaxTree.parse(source)
    rescue Parser::ParseError
      nil
    end

    def cursor_position
      if @offset
        @offset
      elsif @line && @column
        offsets = Rename.line_offsets(@source)
        return nil if @line < 1 || @line > offsets.length

        start = offsets[@line - 1]
        finish = @line < offsets.length ? offsets[@line] : start
        return nil if @column < 0 || start + @column > finish

        start + @column
      end
    end

    # Whether the new name can be used as a local variable name. This rules
    # out reserved words, constants, and anything that is not a plain
    # identifier.
    def valid_local_name?(name)
      program = parse("#{name} = nil")
      return false unless program

      statements = program.statements.body
      statement = statements.first

      statements.length == 1 && statement.is_a?(Assign) &&
        statement.target.is_a?(VarField) &&
        statement.target.value.is_a?(Ident) &&
        statement.target.value.value == name
    end

    def numbered_parameter_conflict(analysis, binding)
      location =
        if analysis.numbered_parameters.first
          analysis.numbered_parameters.first.location
        else
          binding.definitions.first.location
        end

      Conflict.new(
        "#{@new_name.inspect} is reserved for numbered parameters",
        location
      )
    end

    def find_conflicts(analysis, binding)
      scope = binding.scope
      defined_at = binding.defined_at
      conflicts = []

      # The name is already taken in the same scope; merging the two
      # variables would change the meaning of the program.
      if (existing = scope.locals[@new_name])
        conflicts << Conflict.new(
          "#{@new_name.inspect} is already defined in this scope",
          existing.definitions.first.location
        )
      end

      # Uses of an outer variable named like the new name would be captured
      # once the rename puts the name into this scope.
      ancestor = scope.parent

      while ancestor
        if (outer = ancestor.locals[@new_name])
          outer.occurrences.each do |occurrence|
            next unless defined_at < occurrence.start_char
            next unless passes_through?(occurrence.scope, scope, ancestor)

            conflicts << Conflict.new(
              "renaming to #{@new_name.inspect} would capture this use of " +                "the outer #{@new_name.inspect}",
              occurrence.location
            )
          end
        end

        ancestor = ancestor.parent
      end

      # Uses of the renamed variable would be captured by a binding of the
      # new name in a scope between the use and the renamed variable.
      binding.occurrences.each do |occurrence|
        inner = occurrence.scope

        while inner && inner != scope
          shadow = inner.locals[@new_name]

          if shadow && shadow.defined_at < occurrence.start_char
            conflicts << Conflict.new(
              "renaming this reference would make it resolve to the " +                "#{@new_name.inspect} defined in an inner scope",
              occurrence.location
            )
            break
          end

          inner = inner.parent
        end
      end

      # Bare method calls that the rename would re-parse as local variable
      # references.
      analysis.method_calls.each do |call|
        next unless call.name == @new_name
        next unless defined_at < call.start_char

        inner = call.scope
        inner = inner.parent while inner && inner != scope

        if inner == scope
          conflicts << Conflict.new(
            "renaming to #{@new_name.inspect} would turn this method " +              "call into a local variable reference",
            call.location
          )
        end
      end

      conflicts.uniq { |conflict| [conflict.message, conflict.location] }
    end

    # Whether walking up from +from+ reaches +middle+ before +limit+.
    def passes_through?(from, middle, limit)
      scope = from

      while scope && scope != middle && scope != limit
        scope = scope.parent
      end

      scope == middle
    end

    def build_edits(binding)
      offsets = byte_offsets

      binding
        .occurrences
        .map do |occurrence|
          Edit.new(
            start_byte: offsets[occurrence.start_char],
            end_byte: offsets[occurrence.end_char],
            replacement: @new_name
          )
        end
        .sort_by(&:start_byte)
    end

    # [Array[Integer]] the byte offset of each character in the source
    def byte_offsets
      offsets = [0]
      @source.each_char { |char| offsets << offsets.last + char.bytesize }
      offsets
    end

    def apply_edits(edits)
      renamed = @source.b

      edits.reverse_each do |edit|
        renamed[edit.start_byte...edit.end_byte] = edit.replacement.b
      end

      renamed.force_encoding(@source.encoding)
    end

    # Parses the renamed source and checks that every renamed occurrence
    # still resolves to a single binding with the same set of occurrences.
    def verify(binding, renamed)
      program = parse(renamed)
      return "the renamed source could not be parsed" unless program

      analysis = ScopeVisitor.new(renamed)
      analysis.visit(program)

      expected = []
      delta = 0

      binding.occurrences.sort_by(&:start_char).each do |occurrence|
        start_char = occurrence.start_char + delta
        delta += @new_name.length - (occurrence.end_char - occurrence.start_char)
        expected << [start_char, start_char + @new_name.length]
      end

      index = {}

      analysis.bindings.each do |candidate|
        candidate.occurrences.each do |occurrence|
          index[[occurrence.start_char, occurrence.end_char]] = candidate
        end
      end

      matched = expected.map { |range| index[range] }

      if matched.any?(&:nil?) || matched.uniq.length != 1
        return "the renamed variable no longer resolves to a single binding"
      end

      renamed_binding = matched.first

      if renamed_binding.name != @new_name ||
           renamed_binding.occurrences.length != expected.length
        return "the renamed binding does not match the original references"
      end

      nil
    end
  end
end
