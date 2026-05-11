module Rubydoom
  # Moving platforms ("lifts"). A lift sector starts at its high
  # position; on trigger the floor lowers to the lowest neighboring
  # floor, waits ~3s, then rises back to the high. While active the
  # sector's floor_height is the moving y; the player follows
  # automatically because Clipper#floor_at reads from the sector.
  #
  # Currently implements:
  #   * type 88 — WR Lift Lower-Wait-Raise (E1M1's only lift)
  #
  # Re-triggering rules (mirroring vanilla):
  #   * already going down or up — ignored
  #   * waiting at the bottom    — wait timer is reset
  class Plats
    PLAT_SPEED_TIC = 4    # PLATSPEED, mu/tic, vanilla
    PLAT_WAIT_TICS = 105  # 3 seconds at 35 tics/sec

    WR_LIFT = 88

    Plat = Struct.new(:sector, :high, :low, :state, :timer)

    def initialize(map)
      @map     = map
      @active  = {}
      @neighbors_cache = nil
    end

    # Called by the walk-trigger dispatcher when a player crosses
    # a linedef. Returns true if the special was consumed.
    def handle_cross(linedef)
      case linedef.special_type
      when WR_LIFT
        activate_tag(linedef.sector_tag)
        true
      else
        false
      end
    end

    def update_tic
      return if @active.empty?
      @active.each_value do |p|
        case p.state
        when :down
          p.sector.floor_height -= PLAT_SPEED_TIC
          if p.sector.floor_height <= p.low
            p.sector.floor_height = p.low
            p.state = :waiting
            p.timer = PLAT_WAIT_TICS
          end
        when :waiting
          p.timer -= 1
          p.state = :up if p.timer <= 0
        when :up
          p.sector.floor_height += PLAT_SPEED_TIC
          if p.sector.floor_height >= p.high
            p.sector.floor_height = p.high
            p.state = :done
          end
        end
      end
      @active.reject! { |_, p| p.state == :done }
    end

    # Open lift on every sector with this tag. Used by both walk-
    # trigger 88 (WR Lift) and switch 62 (SR Lift) — same plat
    # behaviour, different trigger style. Returns true iff at least
    # one sector was newly affected so the caller (Switches) can
    # detect a real activation versus a no-op tag match.
    def activate_tag(tag)
      fired = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        existing = @active[s.object_id]
        if existing
          if existing.state == :waiting
            existing.timer = PLAT_WAIT_TICS
            fired = true
          end
          next
        end
        low  = lowest_neighbor_floor(s)
        high = s.floor_height
        next if low >= high
        @active[s.object_id] = Plat.new(s, high, low, :down, 0)
        fired = true
      end
      fired
    end

    private

    # Lowest floor among sectors that share a two-sided linedef with this
    # one (excluding the sector itself). Mirrors P_FindLowestFloorSurrounding.
    def lowest_neighbor_floor(sector)
      build_neighbors_cache unless @neighbors_cache
      list = @neighbors_cache[sector.object_id]
      return sector.floor_height if list.nil? || list.empty?
      list.map(&:floor_height).min
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
  end
end
