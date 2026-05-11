module Rubydoom
  # Use-action handler for switch linedefs. Mirrors the Doors ray:
  # cast forward USE_RANGE units, take the first linedef hit, dispatch
  # by special_type. A non-passable hit that isn't a switch stops the
  # ray cold — so a switch hidden behind a wall isn't reachable.
  #
  # On activation we swap the front sidedef's switch texture (SW1xxx
  # ↔ SW2xxx) so the player gets visual feedback. Once-only ("S1")
  # specials clear their special_type after firing so they can't be
  # used twice.
  #
  # Currently implements:
  #   * type 11 — S1 Exit Level. Sets exit_requested; the game loop
  #     reads it.
  class Switches
    USE_RANGE = 64.0

    S1_EXIT_LEVEL = 11

    attr_reader :exit_requested

    def initialize(map)
      @map = map
      @exit_requested = false
    end

    def try_use(player)
      rad = player.angle * Math::PI / 180.0
      dx = Math.cos(rad); dy = Math.sin(rad)
      hits = ray_hits(player.x, player.y, dx, dy, USE_RANGE)
      hits.each do |_t, ld|
        case ld.special_type
        when S1_EXIT_LEVEL
          @exit_requested = true
          swap_switch_texture(ld)
          ld.special_type = 0
          return true
        end
        return false if !ld.two_sided? || ld.impassable?
      end
      false
    end

    private

    # Swap SW1xxx <-> SW2xxx on whichever of upper/middle/lower
    # textures of the front sidedef is currently set to a switch.
    def swap_switch_texture(ld)
      sd = @map.sidedefs[ld.front_sidedef_index]
      %i[upper_texture middle_texture lower_texture].each do |attr|
        name = sd.send(attr)
        next if name.nil? || name.empty? || name == "-"
        if name.start_with?("SW1")
          sd.send("#{attr}=", "SW2" + name[3..])
        elsif name.start_with?("SW2")
          sd.send("#{attr}=", "SW1" + name[3..])
        end
      end
    end

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
