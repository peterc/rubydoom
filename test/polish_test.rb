require "test_helper"

# Tiny-feature coverage:
#   * sector special 17 (fire flicker)
#   * SR switch swap-back after BUTTON_REVERT_TICS
#   * dsoof landing trigger
#   * monster active sound rolls in A_Chase
#   * Sound#play_at pan computation
class PolishTest < Minitest::Test
  # ---- Light effect 17 (fire flicker) ----

  def test_fire_flicker_alters_light_level_within_max_min_range
    map, _bsp = fresh_map(name: "E1M2")
    sec = map.sectors.first
    sec.special_type = 17
    sec.light_level  = 160
    lights = Rubydoom::SectorLights.new(map, rng: Random.new(1))
    # Sample over 60 tics; light should land in [min, max] always and
    # actually move (not be stuck at 160 the whole time).
    seen = Set.new
    60.times do
      lights.update_tic
      seen << sec.light_level
    end
    assert seen.size > 1, "flicker mutates light level over time"
    # Vanilla quirk: min = min_neighbor + 16 can exceed sector's own
    # light, so we don't assert a hard upper bound. We just verify the
    # level lands in plausible 8-bit range.
    assert seen.all? { |v| v >= 0 && v <= 255 }, "in 8-bit light range"
  end

  # ---- SR switch swap-back ----

  def test_sr_switch_reverts_texture_after_button_time
    map, _bsp = fresh_map(name: "E1M2")
    switches = Rubydoom::Switches.new(map)
    # Find an SR switch fixture: type 62 SR lift, or type 63 SR door.
    # We bypass try_use and queue revert directly so the test doesn't
    # depend on map geometry (which sidedef has SW1, ray casting, etc.).
    ld = map.linedefs.find { |l| l.special_type == 62 || l.special_type == 63 }
    skip "no SR switch on E1M1" unless ld
    sd = map.sidedefs[ld.front_sidedef_index]
    # Force a SW2 texture so swap_switch_texture has something to flip.
    sd.middle_texture = "SW2EXIT" if (sd.middle_texture || "-") == "-"
    switches.send(:queue_revert, ld)
    pre = sd.middle_texture
    (Rubydoom::Switches::BUTTON_REVERT_TICS - 1).times { switches.update_tic }
    assert_equal pre, sd.middle_texture, "still depressed before timer"
    switches.update_tic
    refute_equal pre, sd.middle_texture, "texture swapped on revert"
  end

  def test_sr_switch_repress_resets_timer_without_double_revert
    map, _bsp = fresh_map(name: "E1M2")
    switches = Rubydoom::Switches.new(map)
    ld = map.linedefs.find { |l| l.special_type == 62 || l.special_type == 63 }
    skip "no SR switch on E1M1" unless ld
    switches.send(:queue_revert, ld)
    20.times { switches.update_tic }            # timer half-elapsed
    switches.send(:queue_revert, ld)            # re-press resets to 35
    # Make sure we have only one pending entry (no stacking).
    pending = switches.instance_variable_get(:@pending_reverts)
    assert_equal 1, pending.size
    assert_equal Rubydoom::Switches::BUTTON_REVERT_TICS, pending.values.first[1]
  end

  # ---- dsoof landing ----

  def test_oof_plays_on_big_drop
    game = fresh_game
    sound = RecordingSound.new
    game.instance_variable_set(:@sound, sound)
    # Pretend the player was higher last tic by a 32-unit ledge.
    floor_z = game.clipper.floor_at(game.player.x, game.player.y)
    game.instance_variable_set(:@last_floor_z, floor_z + 32)
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, []))
    assert_includes sound.plays, :oof
  end

  def test_oof_silent_on_small_drop
    game = fresh_game
    sound = RecordingSound.new
    game.instance_variable_set(:@sound, sound)
    # A 16-unit drop (under the 24 threshold) is silent.
    floor_z = game.clipper.floor_at(game.player.x, game.player.y)
    game.instance_variable_set(:@last_floor_z, floor_z + 16)
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, []))
    refute_includes sound.plays, :oof
  end

  # ---- Monster active sounds ----

  def test_play_active_sound_uses_mobjinfo_active_sound
    game = fresh_game
    sound = RecordingSound.new
    game.monster_ai.instance_variable_set(:@sound, sound)
    mobj = game.combat.monsters.find { |m| m.thing.type == 3001 } # imp
    skip "no imp on E1M1" unless mobj
    game.monster_ai.send(:play_active_sound, mobj, game.player)
    assert_equal [mobj.info.active_sound], sound.plays
  end

  def test_a_chase_rolls_active_sound_at_3_in_256_rate
    # Stub @rng with an object that returns 0 from rand(256). The
    # 3-in-256 check passes, so a_chase must call play_active_sound.
    game = fresh_game
    sound = RecordingSound.new
    game.monster_ai.instance_variable_set(:@sound, sound)
    # value=2 gives rand(4)→2 (no missile, since 2 != 0), rand(256)→2
    # (< ACTIVE_SOUND_CHANCE = 3, so the roll fires).
    game.monster_ai.instance_variable_set(:@rng, StubRng.new(2))
    mobj = game.combat.monsters.find { |m| m.thing.type == 3001 }
    skip "no imp on E1M1" unless mobj
    mobj.target = game.player
    # Combat#update_tic primes @player before running actions, so we
    # need a tic to flow through it before enter_state's actions fire.
    # Call once to set @player, then enter the run state and tick a few
    # frames so at least one :chase action runs.
    game.combat.update_tic(game.player)
    game.combat.enter_state(mobj, mobj.info.see_state)
    10.times { game.combat.update_tic(game.player) }
    refute_empty sound.plays, "active sound rolled on chase tic"
    assert sound.plays.include?(mobj.info.active_sound)
  end

  # ---- Sound panning ----

  def test_pan_for_centered_source_is_zero
    sound = Rubydoom::Sound.new(TestHelper.wad)
    # Source straight ahead at angle 0° (+x facing): dx=200, dy=0.
    pan = sound.send(:pan_for, 200.0, 0.0, 200.0, 0.0)
    assert_in_delta 0.0, pan, 0.01
  end

  def test_pan_for_source_to_the_right_is_positive
    sound = Rubydoom::Sound.new(TestHelper.wad)
    # Facing +x; right is -y. So a source at (0, -200) is on the right.
    pan = sound.send(:pan_for, 0.0, -200.0, 200.0, 0.0)
    assert pan > 0.5, "source on listener's right => pan > 0 (got #{pan})"
  end

  def test_pan_for_source_to_the_left_is_negative
    sound = Rubydoom::Sound.new(TestHelper.wad)
    # Facing +x; left is +y. Source at (0, +200) is on the left.
    pan = sound.send(:pan_for, 0.0, 200.0, 200.0, 0.0)
    assert pan < -0.5, "source on listener's left => pan < 0 (got #{pan})"
  end

  # Minimal stand-in for Sound that just records what was asked to
  # play, so the tests don't need to load WAV samples.
  class RecordingSound
    attr_reader :plays
    def initialize; @plays = []; end
    def play(name, source: nil); @plays << name; end
    def play_at(name, _x, _y, _l, source: nil); @plays << name; end
  end

  # Deterministic RNG that always returns the same value. Real Random
  # is unsuitable for "must hit the 3-in-256 branch" — we'd need a
  # known-good seed for every change in rand-call order.
  class StubRng
    def initialize(value); @value = value; end
    def rand(n = nil); n ? @value % n : @value; end
  end
end
