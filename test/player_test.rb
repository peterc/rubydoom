require "test_helper"

# Player inventory mechanics (keys, weapons, ammo, armor, health) and
# reset_to_start! semantics for respawn.
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

  def test_reset_to_start_restores_pistol_start
    @player.pickup_key(:blue, :card)
    @player.weapons_owned[:shotgun] = true
    @player.ammo[:shell] = 16
    @player.pickup_armor_pack(50, type: :green)
    @player.health = 0  # killed first

    @player.x = 1234.0; @player.y = 5678.0
    @player.reset_to_start!(@map.player_start)

    refute @player.dead?
    assert_equal 100, @player.health
    assert_equal [@map.player_start.x, @map.player_start.y], [@player.x, @player.y]
    assert_equal @map.player_start.angle, @player.angle
    refute @player.has_weapon?(:shotgun),  "shotgun lost on respawn"
    assert @player.has_weapon?(:pistol),   "pistol kept on respawn"
    assert_equal 50, @player.ammo[:bullet]
    assert_equal 0,  @player.ammo[:shell]
    refute @player.has_key?(:blue),        "blue key lost on respawn"
    assert_equal 0,   @player.armor
    assert_nil @player.armor_class
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
