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
end
