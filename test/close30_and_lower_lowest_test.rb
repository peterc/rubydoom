require "test_helper"

# Linedef types 16 / 76 (close30ThenOpen door) and 23 / 82
# (lowerFloorToLowest). E1M6/E1M7 fixtures.
class Close30AndLowerLowestTest < Minitest::Test
  def test_type_16_close30_lifecycle
    game = fresh_game(map: "E1M6")
    ld = game.map.linedefs.find { |l| l.special_type == 16 }
    refute_nil ld, "E1M6 has a type-16 linedef"

    sec = game.map.sectors.find { |s| s.tag == ld.sector_tag }
    orig_ceil = sec.ceiling_height
    orig_floor = sec.floor_height
    assert orig_ceil > orig_floor, "door starts open"

    assert_equal :w1, game.doors.handle_cross(ld)

    # Close phase: at DOOR_SPEED_TIC = 2, takes (ceil-floor)/2 tics.
    close_tics = ((orig_ceil - orig_floor).to_f / Rubydoom::Doors::DOOR_SPEED_TIC).ceil
    close_tics.times { game.doors.update_tic }
    door = game.doors.instance_variable_get(:@active).values.first
    refute_nil door, "door entry retained during wait"
    assert_equal :wait_closed, door.state, "switched to 30-sec wait"
    assert_equal orig_floor, sec.ceiling_height, "fully closed"

    # Wait phase: 30 sec = 1050 tics.
    1050.times { game.doors.update_tic }
    door = game.doors.instance_variable_get(:@active).values.first
    assert_equal :opening, door.state, "wait expired; reopening"

    # Reopen phase.
    close_tics.times { game.doors.update_tic }
    assert_equal orig_ceil, sec.ceiling_height, "fully reopened"
    assert game.doors.instance_variable_get(:@active).empty?,
           "door reaped after reopen"
  end

  def test_type_76_is_repeatable
    game = fresh_game(map: "E1M6")
    ld = game.map.linedefs.find { |l| l.special_type == 76 }
    skip "E1M6 has no type-76 linedef" unless ld
    assert_equal :wr, game.doors.handle_cross(ld)
    assert_equal 76, ld.special_type, "WR leaves special intact"
  end

  def test_type_23_lower_to_lowest_on_e1m7
    game = fresh_game(map: "E1M7")
    ld = game.map.linedefs.find { |l| l.special_type == 23 }
    refute_nil ld, "E1M7 has a type-23 switch"
    sec = game.map.sectors.find { |s| s.tag == ld.sector_tag }
    refute_nil sec
    orig_floor = sec.floor_height

    assert game.floors.handle_use(ld), "S1 fires"
    movers = game.floors.instance_variable_get(:@active).values
    target = movers.find { |m| m.sector == sec }
    refute_nil target, "queued a mover for the tagged sector"
    assert_equal :down, target.direction
    assert target.dest < orig_floor, "dest is below current floor"

    1000.times { game.floors.update_tic }
    assert_equal target.dest, sec.floor_height,
                 "reached lowest neighbour floor"
  end

  def test_type_82_wr_lower_to_lowest_dispatch
    game = fresh_game(map: "E1M8")
    ld = game.map.linedefs.find { |l| l.special_type == 82 }
    skip "E1M8 has no type-82 linedef" unless ld
    assert_equal :wr, game.floors.handle_cross(ld)
    assert_equal 82, ld.special_type, "WR leaves special intact"
  end
end
