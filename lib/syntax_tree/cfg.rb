# frozen_string_literal: true

require_relative "../syntax_tree"
require_relative "cfg/source_location"
require_relative "cfg/instruction"
require_relative "cfg/basic_block"
require_relative "cfg/edge"
require_relative "cfg/graph"
require_relative "cfg/builder"
require_relative "cfg/path_checker"

module SyntaxTree
  # Build a conservative control-flow graph without evaluating source code.
  module CFG
    UNKNOWN_CALL_TARGET = :unknown

    # Build the control-flow graph for one method definition. Basic blocks and
    # edges carry source locations. Potentially failing expressions have
    # exception edges and calls without resolvable effects are represented with
    # explicit unknown effect metadata and call edges.
    def self.build(source, method_name: nil)
      program = SyntaxTree.parse(source)
      Builder.new(program, source, method_name).build
    end

    def self.for_method(source, method_name)
      build(source, method_name: method_name)
    end

    # Follow one concrete path through a graph. Choices can key off branch
    # labels or an instruction source/id. The returned event list records
    # ensure entry, region entry/exit, calls, and the final method exit without
    # evaluating the analyzed source.
    def self.check_path(source, method_name:, choices: {}, invoke_blocks: true)
      graph = for_method(source, method_name)
      PathChecker.new(graph, choices, invoke_blocks).run
    end
  end
end
