require "test_helper"

# Clipper's spatial lookups — floor_at / sector_at / sector_index_at.
# These are the bridge between (x,y) coordinates and the map's sector
# metadata (floor height, special_type, tag, light_level, ...).
class ClipperGeomTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @ps      = @map.player_start
  end

  def test_floor_at_player_start_matches_player_start_sector
    sec = @clipper.sector_at(@ps.x, @ps.y)
    refute_nil sec
    assert_equal sec.floor_height, @clipper.floor_at(@ps.x, @ps.y)
  end

  def test_sector_index_at_round_trips_through_sector_at
    idx = @clipper.sector_index_at(@ps.x, @ps.y)
    assert_kind_of Integer, idx
    assert (0...@map.sectors.size).cover?(idx)
    assert_equal @map.sectors[idx], @clipper.sector_at(@ps.x, @ps.y)
  end

  def test_floor_at_is_stable_for_the_same_point
    a = @clipper.floor_at(@ps.x, @ps.y)
    b = @clipper.floor_at(@ps.x, @ps.y)
    assert_equal a, b
  end

  def test_distant_points_resolve_to_different_sectors_on_e1m1
    # Pick the player start and a thing on a clearly different floor —
    # the imp at (3440, -3472) is on a raised ledge, so its sector
    # must be different from the spawn sector.
    a_idx = @clipper.sector_index_at(@ps.x, @ps.y)
    b_idx = @clipper.sector_index_at(3440, -3472)
    refute_equal a_idx, b_idx
  end

  def test_floor_at_known_high_ledge_is_above_player_start_floor
    spawn_floor = @clipper.floor_at(@ps.x, @ps.y)
    imp_floor   = @clipper.floor_at(3440, -3472)  # E1M1 imp on a step
    assert imp_floor > spawn_floor,
           "imp ledge floor (#{imp_floor}) should be above spawn floor (#{spawn_floor})"
  end

  def test_sector_at_returns_a_sector_struct_with_height_attributes
    sec = @clipper.sector_at(@ps.x, @ps.y)
    refute_nil sec
    assert sec.respond_to?(:floor_height)
    assert sec.respond_to?(:ceiling_height)
    assert sec.ceiling_height > sec.floor_height,
           "sector has positive opening height"
  end

  def test_e1m2_spawn_sector_has_a_finite_floor
    map2 = Rubydoom::Map.load(TestHelper.wad, "E1M2")
    bsp2 = Rubydoom::Bsp.new(map2.nodes)
    clip2 = Rubydoom::Clipper.new(map2, bsp2)
    ps2 = map2.player_start
    floor = clip2.floor_at(ps2.x, ps2.y)
    refute_nil floor
    assert_kind_of Integer, floor
  end
end
