# frozen_string_literal: true

module SyntaxTree
  # RefinementQuery provides lexical, static information about method calls and
  # refinements that were written directly in Ruby source code.
  class RefinementQuery
    class Candidate
      attr_reader :kind, :method_name, :owner, :location, :reasons

      def initialize(kind, method_name, owner, location, reasons)
        @kind = kind
        @method_name = method_name
        @owner = owner
        @location = location
        @reasons = reasons
      end
    end

    class Evidence
      attr_reader :kind, :location, :description

      def initialize(kind, location, description)
        @kind = kind
        @location = location
        @description = description
      end
    end

    class Result
      attr_reader :status, :receiver_type, :candidates, :evidence, :reason

      def initialize(status:, receiver_type:, candidates:, evidence:, reason: nil)
        @status = status
        @receiver_type = receiver_type
        @candidates = candidates
        @evidence = evidence
        @reason = reason
      end

      def known?
        status == :known
      end
    end

    class ConstantNameVisitor < Visitor
      def visit_const_ref(node)
        [node.constant.value.to_sym]
      end

      def visit_const_path_ref(node)
        visit(node.parent) << node.constant.value.to_sym
      end

      def visit_top_const_ref(node)
        [node.constant.value.to_sym]
      end

      def visit_var_ref(node)
        [node.value.value.to_sym]
      end
    end

    class MethodEntry
      attr_reader :name, :owner, :location

      def initialize(name, owner, location)
        @name = name
        @owner = owner
        @location = location
      end
    end

    class RefinementEntry
    attr_reader :module_path, :target, :location, :unknown_target,
                :methods, :activations

      def initialize(module_path, target, location, unknown_target)
        @module_path = module_path
        @target = target
        @location = location
        @unknown_target = unknown_target
        @methods = []
        @activations = []
      end
    end

    class RefinementMethodEntry
      attr_reader :name, :location

      def initialize(name, location)
        @name = name
        @location = location
      end
    end

    class Activation
      attr_reader :module_path, :location, :refinements

      def initialize(module_path, location, definite: true)
        @module_path = module_path
        @location = location
        @refinements = []
        @definite = definite
      end

      def definite?
        @definite
      end
    end

    class Frame
      attr_reader :kind, :nesting, :activations, :owner, :locals, :subject,
                  :dynamic_locals

      def initialize(
        kind,
        nesting = nil,
        owner: nil,
        locals: {},
        subject: nil,
        dynamic_locals: {}
      )
        @kind = kind
        @nesting = nesting
        @activations = []
        @owner = owner
        @locals = locals
        @subject = subject
        @dynamic_locals = dynamic_locals
      end
    end

    class Analyzer < Visitor
      attr_reader :calls, :refinements, :ordinary_methods,
                  :namespace_registry, :dynamic_modules

      def initialize
        @calls = {}
        @refinements = []
        @ordinary_methods = []
        @frames = [
          Frame.new(
            :sclass,
            [],
            owner: nil,
            locals: {},
            dynamic_locals: {}
          )
        ]
        @namespace_registry = []
        @dynamic_modules = {}
      end

      def result_for(node)
        calls[node]
      end

      def visit_program(node)
        visit_statements(node.statements)
      end

      def visit_statements(node)
        node.body.each { |statement| visit(statement) }
      end

      def visit_bodystmt(node)
        visit(node.statements)
        visit(node.rescue_clause)
        visit(node.else_clause)
        visit(node.ensure_clause)
      end

      def visit_class(node)
        enter_namespace(node, :class)
      end

      def visit_module(node)
        enter_namespace(node, :module)
      end

      def visit_sclass(node)
        owner = singleton_owner(node.target)
        frame =
          Frame.new(
            :lexical,
            current_nesting,
            owner: owner,
            locals: {},
            subject: :lexical,
            dynamic_locals: {}
          )
        with_frame(frame) { visit(node.bodystmt) }
      end

      def visit_if(node)
        with_conditional_frame { super }
      end
      alias visit_unless visit_if

      def visit_case(node)
        with_conditional_frame { super }
      end

      def visit_while(node)
        with_conditional_frame { super }
      end
      alias visit_until visit_while

      def visit_for(node)
        with_conditional_frame { super }
      end

      def visit_rescue(node)
        with_conditional_frame { super }
      end

      def visit_def(node)
        refinement = nearest_frame(:refinement)
        if refinement
          if node.target.nil?
            refinement.subject.methods << RefinementMethodEntry.new(
              method_name(node.name),
              node.location
            )
            visit_definition_body(node)
          end
          return
        end

        owner = definition_owner(node)
        if owner
          ordinary_methods << MethodEntry.new(method_name(node.name), owner, node.location)
        end

        visit(node.params)
        visit_definition_body(node, owner)
      end

      def visit_assign(node)
        visit(node.value)

        target = node.target
        if target.is_a?(VarField) && target.value.is_a?(Ident)
          current_frame.locals[target.value.value] = receiver_type(node.value)
          if dynamic_module_expression?(node.value)
            current_frame.dynamic_locals[target.value.value] = true
          end
        elsif target.is_a?(VarField) && target.value.is_a?(Const)
          if dynamic_module_expression?(node.value)
            @dynamic_modules[[target.value.value.to_sym]] = node.location
          end
        end
      end

      def visit_call(node)
        if using_call?(node)
          record_plain_using(node)
          return
        end

        record_call(node, node.receiver, node.message)
        super
      end

      def visit_command_call(node)
        record_call(node, node.receiver, node.message)
        super
      end

      def visit_command(node)
        message = node.message.value

        if message == "using"
          record_using(node)
          return
        elsif message == "refine" && node.block
          record_refine_command(node)
          return
        end

        record_call(node, nil, node.message)
        super
      end

      def visit_method_add_block(node)
        if using_call?(node.call)
          record_using_call(node)
        elsif refinement_call?(node.call)
          record_refine_call(node)
        else
          visit(node.call)
          with_frame(
            Frame.new(
              :block,
              current_nesting,
              locals: current_locals,
              subject: :transparent,
              dynamic_locals: current_dynamic_locals
            )
          ) do
            visit(node.block)
          end
        end
      end

      private

      def enter_namespace(node, kind)
        parent_nesting = current_nesting.dup
        path = resolve_namespace_path(node.constant, parent_nesting)
        nesting = parent_nesting + path
        superclass =
          if kind == :class && node.superclass
            static_constant_path(node.superclass)
          end

        @namespace_registry << {
          kind: kind,
          path: nesting,
          superclass: superclass,
          location: node.location
        }

        frame = Frame.new(:namespace, nesting, locals: {}, dynamic_locals: {})
        with_frame(frame) do
          visit(node.bodystmt)
        end
      end

      def visit_definition_body(node, owner = definition_owner(node))
        evidence = definition_evidence(node.location)
        frame =
          Frame.new(
            :definition,
            current_nesting,
            owner: owner,
            locals: {},
            subject: evidence,
            dynamic_locals: {}
          )
        frame.activations.concat(evidence)

        with_frame(frame) { visit(node.bodystmt) }
      end

      def record_call(node, receiver, message_node)
        return unless message_node.is_a?(Ident) || message_node == :call

        definition = nearest_frame(:definition)
        evidence = definition ? definition.subject.dup : lexical_evidence
        receiver_type = receiver_type(receiver)

        calls[node] = {
          receiver: receiver,
          message: method_name(message_node),
          receiver_type: receiver_type,
          evidence: evidence,
          definition: !definition.nil?
        }
      end

      def record_using(node)
        return if nearest_frame(:definition)

        argument = node.arguments.parts.first
        activation = record_using_argument(argument, node.location)

        if argument.is_a?(MethodAddBlock) && activation
          record_refinement_from_dynamic_module(argument, activation)
        end
      end

      def record_plain_using(node)
        return if nearest_frame(:definition)

        argument = argument_value(node.arguments)
        record_using_argument(argument, node.location)
      end

      def record_using_argument(argument, location)
        path = static_constant_path(argument)
        local = local_name(argument)
        dynamic_block = false

        if local && dynamic_local?(local)
          add_dynamic_activation(location)
        elsif path
          path = resolve_constant_path(path, current_nesting)
          if @dynamic_modules.key?(path)
            add_dynamic_activation(location)
          else
            add_activation(path, location)
          end
        elsif dynamic_module_expression?(argument)
          activation = add_dynamic_activation(location)
          dynamic_block = argument.is_a?(MethodAddBlock)
        else
          add_dynamic_activation(location)
        end

        dynamic_block ? activation : nil
      end

      def record_using_call(node)
        return if nearest_frame(:definition)

        argument = argument_value(node.call.arguments)
        activation = record_using_argument(argument, node.location)

        if activation
          record_refinement_from_dynamic_module(argument, activation)
        end
      end

      def record_refinement_from_dynamic_module(expression, activation)
        refinement_calls(expression).each do |call|
          target = argument_value(call.arguments)
          target_path = static_constant_path(target)
          refinement =
            RefinementEntry.new(
              nil,
              target_path,
              activation.location,
              target_path.nil?
            )
          refinements << refinement
          activation.refinements << refinement

          frame = Frame.new(:refinement, current_nesting, subject: refinement)
          with_frame(frame) { visit(call.block) }
        end
      end

      def refinement_calls(node)
        calls = []
        walk(node) do |child|
          if child.is_a?(MethodAddBlock) && refinement_call?(child.call)
            calls << child
          end
        end
        calls
      end

      def walk(node, &block)
        return unless node.is_a?(Node)

        yield(node)
        node.child_nodes.each { |child| walk(child, &block) }
      end

      def record_refine_command(node)
        record_refinement(node.arguments.parts.first, node.block, node.location)
      end

      def record_refine_call(node)
        arguments = node.call.arguments
        target =
          if arguments.respond_to?(:arguments)
            arguments.arguments.parts.first
          elsif arguments.respond_to?(:parts)
            arguments.parts.first
          end

        record_refinement(target, node.block, node.location)
      end

      def record_refinement(target_node, block, location)
        path = current_nesting.dup
        target =
          resolve_constant_path(static_constant_path(target_node), current_nesting)
        refinement = RefinementEntry.new(path, target, location, target.nil?)
        refinements << refinement
        refinement.activations.concat(
          definition_evidence(location)
        )

        frame = Frame.new(:refinement, current_nesting, subject: refinement)
        frame.activations.concat(refinement.activations)

        with_frame(frame) do
          visit(block)
        end
      end

      def refinement_call?(node)
        node.is_a?(CallNode) && node.receiver.nil? && node.operator.nil? &&
          node.message.is_a?(Ident) && node.message.value == "refine"
      end

      def using_call?(node)
        node.is_a?(CallNode) && node.receiver.nil? && node.operator.nil? &&
          node.message.is_a?(Ident) && node.message.value == "using"
      end

      def add_dynamic_activation(location)
        Activation.new(nil, location, definite: activation_definite?).tap do |activation|
          lexical_scope_frame.activations << activation
        end
      end

      def add_activation(path, location)
        Activation.new(
          path,
          location,
          definite: activation_definite?
        ).tap { |activation| lexical_scope_frame.activations << activation }
      end

      def activation_definite?
        !@frames.any? { |frame| frame.kind == :conditional }
      end

      def with_conditional_frame
        frame = Frame.new(:conditional, current_nesting, subject: :conditional)
        with_frame(frame) { yield }
      end

      def with_frame(frame, activations = nil)
        frame.activations.concat(activations) if activations
        @frames.push(frame)
        yield
      ensure
        @frames.pop
      end

      def lexical_frame
        @frames.last
      end

      def lexical_scope_frame
        @frames.reverse.find do |frame|
          %i[lexical namespace refinement sclass].include?(frame.kind)
        end
      end

      def nearest_frame(kind)
        @frames.reverse.find { |frame| frame.kind == kind }
      end

      def refinement_frame?
        @frames.any? { |frame| frame.kind == :refinement }
      end

      def current_nesting
        frame = @frames.reverse.find { |entry| entry.nesting }
        frame ? frame.nesting.dup : []
      end

      def lexical_evidence
        @frames.select { |frame| frame.subject != :transparent }.flat_map(&:activations)
      end

      def definition_evidence(location)
        lexical_evidence.reject do |activation|
          activation.location.start_char >= location.start_char
        end
      end

      def constant_path(node)
        node.accept(ConstantNameVisitor.new)
      rescue StandardError
        nil
      end

      def static_constant_path(node)
        case node
        when VarRef
          node.value.is_a?(Const) ? [node.value.value.to_sym] : nil
        when ConstPathRef
          parent = static_constant_path(node.parent)
          parent ? parent + [node.constant.value.to_sym] : nil
        when TopConstRef
          [node.constant.value.to_sym]
        when ConstRef
          [node.constant.value.to_sym]
        end
      end

      def receiver_type(node)
        case node
        when nil
          if definition_frame
            definition_frame.owner
          elsif nearest_frame(:sclass)
            nearest_frame(:sclass).owner
          else
            singleton_path(current_nesting)
          end
        when StringLiteral
          [:String]
        when SymbolLiteral
          [:Symbol]
        when ArrayLiteral
          [:Array]
        when HashLiteral
          [:Hash]
        when Int
          [:Integer]
        when FloatLiteral
          [:Float]
        when CallNode, CommandCall
          constructor_type(node)
        when VarRef
          case node.value
          when Kw
            if node.value.value == "self"
              definition_frame&.owner || current_nesting
            end
          when Ident
            local_type(node.value.value)
          when Const
            singleton_path(resolve_constant_path(static_constant_path(node), current_nesting))
          end
        when VCall
          local_type(node.value.value)
        when ConstPathRef, TopConstRef
          singleton_path(resolve_constant_path(static_constant_path(node), current_nesting))
        end
      end

      def singleton_path(path)
        path ? [:singleton, *path] : nil
      end

      def method_name(node)
        node.respond_to?(:value) ? node.value.to_sym : node
      end

      def definition_frame
        nearest_frame(:definition)
      end

      def current_frame
        @frames.last
      end

      def current_locals
        current_frame.locals
      end

      def current_dynamic_locals
        current_frame.dynamic_locals
      end

      def local_type(name)
        @frames.reverse_each do |frame|
          return frame.locals[name] if frame.locals.key?(name)
        end
        nil
      end

      def dynamic_local?(name)
        @frames.reverse_each do |frame|
          return true if frame.dynamic_locals.key?(name)
        end
        false
      end

      def local_name(node)
        case node
        when VarRef
          node.value.value if node.value.is_a?(Ident)
        when VCall
          node.value.value
        end
      end

      def definition_owner(node)
        return singleton_owner(node.target) if node.target
        return current_frame.owner if current_frame.owner

        current_nesting
      end

      def singleton_owner(target)
        path =
          case target
          when VarRef
            if target.value.is_a?(Kw) && target.value.value == "self"
              current_nesting
            elsif target.value.is_a?(Const)
              [target.value.value.to_sym]
            end
          when ConstPathRef
            static_constant_path(target)
          when TopConstRef
            static_constant_path(target)
          end

        path ? [:singleton, *path] : nil
      end

      def argument_value(arguments)
        return nil unless arguments
        return arguments unless arguments.is_a?(ArgParen) && arguments.arguments

        arguments.arguments.parts.first
      end

      def dynamic_module?(node)
        node.is_a?(CallNode) && node.receiver.is_a?(VarRef) &&
          node.receiver.value.is_a?(Const) &&
          node.receiver.value.value == "Module" && node.message.is_a?(Ident) &&
          node.message.value == "new"
      end

      def dynamic_module_expression?(node)
        return true if dynamic_module?(node)

        node.is_a?(MethodAddBlock) && dynamic_module?(node.call)
      end

      def constructor_type(node)
        receiver =
          case node.receiver
          when VarRef
            node.receiver.value if node.receiver.value.is_a?(Const)
          when ConstPathRef, TopConstRef
            return static_constant_path(node.receiver) if node.message.is_a?(Ident) &&
              node.message.value == "new"
          end

        if node.message.is_a?(Ident) && node.message.value == "new" && receiver
          [receiver.value.to_sym]
        end
      end

      def resolve_constant_path(path, nesting)
        return path unless path
        return path if path.empty? || path.first.to_s.start_with?("::")

        (0...nesting.length).reverse_each do |index|
          candidate = nesting[0..index] + path
          return candidate if namespace_path?(candidate)
        end

        path
      end

      def resolve_namespace_path(constant, nesting)
        path = constant_path(constant)
        return path unless path
        case constant
        when ConstRef
          nesting + path
        when TopConstRef
          path
        when ConstPathRef
          prefix = static_constant_path(constant.parent)
          return path unless prefix
          overlap = nesting.zip(prefix).count { |nested, named| nested == named }
          nesting + path.drop(overlap)
        end
      end

      def namespace_path?(path)
        @namespace_registry.any? { |entry| entry[:path] == path }
      end
    end

    attr_reader :analyzer, :program

    def initialize(source: nil, program: nil)
      @program = program || SyntaxTree.parse(source)
      @analyzer = Analyzer.new
      @program.accept(@analyzer)
    end

    def self.for(source)
      new(source: source)
    end

    def calls_named(name)
      calls = []
      walk(program) do |node|
        if node.is_a?(CallNode) && node.message.is_a?(Ident) &&
             node.message.value == name.to_s
          calls << node
        end
      end
      calls
    end

    def query(call_node, declarations: nil)
      information = analyzer.result_for(call_node)
      unless information
        return unknown_result(
          call_node,
          "Call node was not found in the analyzed source."
        )
      end

      declaration_index = build_declaration_index(declarations)
      evidence = information.fetch(:evidence)

      target = information.fetch(:receiver_type)
      dynamic_activation = evidence.find { |activation| activation.module_path.nil? }
      dynamic_constant =
        evidence.any? do |activation|
          analyzer.dynamic_modules.key?(activation.module_path)
        end
      indefinite_activation = evidence.any? { |activation| !activation.definite? }

      if dynamic_activation || dynamic_constant || indefinite_activation
        return unknown_result(
          call_node,
          if indefinite_activation
            "A refinement is activated on a conditional lexical path."
          else
            "A dynamically constructed module is activated at this lexical scope."
          end,
          information,
          evidence_for(evidence)
        )
      end

      unless target
        return unknown_result(
          call_node,
          "Receiver type could not be determined statically.",
          information,
          evidence_for(evidence)
        )
      end

      activated_refinements =
        activated_refinements_for(
          evidence,
          call_node,
          information[:definition]
        )

      relevant_refinements =
        activated_refinements.select do |refinement|
          refinement.target == target || refinement.unknown_target
        end

      if relevant_refinements.any?(&:unknown_target)
        return unknown_result(
          call_node,
          "A dynamically constructed class or module is refined at this lexical scope.",
          information,
          evidence_for(evidence)
        )
      end

      refined =
        candidates_for_refinements(
          relevant_refinements,
          evidence,
          information.fetch(:message)
        )
      ordinary =
        candidates_for_ordinary(
          declaration_index,
          target,
          information.fetch(:message)
        )

      Result.new(
        status: :known,
        receiver_type: target,
        candidates: refined + ordinary,
        evidence: evidence_for(evidence)
      )
    end

    private

    def build_declaration_index(declarations)
      entries = Array(declarations || analyzer.ordinary_methods)
      namespaces = analyzer.namespace_registry.map { |entry| entry.dup }
      methods = []

      entries.each do |entry|
        case entry
        when Index::ClassDefinition, Index::ModuleDefinition
          namespaces << {
            kind: entry.is_a?(Index::ClassDefinition) ? :class : :module,
            path: entry.nesting.last,
            superclass: entry.is_a?(Index::ClassDefinition) ? entry.superclass : nil,
            location: entry.location
          }
        when Index::MethodDefinition
          methods << MethodEntry.new(entry.name, entry.nesting.last, entry.location)
        when Index::SingletonMethodDefinition
          methods << MethodEntry.new(
            entry.name,
            [:singleton, *entry.nesting.last],
            entry.location
          )
        when MethodEntry
          methods << entry
        end
      end

      {
        namespaces: namespaces,
        methods: methods,
        hierarchy: build_hierarchy(namespaces)
      }
    end

    def build_hierarchy(namespaces)
      namespaces.each_with_object({}) do |entry, hierarchy|
        next unless entry[:kind] == :class

        hierarchy[entry[:path]] = entry[:superclass] if entry[:superclass]&.any?
      end
    end

    def activated_refinements_for(evidence, call_node, definition)
      activated = []
      seen = {}

      evidence.reverse_each do |activation|
        if activation.refinements.any?
          entries = activation.refinements
        else
          entries =
            analyzer.refinements.select do |refinement|
            refinement.module_path == activation.module_path
          end
        end

        unless definition
          entries =
            entries.select do |refinement|
              refinement.location.start_char < call_node.location.start_char
            end
        end

        entries.reverse_each do |refinement|
          next if seen[[refinement.module_path, refinement.target, refinement.location]]

          seen[[refinement.module_path, refinement.target, refinement.location]] = true
          activated << refinement
        end
      end

      activated
    end

    def candidates_for_refinements(refinements, activations, message)
      refinements.flat_map do |refinement|
        activation =
          activations.reverse.find do |entry|
            entry.refinements.include?(refinement) ||
              entry.module_path == refinement.module_path
          end

        refinement.methods.select { |method| method.name == message }.map do |method|
          Candidate.new(
            :refinement,
            message,
            refinement.target,
            method.location,
            refinement_reasons(refinement, activation, message)
          )
        end
      end
    end

    def refinement_reasons(refinement, activation, message)
      reasons = []

      if activation
        reasons << Evidence.new(
          :using,
          activation.location,
          "using #{format_path(activation.module_path)} is lexically active"
        )
      end

      reasons << Evidence.new(
        :refinement,
        refinement.location,
        "refine #{format_path(refinement.target)} defines ##{message}"
      )
      reasons
    end

    def candidates_for_ordinary(index, receiver_type, message)
      return [] unless receiver_type

      owners = ordinary_owners(receiver_type, index.fetch(:hierarchy))
      methods_by_owner = index.fetch(:methods).group_by(&:owner)

      owners.flat_map do |owner|
        (methods_by_owner[owner] || []).select { |entry| entry.name == message }.map do |entry|
          Candidate.new(
            :ordinary,
            message,
            owner,
            entry.location,
            [
              Evidence.new(
                :definition,
                entry.location,
                "ordinary method defined in #{format_path(owner)}"
              )
            ]
          )
        end
      end
    end

    def ordinary_owners(receiver_type, hierarchy)
      if receiver_type.first == :singleton
        [receiver_type]
      else
        visited = {}
        owners = []
        current = receiver_type

        while current && !visited.key?(current)
          visited[current] = true
          owners << current
          current = hierarchy[current]
        end

        owners
      end
    end

    def evidence_for(activations)
      activations.map do |activation|
        Evidence.new(
          :using,
          activation.location,
          "using #{format_path(activation.module_path)}"
        )
      end
    end

    def unknown_result(node, reason, information = nil, evidence = nil)
      Result.new(
        status: :unknown,
        receiver_type: information && information[:receiver_type],
        candidates: [],
        evidence: evidence || [],
        reason: reason
      )
    end

    def format_path(path)
      path ? path.map(&:to_s).join("::") : "<dynamic>"
    end

    def walk(node, &block)
      return unless node.is_a?(Node)

      yield(node)
      node.child_nodes.each { |child| walk(child, &block) }
    end
  end
end
