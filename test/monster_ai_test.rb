require "test_helper"

# Monster mobj spawning + damage routing + A_Look acquisition.
class MonsterAITest < Minitest::Test
  def setup
    fresh_world
  end

  def test_e1m1_monsters_spawn_with_expected_state
    poss = @combat.monsters.find { |m| m.thing.type == 3004 }
    refute_nil poss, "E1M1 has at least one zombieman"
    assert_equal 20,          poss.health
    assert_equal :alive,      poss.state
    assert_equal :poss_stnd,  poss.state_key
    assert_equal "POSS",      poss.thing.sprite_override
    assert_equal "A",         poss.thing.frame_override
    assert @combat.shootables.any? { |t, _| t == poss.thing },
           "zombieman is in shootables"
  end

  def test_damage_puts_monster_in_pain_or_acquires_target
    poss = @combat.monsters.find { |m| m.thing.type == 3004 }
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(poss.thing.x + 50, poss.thing.y, 180.0)
    )
    srand(0)
    @combat.damage(poss, 5, source: player)
    assert_equal 15, poss.health
    in_pain_or_target = [:poss_pain, :poss_pain2].include?(poss.state_key) ||
                        poss.target == player
    assert in_pain_or_target, "either entered pain or acquired the player"
  end

  def test_lethal_damage_drops_corpse_and_removes_from_shootables
    poss = @combat.monsters.find { |m| m.thing.type == 3004 }
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(poss.thing.x + 50, poss.thing.y, 180.0)
    )
    @combat.damage(poss, 100, source: player)
    assert_equal :dying,       poss.state
    assert_equal :poss_die1,   poss.state_key
    assert_equal false,        poss.thing.solid_override
    refute @combat.shootables.any? { |t, _| t == poss.thing },
           "dying monster dropped from shootables"

    30.times { @combat.update_tic(player) }
    assert_equal :poss_die5,   poss.state_key
    assert_equal :dead,        poss.state
    assert_nil   poss.thing.removed,        "corpse not removed"
    assert_equal "L",          poss.thing.frame_override
  end

  def test_a_look_does_not_acquire_a_player_out_of_sight
    fresh_world
    poss = @combat.monsters.find { |m| m.thing.type == 3004 }
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(0.0, 0.0, 0.0)
    )
    poss.reaction_time = 0
    20.times { @combat.update_tic(player) }
    assert_nil poss.target,                    "no target acquired"
    assert [:poss_stnd, :poss_stnd2].include?(poss.state_key),
           "still idle: #{poss.state_key}"
  end

  private

  # Build a fresh map + clipper + combat + AI quartet. Tests that mutate
  # state should call this from setup or between assertions to start
  # over without picking up the previous test's damage / death.
  def fresh_world
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @combat  = Rubydoom::Combat.new(@map)
    @sight   = Rubydoom::Sight.new(@map, @clipper)
    @movement = Rubydoom::MonsterMovement.new(@map, @clipper, @combat)
    @ai = Rubydoom::MonsterAI.new(@map, @combat, @sight, @movement)
    @ai.clipper = @clipper
    @combat.ai  = @ai
  end
end
