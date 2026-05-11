require "test_helper"

# BSP traversal: locating the leaf subsector for a point, and
# enumerating subsectors front-to-back from a viewpoint (the order
# the 3D renderer cares about).
class BspTest < Minitest::Test
  def setup
    @map = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @bsp = Rubydoom::Bsp.new(@map.nodes)
  end

  def test_subsector_at_player_start_returns_a_valid_index
    ps = @map.player_start
    idx = @bsp.subsector_at(ps.x, ps.y)
    assert_kind_of Integer, idx
    assert (0...@map.subsectors.size).cover?(idx),
           "subsector index #{idx} in range"
  end

  def test_subsector_at_is_deterministic_for_same_point
    ps = @map.player_start
    a = @bsp.subsector_at(ps.x, ps.y)
    b = @bsp.subsector_at(ps.x, ps.y)
    assert_equal a, b
  end

  def test_each_subsector_front_to_back_visits_every_subsector_once
    ps = @map.player_start
    seen = []
    @bsp.each_subsector_front_to_back(ps.x, ps.y) { |idx| seen << idx }
    assert_equal @map.subsectors.size, seen.size,
                 "every subsector visited exactly once"
    assert_equal seen.size, seen.uniq.size,
                 "no subsector visited twice"
  end

  def test_front_to_back_starts_with_the_viewpoint_subsector
    ps = @map.player_start
    first = nil
    @bsp.each_subsector_front_to_back(ps.x, ps.y) do |idx|
      first = idx
      break
    end
    assert_equal @bsp.subsector_at(ps.x, ps.y), first,
                 "first subsector yielded is the one containing the viewpoint"
  end

  def test_empty_nodes_array_raises
    assert_raises(RuntimeError) { Rubydoom::Bsp.new([]) }
  end

  def test_traversal_is_stable_across_calls
    ps = @map.player_start
    first  = []
    second = []
    @bsp.each_subsector_front_to_back(ps.x, ps.y) { |i| first  << i }
    @bsp.each_subsector_front_to_back(ps.x, ps.y) { |i| second << i }
    assert_equal first, second
  end

  def test_different_viewpoints_yield_different_first_subsectors
    ps = @map.player_start
    first_a = @bsp.subsector_at(ps.x, ps.y)
    # Pick another player thing position (often a DM start) far away,
    # falling back to a hard-coded offset that's definitely in another
    # subsector for E1M1.
    other = @map.things.find { |t| t.type == 11 } # DM start
    far_x = other ? other.x : (ps.x + 4000)
    far_y = other ? other.y : (ps.y + 4000)
    first_b = @bsp.subsector_at(far_x, far_y)
    refute_equal first_a, first_b,
                 "two distant viewpoints map to different subsectors"
  end
end
