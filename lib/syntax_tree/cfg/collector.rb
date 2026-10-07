# frozen_string_literal: true

module SyntaxTree
  module CFG
    # Collects method, block, and lambda entry points. Nested blocks are kept
    # as independent entries rather than being inlined into an outer method.
    class Collector < Visitor
      attr_reader :entries

      def initialize
        super
        @entries = []
      end

      def self.collect(node)
        collector = new
        node.accept(collector)
        collector.entries
      end

      def visit_def(node)
        @entries << node
        super
      end

      def visit_block(node)
        @entries << node
        super
      end

      def visit_lambda(node)
        @entries << node
        super
      end

      def visit_method_add_block(node)
        visit(node.call)
        visit(node.block)
      end
    end
  end
end
