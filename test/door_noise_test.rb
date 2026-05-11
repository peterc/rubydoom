require "test_helper"

# Opening a door via try_use should propagate noise so monsters in the
# next room can wake up. The alert fires from the player's sector at
# the moment of use, before the door has actually started moving.
class DoorNoiseTest < Minitest::Test
  def test_using_a_dr_door_alerts_the_players_sector
    map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    bsp     = Rubydoom::Bsp.new(map.nodes)
    clipper = Rubydoom::Clipper.new(map, bsp)
    na      = Rubydoom::NoiseAlert.new(map)
    doors   = Rubydoom::Doors.new(map)
    doors.noise_alert = na
    doors.clipper     = clipper

    door_ld = map.linedefs.find { |ld| ld.special_type == 1 }
    refute_nil door_ld
    v1 = map.vertexes[door_ld.start_vertex_index]
    v2 = map.vertexes[door_ld.end_vertex_index]
    mid_x = (v1.x + v2.x) / 2.0
    mid_y = (v1.y + v2.y) / 2.0
    ldx = v2.x - v1.x; ldy = v2.y - v1.y
    len = Math.hypot(ldx, ldy)
    nx = -ldy / len; ny = ldx / len
    candidates = [[mid_x + nx * 24, mid_y + ny * 24],
                  [mid_x - nx * 24, mid_y - ny * 24]]
    fx, fy = candidates.find { |x, y| !clipper.floor_at(x, y).nil? }
    refute_nil fx
    angle = (Math.atan2(mid_y - fy, mid_x - fx) * 180.0 / Math::PI) % 360
    player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(fx, fy, angle)
    )
    psec = clipper.sector_index_at(player.x, player.y)

    assert_equal 0, (0...map.sectors.size).count { |i| na.target_for(i) },
                 "no sectors marked pre-use"

    assert doors.try_use(player), "door use succeeded"
    refute_nil na.target_for(psec), "player's sector got marked"
    marked = (0...map.sectors.size).count { |i| na.target_for(i) }
    assert marked >= 1
  end
end
