# Optional Ruby music

This is a deliberately small synthesizer for playing the original MUS
scores, not a reproduction of DOOM's FM sound hardware. It uses Ruby and
its standard library throughout. Existing Gosu playback is injected at
the frontend boundary; it is not required by the offline renderer.

## Separation

All implementation lives in `lib/rubydoom/music/`:

* `score.rb`: bounded MUS parser. Produces timestamped events in the
  score's own 140 Hz clock. It has no knowledge of game tics or WADs.
* `synth.rb`: event sequencing, six harmonic wavetable timbres, one-shot
  procedural drums, note envelopes, mixing, and incremental WAV output.
* `cache.rb`: content-addressed WAV files, keyed by score bytes, synth
  version and sample rate. Writes go through a temporary file and atomic
  rename. Truncated files are regenerated.
* `player.rb`: map-track selection and playback lifecycle. Accepts a WAD
  reader, cache and song factory; the default live factory is supplied by
  `App` and constructs `Gosu::Song`.

`App` lazily constructs the player only when `RUBYDOOM_MUSIC=1`, starts
music from `load_map`, and stops it on close. Repeated requests for the
same track do not restart playback. Missing or malformed music and
render/playback failures warn and allow the game to continue.
No changes to `Game`, `HeadlessRunner`, the input format, or sound effects
are needed. Music never uses the simulation RNG: each render has its own
fixed percussion seed.

## Sound and timing

Supported: note on/off, per-channel remembered velocity, instrument
selection, volume, expression, sustain pedal, pitch bends (a two-semitone
range), all-notes/all-sound-off, and controller reset. MUS channel 15
drives generated kick, snare and noise percussion. Other controllers are
parsed but bank, modulation, pan, reverb, chorus and soft pedal are ignored
in this first mono version. `GENMIDI` is not used.

Instrument programs are grouped into keys, bells, organ, guitar, bass,
and winds/strings. Timbres use a few sine harmonics in lookup tables.
Drums self-terminate. Sustained notes have attack, decay, sustain and
release envelopes. Mixing is capped at 64 voices (oldest voice is stolen),
and soft limiting keeps output within signed 16-bit range.

Event timestamps map to absolute integer sample positions to avoid
rounding drift. Output length equals the score duration; a 5ms fade at
each end reduces loop clicks without adding a silent tail. WAV output
uses 22,050 Hz mono PCM and is written in blocks, so a long track does
not require a whole-song sample buffer in memory.

The parser's format reference is
[Chocolate Doom's MUS converter](https://github.com/chocolate-doom/chocolate-doom/blob/master/src/mus2mid.c).
No converter or code from that project is needed at runtime.

## Cache and development

Generated audio is under the already-ignored `tmp/music/` directory.
Increment `Synth::VERSION` whenever changing sound/timing behavior so
existing cached audio is not reused. Deleting this cache is safe; tracks
will render again when needed. Rendering is synchronous on first load;
use `ruby scripts/render_music.rb --all [wad]` before play to avoid that
pause entirely. This script loads neither Gosu nor the game engine.

All 13 shareware tracks were parsed and rendered. E1M1 contains 5,825
events and lasts 96 seconds; the first render took approximately 0.86s
on an Apple M5 running CRuby 4.0.2 with YJIT. The live smoke check verified
that Gosu starts a looping track, stops it on map change, starts the new
track, and stops it on window close. Automated tests cover parser errors,
timing, note pitch, pitch bend, volume, sustain/release, percussion
determinism, caching, track lifecycle and dependency isolation.

For a minimal standalone render:

```ruby
require_relative "../lib/rubydoom/music/synth"

score = Rubydoom::Music::Score.new(mus_bytes)
File.open("track.wav", "wb") do |file|
  Rubydoom::Music::Synth.new.write(score, file)
end
```
