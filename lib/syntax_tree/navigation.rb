# frozen_string_literal: true

module SyntaxTree
  # Static navigation queries built directly from SyntaxTree nodes. The
  # analysis models lexical state at each call site instead of treating every
  # +using+ in a file as globally visible.
  module Navigation
    class Declaration
      attr_reader :path, :node, :superclass_path, :superclass_node

      def initialize(path:, node:, superclass_path: nil, superclass_node: nil)
        @path = path
        @node = node
        @superclass_path = superclass_path
        @superclass_node = superclass_node
      end
    end

    class MethodDeclaration
      attr_reader :path, :name, :node

      def initialize(path:, name:, node:)
        @path = path
        @name = name
        @node = node
      end
    end

    class Refinement
      attr_reader :module_path, :target_path, :methods, :module_node, :node

      def initialize(module_path:, target_path:, module_node:, node:, dynamic_module:)
        @module_path = module_path
        @target_path = target_path
        @module_node = module_node
        @node = node
        @dynamic_module = dynamic_module
        @methods = {}
      end

      def dynamic_module?
        @dynamic_module
      end
    end

    class Basis
      attr_reader :kind, :node, :description

      def initialize(kind:, node: nil, description: nil)
        @kind = kind
        @node = node
        @description = description
      end
    end

    class Candidate
      attr_reader :kind, :name, :path, :node, :basis, :evidence

      def initialize(kind:, name:, path:, node:, basis:, evidence: [])
        @kind = kind
        @name = name
        @path = path
        @node = node
        @basis = basis
        @evidence = evidence
      end
    end

    class QueryResult
      attr_reader :call, :receiver_type, :candidates, :unknown, :reasons

      def initialize(call:, receiver_type:, candidates:, unknown:, reasons:)
        @call = call
        @receiver_type = receiver_type
        @candidates = candidates
        @unknown = unknown
        @reasons = reasons
      end

      def resolved?
        !unknown
      end
    end

    class Registry
      CORE_SUPERCLASSES = {
        %i[Object] => %i[BasicObject],
        %i[Integer] => %i[Numeric],
        %i[Float] => %i[Numeric],
        %i[Numeric] => %i[Object],
        %i[String] => %i[Object],
        %i[Symbol] => %i[Object],
        %i[Array] => %i[Object],
        %i[Hash] => %i[Object],
        %i[Regexp] => %i[Object]
      }.freeze

      attr_reader :types, :methods, :refinements, :dynamic_modules, :uncertain_modules

      def initialize
        @types = {}
        @methods = Hash.new { |hash, key| hash[key] = {} }
        @refinements = Hash.new { |hash, key| hash[key] = Hash.new { |targets, path| targets[path] = [] } }
        @dynamic_modules = {}
        @uncertain_modules = {}
      end

      def type(path)
        types[path]
      end

      def dynamic_module?(path)
        dynamic_modules.key?(path)
      end

      def uncertain_module?(path)
        uncertain_modules.key?(path)
      end

      def refinement_blocks(target_path, module_path, before: nil)
        blocks = refinements.dig(target_path, module_path) || []
        return blocks if before.nil?

        blocks.select { |refinement| refinement.node.location.start_char <= before }
      end

      def method_chain(path)
        chain = []
        visited = {}

        while path && !visited.key?(path)
          visited[path] = true
          method = methods[path]
          chain << [path, methods[path]] if method

          path = superclass_of(path)
        end

        chain
      end

      def type_chain(path)
        chain = []
        visited = {}

        while path && !visited.key?(path)
          visited[path] = true
          chain << path
          path = superclass_of(path)
        end

        chain
      end

      private

      def superclass_of(path)
        if types.key?(path)
          types[path].superclass_path
        else
          CORE_SUPERCLASSES[path]
        end
      end
    end

    # Builds the static declaration registry from directly written source.
    class DeclarationCollector
      Frame = Struct.new(:kind, :path, :lexical, :refinement, keyword_init: true)

      attr_reader :registry

      def initialize
        @registry = Registry.new
        @frames = [Frame.new(kind: :root, path: nil, lexical: [])]
      end

      def collect(program)
        collect_statements(program.statements)
        registry
      end

      private

      def current
        @frames.last
      end

      def collect_statements(statements)
        statements.body.each do |node|
          next if node.is_a?(VoidStmt)

          collect_node(node)
        end
      end

      def collect_node(node)
        case node
        when ClassDeclaration
          collect_class(node)
        when ModuleDeclaration
          collect_module(node)
        when DefNode
          collect_def(node)
        when Assign
          collect_assign(node)
        when MethodAddBlock
          collect_method_add_block(node)
        when BodyStmt
          collect_statements(node.statements)
        when Statements
          collect_statements(node)
        else
          collect_children(node)
        end
      end

      def collect_children(node)
        node&.child_nodes&.each { |child| collect_node(child) }
      end

      def collect_class(node)
        relative_path, absolute = declaration_path(node.constant)
        return collect_body_without_frame(node) unless relative_path

        path = absolute ? relative_path : nested_declaration_path(relative_path)
        superclass_path, superclass_node = constant_reference(node.superclass, current.lexical)
        register_type(path, node, superclass_path, superclass_node)

        with_frame(Frame.new(kind: :class, path: path, lexical: current.lexical + [path])) do
          collect_body(node.bodystmt)
        end
      end

      def collect_module(node)
        relative_path, absolute = declaration_path(node.constant)
        return collect_body_without_frame(node) unless relative_path

        path = absolute ? relative_path : nested_declaration_path(relative_path)
        register_type(path, node)

        with_frame(Frame.new(kind: :module, path: path, lexical: current.lexical + [path])) do
          collect_body(node.bodystmt)
        end
      end

      def collect_body_without_frame(node)
        collect_body(node.bodystmt)
      end

      def collect_body(bodystmt)
        case bodystmt
        when BodyStmt
          collect_statements(bodystmt.statements)
          collect_node(bodystmt.rescue_clause) if bodystmt.rescue_clause
          collect_statements(bodystmt.else_clause) if bodystmt.else_clause
          collect_node(bodystmt.ensure_clause) if bodystmt.ensure_clause
        when Statements
          collect_statements(bodystmt)
        else
          collect_node(bodystmt)
        end
      end

      def collect_def(node)
        return collect_def_body(node) unless node.target.nil?

        owner = owner_frame
        if owner
          method = MethodDeclaration.new(path: owner.path, name: node.name.value.to_sym, node: node)
          if owner.kind == :refinement
            owner.refinement.methods[method.name] = method
          else
            registry.methods[owner.path][method.name] = method
          end
        end

        collect_def_body(node)
      end

      def collect_def_body(node)
        collect_body(node.bodystmt) if node.bodystmt
      end

      def owner_frame
        @frames.reverse.find { |frame| frame.kind == :class || frame.kind == :refinement }
      end

      def collect_assign(node)
        dynamic_module = dynamic_module_assignment?(node)
        if dynamic_module
          path = constant_field_path(node.target, current.lexical)
          if path
            register_type(path, node.value.call.receiver)
            registry.dynamic_modules[path] = node
            block = node.value.block

            if block
              frame = Frame.new(kind: :module, path: path, lexical: current.lexical + [path])
              with_frame(frame) { collect_body(block.bodystmt) }
              return
            end
          end
        end

        collect_node(node.value)
      end

      def collect_method_add_block(node)
        target_path = refinement_target(node)
        module_frame = @frames.reverse.find { |frame| frame.kind == :module }

        if target_path && module_frame
          unless target_path == :dynamic
            resolved_target = resolve_path(target_path, module_frame.lexical)
            refinement = Refinement.new(
              module_path: module_frame.path,
              target_path: resolved_target,
              module_node: module_frame.path == :dynamic ? nil : registry.type(module_frame.path)&.node,
              node: node,
              dynamic_module: registry.dynamic_module?(module_frame.path)
            )
            registry.refinements[resolved_target][module_frame.path] << refinement

            frame = Frame.new(
              kind: :refinement,
              path: resolved_target,
              lexical: module_frame.lexical,
              refinement: refinement
            )
            with_frame(frame) { collect_body(node.block.bodystmt) }
            return
          end

          registry.uncertain_modules[module_frame.path] = node if module_frame.path
        end

        collect_node(node.call)
        collect_body(node.block.bodystmt) if node.block
      end

      def refinement_target(node)
        call = node.call
        return nil unless node.block
        return nil unless call.is_a?(CallNode)
        return nil unless call.receiver.nil?
        return nil unless message_name(call.message) == :refine

        arguments = call_arguments(call)
        return nil unless arguments.length == 1

        path, _node = constant_reference(arguments.first, current.lexical)
        path || :dynamic
      end

      def dynamic_module_assignment?(assign)
        value = assign.value
        value.is_a?(MethodAddBlock) && constructor_call?(value.call, "Module")
      end

      def constructor_call?(call, constant_name)
        call.is_a?(CallNode) && message_name(call.message) == :new &&
          receiver_constant(call.receiver) == constant_name
      end

      def receiver_constant(node)
        node = node.value if node.is_a?(VarRef)
        node.is_a?(Const) ? node.value : nil
      end

      def register_type(path, node, superclass_path = nil, superclass_node = nil)
        previous = registry.type(path)
        registry.types[path] = Declaration.new(
          path: path,
          node: node,
          superclass_path: superclass_path || previous&.superclass_path,
          superclass_node: superclass_node || previous&.superclass_node
        )
      end

      def with_frame(frame)
        @frames.push(frame)
        yield
      ensure
        @frames.pop
      end

      def call_arguments(call)
        case call.arguments
        when Args
          call.arguments.parts
        when ArgParen
          call.arguments.arguments.is_a?(Args) ? call.arguments.arguments.parts : []
        else
          []
        end
      end

      def constant_reference(node, lexical)
        case node
        when nil
          [nil, nil]
        when VarRef
          constant_reference(node.value, lexical)
        when Const
          [resolve_path(node.value.to_sym, lexical), node]
        when ConstRef
          constant_reference(node.constant, lexical)
        when TopConstRef
          [[node.constant.value.to_sym], node]
        when ConstPathRef
          parent, root = constant_path_parent(node.parent, lexical)
          parent ? [parent + [node.constant.value.to_sym], node] : [nil, root]
        else
          [nil, node]
        end
      end

      def constant_path_parent(node, lexical)
        case node
        when VarRef
          constant_reference(node, lexical)
        when TopConstRef
          [[node.constant.value.to_sym], node]
        when ConstPathRef
          parent, root = constant_path_parent(node.parent, lexical)
          parent ? [parent + [node.constant.value.to_sym], node] : [nil, root]
        else
          [nil, node]
        end
      end

      def constant_path(node)
        case node
        when ConstRef
          [node.constant.value.to_sym]
        when Const
          [node.value.to_sym]
        when TopConstRef
          [node.constant.value.to_sym]
        when ConstPathRef
          parent, _root = constant_path_parent(node.parent, [])
          parent ? parent + [node.constant.value.to_sym] : nil
        end
      end

      def declaration_path(node)
        case node
        when ConstRef
          [node.constant.value.to_sym, false]
        when Const
          [node.value.to_sym, false]
        when TopConstRef
          [[node.constant.value.to_sym], true]
        when ConstPathRef
          parent, _root = constant_path_parent(node.parent, [])
          parent ? [parent + [node.constant.value.to_sym], node.parent.is_a?(TopConstRef)] : nil
        end
      end

      def nested_declaration_path(relative_path)
        path = Array(relative_path)
        current.lexical.empty? ? path : current.lexical.last + path
      end

      def constant_field_path(node, lexical)
        case node
        when VarField
          node.value.is_a?(Const) ? resolve_path(node.value.value.to_sym, lexical) : nil
        when TopConstField
          [node.constant.value.to_sym]
        when ConstPathField
          parent, _root = constant_path_parent(node.parent, lexical)
          parent ? parent + [node.constant.value.to_sym] : nil
        end
      end

      def resolve_path(name_or_path, lexical)
        path = Array(name_or_path)
        lexical.length.downto(1)
          .map { |index| lexical[index - 1] + path }
          .find { |candidate| registry.types.key?(candidate) } || path
      end

      def message_name(node)
        node == :call ? :call : node.value.to_sym
      rescue NoMethodError
        nil
      end
    end

    # Walks statements in lexical order and snapshots refinement state for
    # each method definition and call node.
    class LexicalAnalyzer
      Frame = Struct.new(
        :kind,
        :path,
        :lexical,
        :active,
        :unknown,
        :locals,
        :using_allowed,
        keyword_init: true
      )

      Activation = Struct.new(:module_path, :position, :node, keyword_init: true)

      attr_reader :records

      def initialize(registry)
        @registry = registry
        @records = {}
        @frames = [
          Frame.new(
            kind: :root,
            path: nil,
            lexical: [],
            active: [],
            unknown: [],
            locals: {},
            using_allowed: true
          )
        ]
      end

      def analyze(program)
        analyze_statements(program.statements)
        self
      end

      def result_for(call, receiver_type: nil)
        context = record_for(call)
        unless context
          return unknown_result(
            call,
            receiver_type,
            ["call node was not found in the analyzed tree"]
          )
        end

        type = receiver_type || context[:receiver_type]
        return unknown_result(call, type, context[:unknown] + context[:unknown_refinements]) unless type

        candidates = candidates_for(call, type, context)
        unknown = !(context[:unknown] + context[:unknown_refinements]).empty?
        QueryResult.new(
          call: call,
          receiver_type: type,
          candidates: candidates,
          unknown: unknown,
          reasons: (context[:unknown] + context[:unknown_refinements]).uniq { |reason| reason.description }
        )
      end

      private

      def current
        @frames.last
      end

      def root_frame?
        current.kind == :root
      end

      def with_frame(frame)
        @frames.push(frame)
        yield
      ensure
        @frames.pop
      end

      def analyze_statements(statements)
        statements.body.each do |node|
          next if node.is_a?(VoidStmt)

          analyze_node(node)
        end
      end

      def record_for(call)
        return records[call] if records.key?(call)

        records.find do |candidate, _context|
          candidate.class == call.class &&
            candidate.location.start_char == call.location.start_char &&
            candidate.location.end_char == call.location.end_char
        end&.last
      end

      def analyze_body(bodystmt)
        case bodystmt
        when BodyStmt
          analyze_statements(bodystmt.statements)
          analyze_node(bodystmt.rescue_clause) if bodystmt.rescue_clause
          analyze_statements(bodystmt.else_clause) if bodystmt.else_clause
          analyze_node(bodystmt.ensure_clause) if bodystmt.ensure_clause
        when Statements
          analyze_statements(bodystmt)
        else
          analyze_node(bodystmt) if bodystmt
        end
      end

      def analyze_node(node)
        case node
        when ClassDeclaration
          analyze_class(node)
        when ModuleDeclaration
          analyze_module(node)
        when DefNode
          analyze_def(node)
        when Assign
          analyze_assign(node)
        when MethodAddBlock
          analyze_method_add_block(node)
        when Command
          analyze_command(node)
        when CommandCall
          analyze_command_call(node)
        when CallNode
          analyze_call(node)
        when VCall
          analyze_vcall(node)
        when BodyStmt
          analyze_body(node)
        when Statements
          analyze_statements(node)
        else
          analyze_children(node)
        end
      end

      def analyze_children(node)
        node&.child_nodes&.each { |child| analyze_node(child) }
      end

      def analyze_class(node)
        relative_path, absolute = declaration_path(node.constant)
        return analyze_children(node) unless relative_path

        path = absolute ? relative_path : nested_declaration_path(relative_path)
        analyze_node(node.superclass) if node.superclass

        push_declaration_frame(:class, path, current.active.dup, current.unknown.dup) do
          analyze_body(node.bodystmt)
        end
      end

      def analyze_module(node)
        relative_path, absolute = declaration_path(node.constant)
        return analyze_children(node) unless relative_path

        path = absolute ? relative_path : nested_declaration_path(relative_path)
        push_declaration_frame(:module, path, current.active.dup, current.unknown.dup) do
          analyze_body(node.bodystmt)
        end
      end

      def push_declaration_frame(kind, path, active, unknown)
        with_frame(
          Frame.new(
            kind: kind,
            path: path,
            lexical: current.lexical + [path],
            active: active,
            unknown: unknown,
            locals: {},
            using_allowed: true
          )
        ) { yield }
      end

      def analyze_def(node)
        analyze_node(node.target) if node.target
        return analyze_body(node.bodystmt) if node.target

        owner = owner_frame
        with_frame(
          Frame.new(
            kind: :method,
            path: owner&.path,
            lexical: current.lexical,
            active: current.active.dup,
            unknown: current.unknown.dup,
            locals: method_locals(node),
            using_allowed: false
          )
        ) do
          analyze_parameters(node.params)
          analyze_body(node.bodystmt)
        end
      end

      def analyze_parameters(params)
        params = params.contents if params.is_a?(Paren)
        return unless params.is_a?(Params)

        params.requireds.each { |name| current.locals[identifier_name(name)] = nil }
        params.optionals.each do |name, value|
          analyze_node(value)
          current.locals[identifier_name(name)] = expression_type(value)
        end
        current.locals[identifier_name(params.rest.name)] = nil if params.rest.respond_to?(:name) && params.rest.name
        params.posts.each { |name| current.locals[identifier_name(name)] = nil }
        params.keywords.each do |name, value|
          current.locals[name.value.delete_suffix(":").to_sym] = value ? expression_type(value) : nil
        end
        if params.block.respond_to?(:name) && params.block.name
          current.locals[identifier_name(params.block.name)] = nil
        end
      end

      def method_locals(node)
        locals = {}
        collect_locals(node.bodystmt, locals)
        locals
      end

      def collect_locals(node, locals)
        case node
        when Assign
          if node.target.is_a?(VarField) && node.target.value.is_a?(Ident)
            locals[node.target.value.value.to_sym] = nil
          end
          collect_locals(node.value, locals)
        when DefNode, ClassDeclaration, ModuleDeclaration
          nil
        when nil
          nil
        else
          node.child_nodes.each { |child| collect_locals(child, locals) }
        end
      end

      def owner_frame
        @frames.reverse.find { |frame| frame.kind == :class || frame.kind == :refinement }
      end
      def analyze_assign(node)
        if dynamic_module_assignment?(node)
          path = constant_field_path(node.target, current.lexical)
          if path
            with_frame(dynamic_module_frame(path, node)) do
              analyze_body(node.value.block.bodystmt)
            end
            return
          end
        end

        analyze_node(node.value)
        if local_assignment?(node)
          current.locals[node.target.value.value.to_sym] = expression_type(node.value)
        end
      end

      def dynamic_module_frame(path, node)
        Frame.new(
          kind: :module,
          path: path,
          lexical: current.lexical + [path],
          active: current.active.dup,
          unknown: current.unknown.dup + [unknown_reason(node, "module is constructed dynamically")],
          locals: current.locals.dup,
          using_allowed: true
        )
      end

      def local_assignment?(node)
        node.target.is_a?(VarField) && node.target.value.is_a?(Ident)
      end

      def dynamic_module_assignment?(assign)
        value = assign.value
        value.is_a?(MethodAddBlock) && value.call.is_a?(CallNode) &&
          message_name(value.call.message) == :new &&
          receiver_constant(value.call.receiver) == "Module"
      end

      def analyze_method_add_block(node)
        target_path = refinement_target(node)
        module_frame = @frames.reverse.find { |frame| frame.kind == :module }

        if target_path && module_frame
          return analyze_dynamic_refinement(node) if target_path == :dynamic

          resolved_target = resolve_path(target_path, module_frame.lexical)
          active = current.active.dup
          if module_frame.path.is_a?(Array)
            active.unshift(
              Activation.new(
                module_path: module_frame.path,
                position: node.location.start_char,
                node: node
              )
            )
          end

          with_frame(refinement_frame(resolved_target, module_frame, active)) do
            analyze_body(node.block.bodystmt)
          end
          return
        end

        analyze_node(node.call)
        push_block_frame(node.block) { analyze_body(node.block.bodystmt) }
      end

      def analyze_dynamic_refinement(node)
        analyze_children(node.call)
        push_block_frame(node.block) { analyze_body(node.block.bodystmt) }
      end

      def refinement_frame(path, module_frame, active)
        Frame.new(
          kind: :refinement,
          path: path,
          lexical: module_frame.lexical,
          active: active,
          unknown: current.unknown.dup,
          locals: current.locals.dup,
          using_allowed: true
        )
      end

      def push_block_frame(block)
        with_frame(
          Frame.new(
            kind: :block,
            path: current.path,
            lexical: current.lexical,
            active: current.active.dup,
            unknown: current.unknown.dup,
            locals: current.locals.dup,
            using_allowed: current.using_allowed
          )
        ) { yield }
      end

      def refinement_target(node)
        call = node.call
        return nil unless node.block
        return nil unless call.is_a?(CallNode) && call.receiver.nil?
        return nil unless message_name(call.message) == :refine

        arguments = call_arguments(call)
        return nil unless arguments.length == 1

        path, _node = constant_reference(arguments.first, current.lexical)
        path || :dynamic
      end

      def analyze_command(node)
        if node.message.is_a?(Ident) && node.message.value == "using"
          activate_using(node.arguments.parts, node)
        else
          analyze_arguments(node.arguments)
          record_call(node, nil)
        end
      end

      def analyze_command_call(node)
        analyze_node(node.receiver)
        analyze_arguments(node.arguments)
        record_call(node, node.receiver)
      end

      def analyze_call(node)
        if using_parentheses?(node)
          activate_using(call_arguments(node), node)
        else
          analyze_node(node.receiver) if node.receiver
          analyze_arguments(node.arguments)
          record_call(node, node.receiver)
        end
      end

      def analyze_vcall(node)
        name = node.value.value.to_sym
        record_call(node, nil) unless current.locals.key?(name)
      end

      def analyze_arguments(arguments)
        case arguments
        when Args
          arguments.parts.each { |argument| analyze_node(argument) }
        when ArgParen
          analyze_node(arguments.arguments)
        end
      end

      def using_parentheses?(node)
        node.receiver.nil? && message_name(node.message) == :using
      end

      def activate_using(arguments, node)
        arguments.each { |argument| analyze_node(argument) }

        unless current.using_allowed
          current.unknown << unknown_reason(node, "using is not statically valid in this lexical scope")
          return
        end

        arguments.each do |argument|
          path, _node = constant_reference(argument, current.lexical)
          if path.nil?
            current.unknown << unknown_reason(node, "using argument is not a statically known module")
          elsif @registry.uncertain_module?(path)
            current.unknown << unknown_reason(node, "using activates a module with non-static refinements")
          elsif @registry.dynamic_module?(path)
            current.unknown << unknown_reason(node, "using activates a dynamically constructed module")
          else
            current.active.unshift(
              Activation.new(
                module_path: path,
                position: node.location.start_char,
                node: node
              )
            )
          end
        end
      end

      def record_call(call, receiver_node)
        type = receiver_type(receiver_node)
        unknown = []
        if receiver_node && type.nil?
          unknown << unknown_reason(receiver_node, "receiver type is not statically known")
        elsif receiver_node.nil? && self_receiver_path.nil?
          unknown << unknown_reason(call, "implicit receiver is not statically known")
        end

        records[call] = {
          receiver_type: type,
          unknown: unknown,
          active: current.active.dup,
          unknown_refinements: current.unknown.dup,
          lexical: current.lexical.dup,
          position: call.location.start_char
        }
      end

      def receiver_type(node)
        case node
        when nil
          self_receiver_path
        when Paren
          unwrapped_parentheses(node)&.then { |contents| receiver_type(contents) }
        when VCall
          current.locals[node.value.value.to_sym]
        when VarRef
          var_ref_type(node)
        when StringLiteral
          %i[String]
        when SymbolLiteral
          %i[Symbol]
        when Int
          %i[Integer]
        when FloatLiteral
          %i[Float]
        when ArrayLiteral
          %i[Array]
        when HashLiteral
          %i[Hash]
        when RegexpLiteral
          %i[Regexp]
        when CallNode
          call_expression_type(node)
        end
      end

      def unwrapped_parentheses(node)
        contents = node.contents
        return contents unless contents.is_a?(Statements)
        contents.body.length == 1 ? contents.body.first : nil
      end

      def var_ref_type(node)
        case node.value
        when Ident
          current.locals[node.value.value.to_sym]
        when Const
          constant_type(node.value.value.to_sym)
        when Kw
          current.path if node.value.value == "self"
        end
      end

      def call_expression_type(node)
        return unless message_name(node.message) == :new

        case node.receiver
        when VarRef
          value = node.receiver.value
          value.is_a?(Const) ? constant_type(value.value.to_sym) : nil
        when ConstPathRef, TopConstRef
          path, _node = constant_reference(node.receiver, current.lexical)
          path
        end
      end

      def expression_type(node)
        receiver_type(node)
      end

      def self_receiver_path
        frame = @frames.reverse.find { |candidate| candidate.path.is_a?(Array) }
        frame&.path
      end

      def candidates_for(call, type, context)
        name = call_message_name(call)
        candidates = []
        seen = {}

        @registry.type_chain(type).each do |target_path|
          context[:active].each do |activation|
            blocks = @registry.refinement_blocks(
              target_path,
              activation.module_path,
              before: activation.position
            )

            blocks.reverse_each do |refinement|
              method = refinement.methods[name]
              key = [method&.path, method&.node]
              next unless method && !seen.key?(key)

              seen[key] = true
              candidates << refinement_candidate(method, refinement, activation)
            end
          end
        end

        @registry.method_chain(type).each do |path, methods|
          method = methods[name]
          next unless method

          candidates << normal_candidate(path, method)
          break
        end

        candidates
      end

      def refinement_candidate(method, refinement, activation)
        Candidate.new(
          kind: :refinement,
          name: method.name,
          path: refinement.target_path,
          node: method.node,
          basis: Basis.new(
            kind: :refinement_method,
            node: method.node,
            description:
              "refined in #{constant_name(refinement.module_path)} for #{constant_name(refinement.target_path)}"
          ),
          evidence: [
            Basis.new(
              kind: :refine,
              node: refinement.node,
              description: "refine(#{constant_name(refinement.target_path)}) was present when using activated"
            ),
            Basis.new(
              kind: :using,
              node: activation.node,
              description: "using #{constant_name(activation.module_path)} is lexically active"
            )
          ]
        )
      end

      def normal_candidate(path, method)
        Candidate.new(
          kind: :normal,
          name: method.name,
          path: path,
          node: method.node,
          basis: Basis.new(
            kind: :normal_method,
            node: method.node,
            description: "defined directly in #{constant_name(path)}"
          )
        )
      end

      def call_message_name(call)
        return call.value.value.to_sym if call.is_a?(VCall)

        message_name(call.message)
      end

      def unknown_result(call, type, reasons)
        reasons = reasons.map do |reason|
          reason.is_a?(Basis) ? reason : unknown_reason(call, reason)
        end

        QueryResult.new(
          call: call,
          receiver_type: type,
          candidates: [],
          unknown: true,
          reasons: reasons
        )
      end

      def unknown_reason(node, description)
        Basis.new(kind: :unknown, node: node, description: description)
      end

      def constant_name(path)
        path.is_a?(Array) ? path.map(&:to_s).join("::") : path.inspect
      end

      def receiver_constant(node)
        node = node.value if node.is_a?(VarRef)
        node.is_a?(Const) ? node.value : nil
      end

      def call_arguments(call)
        case call.arguments
        when Args
          call.arguments.parts
        when ArgParen
          if call.arguments.arguments.is_a?(Args)
            call.arguments.arguments.parts
          else
            []
          end
        else
          []
        end
      end

      def identifier_name(node)
        node.respond_to?(:name) ? node.name.value.to_sym : node.value.to_sym
      end

      def constant_type(name)
        resolve_path(name, current.lexical)
      end

      def constant_reference(node, lexical)
        case node
        when nil
          [nil, nil]
        when VarRef
          constant_reference(node.value, lexical)
        when Const
          [resolve_path_in(node.value.to_sym, lexical), node]
        when ConstRef
          constant_reference(node.constant, lexical)
        when TopConstRef
          [[node.constant.value.to_sym], node]
        when ConstPathRef
          parent, root = constant_path_parent(node.parent, lexical)
          parent ? [parent + [node.constant.value.to_sym], node] : [nil, root]
        else
          [nil, node]
        end
      end

      def constant_path_parent(node, lexical)
        case node
        when VarRef
          constant_reference(node, lexical)
        when TopConstRef
          [[node.constant.value.to_sym], node]
        when ConstPathRef
          parent, root = constant_path_parent(node.parent, lexical)
          parent ? [parent + [node.constant.value.to_sym], node] : [nil, root]
        else
          [nil, node]
        end
      end

      def constant_path(node)
        case node
        when ConstRef
          [node.constant.value.to_sym]
        when Const
          [node.value.to_sym]
        when TopConstRef
          [node.constant.value.to_sym]
        when ConstPathRef
          parent, _root = constant_path_parent(node.parent, [])
          parent ? parent + [node.constant.value.to_sym] : nil
        end
      end

      def declaration_path(node)
        case node
        when ConstRef
          [node.constant.value.to_sym, false]
        when Const
          [node.value.to_sym, false]
        when TopConstRef
          [[node.constant.value.to_sym], true]
        when ConstPathRef
          parent, _root = constant_path_parent(node.parent, [])
          if parent
            [parent + [node.constant.value.to_sym], node.parent.is_a?(TopConstRef)]
          end
        end
      end

      def nested_declaration_path(relative_path)
        path = Array(relative_path)
        current.lexical.empty? ? path : current.lexical.last + path
      end

      def constant_field_path(node, lexical)
        case node
        when VarField
          if node.value.is_a?(Const)
            resolve_path_in(node.value.value.to_sym, lexical)
          end
        when TopConstField
          [node.constant.value.to_sym]
        when ConstPathField
          parent, _root = constant_path_parent(node.parent, lexical)
          parent ? parent + [node.constant.value.to_sym] : nil
        end
      end

      def resolve_path(name_or_path, lexical)
        return name_or_path if name_or_path.is_a?(Array)

        resolve_path_in(name_or_path, lexical)
      end

      def resolve_path_in(name, lexical)
        lexical.reverse_each do |lexical_path|
          candidate = lexical_path + [name]
          return candidate if @registry.type(candidate)
        end

        [name]
      end

      def message_name(node)
        node == :call ? :call : node.value.to_sym
      rescue NoMethodError
        nil
      end
    end

    def self.analyze(source)
      program = SyntaxTree.parse(source)
      registry = DeclarationCollector.new.collect(program)
      LexicalAnalyzer.new(registry).analyze(program)
    end

    def self.method_candidates(source, call, receiver_type: nil)
      analyze(source).result_for(call, receiver_type: receiver_type)
    end
  end
end
