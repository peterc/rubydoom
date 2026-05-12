require "test_helper"

# Rocket launcher: trigger pull consumes one rocket, spawns a Proj
# with the MT_ROCKET stats, and on detonation runs a radius_attack
# splash from the impact point. Direct hit on a thing also applies
# rocket damage before the splash.
class RocketLauncherTest < Minitest::Test
  def setup
    @game = fresh_game(map: "E1M1")
    @player = @game.player
    @player.weapons_owned[:rocket] = true
    @player.current_weapon = :rocket
    @player.ammo[:rocket]  = 5
  end

  def test_fire_rocket_consumes_one_ammo_and_spawns_a_proj
    starting_ammo = @player.ammo[:rocket]
    starting_projs = @game.projectiles.projs.size

    # Hold the fire button and tick until the action frame fires.
    @game.weapons.fire_button = true
    20.times { @game.weapons.update_tic(@player) }

    assert_equal starting_ammo - 1, @player.ammo[:rocket]
    assert_equal starting_projs + 1, @game.projectiles.projs.size
    proj = @game.projectiles.projs.last
    assert_equal "MISL", proj.thing.sprite_override
    assert proj.splash, "rocket carries splash flag"
  end

  def test_rocket_radius_attack_damages_nearby_mobjs_on_detonation
    # Drop the rocket on top of a barrel and tick the projectile.
    barrel_mobj = @game.combat.instance_variable_get(:@mobjs).find { |m| m.kind == :barrel }
    skip "no barrels on E1M1" unless barrel_mobj
    barrel_hp_start = barrel_mobj.health

    @game.projectiles.spawn_rocket(@player, slope: 0.0)
    proj = @game.projectiles.projs.last
    # Teleport the rocket on top of the barrel so the next tic detonates.
    proj.thing.x = barrel_mobj.thing.x.to_f
    proj.thing.y = barrel_mobj.thing.y.to_f
    proj.vx = proj.vy = proj.vz = 0.0
    # Force an immediate explode by collapsing the floor opening.
    # Easier: just call explode directly.
    @game.projectiles.send(:explode, proj, @player)

    assert barrel_mobj.health < barrel_hp_start,
           "barrel took splash damage from rocket detonation"
  end

  # Regression: a rocket fired at an imp on a ledge whose floor is
  # well above the player's eye used to explode against the front
  # face of the step (the AI line-of-sight check is too strict for
  # missiles) — splash would kill the imp, but the rocket itself
  # stayed low. With the missile-specific opening check it clears
  # the step and detonates inside the imp's body.
  def test_rocket_clears_step_up_when_aimed_at_high_target
    @player.x = 3000.0
    @player.y = -3472.0
    @player.angle = 0.0
    @player.view_height = 41.0
    slope = @game.hitscan.aim_slope(@player, shootables: @game.combat.shootables)
    assert slope > 0.1, "imp on ledge produces an upward slope"

    @game.projectiles.spawn_rocket(@player, slope: slope)
    proj = @game.projectiles.projs.last
    50.times do
      break if proj.state != :flying
      @game.projectiles.update_tic(@player)
    end
    assert proj.z > 90, "rocket reached the imp's body z (got #{proj.z.round})"
  end

  # Regression: a rocket flying through a barrel used to pass straight
  # through (hit_thing only iterated monsters, skipped barrels). Now
  # rockets detonate against barrels via the shootables list.
  def test_rocket_detonates_on_barrel
    game = fresh_game(map: "E1M3")
    barrel = game.combat.instance_variable_get(:@mobjs).find { |m| m.kind == :barrel }
    skip "no barrels on E1M3" unless barrel

    player = game.player
    player.x = barrel.thing.x.to_f + 100
    player.y = barrel.thing.y.to_f
    player.angle = 180.0
    slope = game.hitscan.aim_slope(player, shootables: game.combat.shootables)
    game.projectiles.spawn_rocket(player, slope: slope)
    proj = game.projectiles.projs.last

    30.times do
      break if proj.state != :flying
      game.projectiles.update_tic(player)
    end
    assert_equal :exploding, proj.state, "rocket detonated"
    refute_equal :alive, barrel.state, "barrel was destroyed by direct hit + splash"
  end
end
