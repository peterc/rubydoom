require "test_helper"

# Lost Soul (MT_SKULL, doomednum 3006). No projectile: A_SkullAttack
# flings the mobj itself at SKULLSPEED = 20 mu/tic. On overlap with the
# player or another mobj the dive deals (rand%8+1)*3 = 3..24 bash
# damage and ends; on overlap with a wall the dive just stops and the
# soul resets to its spawn state.
#
# Doom 1 shareware (doom1.wad) has zero lost souls in E1, so we
# synthesize one into a live Game via the spawn_monster path — same
# trick as the cacodemon test.
class LostSoulTest < Minitest::Test
  SKULL = 3006

  def test_mobjinfo_registered
    info = Rubydoom::MonsterInfo[SKULL]
    refute_nil info
    assert_equal 100, info.health
    assert_equal  16, info.radius
    assert_equal  56, info.height
    assert_equal :skull_atk1, info.missile_state
    assert_nil   info.melee_state, "MT_SKULL has no melee state — bash decides at runtime"
    assert_nil   info.see_sound,   "MT_SKULL.seesound = sfx_None in vanilla"
    assert_equal :sklatk, info.attack_sound
    assert_equal :firxpl, info.death_sound
  end

  def test_state_table_dive_loop_and_disappear
    # The atk3/atk4 pair is the in-flight body animation that runs
    # while MF_SKULLFLY carries the soul forward.
    assert_equal :skull_atk4, Rubydoom::MonsterStates[:skull_atk3].next
    assert_equal :skull_atk3, Rubydoom::MonsterStates[:skull_atk4].next
    # K is the final visible corpse frame; the next entry hands off to
    # the disappearance action so lost souls leave nothing behind.
    assert_equal :skull_remove, Rubydoom::MonsterStates[:skull_die6].next
    rm = Rubydoom::MonsterStates[:skull_remove]
    assert_nil   rm.tics,   "terminal frame"
    assert_equal :remove_mobj, rm.action
  end

  def test_a_skull_attack_starts_the_dive
    game, skull = skull_in(fresh_game)
    skull.target = game.player
    # Pull the player close enough to be "in front" of the soul.
    game.player.x = skull.thing.x + 200
    game.player.y = skull.thing.y

    refute skull.skullfly
    game.monster_ai.send(:a_skull_attack, skull, game.player)
    assert skull.skullfly, "MF_SKULLFLY set"
    refute_nil skull.vx
    refute_nil skull.vy
    refute_nil skull.vz
    # 20 mu/tic toward +x → vx ≈ 20, vy ≈ 0.
    speed = Math.hypot(skull.vx, skull.vy)
    assert_in_delta 20.0, speed, 0.01
    assert skull.vx > 19.0, "velocity points at the player"
  end

  def test_dive_advances_position_and_damages_player
    game, skull = skull_in(fresh_game)
    skull.target = game.player
    game.player.x = skull.thing.x + 40   # well within reach
    game.player.y = skull.thing.y
    start_x = skull.thing.x

    game.monster_ai.send(:a_skull_attack, skull, game.player)

    hp_before = game.player.health
    # Drive a few tics — first advance_skullfly call should overlap
    # the player and end the dive.
    8.times { game.combat.send(:tick_monster, skull) }

    assert game.player.health < hp_before, "player took bash damage"
    drop = hp_before - game.player.health
    assert_includes 3..24, drop, "bash roll = (rand%8+1)*3"
    refute skull.skullfly, "dive ended on contact"
    assert_in_delta 0.0, skull.vx.to_f, 0.0001
  end

  def test_dive_stops_at_wall_with_no_damage
    game, skull = skull_in(fresh_game)
    skull.target = game.player
    # Aim the soul straight into a wall instead of the player. We do
    # this by relocating the soul next to a wall and pointing it
    # away from the player. We measure the position-valid? rejection
    # path through the public dive sequence.
    sector  = game.clipper.sector_at(skull.thing.x, skull.thing.y)
    # Force a velocity that should immediately leave the map (the
    # bbox cannot accommodate a 16-radius soul outside the geometry).
    skull.skullfly = true
    skull.vx = 1_000_000.0
    skull.vy = 0.0
    skull.vz = 0.0
    skull.skull_z = sector.floor_height + 28

    hp_before = game.player.health
    game.combat.send(:advance_skullfly, skull)

    refute skull.skullfly, "dive ended on bad destination"
    assert_equal hp_before, game.player.health, "wall bash deals no damage"
  end

  def test_skull_attack_chooses_missile_state_via_chase
    # MT_SKULL has no melee state, so a_chase only enters the missile
    # sequence (same shape as the cacodemon test).
    game, skull = skull_in(fresh_game)
    skull.target = game.player
    game.player.x = skull.thing.x + 30
    game.player.y = skull.thing.y
    game.monster_ai.instance_variable_set(:@rng, StubRng.new([0]))
    game.monster_ai.send(:a_chase, skull, game.player)
    assert_equal :skull_atk1, skull.state_key
  end

  def test_terminal_death_action_removes_the_thing
    game, skull = skull_in(fresh_game)
    refute skull.thing.removed
    # Drive through the live death pipeline: lethal damage routes
    # into start_death → enter_state(:skull_die1), then frame_timers
    # advance the chain until the terminal :skull_remove fires.
    game.combat.damage(skull, 1_000)
    150.times { game.combat.send(:tick_monster, skull) }
    assert skull.thing.removed, "vanilla SKULL_DIE6 → S_NULL despawns the soul"
    assert_equal :dead, skull.state
  end

  private

  class StubRng
    def initialize(vals); @vals = vals; @i = 0; end
    def rand(_n = nil)
      v = @vals[@i % @vals.size]; @i += 1; v
    end
  end

  # Synthesize a lost soul next to the player. Mirrors the caco test's
  # spawn_monster path.
  def skull_in(game)
    info = Rubydoom::MonsterInfo[SKULL]
    thing = Rubydoom::Map::Thing.new(
      game.player.x + 200, game.player.y, 0, SKULL, 0, false,
      nil, nil, nil, nil,
    )
    game.map.things << thing
    mobj = game.combat.send(:spawn_monster, thing, info)
    game.combat.instance_variable_get(:@mobjs)    << mobj
    game.combat.instance_variable_get(:@by_thing)[thing] = mobj
    # tick_monster reads @player off Combat — populated only after the
    # first update_tic. Seed it so the synthetic tic path works.
    game.combat.instance_variable_set(:@player, game.player)
    [game, mobj]
  end
end
