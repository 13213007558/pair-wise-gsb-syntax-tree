# frozen_string_literal: true

require_relative "pattern/matcher"
require_relative "pattern/bindings"
require_relative "pattern/compiler"
require_relative "pattern/compilation_error"

module SyntaxTree
  # A pattern is an object that wraps a Ruby pattern matching expression. The
  # expression would normally be passed to an `in` clause within a `case`
  # expression or a rightward assignment expression. For example, in the
  # following snippet:
  #
  #     case node
  #     in Const[value: "SyntaxTree"]
  #     end
  #
  # the pattern is the `Const[value: "SyntaxTree"]` expression.
  #
  # The pattern gets compiled by running the #compile method. The returned
  # object responds to #call with a single argument, which is the node to match
  # against, and returns a boolean. It also responds to #match, which returns a
  # Pattern::MatchResult (or nil if the match failed) that contains any named
  # captures taken during the match. For example:
  #
  #     matcher = SyntaxTree::Pattern.new("CallNode[receiver: rec]").compile
  #     matcher.call(node)
  #     result = matcher.match(node)
  #     result.captures[:rec] #=> { value: ..., location: ... }
  #
  # In addition to the pattern matching syntax documented below, bare
  # identifiers act as captures. The first occurrence binds the matched node
  # (or sequence, for splats) to the name, and any repeated occurrence must
  # match a structurally equal node (ignoring locations and comments).
  #
  # If the query given to the initializer cannot be compiled into a valid
  # matcher (either because of a syntax error, because it is using syntax we do
  # not yet support, or because it asks for ambiguous captures) then a
  # SyntaxTree::Pattern::CompilationError will be raised.
  class Pattern
    # A single named capture produced by matching a pattern against a node.
    #
    # +value+ is the node (or array of nodes for a splat capture) that was
    # matched, and +location+ is the corresponding source range (which can be
    # empty for a splat that matched nothing).
    class Capture
      attr_reader :name, :value, :location

      def initialize(name, value, location)
        @name = name
        @value = value
        @location = location
      end

      def ==(other)
        other.is_a?(Capture) && name == other.name && value == other.value
      end
      alias eql? ==

      def hash
        [name, value].hash
      end
    end

    # The result of successfully matching a compiled pattern against a node.
    #
    # +node+ is the node that was matched and +captures+ is a hash of capture
    # names to Capture objects.
    class MatchResult
      attr_reader :node, :captures

      def initialize(node, captures)
        @node = node
        @captures = captures
      end

      # Fetches the value bound to the given capture name.
      def [](name)
        captures.fetch(name.to_sym).value
      end

      # Fetches the source range bound to the given capture name.
      def location(name)
        captures.fetch(name.to_sym).location
      end

      def to_h
        captures.transform_values(&:value)
      end
    end

    # The object returned by Pattern#compile. It supports the original boolean
    # interface through #call and #===, and exposes #match for retrieving the
    # named captures that a pattern takes.
    class Compiled
      attr_reader :query, :matcher

      def initialize(query, matcher)
        @query = query
        @matcher = matcher
      end

      def call(node, ancestors = [])
        matcher.match?(node, Compiler::Bindings.new, ancestors)
      end

      def ===(node)
        call(node)
      end

      def match(node, ancestors = [])
        bindings = Compiler::Bindings.new

        if matcher.match?(node, bindings, ancestors)
          MatchResult.new(node, bindings.captures)
        end
      end
    end

    attr_reader :query

    def initialize(query)
      @query = query
    end

    def compile
      program =
        begin
          SyntaxTree.parse("case nil\nin #{query}\nend")
        rescue Parser::ParseError
          raise CompilationError, query
        end

      raise CompilationError, query if program.nil?

      root = program.statements.body.first.consequent.pattern
      Compiled.new(query, Compiler.new.compile_node(root))
    end
  end
end
