module Rubydoom
  # Line-of-sight check between two map points. A simplified
  # `P_CheckSight` — vanilla also walks the BSP and consults REJECT (the
  # precomputed sector pair visibility lump); we just ray-cast against
  # every linedef in the blockmap cells the ray passes through and ask
  # "is the vertical opening at the line clear enough at the line's
  # crossing height?". REJECT would only be a speed win, not correctness.
  #
  # `sight_height` for the source is the monster's eye — vanilla uses
  # `z + height - (height >> 2)` (3/4 of body height). For the target,
  # we just use the player's eye level (floor + view_height).
  class Sight
    def initialize(map, clipper)
      @map     = map
      @clipper = clipper
    end

    # Returns true iff a straight line from (sx, sy) to (tx, ty) at the
    # given source/target z's clears every wall between them. A "wall"
    # means a one-sided line OR a two-sided line whose vertical opening
    # at the ray's intersection z is too narrow for the ray to pass.
    def visible?(sx, sy, sz, tx, ty, tz)
      dx = tx - sx
      dy = ty - sy
      len = Math.hypot(dx, dy)
      return true if len < 1e-6

      # Parameterise the ray as (sx + t*dx, sy + t*dy, sz + t*dz)
      # for t ∈ [0, 1]. dz is the elevation gradient.
      dz = tz - sz

      @clipper.each_linedef_in_path(sx, sy, tx, ty) do |ld|
        # Skip lines whose segment doesn't actually cross the ray.
        t = segment_intersect_t(sx, sy, dx, dy, ld)
        next if t.nil? || t <= 0 || t >= 1

        # One-sided lines always block. ML_BLOCKING (impassable) two-
        # sided lines stop movement but not sight — that's how you can
        # see (and shoot) through the window slits in E1M1's entry hall.
        return false unless ld.two_sided?

        front = @map.linedef_front_sector(ld)
        back  = @map.linedef_back_sector(ld)
        return false if front.nil? || back.nil?

        # Vertical opening at the line.
        opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
        opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height
        return false if opening_top <= opening_bot

        # The ray at this t must pass through the opening.
        ray_z = sz + dz * t
        return false if ray_z <= opening_bot
        return false if ray_z >= opening_top
      end
      true
    end

    private

    # Parametric t along the ray (origin (sx, sy), direction (dx, dy))
    # at which it crosses the linedef segment, or nil if it doesn't.
    def segment_intersect_t(sx, sy, dx, dy, ld)
      v1 = @map.vertexes[ld.start_vertex_index]
      v2 = @map.vertexes[ld.end_vertex_index]
      sdx = v2.x - v1.x
      sdy = v2.y - v1.y
      denom = dx * sdy - dy * sdx
      return nil if denom.abs < 1e-9
      t = ((v1.x - sx) * sdy - (v1.y - sy) * sdx) / denom
      s = ((v1.x - sx) * dy  - (v1.y - sy) * dx)  / denom
      return nil if s < 0 || s > 1
      t
    end
  end
end
