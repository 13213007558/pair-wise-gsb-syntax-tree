# frozen_string_literal: true

module SyntaxTree
  # Rewrites safe navigation calls into conditional expressions without using
  # the &. operator. Every receiver is stored in a temporary local variable so
  # that it is evaluated exactly once. Arguments and blocks remain inside the
  # non-nil branch, so they are not evaluated when the receiver is nil.
  class SafeNavigation
    # Safe navigation is currently not rewritten in these contexts:
    # - multiple assignment targets, such as +a, b&.c = values+
    # - indexed setter targets, because Ruby has no +a&.[index] = value+ form
    # - a block attached to an indexed continuation, such as +a&.b[i] {}
    #
    # Raised when source contains safe navigation in a position that cannot yet
    # be represented as a standalone conditional expression.
    class UnsupportedSyntax < StandardError
    end

    # Rewrites a parsed document and returns the resulting syntax tree.
    def self.transform(node)
      new(node).transform
    end

    def initialize(root)
      @root = root
      @temporary_index = 0
      @temporary_names = collect_identifiers(root)
    end

    def transform
      rewrite(@root)
    end

    private

    def rewrite(node)
      case node
      when nil
        nil
      when Array
        node.map { |child| rewrite(child) }
      when Node
        rewrite_node(node)
      else
        node
      end
    end

    def rewrite_node(node)
      case node
      when MethodAddBlock
        if node.call.is_a?(ARef) &&
             contains_safe_navigation?(node.call.collection)
          raise UnsupportedSyntax,
                "blocks attached to indexed safe-navigation " \
                  "continuations are not supported"
        end

        if blockable_safe_chain?(node.call)
          transform_blockable(node)
        else
          copy_node(node)
        end
      when CallNode
        safe_operator?(node.operator) ? transform_call(node) : copy_node(node)
      when CommandCall
        if safe_operator?(node.operator)
          transform_command_call(node)
        else
          copy_node(node)
        end
      when Assign
        safe_target?(node.target) ? transform_assign(node) : copy_node(node)
      when OpAssign
        safe_target?(node.target) ? transform_opassign(node) : copy_node(node)
      when MLHS
        validate_multiple_assignment_targets(node)
        copy_node(node)
      else
        copy_node(node)
      end
    end

    def copy_node(node)
      attributes = node.deconstruct_keys(nil)
      attributes.delete(:comments)
      attributes.delete(:location)

      node.copy(location: node.location, **transform_attributes(attributes))
    end

    def transform_attributes(attributes)
      attributes.each_with_object({}) do |(name, value), transformed|
        transformed[name] = case value
        when Node
          rewrite(value)
        when Array
          value.map do |item|
            if item.is_a?(Array)
              item.map { |nested| rewrite(nested) }
            else
              rewrite(item)
            end
          end
        else
          value
        end
      end
    end

    def transform_call(node)
      receiver = rewrite(node.receiver)

      temporary = temporary_variable
      invocation =
        node.copy(
          receiver: reference(temporary),
          operator: Period.new(value: ".", location: Location.default),
          arguments: rewrite(node.arguments)
        )

      guarded(temporary, receiver, invocation)
    end

    def transform_command_call(node)
      receiver = rewrite(node.receiver)

      temporary = temporary_variable
      invocation =
        node.copy(
          receiver: reference(temporary),
          operator: Period.new(value: ".", location: Location.default),
          arguments: rewrite(node.arguments),
          block: rewrite(node.block)
        )

      guarded(temporary, receiver, invocation)
    end

    def transform_blockable(node)
      call = node.call

      if call.is_a?(CallNode)
        receiver = rewrite(call.receiver)
        temporary = temporary_variable

        invocation =
          node.copy(
            call:
              call.copy(
                receiver: reference(temporary),
                operator: Period.new(value: ".", location: Location.default),
                arguments: rewrite(call.arguments)
              ),
            block: rewrite(node.block)
          )

        guarded(temporary, receiver, invocation)
      end
    end

    def transform_assign(node)
      target = node.target
      receiver = rewrite(target.parent)
      value = rewrite(node.value)
      temporary = temporary_variable

      assignment =
        Assign.new(
          target:
            target.copy(
              parent: reference(temporary),
              operator: Period.new(value: ".", location: Location.default)
            ),
          value: value,
          location: node.location
        )
      assignment.comments.concat(node.comments.map(&:copy))

      guarded(temporary, receiver, assignment, nil_value)
    end

    def transform_opassign(node)
      target = node.target
      receiver = rewrite(target.parent)
      value = rewrite(node.value)
      temporary = temporary_variable

      field =
        target.copy(
          parent: reference(temporary),
          operator: Period.new(value: ".", location: Location.default)
        )

      assignment =
        case node.operator.value
        when "||="
          IfNode.new(
            predicate: reference_field(field),
            statements:
              Statements.new(
                body: [reference_field(field)],
                location: Location.default
              ),
            consequent:
              Else.new(
                keyword: Keyword.default("else"),
                statements:
                  Statements.new(
                    body: [
                      Assign.new(
                        target: field,
                        value: value,
                        location: Location.default
                      )
                    ],
                    location: Location.default
                  ),
                location: Location.default
              ),
            location: Location.default
          )
        when "&&="
          IfNode.new(
            predicate: reference_field(field),
            statements:
              Statements.new(
                body: [
                  Assign.new(
                    target: field,
                    value: value,
                    location: Location.default
                  )
                ],
                location: Location.default
              ),
            consequent:
              Else.new(
                keyword: Keyword.default("else"),
                statements:
                  Statements.new(body: [nil_value], location: Location.default),
                location: Location.default
              ),
            location: Location.default
          )
        else
          operator = node.operator.value.delete_suffix("=").to_sym
          Assign.new(
            target: field,
            value:
              Binary.new(
                left: reference_field(field),
                operator: operator,
                right: value,
                location: Location.default
              ),
            location: node.location
          )
        end

      assignment.comments.concat(node.comments.map(&:copy))
      guarded(temporary, receiver, assignment, nil_value)
    end

    def guarded(temporary, receiver, truthy, falsy = nil_value)
      assignment =
        Assign.new(
          target:
            VarField.new(
              value: identifier(temporary),
              location: Location.default
            ),
          value: receiver,
          location: Location.default
        )

      conditional =
        IfNode.new(
          predicate: not_nil(reference(temporary)),
          statements:
            Statements.new(body: [truthy], location: Location.default),
          consequent:
            Else.new(
              keyword: Keyword.default("else"),
              statements:
                Statements.new(body: [falsy], location: Location.default),
              location: Location.default
            ),
          location: Location.default
        )

      Paren.new(
        lparen: LParen.default,
        contents:
          Statements.new(
            body: [assignment, conditional],
            location: Location.default
          ),
        location: Location.default
      )
    end

    def reference(name)
      VarRef.new(value: identifier(name), location: Location.default)
    end

    def reference_field(field)
      CallNode.new(
        receiver: field.parent,
        operator: Period.new(value: ".", location: Location.default),
        message: field.name.copy,
        arguments: nil,
        location: Location.default
      )
    end

    def identifier(value)
      Ident.new(value: value, location: Location.default)
    end

    def nil_value
      VarRef.new(value: Keyword.default("nil"), location: Location.default)
    end

    def not_nil(value)
      Unary.new(
        operator: "!",
        statement:
          CallNode.new(
            receiver: nil_value,
            operator: Period.new(value: ".", location: Location.default),
            message: Ident.new(value: "equal?", location: Location.default),
            arguments:
              ArgParen.new(
                arguments: Args.new(parts: [value], location: Location.default),
                location: Location.default
              ),
            location: Location.default
          ),
        location: Location.default
      )
    end

    def temporary_variable
      loop do
        name = "_syntax_tree_safe_navigation_#{@temporary_index}"
        @temporary_index += 1

        unless @temporary_names.include?(name)
          @temporary_names << name
          return name
        end
      end
    end

    def safe_operator?(operator)
      operator.is_a?(Op) && operator.value == "&."
    end

    def safe_target?(target)
      target.is_a?(Field) && safe_operator?(target.operator)
    end

    def blockable_safe_chain?(node)
      case node
      when CallNode, CommandCall
        safe_operator?(node.operator)
      else
        false
      end
    end

    def contains_safe_navigation?(node)
      case node
      when Op
        node.value == "&."
      when Node
        node.child_nodes.any? { |child| contains_safe_navigation?(child) }
      when Array
        node.any? { |child| contains_safe_navigation?(child) }
      else
        false
      end
    end

    def validate_multiple_assignment_targets(node)
      unsupported = node.parts.any? { |target| unsafe_target?(target) }
      return unless unsupported

      raise UnsupportedSyntax,
            "safe navigation in multiple assignment targets is not supported"
    end

    def unsafe_target?(node)
      case node
      when Field
        safe_operator?(node.operator)
      when MLHSParen
        unsafe_target?(node.contents)
      when MLHS
        node.parts.any? { |target| unsafe_target?(target) }
      when ARefField
        unsafe_target?(node.collection)
      else
        false
      end
    end

    def collect_identifiers(node, identifiers = [])
      case node
      when Ident
        identifiers << node.value
      when Node
        node.child_nodes.each do |child|
          collect_identifiers(child, identifiers)
        end
      when Array
        node.each { |child| collect_identifiers(child, identifiers) }
      end

      identifiers
    end

    # Provides keyword nodes without depending on parser token state.
    module Keyword
      def self.default(value)
        Kw.new(value: value, location: Location.default)
      end
    end

    private_constant :Keyword
  end
end
