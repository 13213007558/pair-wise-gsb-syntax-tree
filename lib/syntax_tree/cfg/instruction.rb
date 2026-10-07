# frozen_string_literal: true

module SyntaxTree
  module CFG
    Instruction = Struct.new(:id, :type, :source, :location, :effects, keyword_init: true)
  end
end
