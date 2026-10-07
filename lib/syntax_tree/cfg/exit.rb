# frozen_string_literal: true

module SyntaxTree
  class CFG
    class Exit
      attr_reader :kind, :block, :location, :metadata

      def initialize(kind:, block:, location: nil, metadata: nil)
        @kind = kind
        @block = block
        @location = location
        @metadata = metadata || {}
      end

      def to_h
        {
          kind: kind,
          block: block,
          location: location && location.deconstruct_keys(nil),
          metadata: metadata
        }
      end
    end
  end
end
