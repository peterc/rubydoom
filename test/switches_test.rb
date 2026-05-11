require "test_helper"

# Switch / use-action linedef specials. Spot-check the S1 type 103
# remote door opener on E1M2 (the known fixture at the
# (-575, 1080) position).
class SwitchesTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M2", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @doors    = Rubydoom::Doors.new(@map)
    @plats    = Rubydoom::Plats.new(@map)
    @switches = Rubydoom::Switches.new(@map)
    @switches.doors = @doors
    @switches.plats = @plats
  end

  def test_type_103_switch_opens_tagged_door_and_clears_special
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(-575.2346478455787,
                                     1080.1984355411175,
                                     178.0)
    )
    ld = @map.linedefs.find { |l| l.special_type == 103 && l.sector_tag == 7 }
    refute_nil ld, "E1M2 has the type 103 / tag 7 switch"

    tag7 = @map.sectors.select { |s| s.tag == 7 }
    refute tag7.empty?

    assert_equal 0, @doors.instance_variable_get(:@active).size,
                 "no doors active pre-press"
    assert @switches.try_use(player),         "switch fired"
    assert_equal 0, ld.special_type,           "S1 special cleared after use"
    assert @doors.instance_variable_get(:@active).size >= 1,
           "door queued active"

    80.times { @doors.update_tic }
    assert tag7.any? { |s| s.ceiling_height > s.floor_height + 32 },
           "tagged sector ceiling raised"
    assert_equal 0, @doors.instance_variable_get(:@active).size,
                 "D1 reaped after fully open"
  end

  def test_type_20_switch_raises_tagged_floor_to_next_higher_neighbour
    # E1M3 switch at linedef 1020, sector_tag 16. Two sectors (48, 49)
    # at floor=-32 should rise to 88 (the only higher neighbour).
    map     = Rubydoom::Map.load(TestHelper.wad, "E1M3", skill: 3)
    bsp     = Rubydoom::Bsp.new(map.nodes)
    floors  = Rubydoom::Floors.new(map)
    switches = Rubydoom::Switches.new(map)
    switches.floors = floors

    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(-1290.6445508511792,
                                     -757.5419033295158,
                                     196.0)
    )
    ld = map.linedefs.find { |l| l.special_type == 20 && l.sector_tag == 16 }
    refute_nil ld, "E1M3 has the type 20 / tag 16 switch"

    tagged = map.sectors.select { |s| s.tag == 16 }
    starts = tagged.map(&:floor_height)
    assert_equal [-32, -32], starts, "both tagged sectors start at -32"

    assert switches.try_use(player), "switch fired"
    assert_equal 0, ld.special_type, "S1 cleared after use"

    # 1 mu/tic over 120 mu of travel = 120 tics; give a generous bound.
    200.times { floors.update_tic }
    tagged.each { |s| assert_equal 88, s.floor_height,
                                   "sector reached next-higher neighbour 88" }
  end
end
