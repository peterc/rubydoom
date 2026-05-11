module Rubydoom
  # Linedef type 48 — "Scroll Wall Left". Each tic the front sidedef's
  # x_offset is incremented by 1, which the renderer already reads
  # when sampling wall textures. Map state holds the only data we
  # need, so this is essentially a tick-driven UV bump.
  class WallScrollers
    SCROLL_WALL_LEFT = 48

    def initialize(map)
      @sidedefs = map.linedefs.filter_map do |ld|
        next unless ld.special_type == SCROLL_WALL_LEFT
        map.sidedefs[ld.front_sidedef_index]
      end
    end

    def update_tic
      @sidedefs.each { |sd| sd.x_offset += 1 }
    end
  end
end
