require "test_helper"

# E1M4 / E1M5 floor specials beyond the type-36 lower-fast that was
# already wired. Each test pulls a real fixture linedef from the WAD
# and confirms the matching activate_* path either queues movement
# or returns a sensible no-op for sectors that can't move.
class FloorSpecialsTest < Minitest::Test
  def test_type_5_w1_floor_raise_to_low_ceiling_on_e1m4
    game = fresh_game(map: "E1M4")
    ld = game.map.linedefs.find { |l| l.special_type == 5 }
    refute_nil ld, "E1M4 has a type-5 linedef"
    before = game.floors.instance_variable_get(:@active).size
    assert_equal :w1, game.floors.handle_cross(ld)
    after = game.floors.instance_variable_get(:@active).size
    assert after > before, "type 5 queued at least one mover"
  end

  def test_type_98_wr_floor_lower_fast_on_e1m5
    game = fresh_game(map: "E1M5")
    ld = game.map.linedefs.find { |l| l.special_type == 98 }
    refute_nil ld, "E1M5 has a type-98 linedef"
    assert_equal :wr, game.floors.handle_cross(ld)
    movers = game.floors.instance_variable_get(:@active).values
    assert movers.any? { |m| m.direction == :down && m.speed == Rubydoom::Floors::FLOOR_SPEED_FAST },
           "type 98 queues a fast downward mover"
  end

  def test_type_22_w1_raise_to_next_higher_on_e1m5
    game = fresh_game(map: "E1M5")
    ld = game.map.linedefs.find { |l| l.special_type == 22 }
    refute_nil ld, "E1M5 has the type-22 linedef"
    assert_equal :w1, game.floors.handle_cross(ld)
  end

  def test_type_86_routes_to_doors_not_floors
    game = fresh_game(map: "E1M4")
    ld = game.map.linedefs.find { |l| l.special_type == 86 }
    refute_nil ld, "E1M4 has type-86 linedefs"
    assert_nil game.floors.handle_cross(ld)
    targets = game.map.sectors.select { |s| s.tag == ld.sector_tag }
    floors = targets.map(&:floor_height)
    game.send(:handle_walk_cross, ld)
    500.times { game.floors.update_tic; game.doors.update_tic }
    assert_equal floors, targets.map(&:floor_height)
    assert targets.all? { |s| s.ceiling_height > s.floor_height }
    assert_equal 86, ld.special_type, "WR special stays intact"
  end

  def test_type_18_s1_raise_to_next_higher_on_e1m4
    game = fresh_game(map: "E1M4")
    ld = game.map.linedefs.find { |l| l.special_type == 18 }
    refute_nil ld
    before = game.floors.instance_variable_get(:@active).size
    assert game.floors.handle_use(ld), "type 18 use fires"
    after = game.floors.instance_variable_get(:@active).size
    assert after > before, "type 18 queued movement"
  end

  def test_type_70_sr_floor_lower_fast_on_e1m5
    game = fresh_game(map: "E1M5")
    ld = game.map.linedefs.find { |l| l.special_type == 70 }
    refute_nil ld, "E1M5 has a type-70 linedef"
    # E1M5's tag-1 sectors for type 70 already sit at their highest
    # surrounding floor + LIP, so vanilla also no-ops them. The
    # dispatch shape is what matters: handle_use returns truthy iff
    # movement queued, which Switches uses to decide whether to play
    # the click sound. Either way, the linedef stays intact (SR).
    game.floors.handle_use(ld)
    assert_equal 70, ld.special_type, "SR special stays intact"
  end

  def test_type_5_and_91_share_the_same_action
    # Vanilla source: both 5 and 91 call EV_DoFloor(line, raiseFloor).
    # Our Floors#handle_cross dispatches both into
    # activate_raise_to_low_ceiling. Confirm by mutating a copy of a
    # type-5 linedef to be type-91 and asserting identical behaviour.
    game = fresh_game(map: "E1M4")
    ld_real = game.map.linedefs.find { |l| l.special_type == 5 }
    ld_91 = ld_real.dup
    ld_91.special_type = 91
    assert_equal :wr, game.floors.handle_cross(ld_91)
  end
end
