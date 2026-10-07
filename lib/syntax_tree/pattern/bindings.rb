# frozen_string_literal: true

module SyntaxTree
  class Pattern
    class Compiler
      # Bindings tracks the named captures taken while matching a pattern. It
      # is organized as a chain so alternation branches, negative conditions,
      # and ancestor constraints can each get their own binding boundary
      # without leaking captures into sibling branches. Children can read the
      # captures taken by their surrounding context (so a repeated name can
      # compare against an earlier capture), but their captures only become
      # visible after an explicit commit.
      class Bindings
        include Enumerable

        attr_reader :parent

        def initialize(parent = nil)
          @parent = parent
          @captures = {}
        end

        def child
          Bindings.new(self)
        end

        def key?(name)
          @captures.key?(name) || (parent && parent.key?(name))
        end

        def [](name)
          if @captures.key?(name)
            @captures[name]
          elsif parent
            parent[name]
          end
        end

        def []=(name, capture)
          @captures[name] = capture
        end

        # Binds a value to a name within this boundary. If the name is already
        # visible, the bound values must be structurally equal (ignoring
        # locations and comments) or the match fails. Returns a boolean so
        # callers can treat repeated captures as part of the match.
        def bind(name, value, location)
          existing = self[name]

          if existing
            equal = Compiler.structurally_equal?(existing.value, value)
            return false unless equal
          end

          @captures[name] = Capture.new(name, value, location)
          true
        end

        # Commits the captures taken by a child boundary into this one, but
        # only for the names listed in +names+. +names+ is the compile-time set
        # of captures the boundary is allowed to export, so branches that do
        # not bind a required name simply do not commit it (the caller is
        # responsible for compile-time validation of branch capture sets).
        def commit(child_bindings, names)
          names.each do |name|
            capture = child_bindings.local(name)
            next unless capture

            if key?(name)
              equal =
                Compiler.structurally_equal?(self[name].value, capture.value)
              return false unless equal
            end
            @captures[name] = capture
          end
          true
        end

        def local(name)
          @captures[name]
        end

        def each(&block)
          to_hash.each(&block)
        end

        def to_hash
          merged = parent ? parent.to_hash : {}
          merged.merge(@captures)
        end

        def captures
          to_hash
        end
      end
    end
  end
end
