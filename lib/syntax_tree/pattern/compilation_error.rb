# frozen_string_literal: true

module SyntaxTree
  class Pattern
    # Raised when the query given to a pattern is either invalid Ruby syntax,
    # is using syntax that we don't yet support, executes input Ruby, or asks
    # for captures that are illegal or ambiguously bound across branches.
    class CompilationError < StandardError
      def initialize(repr, detail = nil)
        message = <<~ERROR
          Syntax Tree was unable to compile the pattern you provided to search
          into a usable expression. It failed on to understand the node
          represented by:

          #{repr}
        ERROR

        message += "\n#{detail}\n" if detail
        super(message)
      end
    end
  end
end
