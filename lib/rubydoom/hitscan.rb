module Rubydoom
  # Hitscan resolution for weapons that fire instantaneous straight-line
  # shots (pistol / shotgun / chaingun / fist / chainsaw). Walks a 2-D
  # ray from the player along their current facing and returns what the
  # bullet hits first.
  #
  # Returns one of:
  #   [:thing, thing, x, y]  — bullet hit a shootable (barrel, monster)
  #   [:wall,  x, y]         — bullet hit a wall first
  #   nil                    — out of range, nothing hit
  #
  # Vertical aim is auto-computed (vanilla P_AimLineAttack + P_LineAttack):
  # we first sweep the XY ray for shootables, pick the nearest one with
  # an unobstructed eye-height path to it (this is the autoaim
  # candidate), and compute a slope `(target_z_center - eye) / dist`.
  # The real wall-blocking pass then checks each line's opening at
  # `eye + slope*t` rather than at the flat eye line. Without this an
  # imp on a ledge whose floor is above the player's eye sits behind a
  # "blocked" opening even though there's clear sky above the step.
  #
  # Two-sided lines don't block the bullet purely on `impassable?` (the
  # ML_BLOCKING flag stops monsters in vanilla but not bullets) — instead
  # we look at the vertical opening at the line's t versus the bullet's
  # z there.
  class Hitscan
    DEFAULT_RANGE = 2048.0  # 32 * 64 == MISSILERANGE in vanilla.

    def initialize(map, clipper, sight: nil)
      @map     = map
      @clipper = clipper
      # Sight runs the proper slope-aware opening check used for AI
      # line-of-sight. We reuse it for autoaim so a target up on a
      # ledge (whose step-up bottom is above the player's flat eye)
      # still qualifies.
      @sight   = sight || Sight.new(map, clipper)
    end

    # Cast a ray from the player at their facing angle + an optional
    # +/- spread (degrees). `shootables` is a list of
    # [thing, radius, height] tuples (Combat#shootables) — pass nil for
    # wall-only checks. The nearest of (wall, any shootable) wins.
    def fire(player, range: DEFAULT_RANGE, spread_deg: 0.0, shootables: nil)
      ang = player.angle
      ang += (rand - 0.5) * 2 * spread_deg unless spread_deg.zero?
      rad = ang * Math::PI / 180.0
      dx  = Math.cos(rad)
      dy  = Math.sin(rad)
      eye = (@clipper.floor_at(player.x, player.y) || 0) + player.view_height

      # Autoaim: pick the slope toward the nearest shootable that's
      # reachable along the XY ray. With no candidate the bullet flies
      # flat at eye height.
      aim_slope = autoaim_slope(player.x, player.y, dx, dy, eye, range, shootables)

      best_t   = range
      best_hit = nil

      @map.linedefs.each do |ld|
        t = ray_linedef_t(player.x, player.y, dx, dy, ld)
        next unless t && t > 0 && t < best_t
        next unless blocks_bullet_at?(ld, eye + aim_slope * t)
        best_t   = t
        best_hit = :wall
      end

      shootables&.each do |thing, tr, th|
        t = ray_circle_t(player.x, player.y, dx, dy, thing.x, thing.y, tr)
        next unless t && t > 0 && t < best_t
        # Vertical hit: the ray at this t must be within the target's
        # body. floor + 0..height is the body extent.
        floor = @clipper.floor_at(thing.x, thing.y) || 0
        z_at  = eye + aim_slope * t
        next if th && (z_at < floor || z_at > floor + th)
        best_t   = t
        best_hit = thing
      end

      return nil if best_hit.nil?
      hx = player.x + dx * best_t
      hy = player.y + dy * best_t
      best_hit == :wall ? [:wall, hx, hy] : [:thing, best_hit, hx, hy]
    end

    private

    # Find the nearest shootable on the XY ray that the player has a
    # 3-D line of sight to (eye → target body center). Return the slope
    # that aims at its vertical center, or 0.0 if there's no candidate.
    #
    # We don't replicate vanilla's topslope / bottomslope sweep
    # exactly — a single Sight ray to the candidate is enough to clear
    # the common case (target on a higher ledge), and a per-target ray
    # avoids picking a target hidden behind a closed door.
    def autoaim_slope(px, py, dx, dy, eye, range, shootables)
      return 0.0 unless shootables && !shootables.empty?

      best_t = nil
      best_th = nil
      best_thing = nil
      shootables.each do |thing, tr, th|
        t = ray_circle_t(px, py, dx, dy, thing.x, thing.y, tr)
        next unless t && t > 0 && t < range
        floor    = @clipper.floor_at(thing.x, thing.y) || 0
        center_z = floor + (th || 56.0) * 0.5
        next unless @sight.visible?(px, py, eye, thing.x, thing.y, center_z)
        if best_t.nil? || t < best_t
          best_t     = t
          best_th    = th
          best_thing = thing
        end
      end
      return 0.0 unless best_thing

      floor    = @clipper.floor_at(best_thing.x, best_thing.y) || 0
      center_z = floor + (best_th || 56.0) * 0.5
      (center_z - eye) / best_t
    end

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

    # Parametric distance along the ray to where it first enters a
    # circle of radius `r` centered at (cx, cy). Returns nil if the
    # ray's perpendicular miss-distance exceeds the radius (no hit) or
    # the entry point is behind us.
    def ray_circle_t(px, py, dx, dy, cx, cy, r)
      # Project (c - p) onto direction (d is unit-length).
      tx = cx - px; ty = cy - py
      proj = tx * dx + ty * dy
      return nil if proj < 0
      perp_sq = tx * tx + ty * ty - proj * proj
      r_sq    = r * r
      return nil if perp_sq > r_sq
      proj - Math.sqrt(r_sq - perp_sq)
    end

    # A bullet at world z `ray_z` is blocked by this line iff:
    #   * one-sided (a wall), OR
    #   * two-sided but ray_z is outside the vertical opening between
    #     the higher floor and the lower ceiling.
    def blocks_bullet_at?(ld, ray_z)
      return true unless ld.two_sided?
      front = @map.linedef_front_sector(ld)
      back  = @map.linedef_back_sector(ld)
      return true if front.nil? || back.nil?
      opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
      opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height
      ray_z <= opening_bot || ray_z >= opening_top
    end
  end
end
