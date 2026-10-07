# frozen_string_literal: true

module SyntaxTree
  module CFG
    class Graph
      attr_accessor :name, :entry, :exit
      attr_reader :blocks, :edges, :exits, :regions

      def initialize(name)
        @name = name
        @blocks = []
        @edges = []
        @edge_sequence = 0
        @exits = {}
        @regions = {}
      end

      def exits=(value)
        @exits = value
      end

      def add_block(kind = :basic, location: nil)
        id = "bb#{blocks.length + 1}"
        block = BasicBlock.new(id: id, kind: kind, location: location)
        blocks << block
        block
      end

      def add_edge(from, to, type = :fallthrough, location: nil, label: nil, **metadata)
        @edge_sequence += 1
        edge = Edge.new(
          id: "edge#{@edge_sequence}",
          from: from,
          to: to,
          type: type,
          location: location,
          label: label,
          metadata: metadata
        )
        edges << edge
        edge
      end

      def outgoing(block)
        edges.select { |edge| edge.from == block }
      end

      def instructions
        blocks.flat_map(&:instructions)
      end

      def to_h
        {
          name: name,
          entry: entry.id,
          exit: exit.id,
          blocks: blocks.map { |block| serialize_block(block) },
          edges: edges.map { |edge| serialize_edge(edge) },
          exits: exits.transform_values(&:id),
          regions: regions.transform_values do |region|
            { entry: region[:entry].id, exits: region[:exits].transform_values(&:id) }
          end
        }
      end

      private

      def serialize_block(block)
        {
          id: block.id,
          kind: block.kind,
          location: serialize_location(block.location),
          instructions: block.instructions.map { |instruction| serialize_instruction(instruction) }
        }
      end

      def serialize_instruction(instruction)
        {
          id: instruction.id,
          type: instruction.type,
          source: instruction.source,
          location: serialize_location(instruction.location),
          effects: instruction.effects.map { |effect| serialize_effect(effect) }
        }
      end

      def serialize_effect(effect)
        effect.each_with_object({}) do |(key, value), result|
          result[key] = value.is_a?(SourceLocation) ? serialize_location(value) : value
        end
      end

      def serialize_edge(edge)
        {
          from: block_id(edge.from),
          to: block_id(edge.to),
          type: edge.type,
          label: edge.label,
          location: serialize_location(edge.location),
          metadata: edge.metadata
        }
      end

      def serialize_location(location)
        return nil unless location

        {
          start_line: location.start_line,
          start_column: location.start_column,
          end_line: location.end_line,
          end_column: location.end_column
        }
      end

      def block_id(block)
        block.respond_to?(:id) ? block.id : block.to_s
      end
    end
  end
end
