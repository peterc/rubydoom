require "test_helper"

# Hitscan autoaim: a shot whose flat eye-line would be blocked by a
# step-up should still hit a target on the raised ledge, because the
# autoaim slope clears the step. Plus a couple of regressions to make
# sure autoaim isn't hitting things through walls.
class HitscanTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @combat  = Rubydoom::Combat.new(@map)
    @hitscan = Rubydoom::Hitscan.new(@map, @clipper)
  end

  def test_hits_imp_standing_on_a_ledge_above_eye_level
    imp = @combat.monsters.find { |m| m.thing.type == 3001 }
    refute_nil imp, "E1M1 has at least one imp"
    imp_floor = @clipper.floor_at(imp.thing.x, imp.thing.y)

    player = Rubydoom::Player.from_thing(@map.player_start)
    player.view_height = 41.0
    # West of the imp on the lower floor, far enough back that a slope
    # can clear the 144-unit step at x=3348.
    player.x = 3000.0
    player.y = -3472.0
    player.angle = 0.0
    pf = @clipper.floor_at(player.x, player.y)
    eye = pf + player.view_height
    assert eye < imp_floor, "test setup requires eye below imp floor"

    result = @hitscan.fire(player, shootables: @combat.shootables)
    refute_nil result
    assert_equal :thing,    result[0]
    assert_equal imp.thing, result[1]
  end

  def test_barrel_on_ground_still_hits_head_on
    barrel = @combat.instance_variable_get(:@mobjs).find { |m| m.kind == :barrel }
    skip "no barrels on E1M1" unless barrel

    p2 = Rubydoom::Player.from_thing(@map.player_start)
    p2.view_height = 41.0
    p2.x = barrel.thing.x - 100.0
    p2.y = barrel.thing.y
    p2.angle = 0.0
    r = @hitscan.fire(p2, shootables: @combat.shootables)
    refute_nil r
    assert_equal :thing,       r[0]
    assert_equal barrel.thing, r[1]
  end

  def test_facing_a_wall_returns_wall_hit_not_something_behind_it
    p3 = Rubydoom::Player.from_thing(@map.player_start)
    p3.view_height = 41.0
    p3.angle = 180.0  # back into a wall
    r = @hitscan.fire(p3, shootables: @combat.shootables)
    refute_nil r
    assert_equal :wall, r[0]
  end
end
