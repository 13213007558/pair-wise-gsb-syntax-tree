# frozen_string_literal: true

module SyntaxTree
  # Collects edits that are bound to nodes in an immutable AST.
  #
  # Multiple plans can be merged before the tree is copied. This makes the
  # ordering of independent plans observable, while ensuring that ambiguous
  # edits fail before any source is generated.
  class EditPlan
    # Raised when one or more plans cannot be safely applied together.
    class Conflict < StandardError
    end

    # Raised when an edit is attempted in a place that cannot contain it.
    class InvalidEdit < StandardError
    end

    Insertion =
      Struct.new(:target, :node, :position, :order) do
        def ordered?
          !order.nil?
        end
      end

    class << self
      # Merge any number of plans into a new plan. The root is used to
      # establish structural relationships between edited nodes.
      def merge(*plans)
        plans = plans.flatten
        return new if plans.empty?

        first, *rest = plans
        first.merge(*rest)
      end
    end

    attr_reader :root

    def initialize(root = nil)
      @root = root
      @replacements = []
      @deletions = {}
      @insertions = []
    end

    # Replace the given node with another node.
    def replace(target, node)
      edit(target, node)
      @replacements << [target, node]
      self
    end

    # Remove the given node from the collection that contains it.
    def delete(target)
      edit(target)
      @deletions[target.object_id] = target
      self
    end

    # Insert a node immediately before the given collection member.
    def insert_before(target, node, order: nil)
      insert(target, node, :before, order)
    end

    # Insert a node immediately after the given collection member.
    def insert_after(target, node, order: nil)
      insert(target, node, :after, order)
      self
    end

    # Merge this plan with one or more other plans without modifying them.
    def merge(*others)
      root =
        others.reduce(self.root) { |merged, other| shared_root(merged, other) }
      plan = self.class.new(root)

      plan.append(self)
      others.each { |other| plan.append(other) }
      plan.verify!
      plan
    end

    # Check all structural conflicts and return true if the plan is valid.
    def verify!(tree = root)
      unless tree.is_a?(SyntaxTree::Node)
        raise ArgumentError, "a root node is required to verify edits"
      end

      index = Index.new(tree)
      validate_targets(index)
      validate_same_target_edits
      validate_ancestor_edits(index)
      validate_insertion_orders(index)
      true
    end

    # Apply the edits to a copied tree, format it, and reparse it.
    def apply(source, tree: root, maxwidth: SyntaxTree::DEFAULT_PRINT_WIDTH)
      raise ArgumentError, "source is required" unless source.is_a?(String)
      unless tree.is_a?(SyntaxTree::Node)
        raise ArgumentError, "a root node is required"
      end

      verify!(tree)
      applied = Editor.new(self, Index.new(tree)).visit(tree)
      transformed = format_transformed(source, applied, maxwidth)
      SyntaxTree.parse(transformed)
    end

    protected

    attr_reader :replacements, :deletions, :insertions

    def append(other)
      @replacements.concat(other.replacements)
      other.deletions.each_value do |target|
        @deletions[target.object_id] = target
      end
      @insertions.concat(other.insertions)
    end

    private

    def insert(target, node, position, order)
      edit(target, node)
      unless order.nil? || order.is_a?(Integer)
        raise ArgumentError, "insertion order must be an integer"
      end

      @insertions << Insertion.new(target, node, position, order)
      self
    end

    def edit(target, *nodes)
      ([target] + nodes).each do |node|
        unless node.is_a?(SyntaxTree::Node)
          raise ArgumentError, "expected an AST node"
        end
      end
    end

    def shared_root(root, other)
      if root && other.root && !root.equal?(other.root)
        raise Conflict, "edit plans were created from different AST roots"
      end

      root || other.root
    end

    def validate_targets(index)
      targets.each do |target|
        next if index.node?(target)

        raise Conflict, "edit target is not part of the AST: #{target.class}"
      end

      insertions
        .map(&:target)
        .each do |target|
          next if index.collection_member?(target)

          raise InvalidEdit, "insertions require a node inside a collection"
        end

      deletion_targets.each do |target|
        next if index.collection_member?(target)

        raise InvalidEdit, "only collection members can be deleted"
      end
    end

    def validate_same_target_edits
      grouped = replacements.group_by(&:first)

      grouped.each do |target, replacements_for_target|
        raise same_target_conflict(target) if replacements_for_target.length > 1

        raise same_target_conflict(target) if deletions.key?(target.object_id)
      end

      insertions
        .map(&:target)
        .uniq
        .each do |target|
          next unless deletions.key?(target.object_id)

          raise same_target_conflict(target)
        end
    end

    def same_target_conflict(target)
      Conflict.new("conflicting edits target #{target.class}")
    end

    def validate_ancestor_edits(index)
      ancestor_edits = terminal_edits
      descendant_edits = ancestor_edits + insertion_anchors

      descendant_edits.each do |target, kind|
        ancestors = index.ancestors(target)

        ancestor_edits.each do |other_target, other_kind|
          next if target.equal?(other_target)
          next unless ancestors.include?(other_target)

          raise Conflict,
                "#{other_kind} on ancestor #{other_target.class} conflicts " \
                  "with #{kind} on descendant #{target.class}; remove one " \
                  "edit or explicitly replace only one side"
        end
      end
    end

    def validate_insertion_orders(index)
      groups =
        insertions.group_by { |insertion| insertion_gap(insertion, index) }

      groups.each_value do |group|
        next if group.length <= 1

        orders = group.map(&:order)
        if orders.any?(&:nil?)
          raise Conflict,
                "multiple inserts at the same position require an explicit order"
        elsif orders.uniq.length != orders.length
          raise Conflict, "insertion orders at the same position must be unique"
        end
      end
    end

    def insertion_gap(insertion, index)
      target = insertion.target
      collection, member_index = index.collection_for(target)

      case insertion.position
      when :before
        [collection.object_id, member_index]
      when :after
        [collection.object_id, member_index + 1]
      end
    end

    def targets
      replacement_targets + deletion_targets + insertions.map(&:target)
    end

    def replacement_targets
      replacements.map(&:first)
    end

    def deletion_targets
      deletions.values
    end

    def terminal_edits
      edits = []

      replacements.each { |target, _| edits << [target, "replace"] }

      deletions.each_value { |target| edits << [target, "delete"] }

      edits
    end

    def insertion_anchors
      insertions.map { |insertion| [insertion.target, "insert"] }
    end

    def format_transformed(source, node, maxwidth)
      formatter = Formatter.new(source, [], maxwidth)
      node.format(formatter)
      formatter.flush
      formatter.output.join
    end

    # Maintains object identity relationships for one immutable AST. Attached
    # comments are traversed separately and are not editable collection slots.
    class Index
      NodeData = Struct.new(:parent, :collection, :collection_index)

      def initialize(root)
        @parents = { root.object_id => nil }
        @collections = {}
        build(root)
      end

      def node?(node)
        node.is_a?(SyntaxTree::Node) && @parents.key?(node.object_id)
      end

      def collection_member?(node)
        @collections.key?(node.object_id)
      end

      def collection_for(node)
        data = @collections.fetch(node.object_id)
        [data.collection, data.collection_index]
      end

      def ancestors(node)
        ancestors = []
        current = node

        while (data = @parents[current.object_id])
          ancestors << data
          current = data
        end

        ancestors
      end

      private

      def build(node)
        node.instance_variables.each do |name|
          next if name == :@location

          value = node.instance_variable_get(name)
          scan(value) do |child, collection, index|
            if child.is_a?(SyntaxTree::Node)
              @parents[child.object_id] = node
              if collection
                @collections[child.object_id] = NodeData.new(
                  node,
                  collection,
                  index
                )
              end

              build(child)
            end
          end
        end
      end

      def scan(value, &block)
        case value
        when SyntaxTree::Node
          yield(value, nil, nil)
        when Array
          value.each_with_index do |member, index|
            yield(member, value, index) if member.is_a?(SyntaxTree::Node)
            scan(member, &block) unless member.is_a?(SyntaxTree::Node)
          end
        end
      end
    end

    # Copies the original AST once. Insertions are spliced into collection
    # attributes while other child nodes are visited bottom-up through the
    # existing MutationVisitor copy behavior.
    class Editor < MutationVisitor
      def initialize(plan, index)
        super()
        @index = index
        @replacements = {}
        @deletions = {}
        @insertions = Hash.new { |hash, key| hash[key] = [] }
        @insertion_nodes = {}

        plan
          .send(:replacements)
          .each do |target, node|
            @replacements[target.object_id] = copy_edit_node(node)
          end
        plan
          .send(:deletions)
          .each_value { |target| @deletions[target.object_id] = true }
        plan
          .send(:insertions)
          .each do |insertion|
            collection, member_index = @index.collection_for(insertion.target)
            gap =
              insertion.position == :before ? member_index : member_index + 1
            node = copy_edit_node(insertion.node)
            @insertion_nodes[insertion.object_id] = node
            align_location(node, insertion.target.location.start_line)
            @insertions[[collection.object_id, gap]] << insertion
          end

        plan
          .send(:replacements)
          .each do |target, node|
            align_location(
              @replacements[target.object_id],
              target.location.start_line
            )
          end
      end

      def visit(node)
        return unless node

        if @replacements.key?(node.object_id)
          return @replacements[node.object_id]
        end
        return if @deletions.key?(node.object_id)

        node.accept(self)
      end

      def visit_all(nodes)
        edited = false
        result = []
        leading = inserted(nodes, 0)
        edited ||= leading.any?
        result.concat(leading)

        nodes.each_with_index do |node, index|
          if @replacements.key?(node.object_id) ||
               @deletions.key?(node.object_id)
            edited = true
          end

          visited = visit(node)
          if visited.nil?
            edited = true
            next
          end

          result << visited
          following = inserted(nodes, index + 1)
          edited ||= following.any?
          result.concat(following)
        end

        compact_lines(result) if edited
        result
      end

      private

      def inserted(nodes, gap)
        insertions = @insertions[[nodes.object_id, gap]]
        insertions
          .sort_by { |insertion| [insertion.order, insertion.position] }
          .map { |insertion| @insertion_nodes[insertion.object_id] }
      end

      def copy_edit_node(node)
        node.accept(MutationVisitor.new)
      end

      def align_location(node, line)
        location = node.location
        delta = line - location.start_line
        shift_location(node, delta)
      end

      def shift_location(node, delta)
        return unless node.respond_to?(:location)

        location = node.location
        node.instance_variable_set(
          :@location,
          Location.new(
            start_line: location.start_line + delta,
            start_char: location.start_char,
            start_column: location.start_column,
            end_line: location.end_line + delta,
            end_char: location.end_char,
            end_column: location.end_column
          )
        )

        node.instance_variables.each do |name|
          next if name == :@location || name == :@comments

          value = node.instance_variable_get(name)
          shift_structural_location(value, delta)
        end
      end

      def shift_structural_location(value, delta)
        case value
        when SyntaxTree::Node
          shift_location(value, delta)
        when Array
          value.each { |member| shift_structural_location(member, delta) }
        end
      end

      def compact_lines(nodes)
        previous_end_line = nil

        nodes.each do |node|
          if previous_end_line
            desired_start_line = previous_end_line + 1
            delta = desired_start_line - node.location.start_line
            shift_location(node, delta) unless delta.zero?
          end

          previous_end_line = node.location.end_line
        end
      end
    end
  end
end
