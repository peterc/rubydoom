require "test_helper"

# HUD face state machine. Five prioritized states implemented:
# dead > god > ouch > evil-grin > wander. Tests drive Face directly
# with synthetic Player snapshots so we don't depend on tick ordering.
class FaceTest < Minitest::Test
  def setup
    @face = Rubydoom::Face.new
    @player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(0, 0, 0)
    )
  end

  def test_full_health_wanders
    @face.update_tic(@player)
    assert_match(/\ASTFST0[012]\z/, @face.lump_name(@player))
  end

  def test_dead_takes_priority_over_everything
    @player.health = 0
    @face.update_tic(@player)
    assert_equal "STFDEAD0", @face.lump_name(@player)
  end

  def test_god_mode_overrides_normal_wander
    @player.toggle_god!
    @face.update_tic(@player)
    assert_equal "STFGOD0", @face.lump_name(@player)
  end

  def test_dead_still_wins_over_god_mode
    @player.toggle_god!     # heals to 100 too
    @player.health = 0
    @face.update_tic(@player)
    assert_equal "STFDEAD0", @face.lump_name(@player)
  end

  def test_big_hit_triggers_ouch_face
    # Seed prior health.
    @face.update_tic(@player)
    @player.health = 100 - 30   # 30-point drop > 20 threshold
    @face.update_tic(@player)
    assert_match(/\ASTFOUCH[0-4]\z/, @face.lump_name(@player))
  end

  def test_small_hit_does_not_trigger_ouch
    @face.update_tic(@player)
    @player.health = 100 - 10   # 10-point drop is below threshold
    @face.update_tic(@player)
    refute_match(/STFOUCH/, @face.lump_name(@player))
  end

  def test_ouch_expires_after_ouch_tics
    @face.update_tic(@player)
    @player.health = 100 - 30
    @face.update_tic(@player)
    Rubydoom::Face::OUCH_TICS.times { @face.update_tic(@player) }
    refute_match(/STFOUCH/, @face.lump_name(@player))
  end

  def test_picking_up_a_new_weapon_triggers_evil_grin
    @face.update_tic(@player)              # seed weapons count
    @player.weapons_owned[:shotgun] = true
    @face.update_tic(@player)
    assert_match(/\ASTFEVL[0-4]\z/, @face.lump_name(@player))
  end

  def test_evil_grin_does_not_trigger_when_weapon_count_decreases
    # Set up a player with a shotgun, then "respawn" (reset weapons).
    @player.weapons_owned[:shotgun] = true
    @face.update_tic(@player)              # seed weapons count = 3
    @player.weapons_owned[:shotgun] = false
    @face.update_tic(@player)              # count drops to 2
    refute_match(/STFEVL/, @face.lump_name(@player))
  end

  def test_evil_grin_expires_after_evilgrin_tics
    @face.update_tic(@player)
    @player.weapons_owned[:shotgun] = true
    @face.update_tic(@player)
    Rubydoom::Face::EVILGRIN_TICS.times { @face.update_tic(@player) }
    refute_match(/STFEVL/, @face.lump_name(@player))
  end

  def test_ouch_beats_evil_grin
    @face.update_tic(@player)
    # Pick up a weapon AND take a big hit in the same tic.
    @player.weapons_owned[:shotgun] = true
    @player.health = 100 - 30
    @face.update_tic(@player)
    assert_match(/\ASTFOUCH[0-4]\z/, @face.lump_name(@player))
  end

  def test_god_mode_beats_ouch
    @face.update_tic(@player)
    @player.toggle_god!
    @player.health = 100 - 30
    @face.update_tic(@player)
    assert_equal "STFGOD0", @face.lump_name(@player)
  end

  def test_pain_offset_buckets_track_health_bands
    # Vanilla bands: h >= 80 → 0, 60..79 → 1, 40..59 → 2, 20..39 → 3,
    # 1..19 → 4. Validate the band edges via the lump name.
    {100 => 0, 80 => 0, 79 => 1, 60 => 1, 59 => 2,
     40  => 2, 39 => 3, 20 => 3, 19 => 4, 1 => 4}.each do |hp, pain|
      @player.health = hp
      face = Rubydoom::Face.new
      face.update_tic(@player)
      assert_match(/\ASTFST#{pain}[012]\z/, face.lump_name(@player),
                   "health=#{hp} → pain band #{pain}")
    end
  end
end
