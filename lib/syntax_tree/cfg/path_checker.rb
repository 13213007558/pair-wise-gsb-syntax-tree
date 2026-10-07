# frozen_string_literal: true

module SyntaxTree
  class CFG
    class PathChecker
      Result = Struct.new(:events, :exit, keyword_init: true)

      def initialize(cfg)
        @cfg = cfg
      end

      def check(choices: {}, effects: {}, iterations: {}, max_steps: 1000)
        @choices = choices
        @effects = effects
        @iterations = iterations
        @events = []
        @outcome_stack = []
        @outcome_stack << { trigger: :normal }
        block = @cfg.block(@cfg.entry_block)

        max_steps.times do
          break unless block

          record_block(block)
          edges = @cfg.outgoing(block.id)
          return finish(block) if edges.empty?

          edge = select_edge(edges)
          record_edge(edge)
          return finish(nil, unresolved: true) if edge.type == :nonlocal_return

          next_id = traverse(edge)
          block = @cfg.block(next_id)
        end

        raise "path did not terminate within #{max_steps} steps"
      end

      private

      def record_block(block)
        @events << {
          kind: :block,
          block: block.id,
          label: block.label,
          location: location(block.location)
        }
        block.instructions.each do |node|
          @events << {
            kind: :expression,
            type: node.class.name.split("::").last,
            location: location(node.location)
          }
        end
      end

      def record_edge(edge)
        case edge.type
        when :branch, :rescue_match
          @events << {
            kind: :branch,
            value: edge.condition,
            location: location(edge.location)
          }
        when :exception
          @events << {
            kind: :exception,
            location: location(edge.location),
            metadata: edge.metadata
          }
        when :return, :lambda_return
          @events << {
            kind: :return,
            location: location(edge.location),
            metadata: edge.metadata
          }
        when :break, :next, :redo, :retry
          @events << {
            kind: edge.type,
            location: location(edge.location),
            metadata: edge.metadata
          }
        when :ensure_exit
          @events << {
            kind: :ensure_exit,
            trigger: edge.metadata[:trigger],
            location: location(edge.location)
          }
        when :invoke_block, :invoke_lambda, :reinvoke_block, :return_from_call
          @events << {
            kind: edge.type,
            metadata: edge.metadata,
            location: location(edge.location)
          }
        end
      end

      def traverse(edge)
        target = edge.target
        case edge.type
        when :invoke_block, :reinvoke_block
          @outcome_stack.push(edge.metadata.dup)
        when :block_normal, :next
          @outcome_stack.last&.merge!(edge.metadata) if @outcome_stack.last
        when :return, :break
          if edge.metadata[:terminal_target]
            @pending_trigger = edge.type.to_sym
            @outcome_stack << edge.metadata.merge(
              trigger: edge.type.to_sym,
              target: edge.metadata[:terminal_target]
            )
          end
        end
        if edge.type == :ensure_exit
          incoming = @outcome_stack.last || { trigger: :normal }
          trigger =
            @pending_trigger || incoming[:trigger] || edge.metadata[:trigger]
          matching = trigger == :normal ? :normal : trigger
          if edge.metadata[:trigger] == matching
            if edge.metadata[:trigger] == :normal && incoming[:trigger]
              @pending_trigger = incoming[:trigger]
            elsif edge.metadata[:terminal_trigger]
              @pending_trigger = edge.metadata[:terminal_trigger]
            elsif edge.metadata[:trigger] != :normal
              @pending_trigger = incoming[:trigger]
            else
              @pending_trigger = nil
            end
            @outcome_stack.pop unless @outcome_stack.size == 1
          end
        end
        target
      end

      def select_edge(edges)
        branch =
          edges.find do |edge|
            edge.type == :branch || edge.type == :rescue_match
          end
        if branch
          condition =
            chosen(
              branch.location,
              edges.map { |edge| edge.condition },
              branch.condition
            )
          selected = edges.find { |edge| edge.condition == condition }
          return selected || branch
        end

        pending =
          edges.find do |edge|
            edge.type == :ensure_exit &&
              edge.metadata[:trigger] == @pending_trigger
          end
        return pending if pending

        effect_edges = edges.select { |edge| edge.metadata[:effect] }
        if effect_edges.any?
          decision = effect_decision(effect_edges.first)
          selected =
            case decision
            when :exception
              edges.find { |edge| edge.type == :exception }
            when :return
              edges.find { |edge| edge.type == :nonlocal_return }
            else
              edges.find do |edge|
                %i[invoke_block invoke_lambda return_from_call].include?(
                  edge.type
                )
              end
            end
          return selected || effect_edges.first
        end

        invoke = edges.find { |edge| edge.type == :invoke_block }
        return invoke if invoke

        if edges.one?
          edges.first
        else
          edges.find { |edge| edge.type == :fallthrough } ||
            edges.find { |edge| edge.type == :return || edge.type == :break } ||
            edges.find { |edge| edge.type == :exception } || edges.first
        end
      end

      def effect_decision(edge)
        effect_id = edge.metadata[:effect]
        @effects[effect_id] || @effects[effect_id.to_sym] ||
          lookup(@effects, edge.location, :normal, :normal)
      end

      def chosen(location, values, default)
        candidates = values.compact.uniq
        selected = lookup(@choices, location, nil, nil)
        selected ||= branch_default(location, default)
        candidates.include?(selected) ? selected : default
      end

      def branch_default(location, default)
        return default unless location

        iterations = lookup(@iterations, location, 0, 0)
        iterations.to_i.positive? ? :truthy : :falsy
      end

      def lookup(collection, location, default, fallback)
        return fallback unless location.respond_to?(:start_line)

        key = [location&.start_line, location&.start_char].compact.join(":")
        value =
          collection[key.to_sym] || collection[key] ||
            collection[location&.start_line] || default
        value.nil? ? fallback : value
      end

      def finish(block)
        exit_kind =
          case block&.kind
          when :method_exit
            :normal
          when :exception_exit
            :exception
          when :unresolved_exit
            :unresolved
          end
        Result.new(
          events: @events,
          exit: { kind: exit_kind, block: block&.id }.compact
        )
      end

      def location(location)
        location && location.deconstruct_keys(nil)
      end
    end
  end
end
