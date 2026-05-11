require "test_helper"

# Map transition carries player inventory (vanilla single-player rule):
# weapons / ammo / armor / health / backpack stick; keys reset; the
# pending_weapon is cleared because the prior Weapons state machine is
# gone.
class InventoryCarryTest < Minitest::Test
  def setup
    @game = fresh_game(map: "E1M1")
    p = @game.player
    p.pickup_backpack
    p.health = 75
    p.armor = 50
    p.armor_class = :green
    p.weapons_owned[:shotgun]  = true
    p.weapons_owned[:chaingun] = true
    p.current_weapon = :shotgun
    p.pending_weapon = :chaingun
    p.ammo[:bullet] = 87
    p.ammo[:shell]  = 22
    p.ammo[:rocket] = 3
    p.pickup_key(:blue, :card)
  end

  def test_weapons_and_ammo_carry_into_next_map
    @game.load_map("E1M2")
    p = @game.player
    assert_equal 75,        p.health
    assert_equal 50,        p.armor
    assert_equal :green,    p.armor_class
    assert       p.weapons_owned[:shotgun]
    assert       p.weapons_owned[:chaingun]
    assert_equal :shotgun,  p.current_weapon
    assert_equal 87,        p.ammo[:bullet]
    assert_equal 22,        p.ammo[:shell]
    assert_equal 3,         p.ammo[:rocket]
  end

  def test_backpack_doubled_caps_persist
    @game.load_map("E1M2")
    p = @game.player
    assert       p.backpack
    assert_equal 400, p.max_ammo[:bullet]
    assert_equal 100, p.max_ammo[:shell]
  end

  def test_keys_reset_per_map
    @game.load_map("E1M2")
    refute @game.player.has_key?(:blue), "keys reset on transition"
  end

  def test_pending_weapon_clears_on_transition
    @game.load_map("E1M2")
    assert_nil @game.player.pending_weapon
  end

  def test_player_arrives_at_new_player_start
    expected = Rubydoom::Map.load(TestHelper.wad, "E1M2").player_start
    @game.load_map("E1M2")
    assert_equal [expected.x, expected.y], [@game.player.x, @game.player.y]
  end

  def test_inventory_carries_across_a_chain_of_transitions
    @game.load_map("E1M2")
    @game.load_map("E1M3")
    p = @game.player
    assert_equal 75, p.health
    assert       p.weapons_owned[:shotgun]
  end

  def test_god_mode_carries_across_transitions
    @game.player.god_mode = true
    @game.load_map("E1M2")
    assert @game.player.god_mode
  end
end
