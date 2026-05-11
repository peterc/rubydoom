require "test_helper"

# SectorEffects: damage floors (special_type 7 = 5%/tic at 32-tic
# cadence) and secret tagging (special_type 9 → increment
# secrets_found, clear special_type).
class SectorEffectsTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
  end

  def test_damage_floor_chips_health_every_32_tics
    sec = @map.sectors.find { |s| s.special_type == 7 }
    skip "no damage-floor sector on E1M1" unless sec
    px, py = interior_point_for(sec)
    refute_nil px
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(px, py, 0)
    )
    effects = Rubydoom::SectorEffects.new(@clipper)
    100.times { effects.update_tic(player) }
    # 100 / 32 = 3 hits × 5 hp = 15 hp lost.
    assert_equal 85, player.health
  end

  def test_secret_sector_increments_secrets_and_clears_special
    sec = @map.sectors.find { |s| s.special_type == 9 }
    skip "no secret sector on E1M1" unless sec
    px, py = interior_point_for(sec)
    refute_nil px
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(px, py, 0)
    )
    effects = Rubydoom::SectorEffects.new(@clipper)
    before = player.secrets_found
    # The first entry prints "[secret] N found" — runtime feedback,
    # noise here. Swallow it.
    capture_io { effects.update_tic(player) }
    assert_equal before + 1, player.secrets_found
    assert_equal 0,          sec.special_type
    # Re-tick: no double-count.
    effects.update_tic(player)
    assert_equal before + 1, player.secrets_found
  end

  private

  # Centroid of segs in any subsector belonging to target_sec; returns
  # nil if none of the subsectors yield a centroid that maps back to
  # target_sec under clipper.sector_at.
  def interior_point_for(target_sec)
    @map.subsectors.each do |ss|
      seg = @map.segs[ss.first_seg_index]
      ld  = @map.linedefs[seg.linedef_index]
      sd_idx = seg.direction.zero? ? ld.front_sidedef_index : ld.back_sidedef_index
      sd  = @map.sidedefs[sd_idx]
      next unless @map.sectors[sd.sector_index] == target_sec
      xs = []; ys = []
      ss.seg_count.times do |i|
        sg = @map.segs[ss.first_seg_index + i]
        a = @map.vertexes[sg.start_vertex_index]
        b = @map.vertexes[sg.end_vertex_index]
        xs << a.x; xs << b.x
        ys << a.y; ys << b.y
      end
      cx = xs.sum.fdiv(xs.size); cy = ys.sum.fdiv(ys.size)
      return [cx, cy] if @clipper.sector_at(cx, cy) == target_sec
    end
    [nil, nil]
  end
end
