require "minitest/autorun"
require "stringio"
require "tmpdir"
require "open3"
require_relative "../lib/rubydoom/music/player"
require_relative "../lib/rubydoom/wad"

class MusicTest < Minitest::Test
  Music = Rubydoom::Music

  def mus(events)
    "MUS\x1a".b + [events.length, 16, 1, 0, 0, 0].pack("v6") + events.pack("C*")
  end

  def note_score(channel: 0, note: 69)
    # A4 for one second, then 0.1s of release, then end.
    mus([0x90 | channel, 128 | note, 100, 0x81, 0x0c,
         0x80 | channel, note, 14, 0x60])
  end

  def render(bytes)
    io = StringIO.new("".b)
    Music::Synth.new.write(Music::Score.new(bytes), io)
    io.string
  end

  def test_mus_timing_channels_and_inherited_velocity
    score = Music::Score.new(mus([0x10, 188, 90, 0x9f, 164, 100, 0x81, 0x0c,
                                  0x90, 64, 14, 0x60]))
    assert_equal 154, score.ticks
    assert_equal [[0, :on, 0, 60, 90], [0, :on, 15, 36, 100],
                  [140, :on, 0, 64, 90]], score.events.map(&:to_a)
  end

  def test_controllers_pitch_bend_and_system_events
    score = Music::Score.new(mus([0x42, 0, 30, 0x42, 3, 200, 0x22, 192, 0x32, 14, 0x60]))
    assert_equal [[0, :control, 2, 0, 30], [0, :control, 2, 3, 127],
                  [0, :bend, 2, 192, nil], [0, :control, 2, 14, 0]], score.events.map(&:to_a)
  end

  def test_rejects_truncated_or_invalid_scores
    ["", "not mus", note_score.byteslice(0, 20), mus([0x10]),
     mus([0x50]), mus([0x40, 12, 0]), mus([0x30, 9]),
     mus([0x90, 60, 128, 128, 128, 128, 128])].each do |bytes|
      assert_raises(ArgumentError) { Music::Score.new(bytes) }
    end
  end

  def test_wav_has_expected_duration_pitch_and_release
    wav = render(note_score)
    assert_equal "RIFF", wav.byteslice(0, 4)
    assert_equal "WAVEfmt ", wav.byteslice(8, 8)
    assert_equal [1, 1, 22050, 44100, 2, 16], wav.byteslice(20, 16).unpack("vvVVvv")
    assert_equal 44 + 24255 * 2, wav.bytesize
    assert_equal wav.bytesize - 44, wav.byteslice(40, 4).unpack1("V")
    samples = wav.byteslice(44..).unpack("s<*")
    assert_equal 0, samples.first
    assert samples.last(220).all?(&:zero?), "released note should become silent"
    middle = samples[2205, 11025]
    crossings = middle.each_cons(2).count { |a, b| a <= 0 && b > 0 }
    assert_in_delta 220, crossings, 1, "A4 should have 220 cycles in half a second"
    assert_operator samples.map(&:abs).max, :>, 1000
    assert_operator samples.map(&:abs).max, :<, 32767
  end

  def test_sustain_holds_note_until_pedal_release
    held = render(mus([0x40, 8, 127, 0x90, 197, 100, 14,
                       0x80, 69, 126, 0xc0, 8, 0, 28, 0x60]))
    samples = held.byteslice(44..).unpack("s<*")
    assert samples[11025, 1000].any? { |s| s.abs > 100 }, "pedal must hold released key"
    assert samples.last(1000).all?(&:zero?)
  end

  def test_pitch_bend_and_volume_affect_sounding_notes
    wav = render(mus([0x90, 197, 100, 70, 0xa0, 192, 70,
                      0xc0, 3, 0, 70, 0x60]))
    samples = wav.byteslice(44..).unpack("s<*")
    before = samples[2205, 6615].each_cons(2).count { |a, b| a <= 0 && b > 0 }
    after = samples[13230, 6615].each_cons(2).count { |a, b| a <= 0 && b > 0 }
    assert_in_delta 2.0**(1.0 / 12), after.to_f / before, 0.015
    assert samples.last(1000).all?(&:zero?), "channel volume zero must mute active voices"
  end

  def test_percussion_is_deterministic_and_self_terminating
    a = render(note_score(channel: 15, note: 38))
    assert_equal a, render(note_score(channel: 15, note: 38))
    samples = a.byteslice(44..).unpack("s<*")
    assert samples.first(2000).any? { |s| s.abs > 100 }
    assert samples.last(11025).all?(&:zero?)
  end

  def test_cache_reuses_complete_files_and_repairs_partial_files
    Dir.mktmpdir do |dir|
      cache = Music::Cache.new(directory: dir)
      path = cache.fetch(note_score)
      stamp = File.mtime(path)
      assert_equal path, cache.fetch(note_score) { flunk "cache hit should not render" }
      assert_equal stamp, File.mtime(path)
      refute_equal path, cache.fetch(note_score(note: 70))
      File.binwrite(path, "RIFF")
      repaired = false
      cache.fetch(note_score) { repaired = true }
      assert repaired
      assert_operator File.size(path), :>, 44
      assert_equal 2, Dir.children(dir).size, "temporary files should be cleaned up"
    end
  end

  class FakeSong
    attr_accessor :volume
    attr_reader :looping, :stopped
    def play(looping) = @looping = looping
    def stop = @stopped = true
  end

  def test_playback_switches_tracks_and_missing_music_stops_the_old_track
    wad = Object.new
    def wad.bytes_for(name) = name == "D_MISSING" ? nil : name
    cache = Object.new
    def cache.fetch(bytes) = bytes
    songs = []
    player = Music::Player.new(wad: wad, cache: cache, log: StringIO.new,
      song_factory: ->(_path) { songs << FakeSong.new; songs.last })
    player.play_map("E1M1")
    player.play_map("E1M1")
    assert_equal 1, songs.size
    assert songs.first.looping
    assert_equal 0.4, songs.first.volume
    player.play_map("E1M2")
    assert songs.first.stopped
    assert_equal 2, songs.size
    player.play_map("MISSING")
    assert songs.last.stopped
  end

  def test_music_loads_without_gosu_or_the_game
    output, status = Open3.capture2(RbConfig.ruby, "-e",
      'require_relative "lib/rubydoom/music/player"; puts [defined?(Gosu), defined?(Rubydoom::Game)].inspect',
      chdir: File.expand_path("..", __dir__))
    assert status.success?
    assert_equal "[nil, nil]\n", output
  end

  def test_headless_load_does_not_load_music_even_when_enabled
    output, status = Open3.capture2({"RUBYDOOM_MUSIC" => "1"}, RbConfig.ruby, "-e",
      'require_relative "lib/rubydoom"; puts defined?(Rubydoom::Music).inspect',
      chdir: File.expand_path("..", __dir__))
    assert status.success?
    assert_equal "nil\n", output
  end

  def test_all_shareware_music_parses
    wad = Rubydoom::WAD.open(File.expand_path("../wads/doom1.wad", __dir__))
    tracks = wad.lumps.select { |l| l.name.start_with?("D_") }
    assert_equal 13, tracks.length
    tracks.each do |track|
      score = Music::Score.new(wad.bytes_for_lump(track))
      assert_operator score.ticks, :>, 0, track.name
      assert score.events.any? { |e| e.type == :on }, track.name
    end
  end
end
