# frozen_string_literal: true

module SyntaxTree
  # An EditPlan describes a set of edits to a single source file that are all
  # bound to the nodes of one parsed syntax tree. Because every edit points at
  # a node from the same tree, many plans (for example one per codemod) can be
  # merged and then applied to the source in a single pass, instead of
  # rewriting string offsets one patch at a time.
  #
  # A plan supports four kinds of edits:
  #
  # *   +replace+ - swap the source range of a node for new text
  # *   +delete+ - remove the source range of a node
  # *   +insert_before+ / +insert_after+ - insert text next to a node
  #
  # When two plans are merged, structural conflicts are detected before
  # anything is applied:
  #
  # *   Replacing or deleting a node conflicts by default with any edit that
  #     targets a node inside of it, since the inner edit would be swallowed
  #     by the outer one.
  # *   Multiple insertions at the same position require an explicit +order+
  #     so that the merged output does not depend on merge order.
  #
  # Once a merged plan passes validation, EditPlan#apply rewrites the source
  # in a single pass and re-parses the result. The original syntax tree is
  # never mutated, and comments attached to nodes that were not edited are
  # preserved because only the source ranges of edited nodes are touched.
  class EditPlan
    # Raised when two edits cannot coexist in the same plan.
    class ConflictError < StandardError
    end

    # Raised when applying a plan results in source that no longer parses.
    class InvalidResultError < StandardError
    end

    # Replaces the source range of a node with new text.
    class Replace < Struct.new(:node, :source)
    end

    # Deletes the source range of a node.
    class Delete < Struct.new(:node)
    end

    # Inserts text before or after a node. The +position+ is either +:before+
    # or +:after+, and +order+ disambiguates multiple insertions that land on
    # the same position.
    class Insert < Struct.new(:node, :position, :source, :order)
    end

    attr_reader :edits

    def initialize
      @edits = []
    end

    # Replace the source range of the given node with the given source text.
    def replace(node, source)
      edits << Replace.new(node, source)
      self
    end

    # Delete the source range of the given node.
    def delete(node)
      edits << Delete.new(node)
      self
    end

    # Insert the given source text immediately before the given node. When
    # multiple insertions land on the same position they must each provide a
    # distinct +order+.
    def insert_before(node, source, order: nil)
      edits << Insert.new(node, :before, source, order)
      self
    end

    # Insert the given source text immediately after the given node. When
    # multiple insertions land on the same position they must each provide a
    # distinct +order+.
    def insert_after(node, source, order: nil)
      edits << Insert.new(node, :after, source, order)
      self
    end

    # Merge another plan into this one, returning a new plan that contains
    # the edits of both. Neither plan is modified. Raises a ConflictError if
    # any pair of edits structurally conflicts.
    def merge(other)
      merged = EditPlan.new
      merged.edits.concat(edits, other.edits)
      merged.validate!
      merged
    end

    # Verify that none of the edits in this plan conflict with each other.
    # Returns the plan itself so it can be chained.
    def validate!
      replacements = []
      insertions = Hash.new { |hash, key| hash[key] = [] }

      edits.each do |edit|
        case edit
        when Replace, Delete
          replacements << edit
        when Insert
          key = [edit.node, edit.position]
          insertions[key] << edit
        end
      end

      validate_replacements!(replacements)
      validate_insertions!(insertions)
      self
    end

    # Apply every edit to the given source in a single pass, re-parse the
    # result, and return the new source. The source must be the same text
    # that produced the syntax tree these edits are bound to. Raises an
    # InvalidResultError if the resulting source no longer parses.
    def apply(source)
      validate!

      events = []

      edits.each do |edit|
        case edit
        when Replace
          events << range_event(edit.node, edit.source)
        when Delete
          events << range_event(edit.node, +"")
        when Insert
          location = edit.node.location
          offset =
            edit.position == :before ? location.start_char : location.end_char
          events << [offset, 0, edit.source, offset, edit.order || 0]
        end
      end

      # Insertions at the same offset are applied in ascending +order+.
      # Sorting is stable, so insertions without an explicit order keep their
      # relative sequence (there can only be one per position anyway).
      events.sort_by! { |offset, kind, _, _, order| [offset, kind, order] }

      result = +""
      cursor = 0

      events.each do |offset, kind, text, finish, _|
        result << source[cursor...offset]
        result << text
        cursor = kind == 0 ? offset : finish
      end

      result << source[cursor..]

      begin
        reparsed = SyntaxTree.parse(result)
      rescue Parser::ParseError
        reparsed = nil
      end

      unless reparsed
        raise InvalidResultError,
              "applying this edit plan results in source that does not parse"
      end

      result
    end

    private

    def range_event(node, text)
      location = node.location
      [location.start_char, 1, text, location.end_char, 0]
    end

    def validate_replacements!(replacements)
      replacements.combination(2) do |left, right|
        if left.node.equal?(right.node)
          raise ConflictError,
                "multiple edits replace or delete the same node " \
                  "(#{describe(left.node)})"
        end

        [left, right].each do |outer|
          inner = outer.equal?(left) ? right : left
          next unless contains?(outer.node, inner.node)

          action = outer.is_a?(Delete) ? "deletes" : "replaces"
          raise ConflictError,
                "edit #{action} #{describe(outer.node)}, which contains " \
                  "#{describe(inner.node)} targeted by another edit"
        end
      end

      edits.each do |edit|
        next unless edit.is_a?(Insert)

        replacements.each do |replacement|
          next unless contains?(replacement.node, edit.node)

          action = replacement.is_a?(Delete) ? "deletes" : "replaces"
          raise ConflictError,
                "edit #{action} #{describe(replacement.node)}, which " \
                  "contains #{describe(edit.node)} targeted by an insertion"
        end
      end
    end

    def validate_insertions!(insertions)
      insertions.each_value do |group|
        next if group.length < 2

        orders = group.map(&:order)
        next if orders.none?(&:nil?) && orders.uniq.length == orders.length

        node = group.first.node
        raise ConflictError,
              "multiple insertions #{group.first.position} " \
                "#{describe(node)} require an explicit, distinct order"
      end
    end

    # Whether the outer node's source range strictly contains the inner
    # node's range. Two edits on the exact same node are handled separately.
    def contains?(outer, inner)
      return false if outer.equal?(inner)

      outer_location = outer.location
      inner_location = inner.location

      outer_location.start_char <= inner_location.start_char &&
        inner_location.end_char <= outer_location.end_char
    end

    def describe(node)
      location = node.location
      "#{node.class.name.split("::").last} at line #{location.start_line}"
    end
  end
end
