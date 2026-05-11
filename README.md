# rubydoom

A pure-Ruby DOOM port built on top of [Gosu](https://www.libgosu.org/), reading the shareware `DDOM1.WAD`.

The point of the project is not to be a DOOM implementation to *play*, but to be a **realistic, large workload for benchmarking Ruby implementations and their JIT compilers**. DOOM heavily exercises mixed hot loops (rasterizers, BSP traversal, fixed-point-style math), allocation patterns (visplanes, segs, mobjs), method-call density, and string manipulation.

> [!NOTE]
> DOOM1.WAD is needed but not included in this project. However, [you can get it here.](https://doomwiki.org/wiki/DOOM1.WAD)

## Quick start

You need Ruby (tested on 4.0.2), `bundle`, and a shareware `DOOM1.WAD` (`doom1.wad` is also accepted as a filename) in the project root.

```sh
bundle install
bin/rubydoom                          # play E1M1
bin/rubydoom --map E1M3 doom1.wad     # play a different map / wad
```

Default controls: WASD or arrow keys to move, mouse to look (click in the window to capture the cursor, Esc to release), left-Ctrl or left-mouse to fire, Space to use, 1–7 to switch weapons, Tab toggles the automap, P prints the current world position to stdout for debugging purposes. Arrow keys can be used to rotate left/right, if you want to avoid using the mouse entirely.

## Benchmarking

The whole simulation can be driven deterministically: seed the RNG, record a demo (per-tic player input), then replay it under different Ruby/JIT configurations. Output is byte-identical given the same seed.

```sh
# Record (interactive play, normal 35 Hz)
RUBYDOOM_RECORD=demo.rdm RUBYDOOM_SEED=42 bin/rubydoom

# Benchmark headless (no window, no GL, no vsync)
bundle exec ruby scripts/benchmark_demo.rb demo.rdm

# Compare JIT modes
bundle exec ruby scripts/benchmark_demo.rb demo.rdm
RUBYDOOM_DISABLE_YJIT=1 bundle exec ruby scripts/benchmark_demo.rb demo.rdm
```

Sample output:

```
[benchmark] jit=yjit ruby=4.0.2 tics=200 wall=0.937s tps=213.5 (4.68 ms/tic)
[benchmark] gc minor=16 major=0 alloc=629091 (671470/sec)
[benchmark] final_frame_sha1=5413388c5fe2660e8099c30b3854af64776558fc map=E1M1 seed=42
```

`tps` is simulation-plus-rasterizer throughput in pure Ruby. The `final_frame_sha1` is the regression check — if it changes between runs of the same demo, something nondeterministic crept in; if it changes between JIT modes, the JIT is wrong about something.

## How it works

The code is split into two layers separated by a small input struct:

  * **Simulation** (`lib/rubydoom/` everything not in the Gosu list
    below) — pure Ruby. Parses the WAD, builds the BSP, runs collision,
    AI, projectiles, weapons, sector physics. Takes a `Rubydoom::Input`
    each tic, advances the world, exposes state for the renderer.

  * **Frontend** — `app.rb`, `renderer3d.rb`, `automap.rb`,
    `framebuffer.rb`, `gosu_image_cache.rb`, `hud.rb`, `sound.rb`,
    `wipe.rb`. Owns the Gosu window, samples input, draws.

`Renderer3D` writes RGBA bytes into a persistent `Framebuffer` (a
plain String) via a column-major rasterizer for walls and a row-major
rasterizer for visplanes, with COLORMAP shading by row. The last step
uploads that buffer to a Gosu image — and that's the only line that
needs a GL context. Pass `present: false` to skip it.

For benchmarking, `Rubydoom::HeadlessRunner` constructs `Game` +
`Renderer3D` directly, replays a demo, calls `draw(present: false)`
each tic, and reports throughput. No `App`, no `Gosu::Window`, no
display required.

The simulation tic rate is DOOM's native 35 Hz. Every speed, timer,
and animation duration in the codebase is expressed in tics.

## CLI

`bin/rubydoom [options] [wad_path]`

| Flag | Default | Description |
| --- | --- | --- |
| `-m MAP` / `--map MAP` | `E1M1` | Map to load (e.g. `E1M2`, `E1M5`). |
| `-h` / `--help` | — | Show usage and exit. |
| `wad_path` (positional) | `./doom1.wad` | Path to a DOOM WAD. |

## Environment variables

### Selection and difficulty

| Variable | Description |
| --- | --- |
| `RUBYDOOM_SKILL` | Skill level 0–4 (0 = ITYTD, 2 = HMP, 4 = Nightmare). Default: 2. Ignored during demo playback (skill comes from the demo header). |
| `RUBYDOOM_X`, `RUBYDOOM_Y`, `RUBYDOOM_ANGLE` | Debug spawn position. Overrides the map's `player_start` for the initial map only. |

### Demos, determinism, and benchmarking

| Variable | Description |
| --- | --- |
| `RUBYDOOM_SEED` | Seed the master RNG. Without it, every run picks a fresh seed. Threaded through every sim subsystem (combat pain rolls, monster AI, weapon spread, hitscan jitter, sector light flashes, HUD face wandering). |
| `RUBYDOOM_RECORD` | Path to write a demo file. Captures per-tic `Input` to disk while you play. Header includes the resolved seed, skill, and map so the demo is self-describing. |
| `RUBYDOOM_PLAY` | Path to a demo to replay. Skill / seed / starting map come from the file header; passing other selection env vars or `--map` is ignored. Sound is muted during playback. |
| `RUBYDOOM_BENCHMARK` | Dispatch to the headless runner instead of opening a window. Requires `RUBYDOOM_PLAY`. Prints `tics`, `wall`, `tps`, `ms/tic`, GC stats, and final-frame SHA-1. |
| `RUBYDOOM_DISABLE_YJIT` | When set, the `scripts/benchmark_demo.rb` wrapper does *not* call `RubyVM::YJIT.enable`. Useful for A/B comparisons. |

### Visual checkpoints (offscreen rendering)

| Variable | Description |
| --- | --- |
| `RUBYDOOM_DUMP_FRAME` | Path. Renders one frame to PNG and exits. Used by tests / visual diff workflows. |
| `RUBYDOOM_DUMP_TITLE` | Force the dump path to render `TITLEPIC` instead of the playfield. |
| `RUBYDOOM_WIPE_TICS` | Render the playfield with the title screen mid-melt at tic `N`. Verifies the column-melt wipe composites correctly. |
| `RUBYDOOM_AUTOMAP` | Set to `1` to start with the automap visible (Tab toggles in normal play). |
| `RUBYDOOM_AUTOMAP_MODE` | `lines` (default) or `bsp` — switches between vanilla-style line colours and a BSP-traversal visualisation. |

### Profiling

| Variable | Description |
| --- | --- |
| `RUBYDOOM_PROFILE_SECONDS` | Used by `scripts/profile_game.rb` — how long to run under stackprof before auto-closing. Default 8. |

## Scripts

  * `scripts/benchmark_demo.rb path/to/demo.rdm [wad]` — headless
    benchmark. Enables YJIT (unless `RUBYDOOM_DISABLE_YJIT` is set)
    and runs the demo through `Rubydoom::HeadlessRunner`.

  * `scripts/profile_game.rb [seconds]` — wraps `bin/rubydoom` in
    `StackProf.run` for the given duration, then exits. Output goes
    to `tmp/rubydoom-stackprof.dump`. Inspect with:

    ```sh
    bundle exec stackprof tmp/rubydoom-stackprof.dump --text --limit 40
    ```

  * `rake test` — full test suite (175 tests, no Gosu window
    required).

  * `rake profile:game` — alternate stackprof harness invoked via
    Rake. Honours `MAP`, `WAD`, `OUT`, `INTERVAL` env vars.

## Demo file format

Documented at the top of `lib/rubydoom/demo.rb`. Compact binary:

  * 4-byte magic `"RDM1"`
  * `u8` version, `u8` skill, `u64` seed (big-endian)
  * `u8` map-name length, ASCII map name
  * Per-tic record: walk / strafe / turn (`s8` each), fire (`u8`),
    look_dx (`s16`), edge count + edge codes (`u8`)

Edge codes form a stable, append-only table (`use`, `respawn`,
`toggle_god`, `weapon_1..7`, `debug_*`) — older demos keep replaying
as new edges are added.

## License

This project's source is GPL v2 (see `LICENSE.TXT`), matching the
original DOOM source release. It does not include any id Software
content. The shareware `doom1.wad` is distributed by id Software
under its own terms.
