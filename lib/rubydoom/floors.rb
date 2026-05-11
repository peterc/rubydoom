module Rubydoom
  # One-shot floor movement. Mirrors the subset of vanilla's
  # T_MoveFloor needed for E1M1.
  #
  # Currently implements:
  #   * type 36 — W1 Floor Lower (TURBO): drops to the highest
  #     surrounding floor (plus 8 mu of "lip" so the step is visible
  #     if different). 4 mu/tic. Used in E1M1 to drop the demon-trap
  #     floor in front of the secret-area entrance.
  #
  # W1 (walk-once) specials are consumed by the trigger dispatcher in
  # Clipper after this class returns true — we don't clear them here.
  class Floors
    FLOOR_SPEED_TIC = 4    # turboLower speed, mu/tic
    LIP             = 8    # vanilla "see what's behind" offset

    W1_LOWER_FAST = 36

    Mover = Struct.new(:sector, :dest, :speed, :done)

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

    def update_tic
      return if @active.empty?
      @active.each_value do |m|
        m.sector.floor_height -= m.speed
        if m.sector.floor_height <= m.dest
          m.sector.floor_height = m.dest
          m.done = true
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
        @active[s.object_id] = Mover.new(s, dest, FLOOR_SPEED_TIC, false)
      end
    end

    def highest_neighbor_floor(sector)
      build_neighbors_cache unless @neighbors_cache
      list = @neighbors_cache[sector.object_id]
      return sector.floor_height if list.nil? || list.empty?
      list.map(&:floor_height).max
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
