module Rubydoom
  # DOOM's COLORMAP lump: 34 rows of 256 bytes each. Each row remaps a
  # palette index to a darker palette index. Row 0 is identity (full
  # bright); rows 1..31 progressively darken; row 32 is the
  # invulnerability filter (white/grays); row 33 is unused. We only
  # use rows 0..31.
  #
  # All in-game shading goes through this table — DOOM never multiplies
  # RGB values like a modern engine. The result is the characteristic
  # banded / palette-preserving fade rather than a continuous slide
  # toward black.
  #
  # Lighting selection (per DOOM's R_Init.c::scalelight):
  #   light_idx = (sector.light_level >> 4) + contrast    # 0..15
  #     contrast: +1 for vertical (N-S) walls, -1 for horizontal (E-W)
  #     walls — this is DOOM's "fake contrast" trick
  #   startmap   = (15 - light_idx) * 4                   # 0,4,8,...,60 (over-range OK; final row clamps)
  #   scale_idx  = (FOCAL_LENGTH * 16 / z) clamp 0..47    # bigger = closer = brighter
  #   row        = clamp(startmap - scale_idx/2, 0, 31)
  #
  # The shaded-palette table (precomputed against PLAYPAL) gives a
  # one-shot (row, palette_idx) → [r, g, b] lookup for the per-pixel
  # inner loops.
  class Colormap
    NUM_REGULAR_ROWS = 32
    ROW_SIZE         = 256

    # Ties the SCALE numerator to the renderer's focal length:
    # scale_idx = (FOCAL_LENGTH * 16) / z. With FOCAL_LENGTH=160 this
    # is 2560 / z, matching DOOM's behaviour at the engine's native
    # 320×200 resolution.
    SCALE_NUMERATOR = 2560
    SCALE_MAX_IDX   = 47

    def initialize(bytes, palette)
      @bytes  = bytes
      build_shaded(palette)
    end

    def self.from_wad(wad, palette)
      data = wad.bytes_for("COLORMAP") or raise "WAD has no COLORMAP lump"
      new(data, palette)
    end

    # Returns the [r, g, b] triple for a (row, palette_idx) pair.
    def shaded(row, idx)
      @shaded[(row << 8) | idx]
    end

    # Convenience: pick a colormap row given the sector light, the
    # contrast adjustment for this seg / surface, and the scale derived
    # from view-space depth z.
    def row_for(light_level, contrast, z)
      light_idx = (light_level >> 4) + contrast
      light_idx = 0  if light_idx < 0
      light_idx = 15 if light_idx > 15
      startmap = (15 - light_idx) * 4
      s = z <= 0 ? SCALE_MAX_IDX : (SCALE_NUMERATOR / z).to_i
      s = SCALE_MAX_IDX if s > SCALE_MAX_IDX
      row = startmap - (s >> 1)
      row = 0 if row < 0
      row = NUM_REGULAR_ROWS - 1 if row >= NUM_REGULAR_ROWS
      row
    end

    private

    def build_shaded(palette)
      colors = palette.colors
      @shaded = Array.new(NUM_REGULAR_ROWS * ROW_SIZE)
      NUM_REGULAR_ROWS.times do |row|
        base = row * ROW_SIZE
        ROW_SIZE.times do |idx|
          @shaded[base + idx] = colors[@bytes.getbyte(base + idx)]
        end
      end
    end
  end
end
