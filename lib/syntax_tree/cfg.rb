# frozen_string_literal: true

require_relative "cfg/collector"
require_relative "cfg/builder"

module SyntaxTree
  # CFG provides read-only control flow graphs for methods, blocks, and
  # lambdas. Graph nodes do not own or mutate their source AST nodes.
  module CFG
    # A basic block in a control flow graph. +node+ is nil for synthetic entry,
    # exit, join, and test blocks.
    Block = Struct.new(:id, :node, :kind)

    # An edge between basic blocks. Every edge records the AST location that
    # caused it, along with semantic information about the represented flow.
    Edge =
      Struct.new(
        :from,
        :to,
        :type,
        :location,
        :reason,
        :replaces
      ) do
        def replaces?
          replaces
        end
      end

    # The immutable graph returned by CFG.build.
    class Graph
      include Enumerable

      attr_reader :entry, :exit, :entry_node

      EMPTY_ARRAY = [].freeze

      def initialize(entry_node, blocks, edges, entry, exit_block)
        @entry_node = entry_node
        @blocks = blocks.each(&:freeze).freeze
        @edges = edges.each(&:freeze).freeze
        @entry = entry
        @exit = exit_block

        @by_id = @blocks.map { |block| [block.id, block] }.to_h.freeze
        @outgoing = Hash.new { |hash, key| hash[key] = [] }
        @incoming = Hash.new { |hash, key| hash[key] = [] }

        @edges.each do |edge|
          @outgoing[edge.from] << edge
          @outgoing[edge.to]
          @incoming[edge.to] << edge
          @incoming[edge.from]
        end

        @outgoing.each_value { |edges| edges.freeze }
        @incoming.each_value { |edges| edges.freeze }
        @outgoing.freeze
        @incoming.freeze
        freeze
      end

      def each(&block)
        @blocks.each(&block)
      end

      def [](id)
        @by_id[id]
      end

      def blocks
        @blocks.to_enum { @blocks.length }
      end

      def edges
        @edges.to_enum { @edges.length }
      end

      def predecessors(id)
        @incoming.fetch(id, EMPTY_ARRAY)
      end

      def successors(id = @entry)
        @outgoing.fetch(id, EMPTY_ARRAY)
      end
    end

    def self.build(entry)
      Builder.new(entry).build
    end

    def self.for_source(source)
      Collector.collect(SyntaxTree.parse(source)).map { |entry| build(entry) }
    end
  end
end
