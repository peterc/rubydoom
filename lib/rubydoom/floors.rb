module Rubydoom
  # One-shot floor movement. Mirrors the subset of vanilla's
  # T_MoveFloor we need.
  #
  # Currently implements (all vanilla `EV_DoFloor` actions, all on
  # `Floors.handle_cross` for walk-triggers or `Floors.handle_use` for
  # switches; the dispatcher above us decides whether the linedef's
  # special_type should be cleared based on once-only vs repeatable):
  #
  #   * type 36 / 98 — W1 turboLower. Drops to the highest surrounding
  #     floor plus 8 mu of "lip" so the step is visible. 4 mu/tic.
  #     36 is E1M1's demon-trap drop; 98 appears on E1M5.
  #   * type 70    — SR turboLower. Switch-triggered repeatable
  #     variant of 36/98. Same physics.
  #   * type 5 / 91 — W1 raiseFloor. Rises to (lowest neighbouring
  #     ceiling − 8). Slow. Common "barrier raises" trick.
  #   * type 20 / 22 — S1 / W1 raiseFloorToNearest+ChangeTex. Raises
  #     to the lowest neighbouring floor strictly higher than itself.
  #     1 mu/tic. Vanilla also transfers floor flat + sector special
  #     from the donor sector; cosmetic TODO.
  #   * type 18 / 86 — S1 / WR raiseFloorToNearest. Same destination
  #     as 20/22 but no texture transfer (already a no-op for us).
  #
  # Returns `:w1` / `:wr` from `handle_cross` so the walk-cross
  # dispatcher can decide whether to clear the special; once-only
  # switch dispatch (`handle_use`) just returns a boolean since the
  # Switches class drives clearing through ONCE_ONLY.
  class Floors
    FLOOR_SPEED_FAST   = 4    # turboLower speed, mu/tic
    FLOOR_SPEED_NORMAL = 1    # vanilla FLOORSPEED
    LIP                = 8    # vanilla "see what's behind" offset
    # Vanilla raiseFloor stops 8 mu below the lowest neighbouring
    # ceiling for sky-flat sectors only (so the floor doesn't punch
    # into the sky texture). Non-sky sectors raise all the way up.
    SKY_CEILING_GAP    = 8
    SKY_FLAT_NAME      = "F_SKY1"

    # Walk-trigger linedef specials, grouped by once-only vs repeatable.
    W1_LOWER_FAST            = 36
    W1_LOWER_FAST_NOLIP      = 98   # vanilla also calls turboLower
    W1_RAISE_TO_LOW_CEIL_A   = 5
    W1_RAISE_TO_LOW_CEIL_B   = 91
    W1_RAISE_TO_NEXT_CHGTX   = 22
    WR_RAISE_TO_NEXT         = 86

    # Switch (use) linedef specials.
    S1_RAISE_NEXT_CHGTX      = 20
    S1_RAISE_TO_NEXT         = 18
    S1_LOWER_TO_LOWEST       = 23
    S1_LOWER_TO_HIGHEST      = 102
    SR_LOWER_FAST            = 70
    WR_LOWER_TO_LOWEST       = 82

    Mover = Struct.new(:sector, :dest, :speed, :direction, :done)

    def initialize(map)
      @map     = map
      @active  = {}
      @neighbors_cache = nil
    end

    def handle_cross(linedef)
      case linedef.special_type
      when W1_LOWER_FAST, W1_LOWER_FAST_NOLIP
        activate_lower_fast(linedef.sector_tag)
        :w1
      when W1_RAISE_TO_LOW_CEIL_A, W1_RAISE_TO_LOW_CEIL_B
        activate_raise_to_low_ceiling(linedef.sector_tag)
        :w1
      when W1_RAISE_TO_NEXT_CHGTX
        activate_raise_to_next(linedef.sector_tag)
        :w1
      when WR_RAISE_TO_NEXT
        activate_raise_to_next(linedef.sector_tag)
        :wr
      when WR_LOWER_TO_LOWEST
        activate_lower_to_lowest(linedef.sector_tag)
        :wr
      end
    end

    # Switch dispatcher entry. Returns true iff at least one tagged
    # sector started moving (so Switches can play the click sound and
    # swap the SW1/SW2 texture).
    def handle_use(linedef)
      case linedef.special_type
      when S1_RAISE_NEXT_CHGTX, S1_RAISE_TO_NEXT
        activate_raise_to_next(linedef.sector_tag)
      when S1_LOWER_TO_LOWEST
        activate_lower_to_lowest(linedef.sector_tag)
      when S1_LOWER_TO_HIGHEST
        activate_lower_to_highest(linedef.sector_tag)
      when SR_LOWER_FAST
        activate_lower_fast(linedef.sector_tag)
      else
        false
      end
    end

    def update_tic
      return if @active.empty?
      @active.each_value do |m|
        if m.direction == :up
          m.sector.floor_height += m.speed
          if m.sector.floor_height >= m.dest
            m.sector.floor_height = m.dest
            m.done = true
          end
        else
          m.sector.floor_height -= m.speed
          if m.sector.floor_height <= m.dest
            m.sector.floor_height = m.dest
            m.done = true
          end
        end
      end
      @active.reject! { |_, m| m.done }
    end

    private

    def activate_lower_fast(tag)
      fired = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        next if @active[s.object_id]
        dest = highest_neighbor_floor(s)
        dest += LIP if dest != s.floor_height
        next if dest >= s.floor_height
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_FAST, :down, false)
        fired = true
      end
      fired
    end

    def activate_raise_to_next(tag)
      fired = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        next if @active[s.object_id]
        dest = next_higher_neighbor_floor(s)
        next if dest.nil? || dest <= s.floor_height
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_NORMAL, :up, false)
        fired = true
      end
      fired
    end

    # Vanilla raiseFloor destination: lowest neighbouring CEILING
    # minus 8 mu. The −8 leaves a sliver so the moving sector doesn't
    # spear through the lowest adjacent ceiling. Skips the sector if
    # the destination would be at or below its current floor (the
    # "no movement possible" guard).
    def activate_raise_to_low_ceiling(tag)
      fired = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        next if @active[s.object_id]
        dest = lowest_neighbor_ceiling(s)
        dest = [dest, s.ceiling_height].min   # clamp to our own ceiling
        dest -= SKY_CEILING_GAP if s.floor_texture == SKY_FLAT_NAME
        next if dest <= s.floor_height
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_NORMAL, :up, false)
        fired = true
      end
      fired
    end

    public

    # Vanilla `lowerFloorToLowest`. Drops the tagged sector's floor
    # to the lowest neighbouring floor height — the canonical use is
    # an arena revealing its exit teleporter once the bosses fall.
    # Skips sectors that are already at or below that height. Public
    # because `A_BossDeath` calls it directly (no triggering linedef).
    def activate_lower_to_lowest(tag)
      fired = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        next if @active[s.object_id]
        dest = lowest_neighbor_floor(s)
        next if dest.nil? || dest >= s.floor_height
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_NORMAL, :down, false)
        fired = true
      end
      fired
    end

    def activate_lower_to_highest(tag)
      fired = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        next if @active[s.object_id]
        dest = highest_neighbor_floor(s)
        next if dest >= s.floor_height
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_NORMAL, :down, false)
        fired = true
      end
      fired
    end

    private

    def lowest_neighbor_floor(sector)
      list = neighbors_of(sector)
      return nil if list.nil? || list.empty?
      list.map(&:floor_height).min
    end

    def lowest_neighbor_ceiling(sector)
      list = neighbors_of(sector)
      return sector.ceiling_height if list.nil? || list.empty?
      list.map(&:ceiling_height).min
    end

    def highest_neighbor_floor(sector)
      list = neighbors_of(sector)
      return sector.floor_height if list.nil? || list.empty?
      list.map(&:floor_height).max
    end

    # Lowest neighbour floor whose height is strictly greater than
    # `sector`'s. Returns nil if none — caller treats that as "no
    # movement" (vanilla P_FindNextHighestFloor falls back to the
    # current floor, but we'd rather refuse than re-fire a no-op).
    def next_higher_neighbor_floor(sector)
      list = neighbors_of(sector)
      return nil if list.nil? || list.empty?
      higher = list.map(&:floor_height).select { |h| h > sector.floor_height }
      higher.min
    end

    def neighbors_of(sector)
      build_neighbors_cache unless @neighbors_cache
      @neighbors_cache[sector.object_id]
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
