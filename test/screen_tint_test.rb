require "test_helper"

# Damage / pickup screen-tint counters (vanilla's damagecount /
# bonuscount). Player#take_damage bumps damage_count by the raw
# incoming damage, capped at 100; Pickups bumps bonus_count via
# flash_bonus! to BONUSADD=6 on every successful absorption;
# Game#tick decays both by 1/tic.
class ScreenTintTest < Minitest::Test
  def setup
    @player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(0, 0, 0)
    )
  end

  def test_fresh_player_has_no_tint
    assert_equal 0, @player.damage_count
    assert_equal 0, @player.bonus_count
    assert_nil   @player.screen_tint
  end

  def test_take_damage_bumps_damage_count_by_raw_amount
    @player.take_damage(15)
    assert_equal 15, @player.damage_count
  end

  def test_damage_count_caps_at_100
    @player.take_damage(250)
    assert_equal 100, @player.damage_count
  end

  def test_damage_count_uses_raw_damage_not_post_armor
    # Green armor absorbs 1/3 → health takes 20 of a 30 hit. The
    # screen flash still wants the full 30 so the visual matches
    # what the player perceives ("I just got hit hard").
    @player.add_armor(50, type: :green)
    @player.take_damage(30)
    assert_equal 30, @player.damage_count
  end

  def test_god_mode_blocks_damage_count_too
    @player.toggle_god!
    @player.take_damage(50)
    assert_equal 0, @player.damage_count
  end

  def test_flash_bonus_sets_bonus_count_to_bonusadd
    @player.flash_bonus!
    assert_equal 6, @player.bonus_count
  end

  def test_tic_screen_tints_decays_both_counters
    @player.take_damage(10)
    @player.flash_bonus!
    @player.tic_screen_tints!
    assert_equal  9, @player.damage_count
    assert_equal  5, @player.bonus_count
  end

  def test_tic_screen_tints_doesnt_go_below_zero
    20.times { @player.tic_screen_tints! }
    assert_equal 0, @player.damage_count
    assert_equal 0, @player.bonus_count
  end

  def test_screen_tint_returns_red_when_damaged
    @player.take_damage(32)
    tint = @player.screen_tint
    refute_nil tint
    r, g, b, _a = tint
    assert_equal [255, 0, 0], [r, g, b]
  end

  def test_screen_tint_intensity_increases_with_damage
    @player.take_damage(8)
    light_a = @player.screen_tint[3]
    @player.tic_screen_tints!  # decay so next damage stacks freshly
    @player.take_damage(64)
    heavy_a = @player.screen_tint[3]
    assert heavy_a > light_a, "more damage → stronger tint (got #{light_a} → #{heavy_a})"
  end

  def test_screen_tint_returns_gold_for_pickup_when_no_damage
    @player.flash_bonus!
    tint = @player.screen_tint
    refute_nil tint
    r, g, b, _a = tint
    # Yellow-ish — green channel high, red high, blue low.
    assert r > 150
    assert g > 100
    assert b < 100
  end

  def test_damage_takes_priority_over_bonus
    @player.flash_bonus!
    @player.take_damage(10)
    tint = @player.screen_tint
    assert_equal [255, 0, 0], tint[0..2], "red wins over gold"
  end

  def test_pickup_via_pickups_system_sets_bonus_count
    map = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    bsp = Rubydoom::Bsp.new(map.nodes)
    pickups = Rubydoom::Pickups.new(map)

    clip = map.things.find { |t| t.type == 2007 }
    refute_nil clip
    pp = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(clip.x, clip.y, 0)
    )
    pickups.update_tic(pp)
    assert_equal 6, pp.bonus_count
  end

  def test_tic_screen_tints_is_called_each_game_tic
    game = fresh_game
    game.player.take_damage(10)
    assert_equal 10, game.player.damage_count
    game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, []))
    assert_equal 9, game.player.damage_count, "Game.tick decays damage_count"
  end
end
