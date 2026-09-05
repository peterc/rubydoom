# Pure-Ruby rendering optimization measurements

Measured on 2026-09-05, Apple M5, macOS arm64. Baseline:
`b32cf4ca5c44537039b42c63c6af9c3df1bd6ac9`.

## Workload and method

The checked-in `scripts/demo.rdm` contains 1,526 simulation/render tics,
starting on E1M1 with seed 67. Each configuration runs in a fresh process,
with one complete unmeasured replay followed by five measured replays.
Every replay constructs a fresh game and renderer. Construction and an
explicit `GC.start` happen outside the timer; simulation, demo reads,
rasterization, and garbage collection during playback are timed.
Configurations run sequentially, without another benchmark or test suite
running alongside them. Results describe this demo on this machine, not
every map or a guarantee of fully warmed JIT performance.

The engine changes use only Ruby. No native extension, FFI, GPU rendering,
or new dependency was added. Gosu remains the existing frontend dependency;
these measurements do not open a window or upload the framebuffer.
The existing StackProf development dependency was used for profiling only,
and was disabled for the timing comparisons.

## Changes

* `Framebuffer#fill_rect` copies cached RGBA strings into the buffer,
  replacing four `setbyte` calls per pixel for solid rectangles. Full-width
  rectangles use one contiguous copy; partial rectangles copy by row.
* Wall and floor/ceiling rasterizers fetch the shaded palette row once
  per column/span, then index it directly in the pixel loop.
* Visplane grouping uses nested tables instead of allocating a composite
  array key for every column span. Span merging updates existing ranges
  in place and avoids `each_with_index`.

The initial CPU profile identified wall/plane rasterization, sky rendering,
solid fills, and GC as substantial costs. An allocation profile attributed
about 73% of sampled allocations to visplane accumulation, including its
iterator and key construction. The changes target those measured costs.

## Measurements

Medians of five measured replays after one warmup:

| Runtime | Before (s) | After (s) | Before (tics/s) | After (tics/s) | Throughput gain |
| --- | ---: | ---: | ---: | ---: | ---: |
| CRuby 4.0.2 + YJIT | 6.8529 | 5.3710 | 222.7 | 284.1 | 27.6% |
| CRuby 4.0.2 interpreter | 20.1516 | 15.1774 | 75.7 | 100.5 | 32.8% |
| TruffleRuby 34.0.1 | 1.9289 | 1.4949 | 791.1 | 1020.8 | 29.0% |

Observed wall-time ranges (minimum–maximum seconds):

| Runtime | Before | After |
| --- | ---: | ---: |
| CRuby + YJIT | 6.7977–6.9361 | 5.3478–5.4156 |
| CRuby interpreter | 20.1260–20.2181 | 15.1088–15.3972 |
| TruffleRuby | 1.8794–2.0204 | 1.4799–1.7358 |

Median CRuby allocations per replay fell from 6,763,695 to 4,202,879:
2,560,816 fewer objects, a 37.9% reduction, in both interpreter and YJIT
runs. TruffleRuby reports zero for the allocation counter used by the
existing runner; that is not evidence of allocation-free execution.

The first implementation copied full-width rectangles one row at a time.
Although that improved CRuby, it regressed TruffleRuby to a median 4.6306s.
Isolating the changes identified rectangle copying as the cause. The final
implementation copies full-width rectangles in a single operation and
improves all three measured configurations, without runtime-specific paths.

The cached shaded rows add 8,192 references per colormap, and the usual
320×84 background cache contains 107,520 RGBA bytes. This trades a modest
amount of retained memory for less repeated work. No simulation behavior
was changed.

## Verification

`bundle exec rake test`: 284 tests, 14,689 assertions, no failures or errors.
New coverage checks clipped/full-width rectangles and visplane grouping,
merging, and preservation of gaps between disjoint spans.

Separate verification passes hash the concatenation of every framebuffer,
so timing results exclude hashing overhead. All timing runs have the same
final-frame SHA-1: `856d8b980f5d1fe4245e5c02a448ecb9d2937769`.

All 1,526 frames match their respective runtime's baseline byte-for-byte:

| Runtime | Before and after frame-stream SHA-256 |
| --- | --- |
| CRuby, interpreter and YJIT | `d24f4b8187990a8793fbbf5de0d94056fa1a737bfebfe6a093695925ed5c1dda` |
| TruffleRuby | `2d4fedd8fba2e7652861f32bb65680eb1aa4d582813b68a9e44c301915b7a4bf` |

The differing CRuby/TruffleRuby stream hashes are present in the original
code too, despite identical final-frame hashes. This is an existing
cross-runtime output discrepancy; its cause was not investigated in this
optimization pass. The changes preserve each runtime's existing output.

Additional 350-frame movement/turning/firing sequences on each of E1M1,
E1M2, and E1M3 produced identical before/after SHA-256 hashes with YJIT:

| Map | Frame-stream SHA-256 |
| --- | --- |
| E1M1 | `4a11e92e0fe68936f314f7a40d5407554acf5d0dbaa4982e398a697327e836cd` |
| E1M2 | `6edfec7145c8f3c8d79cf2c61c84c4b46086fbe5265cd2b48d01cd53b86d0564` |
| E1M3 | `348f24c6d303bbe01462939fd815f7db94007926509843012a2134b9e73c4a30` |

## Reproduce

```sh
# Current code, one warmup and five measured replays; JSON samples + summary.
bundle exec ruby scripts/measure_demo.rb --yjit scripts/demo.rdm
bundle exec ruby scripts/measure_demo.rb scripts/demo.rdm

# Separate output verification; hashing is not part of timing runs.
bundle exec ruby scripts/measure_demo.rb --yjit --verify scripts/demo.rdm

# Extract the original library without changing the working tree.
baseline=$(mktemp -d)
git archive b32cf4ca5c44537039b42c63c6af9c3df1bd6ac9 lib | tar -x -C "$baseline"
bundle exec ruby scripts/measure_demo.rb --yjit --lib "$baseline/lib" scripts/demo.rdm
bundle exec ruby scripts/measure_demo.rb --yjit --verify --lib "$baseline/lib" scripts/demo.rdm
```

`--runs` and `--warmup` control replay counts. `--yjit` explicitly enables
YJIT; omit it for the interpreter or a different implementation, and ensure
your environment does not independently enable another JIT mode.
The summary records Ruby's full description and SHA-256 hashes of both
input files. CRuby allocation counts measure objects, not allocated bytes.
