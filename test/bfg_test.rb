require "test_helper"

# BFG9000. Vanilla S_BFG1..S_BFG4 PSPR sequence: 20-tic charge with
# dsbfg, 10-tic flash, 10-tic actual missile spawn, 20-tic refire
# window. BFGCELLS = 40. Direct-hit damage (rand%8+1)*100 = 100..800.
# A_BFGSpray (the 40-tracer cone-from-player) is intentionally NOT
# wired here yet — that's a separate task.
class BfgTest < Minitest::Test
  def setup
    @map     = Rubydoom::Map.load(TestHelper.wad, "E1M2")
    @bsp     = Rubydoom::Bsp.new(@map.nodes)
    @clipper = Rubydoom::Clipper.new(@map, @bsp)
    @hitscan = Rubydoom::Hitscan.new(@map, @clipper)
    @combat  = Rubydoom::Combat.new(@map, sound: nil, rng: Random.new(1))
    @sight   = Rubydoom::Sight.new(@map, @clipper)
    @projs   = Rubydoom::Projectiles.new(@map, @sight, @clipper, @combat,
                                          sound: nil, rng: Random.new(1))
  end

  def test_bfg_info_structure
    info = Rubydoom::Weapons::INFO[:bfg]
    assert_equal "BFGGA0", info[:idle]
    assert_equal :cell,    info[:ammo]
    assert_equal 40,       info[:cost]
    # 20 + 10 + 10 + 20 = 60 tics total, matching vanilla S_BFG1..4.
    total = info[:fire_seq].sum { |frame| frame[1] }
    assert_equal 60, total
    # Charge action on the first frame, fire on the third.
    assert_equal :bfg_charge, info[:fire_seq][0][2]
    assert_equal :fire_bfg,   info[:fire_seq][2][2]
  end

  def test_can_fire_requires_40_cells
    weapons = build_weapons
    p = fresh_player
    p.weapons_owned[:bfg] = true
    p.current_weapon = :bfg
    p.ammo[:cell] = 39
    weapons.fire_button = true
    weapons.update_tic(p)
    assert_equal 39, p.ammo[:cell], "no charge with insufficient cells"
    assert_equal "BFGGA0", weapons.display_lump(p), "stays idle"

    p.ammo[:cell] = 40
    weapons.update_tic(p)
    assert_equal "BFGGA0", weapons.display_lump(p),
                 "charge frame shows BFGGA0 while winding up"
  end

  def test_fire_bfg_consumes_40_cells_and_spawns_bfs1_projectile
    weapons = build_weapons
    p = fresh_player
    p.weapons_owned[:bfg] = true
    p.current_weapon = :bfg
    p.ammo[:cell] = 100
    before_projs = @projs.projs.size

    weapons.fire_button = true
    # 20 (charge) + 10 (flash) + 1 (enter S_BFG3) = 31 tics gets us
    # to the actual fire action. Tic a generous 35 to be safe.
    35.times { weapons.update_tic(p) }
    assert_equal 60, p.ammo[:cell], "40 cells consumed"
    assert_equal before_projs + 1, @projs.projs.size,
                 "BFG ball spawned"
    bfg = @projs.projs.last
    assert_equal "BFS1", bfg.thing.sprite_override
    assert_equal :rxplod, bfg.deathsound
  end

  def test_bfg_direct_damage_falls_in_100_to_800
    100.times do
      d = @projs.send(:bfg_direct_damage)
      assert_includes 100..800, d,
                      "MT_BFG damage = (rand%8+1)*100"
    end
  end

  def test_spray_fires_40_tracers_in_a_90_degree_cone_around_ball_angle
    # Inject a Hitscan recorder that captures every angle_override
    # the spray hands it; we don't need the rays to actually hit
    # anything for this assertion — just to verify the geometry.
    recording = RecordingHitscan.new
    @projs.hitscan = recording
    proj = @projs.spawn_bfg_ball(fresh_player.tap { |p| p.angle = 90 })
    # Force-detonate the ball straight into its death sequence.
    proj.state       = :exploding
    proj.frame_index = Rubydoom::Projectiles::BFG_SPRAY_FRAME_INDEX - 1
    proj.frame_timer = 1
    @projs.send(:step, proj, nil)
    # 40 tracers; spread spans 90° centred on 90° → [45°, 135°).
    assert_equal 40, recording.angles.size
    assert_in_delta  45.0, recording.angles.min, 0.01
    assert_in_delta 132.75, recording.angles.max, 0.01
  end

  def test_spray_damages_a_thing_returned_by_hitscan
    # Stub a hitscan that always returns the same shootable thing,
    # plus a combat that records the damage handed to it.
    fake_thing = Struct.new(:x, :y).new(100, 0)
    spy_hitscan = Struct.new(:result) do
      def fire(*, **)
        @i = (@i || -1) + 1
        @i.zero? ? result : nil   # only the first tracer hits
      end
    end.new([:thing, fake_thing, 0, 0])

    recording_combat = Class.new do
      attr_reader :damaged
      def initialize(mobj); @mobj = mobj; @damaged = []; end
      def shootables;      [[Object.new, 16.0, 56.0]]; end
      def mobj_for(_t);    @mobj; end
      def damage(mobj, amt, source: nil); @damaged << [mobj, amt, source]; end
    end.new(:fake_mobj)

    @projs.instance_variable_set(:@hitscan, spy_hitscan)
    @projs.instance_variable_set(:@combat,  recording_combat)

    proj = @projs.spawn_bfg_ball(fresh_player)
    proj.state       = :exploding
    proj.frame_index = Rubydoom::Projectiles::BFG_SPRAY_FRAME_INDEX - 1
    proj.frame_timer = 1
    @projs.send(:step, proj, nil)

    assert_equal 1, recording_combat.damaged.size, "only the one hit landed"
    mobj, amt, _src = recording_combat.damaged.first
    assert_equal :fake_mobj, mobj
    assert_includes 15..120, amt, "damage = 15 * (rand%8+1) = 15..120"
  end

  def test_spray_only_fires_on_bfe1_c_not_on_other_death_frames
    recording = RecordingHitscan.new
    @projs.hitscan = recording
    proj = @projs.spawn_bfg_ball(fresh_player)
    proj.state = :exploding

    # Step through every death frame; spray must fire exactly once,
    # on the transition into frame 2 (BFE1 C).
    proj.frame_index = -1
    Rubydoom::Projectiles::BFG_DEATH_FRAMES.size.times do
      proj.frame_timer = 1
      @projs.send(:step, proj, nil)
    end
    assert_equal 40, recording.angles.size,
                 "one fan of 40 tracers across the whole death sequence"
  end

  def test_non_bfg_projectiles_dont_spray
    recording = RecordingHitscan.new
    @projs.hitscan = recording
    # An imp fireball — no spray flag set, so step_exploding shouldn't
    # call fire_bfg_spray even at frame index 2.
    fake_imp = Struct.new(:thing, :info).new(
      Rubydoom::Map::Thing.new(0, 0, 0, 3001, 0, false, nil, nil, nil, nil),
      Rubydoom::MonsterInfo[3001],
    )
    proj = @projs.spawn_imp_fireball(fake_imp, fresh_player)
    proj.state       = :exploding
    proj.frame_index = 1
    proj.frame_timer = 1
    @projs.send(:step, proj, nil)
    assert_empty recording.angles, "no spray fired from a non-BFG projectile"
  end

  def test_charge_sound_does_not_alert_monsters
    # FIRE_SOUNDS gates emit_noise. :bfg_charge is intentionally
    # absent from FIRE_SOUNDS so vanilla A_BFGsound's "loud but
    # non-alerting" behaviour is preserved.
    refute Rubydoom::Weapons::FIRE_SOUNDS.key?(:bfg_charge),
           "charge action stays out of FIRE_SOUNDS to skip the noise alert"
    # :fire_bfg is in FIRE_SOUNDS (with nil sound) so the noise alert
    # still wakes monsters when the missile leaves.
    assert Rubydoom::Weapons::FIRE_SOUNDS.key?(:fire_bfg),
           "fire action is in FIRE_SOUNDS so monsters wake on launch"
    assert_nil Rubydoom::Weapons::FIRE_SOUNDS[:fire_bfg],
               "fire action plays no sample (dsbfg already played at charge)"
  end

  # Records every angle_override the spray hands to Hitscan#fire, so
  # tests can assert the geometry without needing real ray traces.
  class RecordingHitscan
    attr_reader :angles
    def initialize; @angles = []; end
    def fire(_player, range: nil, spread_deg: 0.0, shootables: nil, angle_override: nil)
      @angles << angle_override
      nil
    end
  end

  private

  def build_weapons
    w = Rubydoom::Weapons.new(hitscan: @hitscan, combat: @combat,
                              sound: nil, rng: Random.new(1))
    w.projectiles = @projs
    w.clipper = @clipper
    w
  end

  def fresh_player
    ps = Struct.new(:x, :y, :angle).new(
      @map.player_start.x, @map.player_start.y, @map.player_start.angle
    )
    Rubydoom::Player.from_thing(ps)
  end
end
