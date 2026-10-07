# frozen_string_literal: true

module SyntaxTree
  class CFG
    class Region
      attr_reader :id,
                  :kind,
                  :location,
                  :entry,
                  :exception_exit,
                  :normal_exit,
                  :return_exit,
                  :break_exit,
                  :next_exit,
                  :iterator_continue,
                  :metadata

      def initialize(
        id:,
        kind:,
        location:,
        entry:,
        exception_exit: nil,
        normal_exit:,
        return_exit: nil,
        break_exit: nil,
        next_exit: nil,
        iterator_continue: nil,
        metadata: nil
      )
        @id = id
        @kind = kind
        @location = location
        @entry = entry
        @exception_exit = exception_exit
        @normal_exit = normal_exit
        @return_exit = return_exit
        @break_exit = break_exit
        @next_exit = next_exit
        @iterator_continue = iterator_continue
        @metadata = metadata || {}
      end

      def to_h
        {
          id: id,
          kind: kind,
          entry: entry,
          exception_exit: exception_exit,
          normal_exit: normal_exit,
          return_exit: return_exit,
          break_exit: break_exit,
          next_exit: next_exit,
          iterator_continue: iterator_continue,
          location: location && location.deconstruct_keys(nil),
          metadata: metadata
        }
      end
    end
  end
end
