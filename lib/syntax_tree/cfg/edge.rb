# frozen_string_literal: true

module SyntaxTree
  module CFG
    Edge = Struct.new(:id, :from, :to, :type, :location, :label, :metadata, keyword_init: true) do
      def initialize(**attributes)
        attributes[:type] ||= :fallthrough
        attributes[:metadata] ||= {}
        super
      end
    end
  end
end
