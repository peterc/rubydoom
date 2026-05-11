require "test_helper"

# Imp fireball (MT_TROOPSHOT) projectile system.
class ProjectilesTest < Minitest::Test
  def test_imp_fireball_spawn_state
    sys, imp, _player = setup_e1m2_imp_and_player_in_front
    floor_imp = sys_clip(sys).floor_at(imp.thing.x, imp.thing.y)

    proj = sys.spawn_imp_fireball(imp, @player)
    assert_equal 1,         sys.projs.size
    assert_equal :flying,   proj.state
    assert       @map.things.include?(proj.thing)
    assert_equal "BAL1",    proj.thing.sprite_override
    assert_equal "A",       proj.thing.frame_override
    assert       proj.z > floor_imp, "spawned above the imp's floor"

    # Velocity points roughly at player (player is at +x), magnitude ≈ 10.
    assert       proj.vx > 0, "velocity x positive (player is at +x)"
    assert_in_delta 10.0, Math.hypot(proj.vx, proj.vy), 0.1
  end

  def test_imp_fireball_damages_player_on_impact
    sys, imp, _player = setup_e1m2_imp_and_player_in_front
    sys.spawn_imp_fireball(imp, @player)
    hp_before = @player.health
    30.times { sys.update_tic(@player) }
    assert @player.health < hp_before, "player took damage from fireball"
  end

  def test_imp_fireball_stops_flying_when_it_hits_a_wall
    map  = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    bsp  = Rubydoom::Bsp.new(map.nodes)
    clip = Rubydoom::Clipper.new(map, bsp)
    sight = Rubydoom::Sight.new(map, clip)
    combat = Rubydoom::Combat.new(map)
    sys = Rubydoom::Projectiles.new(map, sight, clip, combat, rng: Random.new(42))

    imp = combat.monsters.find { |m| m.thing.type == 3001 }
    skip "no imp on E1M1 for wall test" unless imp

    fake_target = Struct.new(:x, :y, :view_height, :health).new(
      imp.thing.x + 5000.0, imp.thing.y, 41.0, 100
    )
    proj = sys.spawn_imp_fireball(imp, fake_target)
    ticks = 0
    while proj.state == :flying && ticks < 200
      sys.update_tic(fake_target)
      ticks += 1
    end
    refute_equal :flying, proj.state, "wall stopped the fireball within 200 tics"
  end

  def test_owner_imp_is_not_damaged_by_its_own_projectile
    map  = Rubydoom::Map.load(TestHelper.wad, "E1M2", skill: 3)
    bsp  = Rubydoom::Bsp.new(map.nodes)
    clip = Rubydoom::Clipper.new(map, bsp)
    sight = Rubydoom::Sight.new(map, clip)
    combat = Rubydoom::Combat.new(map)
    sys = Rubydoom::Projectiles.new(map, sight, clip, combat, rng: Random.new(42))
    imp = combat.monsters.find { |m| m.thing.type == 3001 }
    refute_nil imp

    # Aim at a target colocated with the imp — the ray starts where the
    # imp is, so owner-exclusion is the only thing preventing self-hit.
    fake = Struct.new(:x, :y, :view_height, :health).new(
      imp.thing.x.to_f, imp.thing.y.to_f, 41.0, 100
    )
    hp_before = imp.health
    sys.spawn_imp_fireball(imp, fake)
    3.times { sys.update_tic(fake) }
    assert_equal hp_before, imp.health
  end

  private

  def setup_e1m2_imp_and_player_in_front
    @map  = Rubydoom::Map.load(TestHelper.wad, "E1M2", skill: 3)
    @bsp  = Rubydoom::Bsp.new(@map.nodes)
    @clip = Rubydoom::Clipper.new(@map, @bsp)
    @sight  = Rubydoom::Sight.new(@map, @clip)
    @combat = Rubydoom::Combat.new(@map)
    @sys = Rubydoom::Projectiles.new(@map, @sight, @clip, @combat,
                                     rng: Random.new(42))
    imp = @combat.monsters.find { |m| m.thing.type == 3001 }
    refute_nil imp, "E1M2 has an imp"
    @player = Rubydoom::Player.from_thing(@map.player_start)
    @player.x = imp.thing.x + 100.0
    @player.y = imp.thing.y
    @player.view_height = 41.0
    [@sys, imp, @player]
  end

  def sys_clip(_sys)
    @clip
  end
end
