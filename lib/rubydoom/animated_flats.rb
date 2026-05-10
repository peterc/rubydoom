module Rubydoom
  # Wraps a Flats lookup to implement DOOM's animated-flat behavior:
  # at runtime the engine reassigns each animated name to the next
  # lump in its run every ~8 tics, so a sector that nominally uses
  # NUKAGE1 actually shows NUKAGE1 → NUKAGE2 → NUKAGE3 → NUKAGE1 …
  #
  # Each name keeps its own starting offset within the cycle, so two
  # adjacent sectors using NUKAGE1 and NUKAGE2 stay phase-shifted —
  # matching vanilla, which advances each entry in the run together.
  class AnimatedFlats
    # Hardcoded animation runs from p_spec.c P_InitPicAnims (start
    # name → end name, every lump in between cycles together). I've
    # included the DOOM 1 entries; we filter at construct-time so
    # missing flats in the shareware WAD don't error out.
    RUNS = [
      %w[NUKAGE1 NUKAGE2 NUKAGE3],
      %w[FWATER1 FWATER2 FWATER3 FWATER4],
      %w[SWATER1 SWATER2 SWATER3 SWATER4],
      %w[LAVA1 LAVA2 LAVA3 LAVA4],
      %w[BLOOD1 BLOOD2 BLOOD3],
      %w[RROCK05 RROCK06 RROCK07 RROCK08],
      %w[SLIME01 SLIME02 SLIME03 SLIME04],
      %w[SLIME05 SLIME06 SLIME07 SLIME08],
      %w[SLIME09 SLIME10 SLIME11 SLIME12],
    ].freeze

    FRAME_TICS = 8

    def initialize(flats)
      @flats = flats
      @tic   = 0
      @anims = {}
      RUNS.each do |frames|
        next unless frames.all? { |n| @flats[n] }
        frames.each_with_index { |n, i| @anims[n] = [frames, i] }
      end
    end

    def update_tic
      @tic += 1
    end

    def [](name)
      key = name.to_s.upcase
      entry = @anims[key]
      return @flats[key] unless entry
      frames, base_idx = entry
      idx = (base_idx + @tic / FRAME_TICS) % frames.size
      @flats[frames[idx]]
    end

    def names
      @flats.names
    end
  end
end
