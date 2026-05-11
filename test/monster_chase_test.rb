require "test_helper"

# Integration test: an awake monster in chase state moves toward the
# player and eventually deals damage.
class MonsterChaseTest < Minitest::Test
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
  end

  def test_spos_promotes_to_chase_and_closes_distance
    spos = @combat.monsters.find { |m| m.thing.type == 9 && m.thing.x == -160 }
    skip "no SPOS at the known fixture location on E1M1" unless spos

    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(spos.thing.x + 300, spos.thing.y, 180.0)
    )
    spos.reaction_time = 0
    spos.thing.angle = 0.0  # face the player

    x0, y0 = spos.thing.x, spos.thing.y
    seen_chase = false
    70.times do
      @combat.update_tic(player)
      seen_chase ||= spos.state_key.to_s.start_with?("spos_run")
    end

    assert seen_chase, "entered spos_run at some point"
    moved_dist = Math.hypot(spos.thing.x - x0, spos.thing.y - y0)
    assert moved_dist > 0, "monster actually moved"
    dist_now  = Math.hypot(player.x - spos.thing.x, player.y - spos.thing.y)
    dist_then = Math.hypot(player.x - x0,          player.y - y0)
    assert dist_now < dist_then, "got closer to player"
  end

  def test_zombieman_in_attack_state_damages_player
    spos = @combat.monsters.find { |m| m.thing.type == 9 && m.thing.x == -160 }
    skip "no SPOS at the known fixture location on E1M1" unless spos

    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(spos.thing.x + 100, spos.thing.y, 180.0)
    )
    hp_before = player.health
    @combat.enter_state(spos, :spos_atk1)
    50.times { @combat.update_tic(player) }
    assert player.health < hp_before, "player took damage"
  end
end
