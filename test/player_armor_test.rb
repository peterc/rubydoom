require "test_helper"

# Armor absorption rules + health gain caps. Pure unit tests on
# Player — no map needed.
class PlayerArmorTest < Minitest::Test
  def setup
    thing = Struct.new(:x, :y, :angle).new(0, 0, 0)
    @p = Rubydoom::Player.from_thing(thing)
  end

  def test_fresh_player_has_no_armor
    assert_equal 100, @p.health
    assert_equal 0,   @p.armor
    assert_nil   @p.armor_class
  end

  def test_damage_with_no_armor_just_reduces_health
    @p.take_damage(10)
    assert_equal 90, @p.health
    assert_equal 0,  @p.armor
  end

  def test_green_armor_absorbs_one_third
    @p.add_armor(50, type: :green)
    @p.take_damage(30)
    # 30 damage → 10 absorbed (1/3), 20 to health.
    assert_equal 80, @p.health
    assert_equal 40, @p.armor
    assert_equal :green, @p.armor_class
  end

  def test_blue_armor_absorbs_one_half_and_overrides_class
    @p.add_armor(100, type: :blue, max: 200)
    @p.take_damage(40)
    # 40 damage → 20 absorbed (1/2), 20 to health.
    assert_equal :blue, @p.armor_class
    assert_equal 80,  @p.health
    assert_equal 80,  @p.armor
  end

  def test_armor_exhaustion_clears_class
    @p.add_armor(5, type: :blue, max: 200)
    @p.take_damage(100)
    # 5 absorbed, 95 to health.
    assert_equal 0,   @p.armor
    assert_nil   @p.armor_class
    assert_equal 5,   @p.health
  end

  def test_health_clamps_to_zero
    @p.take_damage(999)
    assert_equal 0, @p.health
  end

  def test_negative_damage_is_a_noop
    @p.take_damage(-5)
    assert_equal 100, @p.health
  end

  def test_add_health_caps_at_default_max
    @p.take_damage(50)
    @p.add_health(25)
    assert_equal 75, @p.health
    @p.add_health(50)
    assert_equal 100, @p.health
    @p.add_health(25)
    assert_equal 100, @p.health
  end

  def test_add_health_with_explicit_max_allows_overheal
    @p.add_health(100, max: 200)
    assert_equal 200, @p.health
  end
end
