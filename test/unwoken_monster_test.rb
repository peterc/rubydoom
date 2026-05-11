require "test_helper"

# Vanilla behaviour:
#   (a) an unwoken monster still cycles between its A/B idle frames
#       (it looks animated even though it isn't moving);
#   (b) it stays idle when the player has no line of sight;
#   (c) it can still be damaged and killed by a hitscan from behind.
class UnwokenMonsterTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @combat  = Rubydoom::Combat.new(@map)
    @sight   = Rubydoom::Sight.new(@map, @clipper)
    @movement = Rubydoom::MonsterMovement.new(@map, @clipper, @combat)
    @ai = Rubydoom::MonsterAI.new(@map, @combat, @sight, @movement)
    @ai.clipper = @clipper
    @combat.ai  = @ai
    @hitscan = Rubydoom::Hitscan.new(@map, @clipper)
    @weapons = Rubydoom::Weapons.new(hitscan: @hitscan, combat: @combat,
                                     rng: Random.new(1))
    @spos = @combat.monsters.find { |m| m.thing.type == 9 && m.thing.x == -160 }
    skip "fixture SPOS not present" unless @spos
  end

  def test_idle_monster_cycles_through_frame_a_and_b_without_acquiring
    far_player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(5000.0, 5000.0, 0.0)
    )
    seen_a = seen_b = false
    50.times do
      @combat.update_tic(far_player)
      seen_a ||= @spos.thing.frame_override == "A"
      seen_b ||= @spos.thing.frame_override == "B"
    end
    assert seen_a, "saw frame A in idle cycle"
    assert seen_b, "saw frame B in idle cycle"
    assert [:spos_stnd, :spos_stnd2].include?(@spos.state_key),
           "stayed in idle states"
    assert_nil @spos.target
  end

  def test_a_hitscan_from_behind_still_damages_and_kills
    close_player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(-260.0, -3232.0, 0.0)
    )
    hp_before = @spos.health
    5.times { @weapons.send(:shoot, close_player, 10) }
    assert @spos.health < hp_before, "monster damaged while still idle"
    @weapons.send(:shoot, close_player, 100)
    assert_equal :dying, @spos.state, "lethal shot starts death animation"
  end
end
