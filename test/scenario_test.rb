require "test_helper"

# In-memory Map synthesis via Scenario. Covers:
#   * builder output shape (vertex/linedef/seg counts, single sector).
#   * Game#load_map accepts a Map directly and rebuilds every
#     per-map subsystem (Bsp / Clipper / Combat / MonsterAI / ...).
#   * both halves of the partition resolve to the room sector via
#     Clipper#sector_at (i.e. the BSP is wired correctly).
#   * monsters placed by .thing() spawn into Combat#monsters.
#   * tic loop runs end-to-end without crashing.
class ScenarioTest < Minitest::Test
  def test_builder_emits_expected_lump_shapes
    map = Rubydoom::Scenario.new(name: "ARENA").size(2048, 2048).build
    assert_equal "ARENA", map.name
    assert_equal 6, map.vertexes.size,  "4 corners + 2 partition split-points"
    assert_equal 4, map.linedefs.size,  "one linedef per wall"
    assert_equal 4, map.sidedefs.size,  "one sidedef per wall"
    assert_equal 1, map.sectors.size,   "single room"
    assert_equal 6, map.segs.size,      "N+S walls split, W+E whole"
    assert_equal 2, map.subsectors.size
    assert_equal 1, map.nodes.size
    map.linedefs.each do |ld|
      refute ld.two_sided?, "every wall is one-sided"
    end
  end

  def test_player_start_thing_is_at_requested_position
    map = Rubydoom::Scenario.new
            .player(x: -123, y: 456, angle: 90)
            .build
    ps = map.player_start
    refute_nil ps
    assert_equal(-123, ps.x)
    assert_equal( 456, ps.y)
    assert_equal(  90, ps.angle)
  end

  def test_extra_thing_carries_doomednum_and_position
    map = Rubydoom::Scenario.new
            .thing(3005, x: 600, y: -200, angle: 180)
            .build
    caco = map.things.find { |t| t.type == 3005 }
    refute_nil caco
    assert_equal 600,  caco.x
    assert_equal(-200, caco.y)
    assert_equal 180,  caco.angle
  end

  def test_game_load_map_accepts_a_scenario_map
    scene = Rubydoom::Scenario.new(name: "ARENA").size(2048, 2048)
              .player(x: -800, y: 0, angle: 0)
              .thing(3005, x: 600, y: 0)
              .build
    game = Rubydoom::Game.new(wad: TestHelper.wad, sound: nil,
                              skill: Rubydoom::Map::SKILL_DEFAULT)
    game.load_map(scene)

    assert_equal "ARENA", game.map.name
    assert_equal(-800, game.player.x)
    assert_equal(   0, game.player.y)
    cacos = game.combat.monsters.select { |m| m.info.doomednum == 3005 }
    assert_equal 1, cacos.size, "caco spawned into Combat"
  end

  def test_bsp_resolves_both_partition_halves_to_room_sector
    scene = Rubydoom::Scenario.new.size(2048, 2048).floor(7).build
    game = Rubydoom::Game.new(wad: TestHelper.wad, sound: nil)
    game.load_map(scene)
    assert_equal 7, game.clipper.sector_at(-500, 0).floor_height,
                 "left side of partition resolves to room sector"
    assert_equal 7, game.clipper.sector_at( 500, 0).floor_height,
                 "right side of partition resolves to room sector"
  end

  def test_tic_loop_runs_in_scenario_without_crashing
    scene = Rubydoom::Scenario.new.size(2048, 2048)
              .player(x: -800, y: 0)
              .thing(3005, x: 600, y: 0)
              .build
    game = Rubydoom::Game.new(wad: TestHelper.wad, sound: nil)
    game.load_map(scene)
    30.times { game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [])) }
    # Player didn't fall out of the world.
    refute_nil game.clipper.sector_at(game.player.x, game.player.y)
  end

  def test_walls_block_player_movement_into_the_wall
    scene = Rubydoom::Scenario.new.size(512, 512)
              .player(x: 0, y: 0)
              .build
    game = Rubydoom::Game.new(wad: TestHelper.wad, sound: nil)
    game.load_map(scene)
    # Walk east, stopping at a destination whose player-radius circle
    # overlaps the east wall (wall at x=256, radius=16, so any
    # destination with x in roughly [240, 272] gets rejected). A bigger
    # single-tic jump would teleport the player past the wall —
    # Clipper#try_move only checks circle-intersection at the
    # destination, which is fine in real DOOM where convex play space
    # always has another wall in the way but matters for synthetic
    # tests against an isolated arena.
    new_x, _ = game.clipper.slide(0, 0, 260, 0)
    assert_in_delta 0, new_x, 1, "wall blocked the move (final x=#{new_x})"
  end
end
