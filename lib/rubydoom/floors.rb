module Rubydoom
  # One-shot floor movement. Mirrors the subset of vanilla's
  # T_MoveFloor we need.
  #
  # Currently implements:
  #   * type 36 — W1 Floor Lower (TURBO): drops to the highest
  #     surrounding floor (plus 8 mu of "lip" so the step is visible
  #     if different). 4 mu/tic. Used in E1M1 to drop the demon-trap
  #     floor in front of the secret-area entrance.
  #   * type 20 — S1 Floor Raise To Next Higher (Change Tex & Type):
  #     raises the tagged floor to the lowest neighbouring floor
  #     strictly higher than itself. 1 mu/tic (vanilla FLOORSPEED).
  #     Used by switches in E1M3 onward. Vanilla also transfers the
  #     floor flat and sector special from the donor sector; that
  #     cosmetic step is TODO.
  #
  # W1 specials get cleared by the trigger dispatcher in Clipper after
  # this class returns true. S1 specials are cleared by Switches.
  class Floors
    FLOOR_SPEED_FAST   = 4    # turboLower speed, mu/tic
    FLOOR_SPEED_NORMAL = 1    # vanilla FLOORSPEED
    LIP                = 8    # vanilla "see what's behind" offset

    W1_LOWER_FAST       = 36
    S1_RAISE_NEXT_CHGTX = 20

    Mover = Struct.new(:sector, :dest, :speed, :direction, :done)

    def initialize(map)
      @map     = map
      @active  = {}
      @neighbors_cache = nil
    end

    def handle_cross(linedef)
      case linedef.special_type
      when W1_LOWER_FAST
        activate_lower_fast(linedef.sector_tag)
        true
      else
        false
      end
    end

    # Switch dispatcher entry. Returns true iff at least one tagged
    # sector started moving (so Switches can play the click sound and
    # swap the SW1/SW2 texture).
    def handle_use(linedef)
      case linedef.special_type
      when S1_RAISE_NEXT_CHGTX
        activate_raise_to_next(linedef.sector_tag)
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
      @map.sectors.each do |s|
        next unless s.tag == tag
        next if @active[s.object_id]
        dest = highest_neighbor_floor(s)
        dest += LIP if dest != s.floor_height
        next if dest >= s.floor_height
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_FAST, :down, false)
      end
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
