# frozen_string_literal: true

module SyntaxTree
  class CFG
    class BasicBlock
      attr_reader :id, :label, :kind, :location, :instructions

      def initialize(
        id:,
        label:,
        kind:,
        location: Location.default,
        source: nil
      )
        @id = id
        @label = label
        @kind = kind
        @location = location
        @source = source
        @instructions = []
      end

      def push(node)
        @location ||= node.location
        instructions << node
        self
      end

      def empty?
        instructions.empty?
      end

      def to_h
        {
          id: id,
          label: label,
          kind: kind,
          location: location && location.deconstruct_keys(nil),
          instructions: instructions.map { |node| instruction_to_h(node) }
        }
      end

      private

      def instruction_to_h(node)
        {
          type: node.class.name.split("::").last,
          location: node.location.deconstruct_keys(nil),
          source: source_for(node)
        }
      end

      def source_for(node)
        return nil unless @source

        @source[node.location.start_char...node.location.end_char]
      end
    end
  end
end
