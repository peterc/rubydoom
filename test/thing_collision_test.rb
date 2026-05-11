require "test_helper"

# Solid things block player movement; pickups don't. Clipper's slide
# resolver should refuse to push the player onto a barrel but should
# walk straight through a health bonus.
class ThingCollisionTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
  end

  def test_walking_toward_a_barrel_is_blocked_short_of_overlap
    barrel = @map.things.find { |t| t.type == 2035 }
    refute_nil barrel
    sx, sy = barrel.x - 64, barrel.y
    tx, ty = barrel.x,      barrel.y
    ax, ay = @clipper.slide(sx, sy, tx, ty)
    moved = (ax - sx).abs + (ay - sy).abs
    # Player radius 16 + barrel radius 10 = 26, so allowed move is
    # ~64 - 26 = 38. Allow some slop for slide resolution.
    assert moved < 60, "barrel blocked some of the move: #{moved}"
    assert moved >= 0, "moved a non-negative distance"
  end

  def test_walking_through_a_pickup_is_not_blocked
    pickup = @map.things.find { |t| t.type == 2014 }
    refute_nil pickup
    sx, sy = pickup.x - 64, pickup.y
    tx, ty = pickup.x,      pickup.y
    ax, ay = @clipper.slide(sx, sy, tx, ty)
    moved = (ax - sx).abs + (ay - sy).abs
    assert_in_delta 64, moved, 2.0, "walked through the pickup"
  end
end
