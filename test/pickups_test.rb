require "test_helper"

# Pickups dispatch: when the player thing overlaps a pickup,
# Pickups#update_tic applies the right Player# helper and removes
# the thing iff it was absorbed (consumed). Pickups follow vanilla
# rules — full-health stim is a no-op, BON1 caps at 200 (not 100),
# green armor sets to 100 rather than adds, etc.
class PickupsTest < Minitest::Test
  def setup
    fresh_map
  end

  def test_stimpack_at_full_health_is_not_consumed
    stim = thing_of_type(2011)
    skip "no stimpack on E1M1" unless stim
    pp = at(stim)
    @pickups.update_tic(pp)
    assert_equal 100, pp.health
    assert_nil   stim.removed
  end

  def test_stimpack_at_50_heals_by_10
    fresh_map
    stim = thing_of_type(2011)
    pp = at(stim)
    pp.health = 50
    @pickups.update_tic(pp)
    assert_equal 60,   pp.health
    assert_equal true, stim.removed
  end

  def test_clip_absorbs_when_below_max
    clip = thing_of_type(2007)
    skip "no clip on E1M1" unless clip
    pp = at(clip)
    assert_equal 50, pp.ammo[:bullet]
    @pickups.update_tic(pp)
    assert_equal 60,   pp.ammo[:bullet]
    assert_equal true, clip.removed
  end

  def test_clip_at_max_bullets_is_not_consumed
    fresh_map
    clip = thing_of_type(2007)
    pp = at(clip)
    pp.ammo[:bullet] = pp.max_ammo[:bullet]
    @pickups.update_tic(pp)
    assert_equal 200, pp.ammo[:bullet]
    assert_nil   clip.removed
  end

  def test_bon1_caps_at_200_not_100
    fresh_map
    bon = thing_of_type(2014)
    skip "no BON1 on E1M1" unless bon
    pp = at(bon)
    pp.health = 150
    @pickups.update_tic(pp)
    assert_equal 151,  pp.health
    assert_equal true, bon.removed
  end

  def test_green_armor_sets_to_100_not_additive
    arm = thing_of_type(2018)
    skip "no green armor on E1M1" unless arm
    fresh_map
    arm = thing_of_type(2018)
    pp = at(arm)
    pp.armor = 30; pp.armor_class = :green
    @pickups.update_tic(pp)
    assert_equal 100,    pp.armor
    assert_equal :green, pp.armor_class
    assert_equal true,   arm.removed
  end

  def test_backpack_doubles_maxes_and_grants_one_clip_each
    map_with_bpak, bpak = find_thing_on_some_map(8)
    skip "no backpack on any E1 map" unless bpak
    @map     = map_with_bpak
    @pickups = Rubydoom::Pickups.new(@map)
    pp = at(bpak)
    @pickups.update_tic(pp)
    assert_equal 400, pp.max_ammo[:bullet]
    assert_equal 100, pp.max_ammo[:shell]
    assert_equal 100, pp.max_ammo[:rocket]
    assert_equal 600, pp.max_ammo[:cell]
    assert_equal 60,  pp.ammo[:bullet]   # 50 starting + 10
    assert_equal 4,   pp.ammo[:shell]
    assert_equal 1,   pp.ammo[:rocket]
    assert_equal 20,  pp.ammo[:cell]
    assert  pp.backpack
    assert_equal true, bpak.removed
  end

  private

  def fresh_map
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @pickups = Rubydoom::Pickups.new(@map)
  end

  def thing_of_type(t)
    @map.things.find { |th| th.type == t && !th.removed }
  end

  def at(thing)
    Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(thing.x, thing.y, 0)
    )
  end

  # Try each E1 map until one has a thing of the given doomednum.
  # Returns [map, thing] or [nil, nil].
  def find_thing_on_some_map(type)
    %w[E1M1 E1M2 E1M3 E1M4 E1M5 E1M6 E1M7 E1M8 E1M9].each do |name|
      m = Rubydoom::Map.load(TestHelper.wad, name)
      t = m.things.find { |th| th.type == type }
      return [m, t] if t
    end
    [nil, nil]
  end
end
