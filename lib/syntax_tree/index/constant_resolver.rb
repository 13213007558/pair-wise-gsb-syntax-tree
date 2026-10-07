# frozen_string_literal: true

module SyntaxTree
  module Index
    # The ConstantResolver augments the index with static constant
    # resolution: for every constant reference found in a set of source
    # files it determines which definition the reference could point to.
    #
    # Resolution follows Ruby's own lookup rules as closely as possible
    # without executing any project code:
    #
    # *   Lexical scopes (Module.nesting) are searched from the innermost
    #     scope outwards. Note that +class A::B+ introduces the single
    #     lexical scope +A::B+, while the nested form (+class A+ containing
    #     +class B+) introduces both +A::B+ and +A+ -- the two forms are
    #     not the same lexical environment.
    # *   Explicit +::+ paths are honored: a leading +::+ starts the
    #     lookup at the top level, and every following segment is looked
    #     up inside the namespace (and its ancestors) found for the
    #     previous segment.
    # *   The ancestors of the innermost lexical scope are searched,
    #     which covers superclass chains and modules mixed in with
    #     +include+.
    # *   Finally the top level (Object) is searched.
    #
    # Every step of the lookup is recorded, so tools can display the
    # exact path that was searched for each reference.
    #
    # Static analysis cannot see everything. When the project defines
    # +const_missing+, uses dynamic +const_set+, or defines constants
    # under conditionals, the resolver keeps the uncertainty instead of
    # guessing -- and it never executes project code to fill in the gaps.
    class ConstantResolver
      # A definition of a constant, class, or module found in the source.
      class Definition
        # [Array[Symbol]] the fully-qualified path of the definition.
        attr_reader :path

        # [Symbol] one of :class, :module, or :constant.
        attr_reader :kind

        # [String] the file where the definition was found.
        attr_reader :file

        # [Integer] the line where the definition starts.
        attr_reader :line

        # [nil | Symbol | Array] for classes, the superclass: nil when
        # there is no superclass clause, :dynamic when the superclass is
        # not a static constant path, or a [segments, absolute, scopes]
        # triple describing the constant reference.
        attr_reader :superclass

        def initialize(
          path:,
          kind:,
          file:,
          line:,
          superclass: nil,
          conditional: false
        )
          @path = path
          @kind = kind
          @file = file
          @line = line
          @superclass = superclass
          @conditional = conditional
        end

        # Whether the definition sits under a conditional
        # (if/unless/case), in which case it may not exist at runtime.
        def conditional?
          @conditional
        end

        def name
          path.join("::")
        end
      end

      # An +include+ call found in the source.
      class Include
        # [Array[Symbol]] the cref (the innermost lexical scope) that
        # the include applies to.
        attr_reader :cref

        # [Array[Symbol]] the segments of the included module
        # reference.
        attr_reader :segments

        # [Array[Array[Symbol]]] the lexical scopes at the include
        # site, innermost first.
        attr_reader :scopes

        # [String] the file where the include was found.
        attr_reader :file

        # [Integer] the line of the include.
        attr_reader :line

        def initialize(cref:, segments:, absolute:, scopes:, file:, line:)
          @cref = cref
          @segments = segments
          @absolute = absolute
          @scopes = scopes
          @file = file
          @line = line
        end

        # Whether the included module starts with an explicit +::+.
        def absolute?
          @absolute
        end
      end

      # A reference to a constant found in the source.
      class Reference
        # [Array[Symbol]] the segments of the reference, e.g. [:A, :B]
        # for +A::B+.
        attr_reader :segments

        # [Array[Array[Symbol]]] the lexical scopes at the reference
        # site, innermost first.
        attr_reader :scopes

        # [String] the file where the reference was found.
        attr_reader :file

        # [Integer] the line of the reference.
        attr_reader :line

        def initialize(segments:, absolute:, scopes:, file:, line:)
          @segments = segments
          @absolute = absolute
          @scopes = scopes
          @file = file
          @line = line
        end

        # Whether the reference starts with an explicit +::+.
        def absolute?
          @absolute
        end

        def name
          segments.join("::")
        end
      end

      # A single step of a constant lookup.
      class Step
        # [Array[Symbol]] the namespace that was searched; empty means
        # the top level.
        attr_reader :scope

        # [Symbol] the constant segment that was looked up.
        attr_reader :segment

        # [Symbol] one of :lexical, :ancestor, :qualified, or
        # :toplevel.
        attr_reader :kind

        def initialize(scope:, segment:, kind:, found:)
          @scope = scope
          @segment = segment
          @kind = kind
          @found = found
        end

        def found?
          @found
        end

        def to_s
          where = scope.empty? ? "Object" : scope.join("::")
          label =
            case kind
            when :lexical
              "lexical scope"
            when :ancestor
              "ancestor"
            when :qualified
              "namespace"
            else
              "top-level"
            end
          "#{where} (#{label})"
        end
      end

      # The result of resolving a single constant reference.
      class Resolution
        # [Reference] the reference that was resolved.
        attr_reader :reference

        # [Array[Step]] the lookup path that was searched, in order.
        attr_reader :steps

        # [Array[String]] the reasons this resolution is uncertain.
        attr_reader :reasons

        # [Array[Definition]] the definitions the reference may point
        # to, empty when unresolved.
        attr_reader :definitions

        def initialize(reference:, steps:, reasons:, definitions:)
          @reference = reference
          @steps = steps
          @reasons = reasons
          @definitions = definitions
        end

        # Whether any definition was found for the reference.
        def resolved?
          !definitions.empty?
        end

        # Whether the resolution is free of uncertainty.
        def certain?
          resolved? && reasons.empty?
        end

        # The most likely definition, or nil when unresolved.
        def target
          definitions.first
        end

        def to_s
          lines = ["#{reference.name} at #{reference.file}:#{reference.line}"]

          steps.each_with_index do |step, index|
            mark = step.found? ? "found" : "not found"
            lines << "  #{index + 1}. #{step} -- #{mark}"
          end

          if resolved?
            lines << "  => #{target.name} " \
              "(#{target.kind}, #{target.file}:#{target.line})"
          else
            lines << "  => unresolved"
          end

          reasons.each { |reason| lines << "  ! #{reason}" }
          lines.join("\n")
        end
      end

      # This visitor walks a parsed file and collects everything the
      # resolver needs: definitions, references, includes, and the
      # sources of uncertainty. It never executes the code it walks.
      class Collector < Visitor
        attr_reader :file,
                    :definitions,
                    :deferred,
                    :includes,
                    :references,
                    :const_missing,
                    :dynamic_consts,
                    :conditional_requires

        def initialize(file)
          @file = file
          @nesting = []
          @conditional_depth = 0

          @definitions = []
          @deferred = []
          @includes = []
          @references = []
          @const_missing = []
          @dynamic_consts = []
          @conditional_requires = []
        end

        def visit_class(node)
          segments, = constant_path(node.constant)

          # `class A::B` references the namespace A.
          if node.constant.is_a?(ConstPathRef)
            parent_segments, parent_absolute =
              constant_path(node.constant.parent)
            add_reference(
              parent_segments,
              parent_absolute,
              node.constant.parent.location
            )
          end

          superclass = nil
          if node.superclass
            super_segments, super_absolute = constant_path(node.superclass)

            if super_segments
              add_reference(
                super_segments,
                super_absolute,
                node.superclass.location
              )
              superclass = [super_segments, super_absolute, current_scopes]
            else
              superclass = :dynamic
            end
          end

          @nesting << segments
          @definitions << Definition.new(
            path: @nesting.flatten,
            kind: :class,
            file: file,
            line: node.location.start_line,
            superclass: superclass,
            conditional: conditional?
          )

          visit(node.bodystmt)
          @nesting.pop
        end

        def visit_module(node)
          segments, = constant_path(node.constant)

          # `module A::B` references the namespace A.
          if node.constant.is_a?(ConstPathRef)
            parent_segments, parent_absolute =
              constant_path(node.constant.parent)
            add_reference(
              parent_segments,
              parent_absolute,
              node.constant.parent.location
            )
          end

          @nesting << segments
          @definitions << Definition.new(
            path: @nesting.flatten,
            kind: :module,
            file: file,
            line: node.location.start_line,
            conditional: conditional?
          )

          visit(node.bodystmt)
          @nesting.pop
        end

        def visit_assign(node)
          case node.target
          when VarField
            value = node.target.value
            if value.is_a?(Const)
              @definitions << Definition.new(
                path: @nesting.flatten + [value.value.to_sym],
                kind: :constant,
                file: file,
                line: node.location.start_line,
                conditional: conditional?
              )
            end
          when TopConstField
            @definitions << Definition.new(
              path: [node.target.constant.value.to_sym],
              kind: :constant,
              file: file,
              line: node.location.start_line,
              conditional: conditional?
            )
          when ConstPathField
            parent_segments, parent_absolute = constant_path(node.target.parent)

            if parent_segments
              add_reference(
                parent_segments,
                parent_absolute,
                node.target.parent.location
              )
              @deferred << [
                parent_segments,
                parent_absolute,
                current_scopes,
                node.target.constant.value.to_sym,
                node.location.start_line,
                conditional?
              ]
            else
              @dynamic_consts << node.location.start_line
            end
          end

          visit(node.value)
        end

        def visit_var_ref(node)
          if node.value.is_a?(Const)
            add_reference([node.value.value.to_sym], false, node.location)
          end
        end

        def visit_const_path_ref(node)
          segments, absolute = constant_path(node)
          add_reference(segments, absolute, node.location) if segments

          # Deliberately do not visit the parent: it is part of this
          # reference, not a separate one.
        end

        def visit_top_const_ref(node)
          add_reference([node.constant.value.to_sym], true, node.location)
        end

        def visit_command(node)
          case node.message.value
          when "include"
            handle_include(node.arguments.parts, node.location)
          when "const_set"
            @dynamic_consts << node.location.start_line
            super
          when "require", "require_relative"
            @conditional_requires << node.location.start_line if conditional?
            super
          else
            super
          end
        end

        def visit_call(node)
          message = node.message

          if message.is_a?(Ident)
            case message.value
            when "include"
              parts = call_parts(node.arguments)
              if node.receiver.nil? && parts
                handle_include(parts, node.location)
                return
              end
            when "const_set"
              @dynamic_consts << node.location.start_line
            when "require", "require_relative"
              @conditional_requires << node.location.start_line if conditional?
            end
          end

          super
        end

        def visit_def(node)
          if node.name.value == "const_missing"
            @const_missing << node.location.start_line
          end
          super
        end

        def visit_if(node)
          @conditional_depth += 1
          super
        ensure
          @conditional_depth -= 1
        end

        def visit_unless(node)
          @conditional_depth += 1
          super
        ensure
          @conditional_depth -= 1
        end

        def visit_case(node)
          @conditional_depth += 1
          super
        ensure
          @conditional_depth -= 1
        end

        private

        def conditional?
          @conditional_depth > 0
        end

        # The lexical scopes at the current point, innermost first.
        # Each entry of the nesting stack is a single lexical scope, so
        # the compact `class A::B` form contributes exactly one scope
        # while the nested form contributes one scope per level.
        def current_scopes
          (1..@nesting.length)
            .map { |length| @nesting.first(length).flatten }
            .reverse
        end

        def add_reference(segments, absolute, location)
          @references << Reference.new(
            segments: segments,
            absolute: absolute,
            scopes: current_scopes,
            file: file,
            line: location.start_line
          )
        end

        # Returns [segments, absolute] for a static constant path, or
        # nil when the node is not a static constant path.
        def constant_path(node)
          case node
          when ConstRef
            [[node.constant.value.to_sym], false]
          when VarRef
            [[node.value.value.to_sym], false] if node.value.is_a?(Const)
          when ConstPathRef
            parent = constant_path(node.parent)
            [parent[0] + [node.constant.value.to_sym], parent[1]] if parent
          when TopConstRef
            [[node.constant.value.to_sym], true]
          end
        end

        def call_parts(arguments)
          case arguments
          when Args
            arguments.parts
          when ArgParen
            arguments.arguments.parts if arguments.arguments.is_a?(Args)
          end
        end

        def handle_include(parts, location)
          parts.each do |part|
            segments, absolute = constant_path(part)

            if segments
              add_reference(segments, absolute, part.location)
              @includes << Include.new(
                cref: @nesting.flatten,
                segments: segments,
                absolute: absolute,
                scopes: current_scopes,
                file: file,
                line: location.start_line
              )
            else
              @dynamic_consts << location.start_line
            end
          end
        end
      end

      # All constant references collected so far.
      attr_reader :references

      def initialize
        @definitions = Hash.new { |hash, key| hash[key] = [] }
        @deferred = []
        @includes = []
        @references = []
        @const_missing = []
        @dynamic_consts = []
        @conditional_requires = []
        @finalized = false
      end

      # Parses and indexes the given source code. The +file+ argument
      # is only used for reporting locations.
      def index_source(source, file: "(source)")
        collector = Collector.new(file)
        SyntaxTree.parse(source).accept(collector)

        collector.definitions.each { |definition| add_definition(definition) }
        @deferred.concat(collector.deferred.map { |entry| [file] + entry })
        @includes.concat(collector.includes)
        @references.concat(collector.references)
        @const_missing.concat(
          collector.const_missing.map { |line| [file, line] }
        )
        @dynamic_consts.concat(
          collector.dynamic_consts.map { |line| [file, line] }
        )
        @conditional_requires.concat(
          collector.conditional_requires.map { |line| [file, line] }
        )

        @finalized = false
        self
      end

      # Parses and indexes the given file.
      def index_file(filepath)
        index_source(SyntaxTree.read(filepath), file: filepath)
      end

      # All definitions collected so far, as a hash from
      # fully-qualified paths (arrays of symbols) to lists of
      # Definition objects.
      def definitions
        finalize
        @definitions
      end

      # Resolves a single constant reference. Returns a Resolution
      # that contains the definitions the reference may point to, the
      # full lookup path, and any remaining sources of uncertainty.
      def resolve(reference)
        finalize

        steps = []
        reasons = []
        path =
          resolve_path(
            reference.segments,
            reference.absolute?,
            reference.scopes,
            steps,
            reasons
          )

        found = path ? @definitions[path] : []

        if found.empty?
          @const_missing.each do |file, line|
            reasons << "const_missing is defined at #{file}:#{line}; " \
              "it may provide this constant at runtime"
          end

          @dynamic_consts.each do |file, line|
            reasons << "a dynamic constant definition (const_set) at " \
              "#{file}:#{line} may provide this constant"
          end

          @conditional_requires.each do |file, line|
            reasons << "a conditional require at #{file}:#{line} may " \
              "load a definition of this constant"
          end
        else
          conditional = found.select(&:conditional?)
          unless conditional.empty?
            locations =
              conditional.map { |defn| "#{defn.file}:#{defn.line}" }.join(", ")
            reasons << "defined under a conditional at #{locations}; " \
              "it may not exist at runtime"
          end

          if found.count { |defn| defn.kind == :constant } > 1
            reasons << "multiple definitions of #{path.join("::")}; " \
              "the runtime value depends on load order"
          end
        end

        Resolution.new(
          reference: reference,
          steps: steps,
          reasons: reasons.uniq,
          definitions: found
        )
      end

      # Resolves every reference collected so far.
      def resolve_all
        references.map { |reference| resolve(reference) }
      end

      private

      def add_definition(definition)
        @definitions[definition.path] << definition
      end

      # Definitions made through an explicit path (A::B = 1) can only
      # be placed once the direct definitions are known, so they are
      # resolved here. A couple of passes allow them to depend on each
      # other. Anything left over is treated as dynamic.
      def finalize
        return if @finalized

        @finalized = true

        2.times do
          break if @deferred.empty?

          remaining = []
          @deferred.each do |entry|
            file, segments, absolute, scopes, name, line, conditional = entry
            parent = resolve_path(segments, absolute, scopes, [], [])

            if parent
              add_definition(
                Definition.new(
                  path: parent + [name],
                  kind: :constant,
                  file: file,
                  line: line,
                  conditional: conditional
                )
              )
            else
              remaining << entry
            end
          end

          break if remaining.length == @deferred.length

          @deferred = remaining
        end

        @deferred.each { |entry| @dynamic_consts << [entry[0], entry[5]] }
        @deferred = []
      end

      # Resolves a constant path to a fully-qualified path (an array
      # of symbols), recording every step of the lookup. Returns nil
      # when the path cannot be resolved statically. The +visited+ set
      # is shared with any enclosing ancestor expansion so that cyclic
      # includes or superclasses cannot cause infinite recursion.
      def resolve_path(
        segments,
        absolute,
        scopes,
        steps,
        reasons,
        visited = nil
      )
        first, *rest = segments
        found = nil

        if absolute
          found = [first] if @definitions.key?([first])
          steps << Step.new(
            scope: [],
            segment: first,
            kind: :toplevel,
            found: !found.nil?
          )
        else
          # 1. Lexical scopes, innermost first.
          scopes.each do |scope|
            candidate = scope + [first]
            hit = @definitions.key?(candidate)
            steps << Step.new(
              scope: scope,
              segment: first,
              kind: :lexical,
              found: hit
            )

            if hit
              found = candidate
              break
            end
          end

          # 2. The ancestors of the innermost lexical scope: included
          # modules and the superclass chain.
          cref = scopes.first
          if found.nil? && cref && !cref.empty?
            ancestors_of(cref, reasons, visited || {}).each do |ancestor|
              candidate = ancestor + [first]
              hit = @definitions.key?(candidate)
              steps << Step.new(
                scope: ancestor,
                segment: first,
                kind: :ancestor,
                found: hit
              )

              if hit
                found = candidate
                break
              end
            end
          end

          # 3. The top level.
          if found.nil?
            hit = @definitions.key?([first])
            steps << Step.new(
              scope: [],
              segment: first,
              kind: :toplevel,
              found: hit
            )
            found = [first] if hit
          end
        end

        return nil unless found

        # Each remaining segment is looked up inside the namespace
        # found for the previous segment, including its ancestors.
        rest.each do |segment|
          base = found
          found = nil

          ancestors_of(base, reasons, visited || {}).uniq.each do |namespace|
            candidate = namespace + [segment]
            hit = @definitions.key?(candidate)
            steps << Step.new(
              scope: namespace,
              segment: segment,
              kind: :qualified,
              found: hit
            )

            if hit
              found = candidate
              break
            end
          end

          if found.nil?
            # Every class chain ends at Object, and modules fall back
            # to Object as well, so the top level is the last resort.
            hit = @definitions.key?([segment])
            steps << Step.new(
              scope: [],
              segment: segment,
              kind: :toplevel,
              found: hit
            )
            found = [segment] if hit
          end

          break unless found
        end

        found
      end

      # The ancestors of the given namespace: itself, included modules
      # (last included first), and the superclass chain.
      def ancestors_of(path, reasons, visited)
        return [path] if path.empty? || visited[path]

        visited[path] = true
        result = [path]

        @includes
          .select { |include| include.cref == path }
          .reverse_each do |include|
            included =
              resolve_path(
                include.segments,
                include.absolute?,
                include.scopes,
                [],
                reasons,
                visited
              )

            if included
              result.concat(ancestors_of(included, reasons, visited))
            else
              reasons << "included module #{include.segments.join("::")} " \
                "at #{include.file}:#{include.line} could not be resolved"
            end
          end

        definition = @definitions[path].find { |defn| defn.kind == :class }
        if definition
          case definition.superclass
          when :dynamic
            reasons << "#{path.join("::")} has a non-constant " \
              "superclass; its ancestors are unknown"
          when nil
            # No superclass clause: the chain continues at Object,
            # whose constants are the top-level ones checked by the
            # caller.
          else
            segments, absolute, scopes = definition.superclass
            superclass =
              resolve_path(segments, absolute, scopes, [], reasons, visited)

            if superclass
              result.concat(ancestors_of(superclass, reasons, visited))
            else
              reasons << "superclass #{segments.join("::")} of " \
                "#{path.join("::")} could not be resolved"
            end
          end
        end

        result
      end
    end
  end
end
