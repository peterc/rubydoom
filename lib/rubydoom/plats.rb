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
      @sound    = nil
      @listener = nil
    end

    # Late-bound from Game#load_map. dspstart plays when the lift starts moving;
    # dspstop plays when it reaches the lowered position and again
    # when it returns to the raised position.
    attr_writer :sound, :listener

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
            play_sector_sound(p.sector, :pstop)
          end
        when :waiting
          p.timer -= 1
          if p.timer <= 0
            p.state = :up
            play_sector_sound(p.sector, :pstart)
          end
        when :up
          p.sector.floor_height += PLAT_SPEED_TIC
          if p.sector.floor_height >= p.high
            p.sector.floor_height = p.high
            p.state = :done
            play_sector_sound(p.sector, :pstop)
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
        play_sector_sound(s, :pstart)
        fired = true
      end
      fired
    end

    private

    # Play `sound_name` at the centroid of a touching linedef on this
    # sector. Vanilla anchors the sound to the sector's "sound origin"
    # which is its centroid; a touching-line midpoint is close enough
    # for our distance falloff to feel right.
    def play_sector_sound(sector, sound_name)
      return unless @sound
      @map.linedefs.each do |ld|
        f = @map.linedef_front_sector(ld)
        b = @map.linedef_back_sector(ld)
        next unless f == sector || b == sector
        v1 = @map.vertexes[ld.start_vertex_index]
        v2 = @map.vertexes[ld.end_vertex_index]
        mx = (v1.x + v2.x) * 0.5
        my = (v1.y + v2.y) * 0.5
        if @listener
          @sound.play_at(sound_name, mx, my, @listener, source: sector)
        else
          @sound.play(sound_name, source: sector)
        end
        return
      end
    end

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
