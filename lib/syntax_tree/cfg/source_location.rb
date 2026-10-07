# frozen_string_literal: true

module SyntaxTree
  module CFG
    SourceLocation = Struct.new(:start_line, :start_column, :end_line, :end_column, keyword_init: true)
  end
end
