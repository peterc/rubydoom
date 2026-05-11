module Rubydoom
  # Hitscan resolution for weapons that fire instantaneous straight-line
  # shots (pistol / shotgun / chaingun / fist / chainsaw). Walks a 2-D
  # ray from the player along their current facing and returns what the
  # bullet hits first.
  #
  # We don't yet have monsters or shootable barrels, so the only thing a
  # ray *can* hit is a wall. The fire entry-point returns a simple
  # [:wall, x, y] / nil result so callers (Weapons) can later distinguish
  # — and so monster damage can drop in as a `[:thing, mobj]` branch
  # without changing the rest of the pipeline.
  #
  # Two-sided lines don't block the bullet purely on `impassable?` (the
  # ML_BLOCKING flag stops monsters in vanilla but not bullets) — instead
  # we look at the horizontal opening at the player's eye height. A door
  # closed at eye level blocks; an over-the-head gap does not.
  class Hitscan
    DEFAULT_RANGE = 2048.0  # 32 * 64 == MISSILERANGE in vanilla.

    def initialize(map, clipper)
      @map     = map
      @clipper = clipper
    end

    # Cast a ray from the player at their facing angle + an optional
    # +/- spread (degrees). Returns the [:wall, x, y] hit point, or nil
    # if nothing was hit within `range`.
    def fire(player, range: DEFAULT_RANGE, spread_deg: 0.0)
      ang = player.angle
      ang += (rand - 0.5) * 2 * spread_deg unless spread_deg.zero?
      rad = ang * Math::PI / 180.0
      dx  = Math.cos(rad)
      dy  = Math.sin(rad)
      eye = (@clipper.floor_at(player.x, player.y) || 0) + player.view_height

      best_t = range
      @map.linedefs.each do |ld|
        t = ray_linedef_t(player.x, player.y, dx, dy, ld)
        next unless t && t > 0 && t < best_t
        next unless blocks_bullet?(ld, eye)
        best_t = t
      end

      return nil if best_t >= range
      [:wall, player.x + dx * best_t, player.y + dy * best_t]
    end

    private

    # Parametric distance `t` along the ray to the intersection with
    # this linedef, or nil if the ray and the segment don't cross.
    def ray_linedef_t(x0, y0, dx, dy, ld)
      v1 = @map.vertexes[ld.start_vertex_index]
      v2 = @map.vertexes[ld.end_vertex_index]
      sdx = v2.x - v1.x
      sdy = v2.y - v1.y
      denom = dx * sdy - dy * sdx
      return nil if denom.abs < 1e-9
      t = ((v1.x - x0) * sdy - (v1.y - y0) * sdx) / denom
      s = ((v1.x - x0) * dy  - (v1.y - y0) * dx)  / denom
      return nil if t < 0 || s < 0 || s > 1
      t
    end

    # A bullet at `eye` z is blocked by this line iff:
    #   * one-sided (a wall), OR
    #   * two-sided but eye is outside the vertical opening between
    #     the higher floor and the lower ceiling.
    def blocks_bullet?(ld, eye)
      return true unless ld.two_sided?
      front = @map.linedef_front_sector(ld)
      back  = @map.linedef_back_sector(ld)
      return true if front.nil? || back.nil?
      opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
      opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height
      eye <= opening_bot || eye >= opening_top
    end
  end
end
