# frozen_string_literal: true

module SyntaxTree
  # Provides an interface for searching for a pattern of nodes against a
  # subtree of an AST.
  class Search
    attr_reader :pattern

    def initialize(pattern)
      @pattern = pattern
    end

    def scan(root)
      return to_enum(__method__, root) unless block_given?
      queue = [root]

      until queue.empty?
        node = queue.shift
        next unless node

        yield node if pattern.call(node)
        queue += node.child_nodes
      end
    end

    # Scans the given subtree for nodes that match the pattern, yielding
    # each matching node along with the result of matching it. When the
    # pattern was compiled with Pattern#compile_with_captures, the result
    # is a SyntaxTree::Pattern::Match containing the values and source
    # locations that the pattern captured.
    def scan_with_captures(root)
      return to_enum(__method__, root) unless block_given?
      queue = [root]

      until queue.empty?
        node = queue.shift
        next unless node

        if (match = pattern.call(node))
          yield node, match
        end

        queue += node.child_nodes
      end
    end
  end
end
