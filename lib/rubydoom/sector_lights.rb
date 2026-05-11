module Rubydoom
  # Light-effect sector specials. Each tic we mutate the affected
  # sector's `light_level` directly, so the renderer needs no change —
  # it already reads the live field when shading walls and flats.
  #
  # Currently implements:
  #   * type 1  — random light flash. Toggles between the sector's
  #               original light_level (max) and the minimum of its
  #               neighbors' light_level (min), at random intervals.
  #   * type 8  — glow. Light_level oscillates smoothly between
  #               max and min at GLOW_SPEED per tic, reversing at
  #               each extreme.
  #   * type 12 — synchronized slow strobe. Bright/dark pulse with
  #               vanilla STROBEBRIGHT / SLOWDARK times. All type-12
  #               sectors start with the same phase, so they pulse
  #               in lock-step (matters once a map has more than one).
  #
  # Original `sector.light_level` is captured at construction as
  # "max"; we lose it if SectorLights is rebuilt mid-level (it isn't
  # in our flow — a fresh SectorLights only appears on map load).
  class SectorLights
    FLASH        = 1
    GLOW         = 8
    STROBE_SYNC  = 12

    STROBE_BRIGHT_TICS = 5
    STROBE_SLOW_DARK   = 35
    GLOW_SPEED         = 8
    FLASH_BRIGHT_MASK  = 64   # bright dwell = (rand & 64) + 1, i.e. 1..65 tics
    FLASH_DARK_MASK    = 7    # dark dwell   = (rand & 7)  + 1, i.e. 1..8 tics

    # Per-sector light-state record. `kind` picks the tic transition.
    Light = Struct.new(:sector, :kind, :max, :min, :state, :count)

    def initialize(map)
      @map     = map
      @lights  = []
      @rng     = Random.new
      @neighbors_cache = nil
      collect_lights
    end

    def update_tic
      @lights.each { |l| step(l) }
    end

    private

    def collect_lights
      @map.sectors.each do |s|
        case s.special_type
        when FLASH
          mn = min_neighbor_light(s)
          @lights << Light.new(s, :flash, s.light_level, mn, :bright,
                               (@rng.rand(256) & FLASH_BRIGHT_MASK) + 1)
        when GLOW
          mn = min_neighbor_light(s)
          @lights << Light.new(s, :glow, s.light_level, mn, :down, 0)
        when STROBE_SYNC
          mn = min_neighbor_light(s)
          mn = 0 if mn == s.light_level  # mirrors vanilla "if equal, force 0"
          @lights << Light.new(s, :strobe, s.light_level, mn, :bright, 1)
        end
      end
    end

    def step(l)
      case l.kind
      when :flash  then step_flash(l)
      when :glow   then step_glow(l)
      when :strobe then step_strobe(l)
      end
    end

    def step_flash(l)
      l.count -= 1
      return if l.count > 0
      if l.state == :bright
        l.sector.light_level = l.min
        l.state = :dark
        l.count = (@rng.rand(256) & FLASH_DARK_MASK) + 1
      else
        l.sector.light_level = l.max
        l.state = :bright
        l.count = (@rng.rand(256) & FLASH_BRIGHT_MASK) + 1
      end
    end

    def step_glow(l)
      if l.state == :down
        l.sector.light_level -= GLOW_SPEED
        if l.sector.light_level <= l.min
          l.sector.light_level = l.min
          l.state = :up
        end
      else
        l.sector.light_level += GLOW_SPEED
        if l.sector.light_level >= l.max
          l.sector.light_level = l.max
          l.state = :down
        end
      end
    end

    def step_strobe(l)
      l.count -= 1
      return if l.count > 0
      if l.state == :bright
        l.sector.light_level = l.min
        l.state = :dark
        l.count = STROBE_SLOW_DARK
      else
        l.sector.light_level = l.max
        l.state = :bright
        l.count = STROBE_BRIGHT_TICS
      end
    end

    def min_neighbor_light(sector)
      build_neighbors_cache unless @neighbors_cache
      list = @neighbors_cache[sector.object_id]
      return sector.light_level if list.nil? || list.empty?
      m = sector.light_level
      list.each { |n| m = n.light_level if n.light_level < m }
      m
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
