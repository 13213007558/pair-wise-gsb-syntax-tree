# frozen_string_literal: true

require_relative "cfg/basic_block"
require_relative "cfg/builder"
require_relative "cfg/edge"
require_relative "cfg/effect"
require_relative "cfg/exit"
require_relative "cfg/path_checker"
require_relative "cfg/region"

module SyntaxTree
  class CFG
    attr_reader :method_name,
                :source_location,
                :source,
                :entry_block,
                :blocks,
                :edges,
                :exits,
                :effects,
                :regions

    def initialize(method_name:, source_location:, entry_block:, source: nil)
      @method_name = method_name
      @source_location = source_location
      @source = source
      @entry_block = entry_block
      @blocks = []
      @edges = []
      @exits = []
      @effects = []
      @regions = []
    end

    def block(id)
      blocks.find { |block| block.id == id }
    end

    def outgoing(block_id)
      edges.select { |edge| edge.source == block_id }
    end

    def incoming(block_id)
      edges.select { |edge| edge.target == block_id }
    end

    def check_path(choices: {}, effects: {}, iterations: {}, max_steps: 1000)
      PathChecker.new(self).check(
        choices: choices,
        effects: effects,
        iterations: iterations,
        max_steps: max_steps
      )
    end

    def to_h
      {
        method_name: method_name,
        source_location: source_location.deconstruct_keys(nil),
        entry_block: entry_block,
        blocks: blocks.map(&:to_h),
        edges: edges.map(&:to_h),
        exits: exits.map(&:to_h),
        effects: effects.map(&:to_h),
        regions: regions.map(&:to_h)
      }
    end

    def self.for(source, method_name: nil)
      program = source.is_a?(Node) ? source : SyntaxTree.parse(source)
      Builder.new(
        program,
        method_name,
        source.is_a?(String) ? source : nil
      ).build
    end
  end
end
