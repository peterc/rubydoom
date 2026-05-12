require "test_helper"

# Player inventory mechanics (keys, weapons, ammo, armor, health).
class PlayerTest < Minitest::Test
  def setup
    @map    = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @player = Rubydoom::Player.from_thing(@map.player_start)
  end

  def test_fresh_player_is_alive_with_pistol_loadout
    refute @player.dead?,                       "fresh player is alive"
    assert_equal 100,    @player.health
    assert @player.has_weapon?(:pistol),        "starts owning pistol"
    assert @player.has_weapon?(:fist),          "starts owning fist"
    refute @player.has_weapon?(:shotgun),       "no shotgun at start"
    assert_equal :pistol, @player.current_weapon
  end

  def test_lethal_damage_drops_to_zero_and_dead
    @player.take_damage(200)
    assert_equal 0, @player.health
    assert @player.dead?
  end

  def test_take_damage_short_circuits_under_god_mode
    @player.toggle_god!
    @player.take_damage(9999)
    assert_equal 100, @player.health
  end

  def test_toggle_god_while_dead_heals_to_100
    @player.health = 0
    @player.toggle_god!
    assert_equal 100, @player.health
    assert @player.god_mode
    refute @player.dead?
  end
end
