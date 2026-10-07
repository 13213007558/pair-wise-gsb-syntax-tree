# frozen_string_literal: true

module SyntaxTree
  # Provides an interface for searching for a pattern of nodes against a
  # subtree of an AST.
  class Search
    attr_reader :pattern

    def initialize(pattern)
      @pattern = pattern
    end

    # Walks the tree using the boolean interface. Yields every node that the
    # pattern matches. When no block is given, returns an enumerator of the
    # matched nodes.
    def scan(root)
      return to_enum(__method__, root) unless block_given?

      walk(root) { |node, _ancestors| yield node }
    end

    # Walks the tree and yields pairs of matched nodes and their
    # Pattern::MatchResult objects. This makes captures and ancestor
    # constraints available while searching. When no block is given, returns
    # an enumerator of the pairs.
    def scan_with_matches(root)
      return to_enum(__method__, root) unless block_given?

      walk(root) do |node, ancestors|
        result =
          if pattern.respond_to?(:match)
            pattern.match(node, ancestors)
          else
            pattern.call(node, ancestors) && Pattern::MatchResult.new(node, {})
          end

        yield node, result if result
      end
    end

    private

    def walk(node, ancestors = [], &block)
      return unless node

      node.child_nodes.each do |child|
        walk(child, ancestors + [node], &block)
      end

      result = pattern.call(node, ancestors)
      block.call(node, ancestors) if result
    end
  end
end
