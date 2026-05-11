require "test_helper"

# Weapons state machine + pickup-to-switch wiring.
class WeaponsTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M2")
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @hitscan = Rubydoom::Hitscan.new(@map, @clipper)
  end

  def test_pistol_start_arsenal
    p = fresh_player
    assert p.has_weapon?(:fist)
    assert p.has_weapon?(:pistol)
    refute p.has_weapon?(:shotgun)
    refute p.has_weapon?(:chaingun)
    refute p.has_weapon?(:chainsaw)
    refute p.has_weapon?(:rocket)
    assert_equal :pistol, p.current_weapon
  end

  def test_first_shotgun_pickup_grants_8_shells_and_queues_switch
    p = fresh_player
    absorbed = p.pickup_weapon(:shotgun)
    assert absorbed,            "absorbed on first pickup"
    assert p.has_weapon?(:shotgun)
    assert_equal 8,       p.ammo[:shell]
    assert_equal :shotgun, p.pending_weapon
  end

  def test_second_shotgun_pickup_grants_ammo_only_no_switch
    p = fresh_player
    p.pickup_weapon(:shotgun)
    p.pending_weapon = nil
    absorbed = p.pickup_weapon(:shotgun)
    assert absorbed,                "absorbed for ammo"
    assert_equal 16,      p.ammo[:shell]
    assert_nil   p.pending_weapon, "no new switch on duplicate weapon"
  end

  def test_shotgun_pickup_at_max_shells_is_rejected
    p = fresh_player
    p.weapons_owned[:shotgun] = true
    p.ammo[:shell] = 50
    refute p.pickup_weapon(:shotgun), "pickup rejected at max"
  end

  def test_pistol_fire_consumes_one_bullet_and_animates
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan, rng: Random.new(42))
    p = fresh_player
    assert_equal "PISGA0", weapons.display_lump(p)
    assert_equal 50, p.ammo[:bullet]

    weapons.fire_button = true
    weapons.update_tic(p)
    assert_equal 49, p.ammo[:bullet]
  end

  def test_pistol_refire_continues_while_button_held
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan, rng: Random.new(42))
    p = fresh_player
    weapons.fire_button = true
    30.times { weapons.update_tic(p) }
    assert p.ammo[:bullet] <= 48, "refire fired at least one extra shot"
  end

  def test_pistol_returns_to_idle_after_button_release
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan, rng: Random.new(42))
    p = fresh_player
    weapons.fire_button = true
    30.times { weapons.update_tic(p) }
    weapons.fire_button = false
    40.times { weapons.update_tic(p) }
    assert_equal "PISGA0", weapons.display_lump(p)
  end

  def test_dry_fire_with_zero_bullets_stays_idle
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan)
    p = fresh_player
    p.ammo[:bullet] = 0
    weapons.fire_button = true
    2.times { weapons.update_tic(p) }
    assert_equal "PISGA0", weapons.display_lump(p)
    assert_equal 0,        p.ammo[:bullet]
  end

  def test_request_switch_to_owned_shotgun_takes_effect_next_tic
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan)
    p = fresh_player
    p.weapons_owned[:shotgun] = true; p.ammo[:shell] = 8
    weapons.request_switch(p, "3")
    assert_equal :shotgun, p.pending_weapon
    weapons.update_tic(p)
    assert_equal :shotgun, p.current_weapon
    assert_nil   p.pending_weapon
    assert_equal "SHTGA0", weapons.display_lump(p)
  end

  def test_key_1_cycles_fist_to_chainsaw_when_both_owned
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan)
    p = fresh_player
    p.weapons_owned[:chainsaw] = true

    weapons.request_switch(p, "1")
    assert_equal :fist, p.pending_weapon
    weapons.update_tic(p)

    weapons.request_switch(p, "1")
    assert_equal :chainsaw, p.pending_weapon
    weapons.update_tic(p)
    assert_equal :chainsaw, p.current_weapon

    weapons.request_switch(p, "1")
    assert_equal :fist, p.pending_weapon
  end

  def test_request_switch_to_unowned_weapon_is_ignored
    weapons = Rubydoom::Weapons.new(hitscan: @hitscan)
    p = fresh_player
    weapons.request_switch(p, "3")
    assert_nil p.pending_weapon
  end

  def test_hitscan_from_spawn_hits_a_wall
    p = fresh_player
    result = @hitscan.fire(p)
    refute_nil result
    assert_equal :wall, result[0]
    hx, hy = result[1], result[2]
    assert Math.hypot(hx - p.x, hy - p.y) > 0
  end

  def test_pickups_grant_weapon_and_auto_switch
    {
      2001 => [:shotgun,  :shell,   8],
      2002 => [:chaingun, :bullet, 20],
      2003 => [:rocket,   :rocket,  2],
      2005 => [:chainsaw, nil,      0],
    }.each do |doomednum, (weapon, ammo_type, expected_ammo)|
      map     = Rubydoom::Map.load(TestHelper.wad, "E1M2")
      pickups = Rubydoom::Pickups.new(map)
      thing   = map.things.find { |t| t.type == doomednum }
      next unless thing
      pp = Rubydoom::Player.from_thing(
        Struct.new(:x, :y, :angle).new(thing.x, thing.y, 0)
      )
      start_ammo = ammo_type ? pp.ammo[ammo_type] : 0
      pickups.update_tic(pp)
      assert       pp.has_weapon?(weapon),     "owns #{weapon} after pickup"
      assert_equal weapon, pp.pending_weapon,  "#{weapon} auto-switch queued"
      if ammo_type
        assert_equal expected_ammo, pp.ammo[ammo_type] - start_ammo
      end
      assert_equal true, thing.removed
    end
  end

  private

  def fresh_player
    ps = Struct.new(:x, :y, :angle).new(
      @map.player_start.x, @map.player_start.y, @map.player_start.angle
    )
    Rubydoom::Player.from_thing(ps)
  end
end
