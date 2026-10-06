# frozen_string_literal: true

module SyntaxTree
  # Rewrites safe navigation calls into ordinary conditional expressions.
  #
  # Supported forms include regular and command calls, call chains, calls with
  # brace or do/end blocks, attribute setters, and compound attribute setters.
  # Safe navigation inside a multiple-assignment target is not supported
  # because expressing its tuple assignment and short-circuit semantics requires
  # a different statement-level rewrite.
  class SafeNavigation < BasicVisitor
    class UnsupportedSyntax < StandardError
    end

    TEMPORARY_PREFIX = "_safe_navigation_receiver".freeze

    SUPPORTED_OPERATORS = %w[
      +=
      -=
      *=
      /=
      %=
      **=
      |=
      &=
      ^=
      <<=
      >>=
      ||=
      &&=
    ].freeze

    include DSL

    def self.transform(node)
      visitor = new(node)
      visitor.send(:validate, node)
      visitor.send(:visit, node)
    end

    def initialize(root)
      super()
      @used_names = {}
      collect_identifiers(root)
    end

    def visit(node)
      return unless node

      transform(node)
    end

    def visit_all(nodes)
      nodes.map { |node| visit(node) }
    end

    private

    def transform(node)
      if node.is_a?(MethodAddBlock) && node.call.is_a?(CallNode) &&
           safe_navigation?(node.call.operator)
        return transform_block_call(node)
      end

      transformed = deep_copy(node)

      case transformed
      when CallNode
        if safe_navigation?(transformed.operator)
          guard_call(transformed)
        else
          transformed
        end
      when CommandCall
        if safe_navigation?(transformed.operator)
          guard_call(transformed)
        else
          transformed
        end
      when Assign
        transform_assign(transformed)
      when OpAssign
        transform_opassign(transformed)
      else
        transformed
      end
    end

    def transform_block_call(node)
      block = visit(node.block)
      call =
        node.call.copy(
          receiver: visit(node.call.receiver),
          message: node.call.message == :call ? :call : visit(node.call.message),
          arguments: visit(node.call.arguments)
        )
      name = next_temporary_name
      plain_call = call.copy(receiver: VarRef(Ident(name)), operator: Period("."))
      guarded(name, call.receiver, MethodAddBlock(plain_call, block))
    end

    def transform_assign(node)
      target = node.target

      if target.is_a?(Field) && safe_navigation?(target.operator)
        name = next_temporary_name
        plain_target = Field(VarRef(Ident(name)), Period("."), target.name)
        guarded(name, target.parent, node.copy(target: plain_target))
      else
        node
      end
    end

    def transform_opassign(node)
      target = node.target
      unless target.is_a?(Field) && safe_navigation?(target.operator)
        return node
      end

      operator = node.operator.value
      unless SUPPORTED_OPERATORS.include?(operator)
        raise UnsupportedSyntax,
              "unsupported compound assignment: #{operator}"
      end

      value = node.value
      receiver_name = next_temporary_name
      receiver = VarRef(Ident(receiver_name))
      getter_name = next_temporary_name
      getter_variable = VarRef(Ident(getter_name))
      plain_target = Field(receiver, Period("."), target.name)
      operation =
        case operator
        when "||="
          IfOp(
            getter_variable,
            getter_variable,
            Assign(plain_target, value)
          )
        when "&&="
          IfOp(
            getter_variable,
            Assign(plain_target, value),
            getter_variable
          )
        else
          Binary(getter_variable, operator.delete_suffix("=").to_sym, value)
        end

      cached_getter =
        Assign(
          VarField(Ident(getter_name)),
          CallNode(receiver, Period("."), target.name, nil)
        )
      truthy =
        if operator == "||=" || operator == "&&="
          operation
        else
          Assign(plain_target, operation)
        end

      guarded(
        receiver_name,
        target.parent,
        truthy,
        before: [cached_getter]
      )
    end

    def guard_call(node)
      name = next_temporary_name
      receiver = VarRef(Ident(name))
      truthy =
        if node.is_a?(CommandCall)
          call =
            CallNode(
              receiver,
              Period("."),
              node.message,
              node.arguments ? ArgParen(node.arguments) : nil
            )
          node.block ? MethodAddBlock(call, node.block) : call
        else
          node.copy(receiver: receiver, operator: Period("."))
        end

      guarded(name, node.receiver, truthy)
    end

    def guarded(name, receiver, truthy, before: [])
      assignment = Assign(VarField(Ident(name)), receiver)
      assignment_result = Paren(LParen.default, assignment)
      nil_check =
        CallNode(assignment_result, Period("."), Ident("nil?"), nil)
      truthy =
        if before.empty?
          truthy
        else
          Paren(LParen.default, Statements(before + [truthy]))
        end

      Paren(
        LParen.default,
        IfOp(
          Unary("!", Paren(LParen.default, nil_check)),
          truthy,
          VarRef(Kw("nil"))
        )
      )
    end

    def deep_copy(node)
      return node unless node

      kwargs =
        copy_parameters(node).to_h do |_, parameter|
          value = node.public_send(parameter)
          [parameter, deep_value(value) { |child| visit(child) }]
        end

      node.copy(**kwargs)
    end

    def deep_value(value)
      case value
      when Node
        yield value
      when Array
        value.map { |item| deep_value(item) { |node| yield node } }
      when Hash
        value.transform_values { |item| deep_value(item) { |node| yield node } }
      else
        value
      end
    end

    def copy_parameters(node)
      node.class.instance_method(:copy).parameters
    end

    def safe_navigation?(operator)
      operator.is_a?(Op) && operator.value == "&."
    end

    def next_temporary_name
      candidate = TEMPORARY_PREFIX
      index = 1

      while @used_names.key?(candidate)
        candidate = "#{TEMPORARY_PREFIX}_#{index}"
        index += 1
      end

      @used_names[candidate] = true
      candidate
    end

    def collect_identifiers(node)
      return unless node

      case node
      when Ident, Const, GVar, IVar, CVar, Label
        @used_names[node.value.delete_suffix(":")] = true
      when Op
        @used_names[node.value] = true
      end

      node.child_nodes.each { |child| collect_identifiers(child) }
    end

    def validate(node)
      case node
      when MAssign
        raise_unsupported_massign if contains_safe_navigation?(node.target)
      end

      deep_value(node.child_nodes) { |child| validate(child) }
    end

    def contains_safe_navigation?(node)
      return false unless node

      case node
      when CallNode, CommandCall, Field
        safe_navigation?(node.operator) ||
          node.child_nodes.compact.any? do |child|
            contains_safe_navigation?(child)
          end
      when Node
        node.child_nodes.compact.any? do |child|
          contains_safe_navigation?(child)
        end
      when Array
        node.any? { |child| contains_safe_navigation?(child) }
      else
        false
      end
    end

    def raise_unsupported_massign
      raise UnsupportedSyntax,
            "safe navigation is not supported in multiple assignment targets"
    end
  end
end
