require "test_helper"
require "tmpdir"

# Headless benchmark runner. Validates that
#   * a recorded demo replays end-to-end with no Gosu window,
#   * the report dict has expected keys + sane values,
#   * two consecutive runs of the same demo produce byte-identical
#     framebuffer SHA-1 (the JIT-vs-no-JIT correctness invariant).
class HeadlessRunnerTest < Minitest::Test
  def with_demo(skill: 3, seed: 42, map: "E1M1", tics: 60, &b)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "test.rdm")
      r = Rubydoom::Demo::Recorder.new(path, skill: skill, seed: seed, map_name: map)
      tics.times { r << Rubydoom::Input.new(1, 0, 0, 0, false, []) }
      r.close
      yield path
    end
  end

  def test_run_returns_report_and_advances_sim
    with_demo(tics: 60) do |demo|
      runner = Rubydoom::HeadlessRunner.new(
        wad_path: TestHelper::WAD_PATH, demo_path: demo, quiet: true,
      )
      result = runner.run
      assert_equal 60, result[:tics]
      assert_operator result[:wall],   :>, 0
      assert_operator result[:tps],    :>, 0
      assert_operator result[:ms_tic], :>, 0
      assert_match(/\A[0-9a-f]{40}\z/, result[:sha1])
      assert_equal "E1M1", result[:map]
      assert_equal 42, result[:seed]
    end
  end

  def test_replay_is_byte_deterministic
    with_demo(tics: 80) do |demo|
      a = Rubydoom::HeadlessRunner.new(
        wad_path: TestHelper::WAD_PATH, demo_path: demo, quiet: true,
      ).run
      b = Rubydoom::HeadlessRunner.new(
        wad_path: TestHelper::WAD_PATH, demo_path: demo, quiet: true,
      ).run
      assert_equal a[:sha1], b[:sha1],
                   "same demo + seed should produce byte-identical framebuffer"
    end
  end
end
