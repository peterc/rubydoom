require "test_helper"

# WR Teleport (linedef type 97). E1M5 has ten of them; without this
# implementation the level is soft-locked at the first teleporter.
class TeleportsTest < Minitest::Test
  def setup
    @game = fresh_game(map: "E1M5")
  end

  def test_teleport_warps_player_to_destination_thing
    ld = @game.map.linedefs.find { |l| l.special_type == 97 }
    refute_nil ld, "E1M5 has at least one type-97 teleporter"

    dest = @game.map.things.find { |t|
      t.type == 14 && @game.clipper.sector_at(t.x, t.y)&.tag == ld.sector_tag
    }
    refute_nil dest, "matching teleport-dest thing exists"

    @game.player.x = -224.0
    @game.player.y = -624.0
    assert @game.teleports.handle_cross(ld, @game.player)
    assert_equal dest.x.to_f, @game.player.x
    assert_equal dest.y.to_f, @game.player.y
    assert_equal dest.angle.to_f, @game.player.angle
  end

  def test_teleport_is_repeatable_special_left_intact
    ld = @game.map.linedefs.find { |l| l.special_type == 97 }
    assert @game.teleports.handle_cross(ld, @game.player)
    assert_equal 97, ld.special_type, "WR teleport doesn't consume special"
    assert @game.teleports.handle_cross(ld, @game.player),
           "second cross teleports again"
  end

  def test_non_teleport_linedef_is_a_noop
    fake = Struct.new(:special_type, :sector_tag).new(0, 0)
    refute @game.teleports.handle_cross(fake, @game.player)
  end

  def test_teleport_without_destination_thing_is_a_noop
    fake = Struct.new(:special_type, :sector_tag).new(97, 9_999)
    refute @game.teleports.handle_cross(fake, @game.player),
           "no destination thing → silent no-op"
  end

  def test_every_e1m5_teleporter_resolves_to_a_destination
    teles = @game.map.linedefs.select { |l| l.special_type == 97 }
    assert_equal 10, teles.size
    teles.each do |ld|
      assert @game.teleports.handle_cross(ld, @game.player),
             "teleporter with tag #{ld.sector_tag} resolved"
    end
  end
end
