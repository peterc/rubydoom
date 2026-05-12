require "tempfile"

module Rubydoom
  # Sound effect playback. DOOM stores sounds as DSxxxx lumps in a
  # DMX-specific 8-bit PCM container:
  #
  #   2 bytes  format (always 3)
  #   2 bytes  sample rate (typically 11025)
  #   4 bytes  total sample count, including pad samples
  #  16 bytes  leading pad (zero in shareware; sometimes click-suppression
  #            samples in commercial WADs)
  #   N bytes  unsigned 8-bit PCM, mono
  #  16 bytes  trailing pad
  #
  # We unwrap that container, build a minimal RIFF/WAV file with the
  # real audio, drop it into a tempfile, and feed the path to
  # Gosu::Sample. Lumps are loaded lazily — first time each name is
  # asked for — and the result is cached. Missing lumps yield a no-op
  # play (the shareware doom1.wad lacks several full-game sounds).
  class Sound
    # Distance fade range — vanilla S_CLOSE_DIST = 200 (full volume at
    # or closer), S_CLIPPING_DIST = 1200 (silent at or beyond). Linear
    # falloff in between.
    CLOSE_DIST    = 200.0
    CLIPPING_DIST = 1200.0

    def initialize(wad)
      @wad        = wad
      @samples    = {}   # "PISTOL" -> Gosu::Sample or nil
      @temp_files = []   # keep Tempfiles alive (GC would unlink them)
      # Per-source channel — vanilla DOOM's S_StartSound model. When
      # the same source plays a new sound, the old one is cut off.
      # Without this, the same monster firing twice quickly stacks
      # both pistol samples on top of each other; with this it sounds
      # like the rapid-fire one expects. Keyed by source object_id
      # so value-equality Structs (Sector, Linedef) don't collide.
      @channels = {}.compare_by_identity
    end

    # Play sound `name` at full volume. `name` is the bit after the
    # "DS" prefix — :pistol → "DSPISTOL". Missing lump = silent no-op.
    # `source:` is an optional handle (mobj, sector, …) used for the
    # one-channel-per-source rule.
    def play(name, source: nil)
      sample = sample_for(name)
      return unless sample
      start_on_channel(source, sample, 1.0)
    end

    # Spatial play — distance from `(source_x, source_y)` to `listener`
    # determines volume, and the listener-relative bearing determines
    # pan. Cuts off entirely beyond CLIPPING_DIST. `source:` enforces
    # the per-source channel rule.
    def play_at(name, source_x, source_y, listener, source: nil)
      sample = sample_for(name)
      return unless sample
      dx   = source_x - listener.x
      dy   = source_y - listener.y
      dist = Math.hypot(dx, dy)
      vol  = volume_for(dist)
      return if vol <= 0.0
      pan = pan_for(dx, dy, dist, listener.angle)
      start_on_channel(source, sample, vol, pan)
    end

    private

    # Cut off the previous sample on this source's channel and start
    # a new one. With `source: nil` the channel is bypassed — useful
    # for one-off sounds (pickups, switch clicks) where stacking is
    # fine and the receiver is the player anyway. `pan` is 0 for
    # non-spatial plays.
    def start_on_channel(source, sample, volume, pan = 0.0)
      if source
        prev = @channels[source]
        prev.stop if prev && prev.playing?
        @channels[source] = sample.play_pan(pan, volume)
      else
        sample.play_pan(pan, volume)
      end
    end

    # Project the source-to-listener vector onto the listener's right
    # axis. DOOM angle convention: 0° = +x, ccw. The listener's right
    # axis is `(sin α, -cos α)`, so right = dx·sin α − dy·cos α, and
    # dividing by distance gives a [-1, +1] pan value Gosu's
    # play_pan accepts directly.
    def pan_for(dx, dy, dist, listener_angle_deg)
      return 0.0 if dist < 1.0
      rad = listener_angle_deg * Math::PI / 180.0
      (dx * Math.sin(rad) - dy * Math.cos(rad)) / dist
    end

    def volume_for(dist)
      return 1.0 if dist <= CLOSE_DIST
      return 0.0 if dist >= CLIPPING_DIST
      (CLIPPING_DIST - dist) / (CLIPPING_DIST - CLOSE_DIST)
    end

    def sample_for(name)
      key = name.to_s.upcase
      return @samples[key] if @samples.key?(key)
      @samples[key] = load_sample(key)
    end

    def load_sample(name)
      lump = @wad.lumps.find { |l| l.name == "DS#{name}" }
      return nil unless lump
      bytes = @wad.bytes_for_lump(lump)
      return nil if bytes.bytesize < 24

      fmt, rate, count = bytes.unpack("S<S<L<")
      return nil unless fmt == 3

      audio_offset = 8 + 16            # 8-byte header + 16-byte leading pad
      audio_size   = count - 32        # strip 16 leading + 16 trailing pads
      max_size     = bytes.bytesize - audio_offset
      audio_size   = max_size if audio_size > max_size
      return nil if audio_size <= 0

      pcm = bytes.byteslice(audio_offset, audio_size)
      return nil if pcm.nil? || pcm.bytesize.zero?

      tmp = Tempfile.new(["doom_#{name}_", ".wav"])
      tmp.binmode
      tmp.write(build_wav(pcm, rate))
      tmp.close
      @temp_files << tmp
      Gosu::Sample.new(tmp.path)
    rescue StandardError => e
      warn "[sound] failed to load DS#{name}: #{e.message}"
      nil
    end

    # Wrap 8-bit unsigned mono PCM in a RIFF/WAV container so
    # Gosu::Sample can read it.
    def build_wav(pcm, rate)
      data_size  = pcm.bytesize
      fmt_chunk  = ["fmt ", 16, 1, 1, rate, rate, 1, 8].pack("a4VvvVVvv")
      data_chunk = ["data", data_size].pack("a4V") + pcm
      riff_size  = 4 + fmt_chunk.bytesize + data_chunk.bytesize
      "RIFF" + [riff_size].pack("V") + "WAVE" + fmt_chunk + data_chunk
    end
  end
end
