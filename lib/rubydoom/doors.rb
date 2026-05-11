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
  #
  # Door specials we recognise (door-by-Use only — walk-triggers and
  # remote-tag doors are still TODO):
  #
  #   DR (repeatable, opens-and-closes):
  #     1  — no key
  #     26 — needs blue key, 27 — yellow, 28 — red
  #   D1 (once, opens-and-stays-open; special cleared after use):
  #     31 — no key
  #     32 — blue, 33 — red, 34 — yellow
  #
  # Doom 1 specials accept either the card or skull of a colour, so
  # we consult `player.has_key?(:colour)` rather than the variant.
  class Doors
    USE_RANGE      = 64.0
    DOOR_SPEED_TIC = 2     # units per tic (DOOM-spec)
    WAIT_TICS      = 150   # ~4.3s at 35 tics/sec (DOOM-spec)
    DOOR_GAP       = 4     # final opening sits this far below the lowest neighbor ceiling

    # special_type → {kind:, key:}.
    #   kind: :dr (repeat, close after delay) or :d1 (once, stay open).
    #   key:  required colour (nil = no key).
    DOOR_SPECIALS = {
      1  => { kind: :dr, key: nil    },
      26 => { kind: :dr, key: :blue  },
      27 => { kind: :dr, key: :yellow },
      28 => { kind: :dr, key: :red   },
      31 => { kind: :d1, key: nil    },
      32 => { kind: :d1, key: :blue  },
      33 => { kind: :d1, key: :red   },
      34 => { kind: :d1, key: :yellow },
    }.freeze

    # `kind` is the door behaviour at the top (:dr closes after WAIT_TICS,
    # :d1 stays open and the entry is dropped from @active once fully open).
    Door = Struct.new(:sector, :top_height, :state, :timer, :kind)

    def initialize(map)
      @map     = map
      @active  = {}
      @neighbors_cache = nil
      @noise_alert = nil
      @clipper     = nil
      @sound       = nil
    end

    # Late-bound so App can construct Doors before the NoiseAlert /
    # Clipper / Sound exist. When set, opening a door propagates a
    # P_NoiseAlert from the player's sector and plays dsdoropn /
    # dsdorcls at the door sector.
    attr_writer :noise_alert, :clipper, :sound

    def try_use(player)
      rad = player.angle * Math::PI / 180.0
      dx = Math.cos(rad); dy = Math.sin(rad)
      hits = ray_hits(player.x, player.y, dx, dy, USE_RANGE)
      hits.each do |_t, ld|
        spec = DOOR_SPECIALS[ld.special_type]
        if spec && ld.two_sided?
          return false unless spec[:key].nil? || player.has_key?(spec[:key])
          activate_door(ld, spec)
          emit_noise(player)
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
            if d.kind == :d1
              d.state = :done   # stays open; will be reaped below
            else
              d.state = :waiting
              d.timer = WAIT_TICS
            end
          end
        when :waiting
          d.timer -= 1
          if d.timer <= 0
            d.state = :closing
            play_door_sound(d.sector, :dorcls)
          end
        when :closing
          d.sector.ceiling_height -= DOOR_SPEED_TIC
          if d.sector.ceiling_height <= d.sector.floor_height
            d.sector.ceiling_height = d.sector.floor_height
          end
        end
      end
      @active.reject! do |_, d|
        d.state == :done ||
          (d.state == :closing && d.sector.ceiling_height <= d.sector.floor_height)
      end
    end

    private

    def emit_noise(player)
      return unless @noise_alert && @clipper
      sec_index = @clipper.sector_index_at(player.x, player.y)
      @noise_alert.alert(player, sec_index)
    end

    def activate_door(ld, spec)
      sector = @map.linedef_back_sector(ld)
      return unless sector
      existing = @active[sector.object_id]
      if existing
        # DR re-press: refresh wait or reverse a close. D1 doors are
        # one-shot (special is cleared on success), so we shouldn't
        # see one here from a Use ray — guard with the kind anyway.
        if existing.kind == :dr
          case existing.state
          when :waiting then existing.timer = WAIT_TICS
          when :closing
            existing.state = :opening
            play_door_sound(sector, :doropn)
          end
        end
        return
      end
      top = lowest_neighbor_ceiling(sector) - DOOR_GAP
      return if top <= sector.floor_height
      @active[sector.object_id] = Door.new(sector, top, :opening, 0, spec[:kind])
      play_door_sound(sector, :doropn)
      # D1 doors are one-time use; vanilla clears the special so a
      # closed-again door can't be reopened (these stay open anyway).
      ld.special_type = 0 if spec[:kind] == :d1
    end

    # Pick a representative point inside the door sector to anchor the
    # sound. Vanilla uses the sector's sound origin (centroid); we
    # approximate with the centroid of the sector's vertexes via the
    # neighbors cache — overkill avoidable by just using any linedef.
    # For our purposes the volume falloff is from the door to the
    # player and we just need a point in the door's footprint.
    def play_door_sound(sector, sound_name)
      return unless @sound
      # Find any linedef touching this sector and pick its midpoint.
      @map.linedefs.each do |ld|
        f = @map.linedef_front_sector(ld)
        b = @map.linedef_back_sector(ld)
        next unless f == sector || b == sector
        v1 = @map.vertexes[ld.start_vertex_index]
        v2 = @map.vertexes[ld.end_vertex_index]
        mx = (v1.x + v2.x) * 0.5
        my = (v1.y + v2.y) * 0.5
        listener = @listener
        if listener
          @sound.play_at(sound_name, mx, my, listener)
        else
          @sound.play(sound_name)
        end
        return
      end
    end

    public

    # Listener for spatial sound. App sets this to the player; falls
    # back to full-volume play if absent.
    attr_writer :listener

    private

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
