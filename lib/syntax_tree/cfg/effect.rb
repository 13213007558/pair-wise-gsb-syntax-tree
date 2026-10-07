# frozen_string_literal: true

module SyntaxTree
  class CFG
    class Effect
      attr_reader :id, :kind, :location, :node, :method_name, :metadata

      def initialize(
        id:,
        kind:,
        location:,
        node: nil,
        method_name: nil,
        metadata: nil
      )
        @id = id
        @kind = kind
        @location = location
        @node = node
        @method_name = method_name
        @metadata = metadata || {}
      end

      def to_h
        {
          id: id,
          kind: kind,
          method_name: method_name,
          location: location.deconstruct_keys(nil),
          metadata: metadata
        }
      end
    end
  end
end
