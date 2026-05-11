require "test_helper"
require "tmpdir"

# Demo recorder / playback round-trip. The benchmark contract is "record
# a session, replay it, get the same simulation" — so we verify both
# byte-faithful Input round-tripping AND end-to-end determinism through
# Game#tick under a fixed seed.
class DemoTest < Minitest::Test
  def with_tmpdemo
    Dir.mktmpdir do |dir|
      yield File.join(dir, "test.rdm")
    end
  end

  def test_recorder_writes_header_and_records_roundtrip
    with_tmpdemo do |path|
      r = Rubydoom::Demo::Recorder.new(path, skill: 3, seed: 42, map_name: "E1M1")
      inputs = [
        Rubydoom::Input.new(1, 0, 0, 0, false, []),
        Rubydoom::Input.new(0, -1, 1, 25, true, [:use]),
        Rubydoom::Input.new(-1, 0, 0, -300, false, [:weapon_2, :debug_hurt]),
        Rubydoom::Input.new(0, 0, -1, 32767, true, [:respawn, :toggle_god]),
      ]
      inputs.each { |i| r << i }
      r.close

      p = Rubydoom::Demo::Player.new(path)
      assert_equal 1,    p.header.version
      assert_equal 3,    p.header.skill
      assert_equal 42,   p.header.seed
      assert_equal "E1M1", p.header.map_name

      played = []
      until p.end_of_file?
        i = p.next_input
        # Player reuses the struct — snapshot the values.
        played << [i.walk_axis, i.strafe_axis, i.turn_axis,
                   i.look_dx, i.fire, i.edges.dup]
      end
      p.close

      expected = inputs.map { |i| [i.walk_axis, i.strafe_axis, i.turn_axis,
                                   i.look_dx, i.fire, i.edges] }
      assert_equal expected, played
    end
  end

  def test_axis_clamping_and_unknown_edges_dropped
    with_tmpdemo do |path|
      r = Rubydoom::Demo::Recorder.new(path, skill: 0, seed: 1, map_name: "E1M1")
      # Out-of-range axis values get clamped; unknown edge symbols are
      # silently dropped so an older replayer doesn't crash on new edges.
      r << Rubydoom::Input.new(99, -99, 0, 0, false, [:use, :no_such_edge])
      r.close

      p = Rubydoom::Demo::Player.new(path)
      i = p.next_input
      assert_equal  1, i.walk_axis
      assert_equal(-1, i.strafe_axis)
      assert_equal [:use], i.edges
      p.close
    end
  end

  def test_demo_drives_game_deterministically_under_seed
    with_tmpdemo do |path|
      # Record a 50-tic walk-forward session. The actual simulation isn't
      # important — we just need a non-trivial input stream to drive the
      # tick loop.
      wad  = TestHelper.wad
      r    = Rubydoom::Demo::Recorder.new(path, skill: 3, seed: 1234, map_name: "E1M1")
      50.times do |t|
        edges = (t == 10 ? [:use] : [])
        r << Rubydoom::Input.new(1, 0, 0, 0, false, edges)
      end
      r.close

      replay_once = lambda do
        game = Rubydoom::Game.new(wad: wad, skill: 3, rng: Random.new(1234))
        game.load_map("E1M1")
        player = Rubydoom::Demo::Player.new(path)
        game.tick(player.next_input) until player.end_of_file?
        player.close
        [game.player.x, game.player.y, game.player.angle,
         game.combat.monsters.map { |m| [m.thing.x, m.thing.y, m.health] }]
      end

      a = replay_once.call
      b = replay_once.call
      assert_equal a, b, "replay must be deterministic under fixed seed"
    end
  end
end
