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
  #   * types 2 / 13 — fast strobe (STROBEBRIGHT=5, FASTDARK=15).
  #               Type 2 starts with a random per-sector phase
  #               (P_Random & 7 + 1); type 13 starts in lockstep so
  #               all type-13 sectors pulse together.
  #   * types 3 / 12 — slow strobe (STROBEBRIGHT=5, SLOWDARK=35).
  #               Same sync/non-sync split as fast.
  #   * type 17 — fire flicker. Every 4 tics light_level becomes
  #               max − (rand & 3)*16, clamped at min. Captures min
  #               at min_neighbor + 16, vanilla quirk.
  #
  # Original `sector.light_level` is captured at construction as
  # "max"; we lose it if SectorLights is rebuilt mid-level (it isn't
  # in our flow — a fresh SectorLights only appears on map load).
  class SectorLights
    FLASH            = 1
    STROBE_FAST      = 2     # FASTDARK, non-sync
    STROBE_SLOW      = 3     # SLOWDARK, non-sync
    GLOW             = 8
    STROBE_SLOW_SYNC = 12    # SLOWDARK, sync
    STROBE_FAST_SYNC = 13    # FASTDARK, sync
    FIRE_FLICKER     = 17

    STROBE_BRIGHT_TICS = 5
    STROBE_FAST_DARK   = 15
    STROBE_SLOW_DARK   = 35
    GLOW_SPEED         = 8
    FLASH_BRIGHT_MASK  = 64   # bright dwell = (rand & 64) + 1, i.e. 1..65 tics
    FLASH_DARK_MASK    = 7    # dark dwell   = (rand & 7)  + 1, i.e. 1..8 tics
    STROBE_PHASE_MASK  = 7    # non-sync initial dwell = (rand & 7) + 1
    FIRE_PERIOD_TICS   = 4
    FIRE_AMOUNT_MASK   = 3    # rand & 3 → step in {0, 16, 32, 48}
    FIRE_STEP          = 16
    FIRE_MIN_BOOST     = 16

    # Per-sector light-state record. `kind` picks the tic transition;
    # `dark_tics` carries the strobe's dark duration so fast and slow
    # variants can share `step_strobe`.
    Light = Struct.new(:sector, :kind, :max, :min, :state, :count, :dark_tics)

    def initialize(map, rng: Random.new)
      @map     = map
      @lights  = []
      @rng     = rng
      @neighbors_cache = nil
      collect_lights
    end

    def update_tic
      @lights.each { |l| step(l) }
    end

    # Walk-trigger linedef type 35: snap every sector with the given
    # tag to light_level 35 (vanilla "0 minus 8 + 35"). Drop any
    # active strobe/flash/glow effect on those sectors so it doesn't
    # immediately overwrite the new level next tic. Returns true if
    # at least one sector matched (so the caller can clear W1).
    def set_tag_light(tag, level)
      hit = false
      @map.sectors.each do |s|
        next unless s.tag == tag
        s.light_level = level
        @lights.reject! { |l| l.sector == s }
        hit = true
      end
      hit
    end

    private

    def collect_lights
      @map.sectors.each do |s|
        case s.special_type
        when FLASH
          mn = min_neighbor_light(s)
          @lights << Light.new(s, :flash, s.light_level, mn, :bright,
                               (@rng.rand(256) & FLASH_BRIGHT_MASK) + 1, nil)
        when GLOW
          mn = min_neighbor_light(s)
          @lights << Light.new(s, :glow, s.light_level, mn, :down, 0, nil)
        when STROBE_FAST
          add_strobe(s, STROBE_FAST_DARK, sync: false)
        when STROBE_SLOW
          add_strobe(s, STROBE_SLOW_DARK, sync: false)
        when STROBE_FAST_SYNC
          add_strobe(s, STROBE_FAST_DARK, sync: true)
        when STROBE_SLOW_SYNC
          add_strobe(s, STROBE_SLOW_DARK, sync: true)
        when FIRE_FLICKER
          mn = min_neighbor_light(s) + FIRE_MIN_BOOST
          @lights << Light.new(s, :fire, s.light_level, mn, nil,
                               FIRE_PERIOD_TICS, nil)
        end
      end
    end

    def add_strobe(sector, dark_tics, sync:)
      mn = min_neighbor_light(sector)
      mn = 0 if mn == sector.light_level  # vanilla "if equal, force 0"
      count = sync ? 1 : (@rng.rand(256) & STROBE_PHASE_MASK) + 1
      @lights << Light.new(sector, :strobe, sector.light_level, mn,
                           :bright, count, dark_tics)
    end

    def step(l)
      case l.kind
      when :flash  then step_flash(l)
      when :glow   then step_glow(l)
      when :strobe then step_strobe(l)
      when :fire   then step_fire(l)
      end
    end

    def step_fire(l)
      l.count -= 1
      return if l.count > 0
      amount = (@rng.rand(256) & FIRE_AMOUNT_MASK) * FIRE_STEP
      target = l.max - amount
      l.sector.light_level = target < l.min ? l.min : target
      l.count = FIRE_PERIOD_TICS
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
        l.count = l.dark_tics
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
