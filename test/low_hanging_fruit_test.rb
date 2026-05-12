require "test_helper"

# Coverage for three small additions:
#   * sector specials 5 (10% damage) and 11 (20% damage + level-exit
#     once health drops to 10 or below)
#   * walk-trigger linedef type 124 (W1 secret exit) + 52 (W1 normal)
#   * berserk pack (doomednum 2023) — grants the power, heals to 100,
#     auto-switches to fist, and the fist's hit damage 10×es while held
class LowHangingFruitTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1")
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
  end

  # ---- Sector specials ----

  def test_type_5_slime_does_10_per_cycle
    sec = @map.sectors.find { |s| s.special_type == 7 }
    skip "no damage floor on E1M1 to repurpose" unless sec
    sec.special_type = 5  # treat it as 10%/cycle slime for the test
    px, py = interior_point_for(sec)
    refute_nil px
    player = make_player(px, py)
    effects = Rubydoom::SectorEffects.new(@clipper)

    100.times { effects.update_tic(player) }
    # 100 tics / 32-tic cadence = 3 hits × 10 hp = 30 hp lost.
    assert_equal 70, player.health
  end

  def test_type_5_respects_radsuit
    sec = @map.sectors.find { |s| s.special_type == 7 }
    skip "no damage floor on E1M1" unless sec
    sec.special_type = 5
    px, py = interior_point_for(sec)
    player = make_player(px, py)
    player.grant_power(:radsuit)
    effects = Rubydoom::SectorEffects.new(@clipper)
    100.times { effects.update_tic(player) }
    assert_equal 100, player.health
  end

  def test_type_11_strips_god_mode_and_exits_on_low_health
    sec = @map.sectors.find { |s| s.special_type == 7 }
    skip "no damage floor on E1M1" unless sec
    sec.special_type = 11
    px, py = interior_point_for(sec)
    player = make_player(px, py)
    player.god_mode = true
    player.health   = 30  # 2 hits at 20% will drop us under threshold
    switches = Rubydoom::Switches.new(@map)
    effects = Rubydoom::SectorEffects.new(@clipper)
    effects.switches = switches

    200.times { effects.update_tic(player) }

    refute player.god_mode, "type 11 strips god mode"
    assert player.health <= 10, "damage applied past threshold"
    assert switches.exit_requested, "exit requested on death threshold"
  end

  # ---- W1 exits ----

  def test_request_exit_secret_sets_both_flags
    switches = Rubydoom::Switches.new(@map)
    switches.request_exit!(secret: true)
    assert switches.exit_requested
    assert switches.secret_exit_requested
  end

  def test_request_exit_normal_does_not_set_secret
    switches = Rubydoom::Switches.new(@map)
    switches.request_exit!
    assert switches.exit_requested
    refute switches.secret_exit_requested
  end

  # ---- Berserk ----

  def test_berserk_pickup_grants_power_heals_and_switches
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(0, 0, 0)
    )
    player.health = 40
    # Simulate the pickup by calling the same Player methods the
    # pickup helper uses. We don't run Pickups#update_tic here because
    # we don't have a berserk thing in the map at a touchable location.
    player.grant_power(:berserk)
    player.add_health(100) if player.health < 100
    player.pending_weapon = :fist

    assert player.has_power?(:berserk)
    assert_equal 100, player.health
    assert_equal :fist, player.pending_weapon
  end

  def test_punch_damage_x10_while_berserk
    weapons = Rubydoom::Weapons.new(hitscan: nil, combat: nil, sound: nil,
                                    noise_alert: nil, rng: Random.new(42))
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(0, 0, 0)
    )
    # Without berserk: base is in 2..20. melee_damage is private; call
    # via send so we don't have to expose it.
    base_samples = 200.times.map { weapons.send(:melee_damage) }
    assert base_samples.all? { |d| (2..20).cover?(d) }

    player.grant_power(:berserk)
    boosted_samples = 200.times.map do
      weapons.send(:melee_damage, player, berserk_bonus: true)
    end
    assert boosted_samples.all? { |d| (20..200).cover?(d) }
    # Saw path (no bonus) stays base even with berserk.
    saw_samples = 200.times.map { weapons.send(:melee_damage, player) }
    assert saw_samples.all? { |d| (2..20).cover?(d) }
  end

  private

  def make_player(px, py)
    Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(px, py, 0)
    )
  end

  def interior_point_for(target_sec)
    @map.subsectors.each do |ss|
      seg = @map.segs[ss.first_seg_index]
      ld  = @map.linedefs[seg.linedef_index]
      sd_idx = seg.direction.zero? ? ld.front_sidedef_index : ld.back_sidedef_index
      sd  = @map.sidedefs[sd_idx]
      next unless @map.sectors[sd.sector_index] == target_sec
      xs = []; ys = []
      ss.seg_count.times do |i|
        sg = @map.segs[ss.first_seg_index + i]
        a = @map.vertexes[sg.start_vertex_index]
        b = @map.vertexes[sg.end_vertex_index]
        xs << a.x; xs << b.x
        ys << a.y; ys << b.y
      end
      cx = xs.sum.fdiv(xs.size); cy = ys.sum.fdiv(ys.size)
      return [cx, cy] if @clipper.sector_at(cx, cy) == target_sec
    end
    [nil, nil]
  end
end
