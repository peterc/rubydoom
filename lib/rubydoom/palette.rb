module Rubydoom
  # PLAYPAL contains 14 palettes of 256 RGB colors (768 bytes each).
  # Palette 0 is the normal one; the others are used for damage / pickup
  # / radiation suit screen flashes.
  class Palette
    PALETTE_BYTES = 768
    PALETTE_COUNT = 14

    attr_reader :colors

    def self.from_wad(wad, index: 0)
      data = wad.bytes_for("PLAYPAL") or raise "WAD has no PLAYPAL lump"
      raise "palette index #{index} out of range" if index < 0 || index >= PALETTE_COUNT
      raw = data[index * PALETTE_BYTES, PALETTE_BYTES]
      colors = raw.unpack("C*").each_slice(3).map { |r, g, b| [r, g, b].freeze }.freeze
      new(colors)
    end

    def initialize(colors)
      @colors = colors
    end

    def [](index)
      @colors[index]
    end
  end
end
