require "test_helper"

# Exploding-barrel behaviour (MT_BARREL): damage drops it into a death
# animation, the corpse vanishes after the animation, splash damage hits
# nearby mobjs, and barrels in close proximity chain-react.
class BarrelsTest < Minitest::Test
  def setup
    fresh
  end

  def test_combat_tracks_barrels_at_full_health
    barrel = @map.things.find { |t| t.type == 2035 }
    refute_nil barrel
    mobj = @combat.mobj_for(barrel)
    refute_nil mobj
    assert_equal 20,      mobj.health
    assert_equal :alive,  mobj.state
    assert_equal :barrel, mobj.kind
    assert @combat.shootables.any? { |t, _| t == barrel }
    assert_nil barrel.solid_override
  end

  def test_non_lethal_damage_keeps_barrel_alive
    barrel = @map.things.find { |t| t.type == 2035 }
    mobj = @combat.mobj_for(barrel)
    @combat.damage(mobj, 10)
    assert_equal 10,    mobj.health
    assert_equal :alive, mobj.state
    assert_nil  barrel.sprite_override
  end

  def test_lethal_damage_starts_death_animation_and_drops_solid
    barrel = @map.things.find { |t| t.type == 2035 }
    mobj = @combat.mobj_for(barrel)
    far_player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(barrel.x + 1000, barrel.y, 0)
    )
    hp_before = far_player.health
    @combat.damage(mobj, 20, source: far_player)
    assert       mobj.health <= 0
    assert_equal :dying, mobj.state
    assert_equal "BEXP", barrel.sprite_override
    assert_equal "A",    barrel.frame_override
    assert_equal false,  barrel.solid_override
    refute @combat.shootables.any? { |t, _| t == barrel },
           "dropped from shootables once dying"
    assert_equal hp_before, far_player.health, "splash didn't reach far player"
  end

  def test_death_animation_completes_and_corpse_is_removed
    barrel = @map.things.find { |t| t.type == 2035 }
    mobj   = @combat.mobj_for(barrel)
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(barrel.x + 200, barrel.y, 0)
    )
    @combat.damage(mobj, 20, source: player)
    40.times { @combat.update_tic(player) }
    assert_equal :dead, mobj.state
    assert_equal true,  barrel.removed
  end

  def test_close_barrel_pair_chain_reacts
    map, pair = nil, nil
    %w[E1M1 E1M2 E1M3 E1M4 E1M5 E1M6 E1M7 E1M8 E1M9].each do |name|
      m = Rubydoom::Map.load(TestHelper.wad, name, skill: 3)
      barrels = m.things.select { |t| t.type == 2035 }
      barrels.each do |a|
        b = barrels.find { |x| x != a && Math.hypot(a.x - x.x, a.y - x.y) < 128 }
        if b
          map, pair = m, [a, b]
          break
        end
      end
      break if pair
    end
    skip "no barrel pair within 128 anywhere in E1" unless pair

    combat = Rubydoom::Combat.new(map)
    a, b = pair
    ma = combat.mobj_for(a)
    mb = combat.mobj_for(b)
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(a.x + 500, a.y, 0)
    )
    combat.damage(ma, 20, source: player)
    assert_equal :dying, ma.state
    assert_equal :dying, mb.state, "B chain-killed by A's splash"
  end

  def test_barrel_at_point_blank_kills_a_zombieman
    fresh
    barrel = @combat.instance_variable_get(:@mobjs).find { |m| m.kind == :barrel }
    poss   = @combat.monsters.find { |m| m.thing.type == 3004 }
    poss.thing.x = barrel.thing.x.to_f
    poss.thing.y = barrel.thing.y.to_f + 16
    hp_before = poss.health
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(10_000.0, 10_000.0, 0.0)
    )
    @combat.damage(barrel, 100, source: player)
    assert poss.health < hp_before
    assert [:dying, :dead].include?(poss.state), "POSS state: #{poss.state}"
  end

  def test_barrel_at_radius_edge_only_scratches
    fresh
    barrel = @combat.instance_variable_get(:@mobjs).find { |m| m.kind == :barrel }
    poss   = @combat.monsters.find { |m| m.thing.type == 3004 }
    poss.thing.x = barrel.thing.x.to_f
    poss.thing.y = barrel.thing.y.to_f + 127.0
    hp_before = poss.health
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(10_000.0, 10_000.0, 0.0)
    )
    @combat.damage(barrel, 100, source: player)
    assert poss.health < hp_before, "took at least 1 damage at edge"
    assert_equal :alive, poss.state, "but did not die at the edge"
  end

  def test_barrel_outside_radius_does_no_damage
    fresh
    barrel = @combat.instance_variable_get(:@mobjs).find { |m| m.kind == :barrel }
    poss   = @combat.monsters.find { |m| m.thing.type == 3004 }
    poss.thing.x = barrel.thing.x.to_f
    poss.thing.y = barrel.thing.y.to_f + 200.0
    hp_before = poss.health
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(10_000.0, 10_000.0, 0.0)
    )
    @combat.damage(barrel, 100, source: player)
    assert_equal hp_before, poss.health
  end

  private

  def fresh
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @combat  = Rubydoom::Combat.new(@map)
  end
end
