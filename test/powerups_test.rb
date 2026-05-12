require "test_helper"

# Powerup system (timer + per-power effects). Currently wired:
#   * Radiation suit (biosuit, doomednum 2025) — IRONTICS = 60 sec.
#     Negates damage from types 7 and 16 while active.
#   * Blursphere (doomednum 2024) — INVISTICS = 60 sec. Monster
#     aim is perturbed by ±22.5° while active.
class PowerupsTest < Minitest::Test
  def setup
    @game   = fresh_game(map: "E1M3")
    @player = @game.player
  end

  def test_grant_power_sets_timer_and_tic_decrements
    assert @player.grant_power(:radsuit)
    assert_equal 60 * 35, @player.powers[:radsuit]
    @player.tic_powers!
    assert_equal 60 * 35 - 1, @player.powers[:radsuit]
    assert @player.has_power?(:radsuit)
  end

  def test_radsuit_negates_floor_damage
    sec = @game.map.sectors.find { |s| s.special_type == 16 }
    refute_nil sec
    park_player_in(sec)

    @player.health = 100
    @player.grant_power(:radsuit)
    100.times { @game.sector_effects.update_tic(@player) }
    assert_equal 100, @player.health, "radsuit absorbed all damage"
  end

  def test_radsuit_expiry_lets_damage_through_again
    sec = @game.map.sectors.find { |s| s.special_type == 16 }
    park_player_in(sec)
    @player.health = 100
    # Set timer to 1 tic — expires next tic_powers! call.
    @player.powers[:radsuit] = 1
    @game.sector_effects.update_tic(@player)        # leveltime=1, no damage (not aligned)
    # Run a full 32-tic period of damage *after* expiry
    @player.tic_powers!                              # radsuit drops to 0
    refute @player.has_power?(:radsuit)
    32.times { @game.sector_effects.update_tic(@player) }
    assert @player.health < 100, "damage resumes once radsuit expires"
  end

  def test_blursphere_pickup_grants_invisibility
    blur = @game.map.things.find { |t| t.type == 2024 }
    refute_nil blur, "E1M3 has a blursphere"
    @player.x = blur.x.to_f
    @player.y = blur.y.to_f
    @game.pickups.update_tic(@player)
    assert @player.has_power?(:invisibility)
    assert_equal 60 * 35, @player.powers[:invisibility]
    assert blur.removed, "blursphere consumed"
  end

  def test_invisibility_perturbs_monster_aim
    # Set up an imp with the player as target, then call a_face_target
    # twice — once visible, once invisible — and confirm the angle
    # differs when invisible (we don't pin a specific value because
    # the RNG is shared).
    imp = @game.combat.monsters.find { |m| m.thing.type == 3001 }
    refute_nil imp
    imp.target = @player

    # Visible: angle should snap exactly to atan2(player - imp).
    @player.powers[:invisibility] = 0
    @game.monster_ai.send(:a_face_target, imp, @player)
    clean_angle = imp.thing.angle

    # Invisible: aim is perturbed. Try several rolls — at least one
    # should differ from the clean angle by more than a degree.
    @player.grant_power(:invisibility)
    diffs = (1..10).map do
      @game.monster_ai.send(:a_face_target, imp, @player)
      ((imp.thing.angle - clean_angle + 540) % 360 - 180).abs
    end
    assert diffs.any? { |d| d > 1.0 },
           "invisibility introduced visible angle variance (max #{diffs.max})"
  end

  private

  def park_player_in(sec)
    @game.map.linedefs.each do |ld|
      f = @game.map.linedef_front_sector(ld)
      b = @game.map.linedef_back_sector(ld)
      next unless f == sec || b == sec
      v1 = @game.map.vertexes[ld.start_vertex_index]
      v2 = @game.map.vertexes[ld.end_vertex_index]
      mx = (v1.x + v2.x) * 0.5
      my = (v1.y + v2.y) * 0.5
      nx, ny = -(v2.y - v1.y), (v2.x - v1.x)
      len = Math.hypot(nx, ny)
      next if len.zero?
      nx /= len; ny /= len
      [+1, -1].each do |sgn|
        px = mx + nx * sgn * 8
        py = my + ny * sgn * 8
        if @game.clipper.sector_at(px, py) == sec
          @player.x = px
          @player.y = py
          return
        end
      end
    end
    flunk "couldn't park player in sector"
  end
end
