module Rubydoom
  # Use-action ray casting + active door animation.
  #
  # A "door" in DOOM is a sector whose ceiling starts at floor height
  # (so the opening is zero) with a door-special on the front linedef.
  # On Use, we ray-cast forward up to USE_RANGE units, find the first
  # linedef hit, and if its special is a door type we start animating
  # the back sector's ceiling: rise to (lowest-neighbor-ceiling − 4),
  # wait ~4.3s, drop back to floor.
  #
  # Re-pressing Use while the door is moving / waiting:
  #   * waiting   → reset the wait timer
  #   * closing   → reverse to opening
  #   * opening   → ignored (mirrors DOOM DR behaviour)
  class Doors
    USE_RANGE      = 64.0
    DOOR_SPEED_TIC = 2     # units per tic (DOOM-spec)
    WAIT_TICS      = 150   # ~4.3s at 35 tics/sec (DOOM-spec)
    DOOR_GAP       = 4     # final opening sits this far below the lowest neighbor ceiling

    DR_DOOR_SPECIAL = 1

    Door = Struct.new(:sector, :top_height, :state, :timer)

    def initialize(map)
      @map     = map
      @active  = {}
      @neighbors_cache = nil
    end

    def try_use(player)
      rad = player.angle * Math::PI / 180.0
      dx = Math.cos(rad); dy = Math.sin(rad)
      hits = ray_hits(player.x, player.y, dx, dy, USE_RANGE)
      hits.each do |_t, ld|
        # First special we run into wins.
        if ld.special_type == DR_DOOR_SPECIAL && ld.two_sided?
          activate_dr_door(ld)
          return true
        end
        # A solid line (one-sided or impassable) stops the ray cold —
        # the use action can't reach anything behind it. Plain
        # passable two-sided lines (doorsteps, sector dividers) we
        # walk straight through.
        return false if !ld.two_sided? || ld.impassable?
      end
      false
    end

    def update_tic
      return if @active.empty?
      @active.each_value do |d|
        case d.state
        when :opening
          d.sector.ceiling_height += DOOR_SPEED_TIC
          if d.sector.ceiling_height >= d.top_height
            d.sector.ceiling_height = d.top_height
            d.state = :waiting
            d.timer = WAIT_TICS
          end
        when :waiting
          d.timer -= 1
          d.state = :closing if d.timer <= 0
        when :closing
          d.sector.ceiling_height -= DOOR_SPEED_TIC
          if d.sector.ceiling_height <= d.sector.floor_height
            d.sector.ceiling_height = d.sector.floor_height
          end
        end
      end
      @active.reject! { |_, d| d.state == :closing && d.sector.ceiling_height <= d.sector.floor_height }
    end

    private

    def activate_dr_door(ld)
      sector = @map.linedef_back_sector(ld)
      return unless sector
      existing = @active[sector.object_id]
      if existing
        case existing.state
        when :waiting then existing.timer = WAIT_TICS
        when :closing then existing.state = :opening
        end
        return
      end
      top = lowest_neighbor_ceiling(sector) - DOOR_GAP
      return if top <= sector.floor_height
      @active[sector.object_id] = Door.new(sector, top, :opening, 0)
    end

    # Lowest ceiling among sectors that share a two-sided linedef with
    # this one. DOOM uses this as the open height for DR doors so the
    # door tucks just below the connecting room's ceiling.
    def lowest_neighbor_ceiling(sector)
      build_neighbors_cache unless @neighbors_cache
      list = @neighbors_cache[sector.object_id]
      return sector.ceiling_height if list.nil? || list.empty?
      list.map(&:ceiling_height).min
    end

    def build_neighbors_cache
      cache = Hash.new { |h, k| h[k] = [] }
      @map.linedefs.each do |ld|
        next unless ld.two_sided?
        f = @map.linedef_front_sector(ld)
        b = @map.linedef_back_sector(ld)
        next if f.nil? || b.nil? || f == b
        cache[f.object_id] << b
        cache[b.object_id] << f
      end
      @neighbors_cache = cache
    end

    # All linedefs the ray (origin (x,y), direction (dx,dy)) intersects
    # within max_t, in distance order. Returns [[t, linedef], ...].
    def ray_hits(x, y, dx, dy, max_t)
      hits = []
      @map.linedefs.each do |ld|
        v1 = @map.vertexes[ld.start_vertex_index]
        v2 = @map.vertexes[ld.end_vertex_index]
        sdx = v2.x - v1.x
        sdy = v2.y - v1.y
        denom = dx * sdy - dy * sdx
        next if denom.abs < 1e-9
        t = ((v1.x - x) * sdy - (v1.y - y) * sdx).fdiv(denom)
        next if t < 0 || t > max_t
        s = ((v1.x - x) * dy - (v1.y - y) * dx).fdiv(denom)
        next if s < 0 || s > 1
        hits << [t, ld]
      end
      hits.sort_by!(&:first)
      hits
    end
  end
end
