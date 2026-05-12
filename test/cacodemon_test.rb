require "test_helper"

# Cacodemon (MT_HEAD, doomednum 3005). No melee state — vanilla
# mobjinfo sets melee_state = S_NULL, so a_chase only enters the
# missile sequence. A_HeadAttack itself chooses bite (10..60) when in
# melee range, otherwise spits an MT_HEADSHOT fireball (BAL2, 5..40
# damage, speed 10).
#
# Doom 1 shareware (doom1.wad) has zero cacos in E1, so we synthesize
# one into a live Game via the spawn_monster path.
class CacodemonTest < Minitest::Test
  CACO = 3005

  def test_caco_mobjinfo_registered
    info = Rubydoom::MonsterInfo[CACO]
    refute_nil info
    assert_equal 400, info.health
    assert_equal  31, info.radius
    assert_equal  56, info.height
    assert_nil   info.melee_state,
                 "vanilla MT_HEAD has no melee_state — bite is decided in the action"
    assert_equal :head_atk1, info.missile_state
    assert_equal :cacsit,    info.see_sound
    assert_equal :cacdth,    info.death_sound
  end

  def test_state_table_run_loops_to_itself
    s = Rubydoom::MonsterStates[:head_run1]
    assert_equal :head_run1, s.next, "vanilla MT_HEAD chase state self-loops"
    assert_equal :chase,     s.action
  end

  def test_terminal_die_frame_is_inactive_and_held
    s = Rubydoom::MonsterStates[:head_die6]
    refute_nil s
    assert_nil s.tics
    assert_nil s.action
    assert_nil s.next
  end

  def test_a_head_attack_melee_branch_damages_player
    game, caco = caco_in(game_for(:E1M1))
    caco.target = game.player
    game.player.x = caco.thing.x + 50  # well within MELEE_RANGE + 20
    game.player.y = caco.thing.y
    hp_before = game.player.health
    game.monster_ai.instance_variable_set(:@rng, Random.new(42))
    game.monster_ai.send(:a_head_attack, caco, game.player)
    assert game.player.health < hp_before, "player took bite damage"
    drop = hp_before - game.player.health
    assert_includes 10..60, drop, "vanilla bite roll = (rand%6+1)*10"
  end

  def test_a_head_attack_missile_branch_spawns_bal2
    game, caco = caco_in(game_for(:E1M1))
    caco.target = game.player
    game.player.x = caco.thing.x + 600
    game.player.y = caco.thing.y
    before = game.projectiles.projs.size
    game.monster_ai.send(:a_head_attack, caco, game.player)
    assert_equal before + 1, game.projectiles.projs.size
    bal = game.projectiles.projs.last
    assert_equal "BAL2", bal.thing.sprite_override
  end

  def test_headshot_damage_falls_in_5_to_40_range
    p = Rubydoom::Projectiles.new(*projectile_deps)
    100.times do
      d = p.send(:headshot_damage)
      assert_includes 5..40, d,
                      "MT_HEADSHOT damage = (rand%8+1)*5"
    end
  end

  def test_chase_doesnt_pick_melee_state_for_caco
    # Vanilla a_chase: `if mobj.info.melee_state && dist <= MELEE_RANGE`
    # — caco's melee_state is nil so this branch is never taken. With
    # the player adjacent, chase should instead enter missile_state.
    game, caco = caco_in(game_for(:E1M1))
    caco.target = game.player
    game.player.x = caco.thing.x + 30   # very close
    game.player.y = caco.thing.y
    # Force the missile-roll to succeed: rand(4) == 0.
    game.monster_ai.instance_variable_set(:@rng, StubRng.new([0]))
    game.monster_ai.send(:a_chase, caco, game.player)
    assert_equal :head_atk1, caco.state_key,
                 "caco enters missile state from chase, never a melee state"
  end

  private

  # A minimal RNG that returns canned values from an array, looping.
  class StubRng
    def initialize(vals); @vals = vals; @i = 0; end
    def rand(_n = nil)
      v = @vals[@i % @vals.size]; @i += 1; v
    end
  end

  def game_for(map_name)
    fresh_game(map: map_name.to_s)
  end

  # Inject a synthetic cacodemon mobj into the live Combat. Picks a
  # position next to the player so the AI hand-offs work without
  # walking the BSP.
  def caco_in(game)
    info = Rubydoom::MonsterInfo[CACO]
    thing = Rubydoom::Map::Thing.new(
      game.player.x + 200, game.player.y, 0, CACO, 0, false,
      nil, nil, nil, nil,
    )
    game.map.things << thing
    # Combat#spawn_monster is private; reach in via send.
    mobj = game.combat.send(:spawn_monster, thing, info)
    game.combat.instance_variable_get(:@mobjs)    << mobj
    game.combat.instance_variable_get(:@by_thing)[thing] = mobj
    [game, mobj]
  end

  # Projectiles.new arguments mirror App's wiring: map, sight,
  # clipper, combat, sound:, rng:. For the damage-roll test we only
  # exercise headshot_damage so the other deps can be nil.
  def projectile_deps
    map, _bsp = fresh_map
    [map, nil, nil, nil]
  end
end
