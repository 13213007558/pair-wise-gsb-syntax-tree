# frozen_string_literal: true

module SyntaxTree
  module CFG
    class PathChecker
      def initialize(graph, choices = {}, invoke_blocks = true)
        @graph = graph
        @choices = choices
        @invoke_blocks = invoke_blocks
        @events = []
        @edge_ids = []
        @pending = nil
      end

      def run
        follow(@graph.entry, {})
        { events: @events, exit: @exit, edges: @edge_ids }
      end

      private

      def follow(block, active)
        return unless block.respond_to?(:instructions)
        return :cycle if active[block]

        block.instructions.each { |instruction| @events << event_for(instruction) }
        edges = @graph.outgoing(block)
        return finish(block) if edges.empty?

        edge = select_edge(block, edges)
        @edge_ids << edge.id
        return traverse(edge, active.merge(block => true))
      end

      def event_for(instruction)
        {
          id: instruction.id,
          type: instruction.type,
          source: instruction.source,
          location: instruction.location.to_h
        }
      end

      def select_edge(block, edges)
        return select_pending_edge(edges) if @pending
        return edges.first if edges.length == 1

        selected = edges.find { |edge| matches_choice?(block, edge) }
        selected || default_edge(edges)
      end

      def select_pending_edge(edges)
        dispatch = edges.find { |edge| edge.type == :ensure_dispatch && edge.metadata[:outcome][:kind] == @pending }
        if dispatch
          @pending = nil
          return dispatch
        end

        selected_exception = edges.find do |edge|
          edge.type == :exception && matches_choice?(@current_block, edge)
        end
        selected_exception ||
          edges.find { |edge| edge.type == :call_return } ||
          edges.find { |edge| edge.type != :exception } || edges.first
      end

      def select_non_exception(edges)
        edges.find { |edge| edge.type != :exception } || edges.first
      end

      def default_edge(edges)
        edges.find { |edge| edge.type == :call_return } ||
          edges.find { |edge| edge.type == :branch && edge.label == :falsy } ||
          edges.find { |edge| edge.type != :exception } || edges.first
      end

      def matches_choice?(block, edge)
        return false unless block
        instruction = block.instructions.last
        choice = @choices[instruction&.id] || @choices[instruction&.source] || @choices[edge.label]
        case edge.type
        when :branch, :rescue_match, :match
          choice == edge.label
        when :exception
          choice == :exception
        when :block_entry
          choice.nil? ? @invoke_blocks : choice == :enter
        when :loop_back, :redo, :retry
          choice == edge.type
        else
          false
        end
      end

      def traverse(edge, active)
        if edge.type == :ensure_enter
          @pending = edge.metadata[:outcome][:kind]
        end

        region = region_for(edge)
        if region
          return follow_region(region, active)
        else
          return follow(edge.to, active)
        end
      end

      def region_for(edge)
        return unless edge.type == :block_entry || edge.type == :call

        if edge.metadata[:lambda]
          @graph.regions[edge.metadata[:lambda]]
        else
          @graph.regions.values.find { |region| region[:entry] == edge.to }
        end
      end

      def follow_region(region, active)
        @events << { type: :region_enter, region: region[:id] }
        result = follow(region[:entry], active)
        return unless result == :region_exit

        block = @current_block
        exit_name = region[:exits].key(block)
        @events << { type: :region_exit, region: region[:id], exit: exit_name }
        edges = @graph.outgoing(block)
        return unless edges.any?

        edge = edges.find { |candidate| candidate.type.to_s.include?(exit_name.to_s) } || edges.first
        @edge_ids << edge.id
        return traverse(edge, active)
      end

      def finish(block)
        exit_name = @graph.exits.key(block)
        if exit_name && @graph.outgoing(block).empty?
          @events << { type: :exit, exit: exit_name }
          @exit = exit_name
          :method_exit
        else
          :region_exit
        end
      end
    end
  end
end
