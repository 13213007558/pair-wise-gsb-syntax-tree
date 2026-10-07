# frozen_string_literal: true

module SyntaxTree
  class CFG
    class Edge
      attr_reader :source, :target, :type, :condition, :location, :metadata

      def initialize(
        source:,
        target:,
        type: :fallthrough,
        condition: nil,
        location: nil,
        metadata: nil
      )
        @source = source
        @target = target
        @type = type
        @condition = condition
        @location = location
        @metadata = metadata || {}
      end

      def to_h
        {
          source: source,
          target: target,
          type: type,
          condition: condition,
          location: location && location.deconstruct_keys(nil),
          metadata: metadata
        }
      end
    end
  end
end
