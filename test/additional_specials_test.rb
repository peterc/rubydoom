require "test_helper"

class AdditionalSpecialsTest < Minitest::Test
  FixtureMap = Struct.new(:sectors, :sidedefs, :linedefs) do
    def linedef_front_sector(ld) = sectors[sidedefs[ld.front_sidedef_index].sector_index]
    def linedef_back_sector(ld)
      sectors[sidedefs[ld.back_sidedef_index].sector_index] if ld.two_sided?
    end
  end

  def setup
    @donor = Rubydoom::Map::Sector.new(0, 128, "DONOR", "CEIL", 64, 7, 0)
    @target = Rubydoom::Map::Sector.new(64, 128, "OLD", "CEIL", 160, 16, 9)
    @neighbor = Rubydoom::Map::Sector.new(16, 160, "OTHER", "CEIL", 32, 0, 0)
    @map = FixtureMap.new([@donor, @target, @neighbor], [], [])
    connect(1, 0, "TALL", "SHORT")
    connect(1, 2, "TALL", "-")
    @line = connect(0, nil, "-", "-")
    @line.sector_tag = 9
    @map.sidedefs[@line.front_sidedef_index].middle_texture = "SW1BRCOM"
    textures = {"SHORT" => Struct.new(:height).new(24), "TALL" => Struct.new(:height).new(48)}
    @floors = Rubydoom::Floors.new(@map, textures: textures)
    @plats = Rubydoom::Plats.new(@map, rng: Random.new(1))
    @doors = Rubydoom::Doors.new(@map)
    @switches = Rubydoom::Switches.new(@map)
    @switches.floors = @floors
    @switches.plats = @plats
    @switches.doors = @doors
    @switches.stairs = Rubydoom::Stairs.new(@map)
    @player = Rubydoom::Player.from_thing(Struct.new(:x, :y, :angle).new(0, 0, 0))
  end

  def connect(front, back, front_texture, back_texture)
    ld = Rubydoom::Map::LineDef.new
    ld.flags = 0
    ld.special_type = 0
    ld.sector_tag = 0
    ld.front_sidedef_index = @map.sidedefs.size
    @map.sidedefs << Rubydoom::Map::SideDef.new(0, 0, "-", front_texture, "-", front)
    ld.back_sidedef_index = Rubydoom::Map::NO_SIDEDEF
    if back
      ld.back_sidedef_index = @map.sidedefs.size
      @map.sidedefs << Rubydoom::Map::SideDef.new(0, 0, "-", back_texture, "-", back)
    end
    @map.linedefs << ld
    ld
  end

  def use(type)
    @line.special_type = type
    line = @line
    @switches.define_singleton_method(:ray_hits) { |*| [[16, line]] }
    @switches.try_use(@player)
  end

  def test_switch_stairs_on_real_e1m8_clear_once_and_raise_steps
    game = fresh_game(map: "E1M8")
    line = game.map.linedefs.find { |ld| ld.special_type == 7 }
    refute_nil line
    target = game.map.sectors.find { |s| s.tag == line.sector_tag }
    before = target.floor_height
    game.switches.define_singleton_method(:ray_hits) { |*| [[16, line]] }
    assert game.switches.try_use(game.player)
    assert_equal 0, line.special_type
    32.times { game.stairs.update_tic }
    assert_equal before + 8, target.floor_height
  end

  def test_switch_without_a_target_is_not_consumed
    @line.sector_tag = 999
    refute use(7)
    assert_equal 7, @line.special_type
    assert_equal "SW1BRCOM", @map.sidedefs[@line.front_sidedef_index].middle_texture
  end

  def test_floor_19_lowers_to_highest_and_38_to_lowest
    {19 => 16, 38 => 0}.each do |type, destination|
      @target.floor_height = 64
      @line.special_type = type
      assert_equal :w1, @floors.handle_cross(@line)
      @floors.update_tic
      assert_equal 63, @target.floor_height
      100.times { @floors.update_tic }
      assert_equal destination, @target.floor_height
    end
  end

  def test_lower_and_change_copies_properties_only_at_destination
    @line.special_type = 37
    @floors.handle_cross(@line)
    63.times { @floors.update_tic }
    assert_equal 1, @target.floor_height
    assert_equal ["OLD", 16], [@target.floor_texture, @target.special_type]
    @floors.update_tic
    assert_equal [0, "DONOR", 7], [@target.floor_height, @target.floor_texture, @target.special_type]
  end

  def test_raise_by_shortest_lower_texture_includes_both_sides
    @line.special_type = 30
    @floors.handle_cross(@line)
    100.times { @floors.update_tic }
    assert_equal 88, @target.floor_height
  end

  def test_raise24_with_and_without_property_change
    [58, 59].each do |type|
      @target.floor_height = 64
      @target.floor_texture, @target.special_type = "OLD", 16
      @line.special_type = type
      @floors.handle_cross(@line)
      expected = type == 59 ? ["DONOR", 7] : ["OLD", 16]
      assert_equal expected, [@target.floor_texture, @target.special_type]
      24.times { @floors.update_tic }
      assert_equal 88, @target.floor_height
    end
  end

  def test_switch_14_raises_32_at_half_speed_and_only_changes_texture
    assert use(14)
    assert_equal 0, @line.special_type
    assert_equal ["DONOR", 16], [@target.floor_texture, @target.special_type]
    @floors.update_tic
    assert_equal 64.5, @target.floor_height
    100.times { @floors.update_tic }
    assert_equal 96, @target.floor_height
  end

  def test_gun_floor_24_is_once_only
    @line.special_type = 24
    assert @switches.try_shoot(@line)
    assert_equal 0, @line.special_type
    refute @switches.try_shoot(@line)
    100.times { @floors.update_tic }
    assert_equal 128, @target.floor_height
  end

  def test_lift10_lifecycle_and_switch21_consumption
    @line.special_type = 10
    assert_equal :w1, @plats.handle_cross(@line)
    16.times { @plats.update_tic }
    assert_equal 0, @target.floor_height
    104.times { @plats.update_tic }
    assert_equal 0, @target.floor_height
    17.times { @plats.update_tic }
    assert_equal 64, @target.floor_height
    assert use(21)
    assert_equal 0, @line.special_type
  end

  def test_perpetual_lift_stops_and_resumes_without_resetting_height
    @target.floor_height = 8
    @line.special_type = 87
    @plats.handle_cross(@line)
    3.times { @plats.update_tic }
    @line.special_type = 89
    @plats.handle_cross(@line)
    stopped = @target.floor_height
    200.times { @plats.update_tic }
    assert_equal stopped, @target.floor_height
    @line.special_type = 87
    @plats.handle_cross(@line)
    @plats.update_tic
    refute_equal stopped, @target.floor_height
    heights = 500.times.map { @plats.update_tic; @target.floor_height }
    assert_equal [0, 16], heights.minmax
    assert_equal 87, @line.special_type
  end

  def test_door_close_walk_variants_and_repeatable_switches
    {3 => :w1, 75 => :wr}.each do |type, result|
      @target.ceiling_height = 128
      @line.special_type = type
      assert_equal result, @doors.handle_cross(@line)
      1000.times { @doors.update_tic }
      assert_equal 64, @target.ceiling_height, "close stays closed"
    end
    assert use(61)
    assert_equal 61, @line.special_type
    100.times { @doors.update_tic }
    assert_equal 124, @target.ceiling_height
    assert use(42)
    assert_equal 42, @line.special_type
    100.times { @doors.update_tic }
    assert_equal 64, @target.ceiling_height
  end

  def test_crushing_floor_stops_eight_below_ceiling_and_calls_damage_every_four_tics
    calls = []
    @floors.crush_handler = ->(s) { calls << s }
    @line.special_type = 56
    @floors.handle_cross(@line)
    56.times { @floors.update_tic }
    assert_equal 120, @target.floor_height
    assert_equal 14, calls.length
    assert calls.all? { |s| s.equal?(@target) }
  end

  def test_walk_dispatch_consumes_once_only_lift_but_preserves_repeatable
    game = fresh_game
    line = game.map.linedefs.find { |ld| ld.special_type == 88 }
    refute_nil line
    game.send(:handle_walk_cross, line)
    assert_equal 88, line.special_type
    line.special_type = 10
    game.send(:handle_walk_cross, line)
    assert_equal 0, line.special_type
  end

  def test_active_floor_does_not_restart_or_change_properties
    @line.special_type = 58
    @floors.handle_cross(@line)
    4.times { @floors.update_tic }
    @line.special_type = 59
    @floors.handle_cross(@line)
    30.times { @floors.update_tic }
    assert_equal [88, "OLD", 16], [@target.floor_height, @target.floor_texture, @target.special_type]
  end

  def test_perpetual_lift_preserves_wait_timer_while_stopped
    @target.floor_height = 8
    @line.special_type = 87
    @plats.handle_cross(@line)
    8.times { @plats.update_tic }
    endpoint = @target.floor_height
    assert_includes [0, 16], endpoint
    20.times { @plats.update_tic }
    @line.special_type = 89
    @plats.handle_cross(@line)
    200.times { @plats.update_tic }
    @line.special_type = 87
    @plats.handle_cross(@line)
    85.times { @plats.update_tic }
    assert_equal endpoint, @target.floor_height
    @plats.update_tic
    refute_equal endpoint, @target.floor_height
  end

  def test_crush_damage_reaches_player_and_monster
    scene = Rubydoom::Scenario.new.ceiling(64).player(x: 0, y: 0)
      .thing(3001, x: 64, y: 0).build
    game = Rubydoom::Game.new(wad: TestHelper.wad, rng: Random.new(42))
    game.load_map(scene)
    scene.sectors.first.floor_height = 16
    monster = game.combat.monsters.first
    health = monster.health
    game.send(:crush_floor_occupants, scene.sectors.first)
    assert_equal 90, game.player.health
    assert_equal health - 10, monster.health
  end

  def test_sector4_blinks_and_damages_without_losing_special
    @target.special_type = 4
    lights = Rubydoom::SectorLights.new(@map, rng: Random.new(42))
    clipper = Object.new
    sector = @target
    clipper.define_singleton_method(:sector_at) { |*| sector }
    effects = Rubydoom::SectorEffects.new(clipper)
    values = []
    32.times do
      lights.update_tic
      effects.update_tic(@player)
      values << @target.light_level
    end
    assert_equal 80, @player.health
    assert_equal [32, 160], values.uniq.sort
    assert_equal 4, @target.special_type
    @player.god_mode = true
    32.times { effects.update_tic(@player) }
    assert_equal 80, @player.health
  end

  def test_sector4_suit_protects_but_can_leak_deterministically
    @target.special_type = 4
    @player.powers[:radsuit] = 1000
    clipper = Object.new
    sector = @target
    clipper.define_singleton_method(:sector_at) { |*| sector }
    [255, 0].each do |roll|
      rng = Object.new
      rng.define_singleton_method(:rand) { |_| roll }
      effects = Rubydoom::SectorEffects.new(clipper, rng: rng)
      32.times { effects.update_tic(@player) }
      assert_equal(roll == 0 ? 80 : 100, @player.health)
    end
  end
end
