module Rubydoom
  # BSP tree traversal for a Map. The NODES lump is an array of binary
  # space partition nodes; the root is the LAST entry. Each node has a
  # directed partition line and two children, which are either further
  # nodes or subsectors (leaves) — distinguished by the SUBSECTOR_FLAG
  # high bit.
  #
  # Two queries the 3D renderer cares about:
  #
  #   #subsector_at(x, y)
  #     Walks the tree to the leaf containing the point. Used to find
  #     the player's current subsector (and from there, current sector,
  #     for floor/ceiling heights and lighting).
  #
  #   #each_subsector_front_to_back(x, y) { |idx| ... }
  #     Visits every subsector in front-to-back order from the given
  #     viewpoint. This is the heart of DOOM's renderer: walls of
  #     closer subsectors get drawn first, and once enough of the
  #     screen is filled we can stop.
  class Bsp
    SUBSECTOR_FLAG = 0x8000
    INDEX_MASK     = 0x7FFF

    def initialize(nodes)
      @nodes = nodes
      raise "BSP has no nodes" if nodes.empty?
      @root_index = nodes.size - 1
    end

    def subsector_at(x, y)
      index = @root_index
      loop do
        node = @nodes[index]
        child = point_on_side(x, y, node) == 0 ? node.right_child : node.left_child
        return child & INDEX_MASK if (child & SUBSECTOR_FLAG) != 0
        index = child
      end
    end

    def each_subsector_front_to_back(x, y, &block)
      visit(@root_index, x, y, &block)
    end

    private

    def visit(index, x, y, &block)
      if (index & SUBSECTOR_FLAG) != 0
        yield(index & INDEX_MASK)
        return
      end
      node = @nodes[index]
      if point_on_side(x, y, node) == 0
        visit(node.right_child, x, y, &block)
        visit(node.left_child,  x, y, &block)
      else
        visit(node.left_child,  x, y, &block)
        visit(node.right_child, x, y, &block)
      end
    end

    # Returns 0 if (x, y) is on the front (right) side of the node's
    # partition line, 1 if on the back (left). Matches the sign
    # convention DOOM uses to drive child selection.
    #
    # Derivation: cross product of partition direction with
    # (point - partition_origin). Positive cross = point is on the left
    # of the directed line (back side); negative = front.
    def point_on_side(x, y, node)
      dx = x - node.partition_x
      dy = y - node.partition_y
      cross = node.partition_dx * dy - node.partition_dy * dx
      cross > 0 ? 1 : 0
    end
  end
end
