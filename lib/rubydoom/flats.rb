module Rubydoom
  # A flat is a 64×64 raw palette-indexed image used for floors and
  # ceilings. No transparency, no posts — just 4096 bytes of palette
  # indices in row-major order (v * 64 + u). Stored as a binary string
  # for fast getbyte sampling.
  class Flat
    SIZE     = 64
    BYTES    = SIZE * SIZE
    SKY_NAME = "F_SKY1"

    attr_reader :name, :pixels

    def initialize(name, pixels)
      @name   = name
      @pixels = pixels
    end

    def sky?
      @name == SKY_NAME
    end
  end

  # Loads flats from F_START/F_END markers (and the F1_/F2_/F3_ subgroup
  # markers used by IWADs). Anything in between of size 4096 is treated
  # as a flat lump; markers and zero-size separator lumps are ignored.
  class Flats
    START_MARKERS = %w[F_START FF_START F1_START F2_START F3_START].freeze
    END_MARKERS   = %w[F_END   FF_END   F1_END   F2_END   F3_END].freeze

    def initialize(wad)
      @by_name = {}
      load(wad)
    end

    def [](name)
      key = name.to_s.upcase
      return nil if key.empty? || key == "-"
      @by_name[key]
    end

    def names
      @by_name.keys
    end

    private

    def load(wad)
      depth = 0
      wad.lumps.each do |lump|
        if START_MARKERS.include?(lump.name)
          depth += 1
        elsif END_MARKERS.include?(lump.name)
          depth -= 1
        elsif depth > 0 && lump.size == Flat::BYTES
          bytes = wad.bytes_for_lump(lump)
          @by_name[lump.name] = Flat.new(lump.name, bytes)
        end
      end
    end
  end
end
