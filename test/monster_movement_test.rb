require "test_helper"

# Monster movement rules: no dropoff from a ledge taller than 24 units
# (vanilla — only flagged "dropoff" mobjs may step down further). The
# integration variant places a zombieman on a high ledge facing a player
# below and asserts the monster doesn't step off into the gap.
class MonsterMovementTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
  end

  def test_position_valid_refuses_dropoff_for_non_dropoff_mobjs
    big_step = find_big_step(min_diff: 32)
    skip "no >32-unit step found on E1M1" unless big_step

    hi_side, lo_side, high_floor, _low = sides_of(big_step)
    step_dst = [
      hi_side[0] + (lo_side[0] - hi_side[0]) * 0.5,
      hi_side[1] + (lo_side[1] - hi_side[1]) * 0.5
    ]
    refused = @clipper.position_valid?(
      step_dst[0], step_dst[1], high_floor, 20,
      start_x: hi_side[0], start_y: hi_side[1], allow_dropoff: false
    )
    allowed = @clipper.position_valid?(
      step_dst[0], step_dst[1], high_floor, 20,
      start_x: hi_side[0], start_y: hi_side[1], allow_dropoff: true
    )
    refute refused, "step refused under no-dropoff"
    assert allowed, "same step allowed when dropoff permitted"
  end

  def test_chasing_zombieman_does_not_step_off_a_high_ledge
    big_step = find_big_step(min_diff: 32)
    skip "no >32-unit step found on E1M1" unless big_step
    hi_side, lo_side, _high, _low = sides_of(big_step)

    combat   = Rubydoom::Combat.new(@map)
    sight    = Rubydoom::Sight.new(@map, @clipper)
    movement = Rubydoom::MonsterMovement.new(@map, @clipper, combat)
    ai = Rubydoom::MonsterAI.new(@map, combat, sight, movement)
    ai.clipper = @clipper
    combat.ai  = ai

    poss = combat.monsters.find { |m| m.thing.type == 3004 }
    poss.thing.x = hi_side[0]
    poss.thing.y = hi_side[1]
    poss.thing.angle =
      (Math.atan2(lo_side[1] - hi_side[1], lo_side[0] - hi_side[0]) * 180.0 / Math::PI) % 360
    poss.reaction_time = 0
    poss.target = nil

    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(
        lo_side[0] + (lo_side[0] - hi_side[0]) * 2,
        lo_side[1] + (lo_side[1] - hi_side[1]) * 2,
        0.0
      )
    )
    combat.enter_state(poss, poss.info.see_state)
    poss.target = player

    floor_start = @clipper.floor_at(poss.thing.x, poss.thing.y)
    60.times { combat.update_tic(player) }
    floor_end   = @clipper.floor_at(poss.thing.x, poss.thing.y)
    assert_equal floor_start, floor_end, "monster stayed on the high floor"
  end

  private

  # Returns the first two-sided linedef whose front and back floors
  # differ by at least min_diff, or nil if none.
  def find_big_step(min_diff:)
    @map.linedefs.find do |ld|
      next false unless ld.two_sided?
      f = @map.linedef_front_sector(ld)
      b = @map.linedef_back_sector(ld)
      next false if f.nil? || b.nil?
      (f.floor_height - b.floor_height).abs > min_diff
    end
  end

  def sides_of(ld)
    v1 = @map.vertexes[ld.start_vertex_index]
    v2 = @map.vertexes[ld.end_vertex_index]
    mid_x = (v1.x + v2.x) / 2.0
    mid_y = (v1.y + v2.y) / 2.0
    front = @map.linedef_front_sector(ld)
    back  = @map.linedef_back_sector(ld)
    high_floor, low_floor = [front.floor_height, back.floor_height].sort.reverse
    ldx = v2.x - v1.x; ldy = v2.y - v1.y
    len = Math.hypot(ldx, ldy)
    nx = -ldy / len; ny = ldx / len
    test_p = [mid_x + nx * 32, mid_y + ny * 32]
    test_n = [mid_x - nx * 32, mid_y - ny * 32]
    hi_side = (@clipper.floor_at(*test_p) == high_floor) ? test_p : test_n
    lo_side = (hi_side == test_p) ? test_n : test_p
    [hi_side, lo_side, high_floor, low_floor]
  end
end
