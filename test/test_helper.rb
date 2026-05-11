$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "rubydoom"

module TestHelper
  WAD_PATH = File.expand_path("../doom1.wad", __dir__)

  # The WAD is large to parse — share one across all tests. Each test
  # that wants a fresh Game still gets one (Game.new re-parses palette /
  # colormap / textures / sprites / flats, but reuses the in-memory WAD
  # lump table).
  def self.wad
    @wad ||= Rubydoom::WAD.open(WAD_PATH)
  end

  # Build a fresh Game on the given map. `sound: nil` keeps tests from
  # touching the Gosu audio driver.
  def fresh_game(map: "E1M1", skill: Rubydoom::Map::SKILL_DEFAULT)
    game = Rubydoom::Game.new(wad: TestHelper.wad, sound: nil, skill: skill)
    game.load_map(map)
    game
  end

  # Build just a map + clipper + combat trio — cheaper than a full Game
  # for tests that only poke at one subsystem.
  def fresh_map(name: "E1M1", skill: Rubydoom::Map::SKILL_DEFAULT)
    map = Rubydoom::Map.load(TestHelper.wad, name, skill: skill)
    bsp = Rubydoom::Bsp.new(map.nodes)
    [map, bsp]
  end
end

Minitest::Test.include(TestHelper)
