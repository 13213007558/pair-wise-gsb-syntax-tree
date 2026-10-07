# frozen_string_literal: true

module SyntaxTree
  module CFG
    BasicBlock = Struct.new(:id, :kind, :instructions, :location, keyword_init: true) do
      def initialize(**attributes)
        attributes[:kind] ||= :basic
        attributes[:instructions] ||= []
        super
      end
    end
  end
end
