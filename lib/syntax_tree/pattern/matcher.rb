# frozen_string_literal: true

module SyntaxTree
  class Pattern
    # Matcher is the internal interface implemented by each compiled piece of a
    # pattern. A matcher receives the value to test, the current set of named
    # captures, and the chain of ancestor nodes (outermost last). It returns a
    # boolean indicating whether the match succeeded and mutates the bindings
    # when captures are taken. Compound matchers are responsible for restoring
    # the bindings when a branch fails so failed branches cannot leak captures
    # into later branches.
    module Matcher
      # The set of capture names this matcher can bind at this binding
      # boundary. Used at compile time to validate alternation branches.
      attr_reader :captures

      def match?(_value, _bindings, _ancestors)
        raise NotImplementedError
      end

      private

      # Runs the given block with its own binding boundary: captures taken by
      # a failed branch are discarded, while captures taken by a successful
      # branch are committed back into the surrounding bindings.
      def with_boundary(bindings, name_set)
        branch = bindings.child
        success = yield(branch)
        success = bindings.commit(branch, name_set) if success
        success
      end

      # Runs the given block with an isolated binding boundary. Any captures
      # taken inside the block (including on success) are discarded when it
      # returns. Used for negative conditions and ancestor constraints, where
      # captures are used only to express structural equality within the
      # condition.
      def with_isolation(bindings)
        # The isolated boundary can see nothing from its surroundings, so
        # negative conditions and ancestor constraints cannot accidentally
        # observe captures taken by the guarded pattern. Repeated names used
        # purely within the condition still compare against each other.
        isolated = Pattern::Compiler::Bindings.new
        yield(isolated)
      end
    end
  end
end
