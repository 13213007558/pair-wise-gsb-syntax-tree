# frozen_string_literal: true

module SyntaxTree
  module Index
    class ConstantReference
      attr_reader(:nesting, :path, :rooted, :usage, :conditional, :location)

      def initialize(nesting, path, rooted, usage, conditional, location)
        @nesting = nesting
        @path = path
        @rooted = rooted
        @usage = usage
        @conditional = conditional
        @location = location
      end
    end

    class ModuleInclusion
      attr_reader :nesting, :path, :rooted, :kind, :location

      def initialize(nesting, path, rooted, kind, location)
        @nesting = nesting
        @path = path
        @rooted = rooted
        @kind = kind
        @location = location
      end
    end

    class Uncertainty
      attr_reader :nesting, :reason, :constant, :location

      def initialize(nesting, reason, constant, location)
        @nesting = nesting
        @reason = reason
        @constant = constant
        @location = location
      end
    end

    class DefinitionRecord
      attr_reader :index, :kind, :path, :entry, :conditional

      def initialize(index, kind, path, entry, conditional)
        @index = index
        @kind = kind
        @path = path
        @entry = entry
        @conditional = conditional
      end
    end

    class ConstantResolution
      attr_reader :reference, :definitions, :lookup_path, :uncertainties

      def initialize(reference, definitions, lookup_path, uncertainties)
        @reference = reference
        @definitions = definitions
        @lookup_path = lookup_path
        @uncertainties = uncertainties
      end

      def certain?
        uncertainties.empty?
      end
    end

    class ScopeDeclaration
      attr_reader(
        :scope_id,
        :parent_scope_id,
        :name,
        :path,
        :rooted,
        :kind,
        :superclass,
        :superclass_rooted,
        :location,
        :conditional
      )

      def initialize(
        scope_id,
        parent_scope_id,
        name,
        path,
        rooted,
        kind,
        superclass,
        superclass_rooted,
        location,
        conditional
      )
        @scope_id = scope_id
        @parent_scope_id = parent_scope_id
        @name = name
        @path = path
        @rooted = rooted
        @kind = kind
        @superclass = superclass
        @superclass_rooted = superclass_rooted
        @location = location
        @conditional = conditional
      end
    end

    class StaticConstantDeclaration
      attr_reader(:scope_id, :name, :path, :rooted, :location, :conditional)

      def initialize(scope_id, name, path, rooted, location, conditional)
        @scope_id = scope_id
        @name = name
        @path = path
        @rooted = rooted
        @location = location
        @conditional = conditional
      end
    end

    class StaticIndex
      attr_reader(
        :scope_declarations,
        :constant_declarations,
        :scopes,
        :definitions,
        :references,
        :inclusions,
        :uncertainties
      )

      def initialize(
        scope_declarations,
        constant_declarations,
        scopes,
        definitions,
        references,
        inclusions,
        uncertainties
      )
        @scope_declarations = scope_declarations
        @constant_declarations = constant_declarations
        @scopes = scopes
        @definitions = definitions
        @references = references
        @inclusions = inclusions
        @uncertainties = uncertainties
      end
    end

    class StaticCollector < Visitor
      class Scope
        attr_reader :id, :parent_id, :lexical_chain, :kind

        def initialize(id, parent_id, lexical_chain, kind = :normal)
          @id = id
          @parent_id = parent_id
          @lexical_chain = lexical_chain
          @kind = kind
        end
      end

      attr_reader(
        :scope_declarations,
        :constant_declarations,
        :definitions,
        :references,
        :inclusions,
        :uncertainties,
        :scopes
      )

      def initialize
        @scope_declarations = []
        @constant_declarations = []
        @definitions = []
        @references = []
        @inclusions = []
        @uncertainties = []
        @scopes = {}
        @scope_stack = []
        @conditional_depth = 0
        @next_scope_id = 0
      end

      def index(source)
        SyntaxTree.parse(source).accept(self)
        StaticIndex.new(
          scope_declarations,
          constant_declarations,
          scopes,
          definitions,
          references,
          inclusions,
          uncertainties
        )
      end

      def visit_program(node)
        visit_child_nodes(node)
      end

      def visit_class(node)
        visit_declaration(node, node.superclass, true)
      end

      def visit_module(node)
        visit_declaration(node, nil, false)
      end

      def visit_assign(node)
        target = node.target

        case target
        when VarField
          if target.value.is_a?(Const)
            add_constant_definition(target.value)
          else
            visit(target)
          end
        when TopConstField
          add_constant_definition(target.constant, [], true, conditional?)
        when ConstPathField
          path, rooted = constant_path(target)
          if path || rooted
            add_constant_definition(target.constant, path, rooted, conditional?)
          else
            add_uncertainty(:dynamic_constant, nil, target)
          end
        else
          visit(target)
        end

        visit(node.value)
      end

      def visit_command(node)
        message = node.message.value

        case message
        when "include", "prepend"
          add_inclusions(node, message.to_sym)
          return
        when "const_missing"
          add_uncertainty(:const_missing, nil, node)
        when "autoload"
          add_uncertainty(:conditional_load, autoload_constant(node), node)
        when "require", "require_relative", "load"
          add_uncertainty(:conditional_load, nil, node) if conditional?
        end

        visit_child_nodes(node)
      end

      def visit_command_call(node)
        if node.message.value == "const_set"
          add_uncertainty(:const_set, const_set_name(node), node)
          visit(node.receiver)
          visit_arguments(node.arguments)
          return
        end

        visit_child_nodes(node)
      end

      def visit_call(node)
        if node.message.value == "const_set"
          add_uncertainty(:const_set, const_set_name(node), node)
          visit(node.receiver)
          visit_arguments(node.arguments)
          return
        end

        visit_child_nodes(node)
      end

      def visit_def(node)
        if node.name.value == "const_missing"
          add_uncertainty(:const_missing, nil, node)
        end

        visit_child_nodes(node)
      end

      def visit_sclass(node)
        visit(node.target)

        if self_target?(node.target)
          push_singleton_scope
          visit(node.bodystmt)
          @scope_stack.pop
        else
          visit(node.bodystmt)
        end
      end

      def visit_opassign(node)
        target = node.target

        if target.is_a?(VarField) && target.value.is_a?(Const)
          add_reference_parts(
            node,
            [target.value.value.to_sym],
            false,
            :reference
          )
          add_constant_definition(target.value, nil, nil, true)
          visit(node.value)
        else
          visit_child_nodes(node)
        end
      end

      def visit_massign(node)
        visit_child_nodes(node)
      end

      def visit_var_ref(node)
        if node.value.is_a?(Const)
          add_reference_parts(
            node,
            [node.value.value.to_sym],
            false,
            :reference
          )
        end
      end

      def visit_const_path_ref(node)
        path, rooted = constant_path(node)
        add_reference_parts(
          node,
          path + [node.constant.value.to_sym],
          rooted,
          :reference
        )
        visit(node.parent)
      end

      def visit_top_const_ref(node)
        add_reference_parts(
          node,
          [node.constant.value.to_sym],
          true,
          :reference
        )
      end

      def visit_if(node)
        visit_conditional(node.statements)
        visit(node.predicate)
        visit_conditional(node.consequent)
      end
      alias visit_elsif visit_if

      def visit_unless(node)
        visit_conditional(node.statements)
        visit(node.predicate)
        visit_conditional(node.consequent)
      end

      def visit_case(node)
        visit(node.predicate)
        visit_conditional(node.cons)
      end

      def visit_when(node)
        visit_conditional(node.statements)
        visit(node.arguments)
      end

      def visit_rescue(node)
        visit(node.exception)
        visit_conditional(node.statements)
        visit(node.consequent)
      end

      def visit_ifop(node)
        visit(node.predicate)
        with_conditional { visit(node.truthy) }
        with_conditional { visit(node.falsy) }
      end

      def visit_binary(node)
        visit(node.left)

        if %w[&& || and or].include?(node.operator)
          with_conditional { visit(node.right) }
        else
          visit(node.right)
        end
      end

      private

      def visit_declaration(node, superclass_node, is_class)
        path, rooted = declaration_path(node.constant)
        name = declaration_name(node.constant)
        location = location_for(node)
        parent_scope_id = declaration_parent_id
        superclass = nil
        superclass_rooted = false

        if is_class && superclass_node
          superclass_reference, superclass, superclass_rooted =
            add_reference_node(superclass_node, :superclass)
          superclass = [] unless superclass_reference
        end

        if path
          add_reference_parts(
            node.constant,
            path + [name],
            rooted || false,
            :declaration
          )
        end

        scope = push_scope
        declaration =
          ScopeDeclaration.new(
            scope.id,
            parent_scope_id == :root ? nil : parent_scope_id,
            name,
            path,
            rooted || false,
            is_class ? :class : :module,
            superclass,
            superclass_rooted || false,
            location,
            conditional?
          )
        scope_declarations << declaration
        definitions << declaration

        visit(node.bodystmt)
        @scope_stack.pop
      end

      def push_scope(kind = :normal)
        id = @next_scope_id
        @next_scope_id += 1
        parent = current_scope
        chain = (parent ? parent.lexical_chain.dup : [])
        chain << [id, kind] unless kind == :singleton
        scope = Scope.new(id, parent&.id, chain, kind)
        @scopes[id] = scope
        @scope_stack << scope
        scope
      end

      def declaration_parent_id
        current_scope ? current_scope.id : :root
      end

      def push_singleton_scope
        id = @next_scope_id
        @next_scope_id += 1
        parent = current_scope
        chain = parent ? parent.lexical_chain.dup : []
        scope = Scope.new(id, parent&.id, chain, :singleton)
        @scopes[id] = scope
        @scope_stack << scope
        scope
      end

      def current_scope
        @scope_stack.last
      end

      def current_nesting
        current_scope ? current_scope.lexical_chain.map(&:first) : []
      end

      def conditional?
        @conditional_depth > 0
      end

      def with_conditional
        @conditional_depth += 1
        yield
      ensure
        @conditional_depth -= 1
      end

      def visit_conditional(node)
        return unless node

        with_conditional { visit(node) }
      end

      def add_reference_parts(node, full_path, rooted, usage)
        references << ConstantReference.new(
          current_nesting,
          full_path,
          rooted || false,
          usage,
          conditional?,
          location_for(reference_constant(node))
        )

        [references.last, full_path, rooted || false]
      end

      def add_reference_node(node, usage)
        path, rooted = reference_path(node)
        return nil, nil, false unless path

        add_reference_parts(node, path, rooted, usage)
      end

      def add_constant_definition(
        constant,
        parent_path = nil,
        rooted = false,
        conditional = conditional?
      )
        location = location_for(constant)
        name = constant.value.to_sym
        declaration =
          StaticConstantDeclaration.new(
            current_scope&.id,
            name,
            parent_path,
            rooted,
            location,
            conditional
          )

        constant_declarations << declaration
        definitions << declaration
        declaration
      end

      def add_inclusions(node, kind)
        arguments(node).each do |argument|
          path, rooted = reference_path(argument)
          unless path
            add_uncertainty(:dynamic_inclusion, nil, argument)
            next
          end

          add_reference_parts(argument, path, rooted || false, kind)
          inclusions << ModuleInclusion.new(
            current_nesting,
            path,
            rooted || false,
            kind,
            location_for(argument)
          )
        end
      end

      def add_uncertainty(reason, constant = nil, node = nil)
        uncertainties << Uncertainty.new(
          current_nesting,
          reason,
          constant,
          node ? location_for(node) : nil
        )
      end

      def arguments(node)
        argument_parts(node.arguments)
      end

      def argument_parts(arguments)
        return [] unless arguments
        return arguments.parts if arguments.respond_to?(:parts)

        argument_parts(arguments.arguments) if arguments.respond_to?(:arguments)
      end

      def visit_arguments(arguments)
        argument_parts(arguments).each { |argument| visit(argument) }
      end

      def autoload_constant(node)
        arguments(node).first
      end

      def const_set_name(node)
        argument = arguments(node).first
        return nil unless argument.respond_to?(:value)

        value = argument.value
        value.respond_to?(:value) ? value.value.to_sym : value
      end

      def declaration_path(node)
        case node
        when ConstRef
          [nil, false]
        when TopConstRef
          [[], true]
        when ConstPathRef
          path, rooted = reference_path(node.parent)
          path ? [path, rooted] : [nil, false]
        end
      end

      def declaration_name(node)
        case node
        when ConstRef
          node.constant.value.to_sym
        when TopConstRef
          node.constant.value.to_sym
        when ConstPathRef
          node.constant.value.to_sym
        end
      end

      def reference_path(node)
        case node
        when VarRef
          [[node.value.value.to_sym], false] if node.value.is_a?(Const)
        when ConstRef
          [[node.constant.value.to_sym], false]
        when TopConstRef
          [[], true]
        when ConstPathRef
          parent = reference_path(node.parent)
          return nil unless parent

          parent_path, parent_rooted = parent
          [parent_path + [node.constant.value.to_sym], parent_rooted]
        end
      end

      def constant_path(node)
        reference_path(node.parent)
      end

      def reference_constant(node)
        case node
        when VarRef
          node.value
        when VarField
          node.value
        when ConstRef
          node.constant
        when TopConstRef
          node.constant
        when ConstPathRef
          node.constant
        when Const
          node
        else
          raise NotImplementedError, node.class.name
        end
      end

      def self_target?(node)
        node.is_a?(VarRef) && node.value.is_a?(Kw) && node.value.value == "self"
      end

      def location_for(node)
        Location.new(node.location.start_line, node.location.start_column)
      end
    end

    class StaticConstantResolver
      def initialize(indexes)
        @indexes = indexes
        @scope_paths = {}
        @known_scope_paths = [[]]
        @nodes = Hash.new { |hash, path| hash[path] = new_node }
      end

      def resolve
        normalize_scopes
        build_scope_paths
        register_scopes
        register_constants
        build_inclusions
        resolve_references
      end

      private

      def new_node
        {
          scopes: [],
          constants: Hash.new { |hash, name| hash[name] = [] },
          includes: [],
          superclasses: [],
          unknown_includes: false,
          unknown_superclass: false,
          kinds: Hash.new(0)
        }
      end

      def build_scope_paths
        loop do
          previous_paths = @scope_paths.dup
          previous_known = @known_scope_paths.dup

          @indexes.each_with_index do |index, source_index|
            index.scope_declarations.each do |declaration|
              paths =
                if declaration.path.nil?
                  direct_paths(declaration)
                elsif declaration.rooted
                  [[declaration.path + [declaration.name], declaration.kind]]
                else
                  explicit_paths(declaration)
                end

              update_scope_paths(
                scope_key(source_index, declaration.scope_id),
                paths,
                declaration.kind
              )
            end
          end

          if @scope_paths == previous_paths &&
               @known_scope_paths == previous_known
            return
          end
        end
      end

      def direct_paths(declaration)
        parent_paths(declaration)
          .map do |path, kind|
            next if kind == :singleton

            [path + [declaration.name], :normal]
          end
          .compact
      end

      def explicit_paths(declaration)
        source_index = declaration_source_index(declaration)
        parent_key =
          scope_key(source_index, declaration.parent_scope_id || :root)

        resolve_namespace_path(
          parent_key,
          declaration.path,
          declaration.rooted
        ).map { |path| [path + [declaration.name], :normal] }
      end

      def parent_paths(declaration)
        parent_id =
          declaration.parent_scope_id.nil? ? :root : declaration.parent_scope_id
        source_index = declaration_source_index(declaration)
        @scope_paths.fetch(scope_key(source_index, parent_id), [[[], :normal]])
      end

      def declaration_source_index(declaration)
        @indexes.index do |index|
          index.scope_declarations.include?(declaration)
        end
      end

      def update_scope_paths(scope_id, paths, _kind)
        existing = @scope_paths[scope_id] || []
        merged = existing + paths
        @scope_paths[scope_id] = merged.uniq
        paths.each do |path, _path_kind|
          @known_scope_paths << path unless @known_scope_paths.include?(path)
        end
      end

      def register_scopes
        each_scope_record do |source_index, declaration, paths|
          paths.each do |path, _kind|
            node = @nodes[path]
            node[:scopes] << DefinitionRecord.new(
              source_index,
              declaration.kind,
              path,
              declaration,
              declaration.conditional
            )
            node[:kinds][declaration.kind] += 1
          end
        end
      end

      def register_constants
        @indexes.each_with_index do |index, source_index|
          index.constant_declarations.each do |declaration|
            paths = constant_target_paths(declaration, source_index)

            paths.each do |path, _kind|
              target_path = path + [declaration.name]
              parent_path = path
              record =
                DefinitionRecord.new(
                  source_index,
                  :constant,
                  target_path,
                  declaration,
                  declaration.conditional
                )
              @nodes[parent_path][:constants][declaration.name] << record
            end
          end
        end
      end

      def constant_target_paths(declaration, source_index)
        if declaration.path.nil?
          scope_id = declaration.scope_id || :root
          return(
            @scope_paths
              .fetch(scope_key(source_index, scope_id), [])
              .reject { |_path, kind| kind == :singleton }
          )
        end

        if declaration.rooted
          if namespace_path?(declaration.path)
            return [[declaration.path, :root]]
          end

          return []
        end

        resolve_namespace_path(
          scope_key(source_index, declaration.scope_id),
          declaration.path,
          false
        )
      end

      def build_inclusions
        loop do
          previous_includes = edge_signature(:includes)
          previous_superclasses = edge_signature(:superclasses)

          @indexes.each_with_index do |index, source_index|
            register_inclusions(index, source_index)
            register_superclasses(index, source_index)
          end

          if previous_includes == edge_signature(:includes) &&
               previous_superclasses == edge_signature(:superclasses)
            break
          end
        end
      end

      def edge_signature(kind)
        @nodes.values.map { |node| node[kind] }
      end

      def register_superclasses(index, source_index)
        index.scope_declarations.each do |declaration|
          next unless declaration.kind == :class

          paths =
            if declaration.superclass
              resolve_reference_path(
                scope_key(source_index, declaration.parent_scope_id || :root),
                declaration.superclass,
                declaration.superclass_rooted
              )
            else
              nil
            end

          target_paths =
            @scope_paths[scope_key(source_index, declaration.scope_id)] || []
          target_paths.each do |target_path, _kind|
            if paths.nil?
              next
            elsif paths.empty?
              @nodes[target_path][:unknown_superclass] = true
            else
              paths.each do |superclass_path|
                @nodes[target_path][:superclasses] << superclass_path
              end
            end
          end
        end
      end

      def register_inclusions(index, source_index)
        index.inclusions.each do |inclusion|
          scope_id = scope_key(source_index, inclusion.nesting.last || :root)
          paths =
            resolve_reference_path(scope_id, inclusion.path, inclusion.rooted)
          target_paths = @scope_paths[scope_id] || []
          target_paths.each do |target_path, kind|
            if paths.empty? || kind == :singleton
              @nodes[target_path][:unknown_includes] = true
            else
              paths.each do |included_path|
                @nodes[target_path][:includes] << {
                  path: included_path,
                  kind: inclusion.kind
                }
              end
            end
          end
        end
      end

      def resolve_reference_path(scope_id, path, rooted)
        if rooted
          rooted_path(path[0..-2]).map { |base_path| base_path + [path.last] }
        elsif path.length == 1
          lexical_scopes(scope_id)
            .flat_map do |candidate_scope_id|
              lexical_ancestor_paths(candidate_scope_id).map do |base_path|
                base_path + path
              end
            end
            .uniq
            .select { |target_path| namespace_path?(target_path) } +
            (namespace_path?(path) ? [path] : [])
        else
          lexical_scopes(scope_id)
            .flat_map do |candidate_scope_id|
              lexical_ancestor_paths(candidate_scope_id).flat_map do |base_path|
                parent_path = follow_qualified_path(base_path, path[0..-2])
                next [] unless parent_path

                [parent_path + [path.last]]
              end
            end
            .uniq
            .select { |target_path| namespace_path?(target_path) }
        end
      end

      def each_scope_record
        @indexes.each_with_index do |index, source_index|
          index.scope_declarations.each do |declaration|
            paths =
              @scope_paths[scope_key(source_index, declaration.scope_id)] || []
            yield(source_index, declaration, paths)
          end
        end
      end

      def resolve_namespace_path(scope_id, path, rooted)
        return [path] if path.empty?
        return rooted_path(path) if rooted

        lexical_scopes(scope_id)
          .flat_map do |candidate_scope_id|
            lexical_ancestor_paths(candidate_scope_id).map do |base_path|
              follow_qualified_path(base_path, path)
            end
          end
          .compact
          .uniq
      end

      def rooted_path(path)
        path.reduce([[]]) do |paths, name|
          paths.flat_map do |base_path|
            next_path = base_path + [name]
            namespace_path?(next_path) ? [next_path] : []
          end
        end
      end

      def follow_qualified_path(base_path, path)
        path.reduce(base_path) do |current_path, name|
          next_path = current_path + [name]
          return nil unless namespace_path?(next_path)

          next_path
        end
      end

      def namespace_path?(path)
        path.empty? || @known_scope_paths.include?(path) || @nodes.key?(path)
      end

      def lexical_scopes(scope_id)
        return [[:root]] if scope_id.nil?
        if scope_id.is_a?(Array) && scope_id[0] == :scope
          source_index = scope_id[1]
          local_scope_id = scope_id[2]
          root_key = root_scope_key(source_index)
          return [root_key] if local_scope_id == :root

          scope = @indexes[source_index].scopes[local_scope_id]
          return [root_key] unless scope

          return(
            scope
              .lexical_chain
              .map(&:first)
              .reverse
              .map { |id| scope_key(source_index, id) }
          )
        end

        [[:root]]
      end

      def lexical_scope_paths(scope_id)
        lexical_scopes(scope_id).flat_map do |candidate_scope_id|
          (@scope_paths[candidate_scope_id] || []).map do |path, kind|
            [path, kind, candidate_scope_id]
          end
        end
      end

      def lexical_ancestor_paths(scope_id)
        lexical_scope_paths(scope_id)
          .flat_map do |path, kind, candidate_scope_id|
            if kind == :singleton
              []
            else
              ancestors_for(path)
            end
          end
          .uniq
      end

      def ancestors_for(path, visiting = [])
        return [] if visiting.include?(path)

        visiting = visiting + [path]
        node = @nodes[path]
        chain = [path]

        includes = node[:includes]
        prepends = includes.select { |event| event[:kind] == :prepend }
        regular_includes = includes.reject { |event| event[:kind] == :prepend }

        prepend_paths(prepends, visiting).each do |included_path|
          chain << included_path unless chain.include?(included_path)
        end

        include_paths(regular_includes, visiting).each do |included_path|
          chain << included_path unless chain.include?(included_path)
        end

        superclass_chains(path, node, visiting).each do |ancestor_path|
          chain << ancestor_path unless chain.include?(ancestor_path)
        end

        chain
      end

      def normalize_scopes
        @indexes.each_with_index do |_index, source_index|
          @scope_paths[scope_key(source_index, :root)] = [[[], :normal]]

          _index.scopes.each_key do |scope_id|
            @scope_paths[scope_key(source_index, scope_id)] ||= []
          end
        end
      end

      def scope_key(source_index, scope_id)
        [:scope, source_index, scope_id]
      end

      def root_scope_key(source_index)
        scope_key(source_index, :root)
      end

      def prepend_paths(events, visiting)
        events.reverse.flat_map do |event|
          next [] if visiting.include?(event[:path])

          ancestors_for(event[:path], visiting)
        end
      end

      def include_paths(events, visiting)
        events.reverse.flat_map do |event|
          next [] if visiting.include?(event[:path])

          ancestors_for(event[:path], visiting)
        end
      end

      def superclass_chains(_path, node, visiting)
        node[:superclasses].flat_map do |superclass_path|
          next [] if visiting.include?(superclass_path)

          ancestors_for(superclass_path, visiting)
        end
      end

      def resolve_references
        results = []

        @indexes.each_with_index do |index, source_index|
          index.references.each do |reference|
            results << resolve_reference(index, source_index, reference)
          end
        end

        results
      end

      def resolve_reference(index, source_index, reference)
        candidates, lookup_path =
          if reference.rooted
            resolve_rooted_reference(reference)
          elsif reference.path.length == 1
            resolve_bare_reference(reference, source_index)
          else
            resolve_qualified_reference(reference, source_index)
          end

        records = candidates.uniq
        uncertainties =
          uncertainties_for(index, reference, records, lookup_path)

        ConstantResolution.new(reference, records, lookup_path, uncertainties)
      end

      def resolve_bare_reference(reference, source_index)
        lookup_path = []
        records = []
        name = reference.path.first
        checked_top = false

        reference_scope_keys(source_index, reference).each do |scope_id|
          if scope_id == root_scope_key(source_index)
            next if checked_top

            paths = [[]]
            checked_top = true
          else
            paths = lexical_ancestor_paths(scope_id)
          end

          paths.uniq.each do |path|
            lookup_path << [:lexical, path]
            found = definitions_at(path, name)
            next if found.empty?

            records.concat(found)
            break
          end

          break if records.any?
        end
        return records.uniq, lookup_path.uniq if records.any?

        unless checked_top
          lookup_path << [:top, []]
          records.concat(definitions_at([], name))
        end
        [records.uniq, lookup_path.uniq]
      end

      def resolve_qualified_reference(reference, source_index)
        path = reference.path
        name = path.last
        lookup_path = []
        records = []

        reference_scope_keys(source_index, reference).each do |scope_id|
          lexical_ancestor_paths(scope_id).each do |base_path|
            resolved = follow_qualified_path(base_path, path[0..-2])
            next unless resolved

            lookup_path << [:lexical, resolved]
            found = definitions_at(resolved, name)
            next if found.empty?

            records.concat(found)
            break
          end
          break if records.any?
        end

        [records.uniq, lookup_path.uniq]
      end

      def reference_scope_keys(source_index, reference)
        keys =
          reference.nesting.reverse.map do |scope_id|
            scope_key(source_index, scope_id)
          end
        keys << root_scope_key(source_index)
        keys.uniq
      end

      def resolve_rooted_reference(reference)
        name = reference.path.last
        parent_path = reference.path[0..-2]
        resolved = rooted_path(parent_path)
        lookup_path = resolved.map { |path| [:root, path] }
        records = resolved.flat_map { |path| definitions_at(path, name) }
        [records.uniq, lookup_path]
      end

      def definitions_at(path, name)
        target_path = path + [name]
        scope_records = @nodes[target_path][:scopes] if @nodes.key?(target_path)
        constant_records =
          @nodes.key?(path) ? @nodes[path][:constants][name] : []
        Array(scope_records) + constant_records
      end

      def uncertainties_for(index, reference, records, lookup_path)
        reasons = []

        lookup_path.each do |_kind, path|
          node = @nodes[path]
          reasons << :unknown_include if node && node[:unknown_includes]
          reasons << :unknown_superclass if node && node[:unknown_superclass]
        end
        reasons << :multiple_definitions if records.map(&:entry).uniq.length > 1
        reasons << :conditional_definition if records.any?(&:conditional)

        reasons << :unresolved if records.empty?
        reasons.concat(static_uncertainty_reasons(index, reference))

        reasons.uniq.map do |reason|
          Uncertainty.new(
            reference.nesting,
            reason,
            reference.path.last,
            reference.location
          )
        end
      end

      def static_uncertainty_reasons(index, reference)
        index
          .uncertainties
          .select { |uncertainty| uncertainty_applies?(uncertainty, reference) }
          .map(&:reason)
      end

      def uncertainty_applies?(uncertainty, reference)
        if uncertainty.constant.respond_to?(:value)
          value = uncertainty.constant.value
          value = value.value if value.respond_to?(:value)
          return false unless value.to_sym == reference.path.last
        elsif uncertainty.constant.is_a?(Symbol)
          return false unless uncertainty.constant == reference.path.last
        end

        uncertainty.nesting.empty? ||
          reference
            .nesting
            .each_cons(uncertainty.nesting.length)
            .any? { |part| part == uncertainty.nesting }
      end
    end
  end
end
