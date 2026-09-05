require "test_helper"

class MapTransitionTest < Minitest::Test
  def next_map(name, secret: false, wad: TestHelper.wad)
    # Exercise the frontend's routing without initializing a Gosu window.
    app = Rubydoom::App.allocate
    game = Struct.new(:map, :switches, :wad).new(
      Struct.new(:name).new(name),
      Struct.new(:secret_exit_requested).new(secret), wad
    )
    app.instance_variable_set(:@game, game)
    app.send(:pick_next_map)
  end

  def test_e1_secret_detour_returns_to_main_route
    assert_equal "E1M9", next_map("E1M3", secret: true)
    assert_equal "E1M4", next_map("E1M9")
    assert_equal "E1M5", next_map("E1M4")
  end

  def test_normal_e1m3_exit_still_skips_secret_map
    assert_equal "E1M4", next_map("E1M3")
  end

  def test_episode_ending_is_unchanged
    assert_equal "E1M9", next_map("E1M8")
  end

  def test_missing_return_map_uses_directory_order
    lump = Struct.new(:name)
    wad = Struct.new(:lumps) do
      def lump(name) = lumps.find { |entry| entry.name == name }
    end.new([lump.new("E1M9"), lump.new("E2M1")])
    assert_equal "E2M1", next_map("E1M9", wad: wad)
    wad.lumps.pop
    assert_nil next_map("E1M9", wad: wad)
  end
end
