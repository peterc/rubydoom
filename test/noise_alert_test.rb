require "test_helper"

# NoiseAlert flood-fills from the emitter's sector through connected,
# unblocked two-sided lines (P_NoiseAlert / sound propagation). The
# touched sectors store soundtarget = player so monsters' A_Look
# tic checks pick them up.
class NoiseAlertTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M1", skill: 3)
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @na      = Rubydoom::NoiseAlert.new(@map)
    ps = @map.player_start
    @player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(ps.x.to_f, ps.y.to_f, ps.angle.to_f)
    )
    @psec = @clipper.sector_index_at(@player.x, @player.y)
  end

  def test_no_sector_targets_before_any_alert
    assert_nil @na.target_for(@psec)
  end

  def test_alert_marks_emitter_sector
    @na.alert(@player, @psec)
    assert_equal @player, @na.target_for(@psec)
  end

  def test_alert_propagates_beyond_the_emitter_sector
    @na.alert(@player, @psec)
    marked = (0...@map.sectors.size).count { |i| @na.target_for(i) == @player }
    assert marked > 1, "flood reached at least one adjacent sector"
  end

  def test_second_alert_remarks_the_same_count
    @na.alert(@player, @psec)
    marked1 = (0...@map.sectors.size).count { |i| @na.target_for(i) == @player }
    @na.alert(@player, @psec)
    marked2 = (0...@map.sectors.size).count { |i| @na.target_for(i) == @player }
    assert_equal marked1, marked2
  end
end
