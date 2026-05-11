require "digest"

module Rubydoom
  # Pure-Ruby benchmark harness. Skips the Gosu window entirely:
  # constructs Game + Renderer3D directly, replays a recorded demo,
  # and ticks sim + render in a tight loop with no GL context, no
  # vsync, and no GPU upload. The point is to measure exactly the
  # work a Ruby JIT can speed up.
  #
  # Outputs:
  #   * tics, wall time, tps, ms/tic
  #   * GC minor/major/alloc counts + alloc/sec
  #   * SHA-1 of the final-frame framebuffer (reproducibility check —
  #     same JIT or different, same demo + seed should give the same
  #     bytes)
  #
  # Demo header carries the seed/skill/starting map, so a replay is
  # self-describing. Map transitions during the demo (exit switches)
  # hot-swap to the next map and rebuild the renderer; no wipe.
  class HeadlessRunner
    def initialize(wad_path:, demo_path:, quiet: false)
      @wad   = WAD.open(wad_path)
      @demo  = Demo::Player.new(demo_path)
      @quiet = quiet
      hdr    = @demo.header
      @seed  = hdr.seed
      @game  = Game.new(wad: @wad, skill: hdr.skill, rng: Random.new(hdr.seed))
      @game.load_map(hdr.map_name)
      @renderer = build_renderer(hdr.map_name)
      @exit_announced = false
      @map_name       = hdr.map_name
    end

    def run
      tics    = 0
      gc0     = GC.stat
      t0      = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      until @demo.end_of_file?
        input = @demo.next_input
        @game.tick(input)
        @renderer.draw(@game.player, present: false)
        handle_exit
        tics += 1
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      gc1     = GC.stat
      @demo.close
      report(tics, elapsed, gc0, gc1) unless @quiet
      {
        tics:    tics,
        wall:    elapsed,
        tps:     tics / elapsed,
        ms_tic:  (elapsed * 1000.0) / tics,
        gc_minor: gc1[:minor_gc_count] - gc0[:minor_gc_count],
        gc_major: gc1[:major_gc_count] - gc0[:major_gc_count],
        alloc:    gc1[:total_allocated_objects] - gc0[:total_allocated_objects],
        sha1:    Digest::SHA1.hexdigest(@renderer.framebuffer.rgba),
        map:     @map_name,
        seed:    @seed,
      }
    end

    private

    def build_renderer(map_name)
      sky = Sky.for_map(map_name, @game.textures)
      Renderer3D.new(@game.map, @game.bsp,
                     textures: @game.textures, flats: @game.flats,
                     palette: @game.palette, colormap: @game.colormap,
                     sky: sky, sprites: @game.sprites)
    end

    # If the demo crossed an exit switch, hot-swap to the next map and
    # rebuild the renderer. No wipe — that's a frontend decoration the
    # benchmark doesn't care about.
    def handle_exit
      return unless @game.switches.exit_requested
      next_name = Map.next_in_wad(@game.wad, @game.map.name)
      return unless next_name
      @game.load_map(next_name)
      @renderer = build_renderer(next_name)
      @map_name = next_name
    end

    def report(tics, elapsed, gc0, gc1)
      tps   = tics / elapsed
      minor = gc1[:minor_gc_count]          - gc0[:minor_gc_count]
      major = gc1[:major_gc_count]          - gc0[:major_gc_count]
      alloc = gc1[:total_allocated_objects] - gc0[:total_allocated_objects]
      jit   = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "yjit" : "no-jit"
      sha   = Digest::SHA1.hexdigest(@renderer.framebuffer.rgba)
      puts "[benchmark] jit=#{jit} ruby=#{RUBY_VERSION} " \
           "tics=#{tics} wall=#{format("%.3f", elapsed)}s " \
           "tps=#{format("%.1f", tps)} (#{format("%.2f", (elapsed * 1000.0) / tics)} ms/tic)"
      puts "[benchmark] gc minor=#{minor} major=#{major} " \
           "alloc=#{alloc} (#{format("%.0f", alloc / elapsed)}/sec)"
      puts "[benchmark] final_frame_sha1=#{sha} map=#{@map_name} seed=#{@seed}"
    end
  end
end
