require "test_helper"

# End-to-end Game#tick behaviour: synthetic Input drives the simulation
# and inventory carries across map transitions.
class GameTest < Minitest::Test
  def test_game_loads_without_pulling_gosu
    # Verify in an isolated subprocess: the test process itself loads
    # rubydoom (which loads app.rb, which loads Gosu), so we can't check
    # from here. Build a tiny script that requires the pre-Gosu chain
    # plus game.rb and asserts Gosu is undefined.
    script = <<~RUBY
      $LOAD_PATH.unshift "#{File.expand_path("../lib", __dir__)}"
      %w[wad palette colormap picture graphics textures animated_textures
         sprites thing_types sky flats animated_flats visplanes map bsp
         clipper doors plats floors switches wall_scrollers sector_lights
         sector_effects pickups player hitscan monster_info monster_states
         sight monster_movement noise_alert combat monster_ai projectiles
         weapons face input game].each do |m|
        require "rubydoom/\#{m}"
      end
      abort "Gosu loaded" if Object.const_defined?(:Gosu)
      print "ok"
    RUBY
    out = IO.popen([RbConfig.ruby, "-e", script], &:read)
    assert_equal "ok", out, "Game loads without pulling Gosu in"
  end

  def test_walking_forward_moves_the_player
    game = fresh_game
    x0, y0 = game.player.x, game.player.y
    fwd = Rubydoom::Input.new(1, 0, 0, 0, false, [])
    10.times { game.tick(fwd) }
    refute_equal [x0, y0], [game.player.x, game.player.y]
  end

  def test_mouse_look_changes_angle
    game = fresh_game
    ang0 = game.player.angle
    look = Rubydoom::Input.new(0, 0, 0, 100, false, [])
    game.tick(look)
    refute_equal ang0, game.player.angle
  end

  def test_debug_hurt_edge_subtracts_10
    game = fresh_game
    hp = game.player.health
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:debug_hurt]))
    assert_equal hp - 10, game.player.health
  end

  def test_debug_heal_edge_adds_10
    game = fresh_game
    game.player.health = 50
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:debug_heal]))
    assert_equal 60, game.player.health
  end

  def test_toggle_god_makes_player_immune
    game = fresh_game
    silence { game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:toggle_god])) }
    assert game.player.god_mode
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:debug_hurt]))
    assert_equal 100, game.player.health
  end

  def test_use_edge_does_not_crash_when_no_door_in_front
    game = fresh_game
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:use]))
    # No assertion — just exercising the path.
    assert true
  end

  def test_weapon_1_sets_pending_to_fist
    game = fresh_game
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:weapon_1]))
    assert_equal :fist, game.player.pending_weapon
  end

  def test_respawn_edge_revives_dead_player
    game = fresh_game
    game.player.health = 0
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:respawn]))
    assert_equal 100, game.player.health
    refute game.player.dead?
  end

  # Vanilla single-player: dying reloads the entire level (monsters back,
  # doors closed, sectors reverted) and the player is pistol-started.
  def test_death_respawn_reloads_map_and_pistol_starts
    game = fresh_game
    alive = ->(c) { c.monsters.count { |m| m.state != :dead } }
    alive_before = alive.call(game.combat)
    combat_instance_before = game.combat.object_id
    doors_instance_before  = game.doors.object_id

    # Build up some non-default inventory so we can prove it's wiped.
    game.player.weapons_owned[:shotgun] = true
    game.player.ammo[:bullet] = 200
    game.player.add_armor(50, type: :green)
    game.player.keys[:blue][:card] = true

    # Kill a few monsters so they fall out of the alive count.
    game.combat.monsters.first(3).each do |m|
      game.combat.damage(m, 10_000, source: game.player)
    end
    50.times { game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [])) }
    assert alive.call(game.combat) < alive_before,
           "killed monsters drop out of the alive count"

    game.player.health = 0
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [:respawn]))

    # Pistol-start kit.
    assert_equal 100, game.player.health
    assert_equal 0,   game.player.armor
    refute game.player.has_weapon?(:shotgun), "shotgun gone on respawn"
    assert game.player.has_weapon?(:pistol),  "pistol kept on respawn"
    assert_equal 50,  game.player.ammo[:bullet]
    refute game.player.has_key?(:blue),       "blue key gone on respawn"

    # Map reloaded: subsystems are fresh instances and the dead
    # monsters are alive again.
    refute_equal combat_instance_before, game.combat.object_id
    refute_equal doors_instance_before,  game.doors.object_id
    assert_equal alive_before, alive.call(game.combat),
                 "killed monsters back alive after full-level reset"
  end

  private

  # toggle_god prints "[god mode] ON" to stdout. Swallow it so the
  # test output stays clean.
  def silence
    old = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old
  end
end
