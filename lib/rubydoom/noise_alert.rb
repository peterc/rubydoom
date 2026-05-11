module Rubydoom
  # Sound-propagation wake-up for monsters. Ported from
  # linuxdoom-1.10/p_enemy.c's `P_NoiseAlert` / `P_RecursiveSound`.
  #
  # When the player makes noise (firing a weapon, opening a door), the
  # engine floods through the sector graph: each two-sided line whose
  # vertical opening isn't fully closed lets the sound through to the
  # neighbouring sector. Each visited sector is marked with the noise
  # emitter (the player), and `A_Look` reads this on its next tic to
  # acquire the target — no line of sight required.
  #
  # Map designers use the ML_SOUNDBLOCK linedef flag to wall off
  # encounter zones. Vanilla allows sound to pass through one
  # SOUNDBLOCK line at "depth 1" but the second SOUNDBLOCK at depth 1
  # is a hard stop. We mirror that with the `soundblocks` counter.
  #
  # Per-sector state lives in parallel arrays keyed by sector index,
  # not on the Sector struct itself — Sector is a value-equality Struct,
  # and mutating it would shift its hash buckets.
  class NoiseAlert
    FLAG_SOUNDBLOCK = 0x40  # ML_SOUNDBLOCK in linuxdoom-1.10/doomdata.h

    def initialize(map)
      @map = map
      @soundtarget    = Array.new(map.sectors.size, nil)
      @soundtraversed = Array.new(map.sectors.size, 0)
      @visited        = Array.new(map.sectors.size, 0)
      @validcount     = 0
      build_lines_per_sector
    end

    # Emit noise from `emitter` (the player) inside `sector_index`.
    # Floods the sector graph; `target_for(sec)` will then return
    # `emitter` for every reachable sector.
    def alert(emitter, sector_index)
      return if sector_index.nil?
      @validcount += 1
      recurse(sector_index, 0, emitter)
    end

    # The most recent soundtarget recorded for a sector — what A_Look
    # consults to decide whether to wake without a sight check.
    def target_for(sector_index)
      return nil if sector_index.nil?
      @soundtarget[sector_index]
    end

    private

    def recurse(sec_index, soundblocks, emitter)
      # `validcount` keeps a sector from being processed twice for the
      # same alert; `soundtraversed` lets a sector be re-entered with
      # a stronger (lower soundblocks) flood front, which is what
      # happens when two sound paths reach the same room from
      # different sides.
      return if @visited[sec_index] == @validcount &&
                @soundtraversed[sec_index] <= soundblocks + 1
      @visited[sec_index]        = @validcount
      @soundtraversed[sec_index] = soundblocks + 1
      @soundtarget[sec_index]    = emitter

      @lines_per_sector[sec_index].each do |ld|
        next unless ld.two_sided?

        front = @map.linedef_front_sector(ld)
        back  = @map.linedef_back_sector(ld)
        next if front.nil? || back.nil?

        opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
        opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height
        next if opening_top - opening_bot <= 0  # fully closed (door, riser)

        front_sd = @map.sidedefs[ld.front_sidedef_index]
        back_sd  = @map.sidedefs[ld.back_sidedef_index]
        other_index =
          front_sd.sector_index == sec_index ? back_sd.sector_index : front_sd.sector_index

        if (ld.flags & FLAG_SOUNDBLOCK) != 0
          # Pass through the first SOUNDBLOCK only.
          recurse(other_index, 1, emitter) if soundblocks.zero?
        else
          recurse(other_index, soundblocks, emitter)
        end
      end
    end

    # Build the per-sector list of touching linedefs once at init.
    def build_lines_per_sector
      @lines_per_sector = Array.new(@map.sectors.size) { [] }
      @map.linedefs.each do |ld|
        front_sd = @map.sidedefs[ld.front_sidedef_index]
        @lines_per_sector[front_sd.sector_index] << ld if front_sd
        next unless ld.two_sided?
        back_sd = @map.sidedefs[ld.back_sidedef_index]
        @lines_per_sector[back_sd.sector_index] << ld if back_sd
      end
    end
  end
end
