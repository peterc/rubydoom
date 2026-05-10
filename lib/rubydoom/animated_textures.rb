module Rubydoom
  # Same scheme as AnimatedFlats but for wall textures. Vanilla DOOM
  # rebinds each animated texture name to the next lump in its run
  # every 8 tics, so a wall using FIREBLU1 actually shows
  # FIREBLU1 → FIREBLU2 → FIREBLU1 …  Each name keeps its own offset
  # so adjacent walls using different members of a run stay phase-
  # shifted, just like vanilla.
  #
  # Runs from p_spec.c animdefs (istexture == true entries). I've
  # included the DOOM 1 + DOOM 2 wall animations; missing ones are
  # filtered out at construct time so we don't error on shareware.
  class AnimatedTextures
    RUNS = [
      %w[BLODGR1 BLODGR2 BLODGR3 BLODGR4],
      %w[SLADRIP1 SLADRIP2 SLADRIP3],
      %w[BLODRIP1 BLODRIP2 BLODRIP3 BLODRIP4],
      %w[FIREWALA FIREWALB FIREWALL],
      %w[GSTFONT1 GSTFONT2 GSTFONT3],
      %w[FIRELAV3 FIRELAVA],
      %w[FIREMAG1 FIREMAG2 FIREMAG3],
      %w[FIREBLU1 FIREBLU2],
      %w[ROCKRED1 ROCKRED2 ROCKRED3],
      %w[BFALL1 BFALL2 BFALL3 BFALL4],
      %w[SFALL1 SFALL2 SFALL3 SFALL4],
      %w[WFALL1 WFALL2 WFALL3 WFALL4],
      %w[DBRAIN1 DBRAIN2 DBRAIN3 DBRAIN4],
    ].freeze

    FRAME_TICS = 8

    def initialize(textures)
      @textures = textures
      @tic      = 0
      @anims    = {}
      RUNS.each do |frames|
        next unless frames.all? { |n| @textures[n] }
        frames.each_with_index { |n, i| @anims[n] = [frames, i] }
      end
    end

    def update_tic
      @tic += 1
    end

    def [](name)
      key = name.to_s.upcase
      entry = @anims[key]
      return @textures[key] unless entry
      frames, base_idx = entry
      idx = (base_idx + @tic / FRAME_TICS) % frames.size
      @textures[frames[idx]]
    end

    def names
      @textures.names
    end
  end
end
