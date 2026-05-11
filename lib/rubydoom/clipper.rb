module Rubydoom
  # Player-vs-world collision. Treats the player as an upright cylinder
  # of radius 16 and height 56 (DOOM's MOBJINFO values for MT_PLAYER) and
  # decides whether a proposed move from (x0, y0) to (x1, y1) is allowed.
  #
  # We don't load the WAD's BLOCKMAP lump — instead we build our own
  # 128-unit grid at construction time. Each cell stores the indices of
  # linedefs whose bounding box touches it (slightly conservative, but
  # the precise circle-vs-segment test runs at query time anyway, so
  # over-listing only costs a few extra checks).
  #
  # Two-sided line rules match DOOM's classic clipping:
  #   * opening height = min(front.ceil, back.ceil) - max(front.floor, back.floor)
  #     must be at least PLAYER_HEIGHT (56) — anything shorter is "too
  #     short to walk through" and includes closed doors (opening = 0).
  #   * the higher of the two floors must not be more than MAX_STEP (24)
  #     above the current floor — that's DOOM's max step-up.
  #
  # Sliding falls out of trying the full move first, then x-only, then
  # y-only. It's not the angle-projection slide DOOM does, but it feels
  # right at axis-aligned and oblique walls alike.
  class Clipper
    PLAYER_RADIUS = 16
    PLAYER_HEIGHT = 56
    MAX_STEP      = 24

    BLOCK_SIZE = 128

    def initialize(map, bsp)
      @map      = map
      @bsp      = bsp
      build_blockmap
      @solid_things = collect_solid_things
      @on_cross = nil
    end

    # Set a callback (taking a linedef) that fires once per walk-trigger
    # linedef the player crossed during a successful slide(). The
    # callback's job is to dispatch the special and (for W1 once-only
    # triggers) clear its special_type so it doesn't fire again.
    attr_writer :on_cross

    # Returns [final_x, final_y] after attempting to move from (x0, y0)
    # to (x1, y1). If the full move fails, tries sliding along each axis
    # independently before giving up and returning the start position.
    # Floor height of the subsector containing (x, y). Public because the
    # view-height smoother in App needs it to detect step-ups each tic.
    def floor_at(x, y)
      sec = sector_at(x, y)
      sec&.floor_height
    end

    # Sector containing point (x, y). Resolved by descending the BSP
    # to a subsector, then back to a sector via the subsector's first
    # seg (the seg's direction picks front or back sidedef).
    def sector_at(x, y)
      ss_index = @bsp.subsector_at(x, y)
      ss = @map.subsectors[ss_index]
      seg = @map.segs[ss.first_seg_index]
      ld = @map.linedefs[seg.linedef_index]
      sd_index = seg.direction.zero? ? ld.front_sidedef_index : ld.back_sidedef_index
      sd = @map.sidedefs[sd_index]
      @map.sectors[sd.sector_index]
    end

    def slide(x0, y0, x1, y1)
      dx = x1 - x0
      dy = y1 - y0
      return [x0, y0] if dx.zero? && dy.zero?

      current_floor = floor_at(x0, y0)
      return [x0, y0] if current_floor.nil?

      if try_move(x0, y0, current_floor, x1, y1)
        emit_crossings(x0, y0, x1, y1)
        return [x1, y1]
      end
      if dx != 0 && try_move(x0, y0, current_floor, x0 + dx, y0)
        emit_crossings(x0, y0, x0 + dx, y0)
        return [x0 + dx, y0]
      end
      if dy != 0 && try_move(x0, y0, current_floor, x0, y0 + dy)
        emit_crossings(x0, y0, x0, y0 + dy)
        return [x0, y0 + dy]
      end
      [x0, y0]
    end

    # Linedefs touching the bounding box of the segment (x0,y0)->(x1,y1),
    # yielded as LineDef structs. Used by Sight#visible? for AI ray
    # tests; the bbox over-list is a few extra checks worst-case, the
    # per-line t-test filters non-crossings at query time.
    def each_linedef_in_path(x0, y0, x1, y1)
      c0 = cell_col(x0); c1 = cell_col(x1)
      r0 = cell_row(y0); r1 = cell_row(y1)
      c0, c1 = c1, c0 if c0 > c1
      r0, r1 = r1, r0 if r0 > r1
      c0 = 0 if c0 < 0
      r0 = 0 if r0 < 0
      c1 = @cols - 1 if c1 >= @cols
      r1 = @rows - 1 if r1 >= @rows
      seen = nil
      (r0..r1).each do |row|
        (c0..c1).each do |col|
          @cells[row * @cols + col].each do |ld_index|
            seen ||= {}
            next if seen[ld_index]
            seen[ld_index] = true
            yield @map.linedefs[ld_index]
          end
        end
      end
    end

    # Probe whether a thing of `radius` at (x, y) would clip into a
    # wall / step / closed door. Same wall rules as try_move but
    # parameterised by radius (the player path uses PLAYER_RADIUS = 16,
    # monsters have 20-30) and ignores per-thing AABB overlap (that's
    # done separately by MonsterMovement#position_clear?). Returns
    # true iff the position is clear.
    def position_valid?(x, y, current_floor, radius)
      seen = nil
      each_linedef_near(x, y, radius) do |ld_index|
        seen ||= {}
        next if seen[ld_index]
        seen[ld_index] = true

        ld = @map.linedefs[ld_index]
        next unless circle_crosses_linedef?(x, y, radius, ld)

        return false if !ld.two_sided? || ld.impassable?

        front = @map.linedef_front_sector(ld)
        back  = @map.linedef_back_sector(ld)
        return false if front.nil? || back.nil?

        opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
        opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height

        return false if opening_top - opening_bot < PLAYER_HEIGHT
        return false if opening_bot - current_floor > MAX_STEP
      end
      true
    end

    private

    def try_move(start_x, start_y, current_floor, x, y)
      return false if thing_blocks?(start_x, start_y, x, y)

      r = PLAYER_RADIUS
      seen = nil
      each_linedef_near(x, y, r) do |ld_index|
        # A linedef may live in several cells we visit; skip duplicates.
        seen ||= {}
        next if seen[ld_index]
        seen[ld_index] = true

        ld = @map.linedefs[ld_index]
        next unless circle_crosses_linedef?(x, y, r, ld)

        # One-sided walls and ML_BLOCKING two-sided lines (e.g. window
        # slits) are solid regardless of opening height.
        return false if !ld.two_sided? || ld.impassable?

        front = @map.linedef_front_sector(ld)
        back  = @map.linedef_back_sector(ld)
        return false if front.nil? || back.nil?

        opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
        opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height

        # Height clearance: if the gap is too short to fit the player,
        # the line is solid — including closed doors (opening = 0) that
        # the player might otherwise slide *along* without ever
        # technically crossing.
        return false if opening_top - opening_bot < PLAYER_HEIGHT

        # Step-up applies when the move *newly* brings the player's
        # bounding box across the line into the higher sector. If the
        # BB already straddled at the start position — e.g. the player
        # is navigating inside a pit whose surrounding floors are 24+
        # higher — let them keep moving (they're already in violation
        # and need to be able to escape). The center-side check that
        # used to live here was too loose: in a corner of two tall
        # ledges the BB could squeeze into the high-floor sector
        # without the center crossing either linedef, letting the
        # player end up effectively inside the wall.
        if !bb_straddles?(start_x, start_y, r, ld) && bb_straddles?(x, y, r, ld)
          return false if opening_bot - current_floor > MAX_STEP
        end
      end
      true
    end

    # AABB overlap of player vs each solid thing. Mirrors vanilla:
    # corpses, pickups, the small candle, etc. have MF_SOLID clear and
    # are walked through; everything else blocks. If the player already
    # overlapped the thing at the START position, the move is allowed —
    # otherwise a player spawned overlapping a prop would be stuck.
    #
    # We store thing references (not snapshot tuples) so live state —
    # `thing.removed` after destruction, `thing.solid_override` after a
    # barrel's MF_SOLID is cleared on death — drives collision without
    # rebuilding the list.
    def thing_blocks?(start_x, start_y, x, y)
      @solid_things.each do |thing, tr|
        next if thing.removed || thing.solid_override == false
        range = PLAYER_RADIUS + tr
        next if (x - thing.x).abs >= range || (y - thing.y).abs >= range
        next if (start_x - thing.x).abs < range && (start_y - thing.y).abs < range
        return true
      end
      false
    end

    # Walk-trigger emission. Fires @on_cross for each special linedef
    # the player's center segment crossed (start and end on different
    # sides AND the line segments actually intersect). Uses the
    # blockmap to scope the search to nearby linedefs only.
    def emit_crossings(x0, y0, x1, y1)
      return unless @on_cross
      half_dx = (x1 - x0).abs * 0.5
      half_dy = (y1 - y0).abs * 0.5
      radius  = half_dx > half_dy ? half_dx : half_dy
      seen    = nil
      each_linedef_near((x0 + x1) * 0.5, (y0 + y1) * 0.5, radius + 1) do |ld_index|
        seen ||= {}
        next if seen[ld_index]
        seen[ld_index] = true

        ld = @map.linedefs[ld_index]
        next if ld.special_type.zero?
        next unless segments_cross?(x0, y0, x1, y1, ld)
        @on_cross.call(ld)
      end
    end

    # True iff player path (a→b) and linedef (c→d) properly intersect.
    # Endpoint touches are fine to count as a cross — we err toward
    # firing rather than missing a trigger that the player skimmed.
    def segments_cross?(ax, ay, bx, by, ld)
      c = @map.vertexes[ld.start_vertex_index]
      d = @map.vertexes[ld.end_vertex_index]
      d1 = (bx - ax) * (c.y - ay) - (by - ay) * (c.x - ax)
      d2 = (bx - ax) * (d.y - ay) - (by - ay) * (d.x - ax)
      d3 = (d.x - c.x) * (ay - c.y) - (d.y - c.y) * (ax - c.x)
      d4 = (d.x - c.x) * (by - c.y) - (d.y - c.y) * (bx - c.x)
      ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    end

    def collect_solid_things
      @map.things.filter_map do |t|
        info = ThingTypes[t.type]
        next unless info && info.solid
        [t, info.radius.to_f]
      end
    end

    # Cross product sign — returns 0 (front/right) or 1 (back/left).
    # Same convention as Bsp#point_on_side.
    def point_side(x, y, ld)
      a = @map.vertexes[ld.start_vertex_index]
      b = @map.vertexes[ld.end_vertex_index]
      cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
      cross > 0 ? 1 : 0
    end

    # Does an axis-aligned bounding box of half-extent `r` centered at
    # (cx, cy) have corners on both sides of the linedef? Used by the
    # step-up rule to decide whether a move puts the player into a new
    # sector (BB crossing) rather than just brushing a wall.
    def bb_straddles?(cx, cy, r, ld)
      a = @map.vertexes[ld.start_vertex_index]
      b = @map.vertexes[ld.end_vertex_index]
      dx = b.x - a.x
      dy = b.y - a.y
      pos = false
      neg = false
      [[-r, -r], [r, -r], [-r, r], [r, r]].each do |ox, oy|
        cross = dx * (cy + oy - a.y) - dy * (cx + ox - a.x)
        pos = true if cross > 0
        neg = true if cross < 0
        return true if pos && neg
      end
      false
    end

    # Distance from circle center (cx, cy) to the line *segment* (a, b)
    # ≤ r. Uses the squared-distance form to avoid a sqrt.
    def circle_crosses_linedef?(cx, cy, r, ld)
      a = @map.vertexes[ld.start_vertex_index]
      b = @map.vertexes[ld.end_vertex_index]
      ax = a.x; ay = a.y
      bx = b.x; by = b.y
      dx = bx - ax
      dy = by - ay
      len_sq = dx * dx + dy * dy
      if len_sq.zero?
        px = ax; py = ay
      else
        t = ((cx - ax) * dx + (cy - ay) * dy).fdiv(len_sq)
        t = 0.0 if t < 0.0
        t = 1.0 if t > 1.0
        px = ax + t * dx
        py = ay + t * dy
      end
      ex = cx - px
      ey = cy - py
      ex * ex + ey * ey <= r * r
    end

    # ----- blockmap -----

    def build_blockmap
      bounds = @map.bounds
      @origin_x = bounds.left
      @origin_y = bounds.bottom
      @cols = ((bounds.right - bounds.left) / BLOCK_SIZE).to_i + 1
      @rows = ((bounds.top   - bounds.bottom) / BLOCK_SIZE).to_i + 1
      @cells = Array.new(@cols * @rows) { [] }

      @map.linedefs.each_with_index do |ld, i|
        a = @map.vertexes[ld.start_vertex_index]
        b = @map.vertexes[ld.end_vertex_index]
        c0 = cell_col(a.x); c1 = cell_col(b.x)
        r0 = cell_row(a.y); r1 = cell_row(b.y)
        c0, c1 = c1, c0 if c0 > c1
        r0, r1 = r1, r0 if r0 > r1
        c0 = 0 if c0 < 0
        r0 = 0 if r0 < 0
        c1 = @cols - 1 if c1 >= @cols
        r1 = @rows - 1 if r1 >= @rows
        (r0..r1).each do |r|
          (c0..c1).each do |c|
            @cells[r * @cols + c] << i
          end
        end
      end
    end

    def each_linedef_near(x, y, r)
      c0 = cell_col(x - r); c1 = cell_col(x + r)
      r0 = cell_row(y - r); r1 = cell_row(y + r)
      c0 = 0 if c0 < 0
      r0 = 0 if r0 < 0
      c1 = @cols - 1 if c1 >= @cols
      r1 = @rows - 1 if r1 >= @rows
      (r0..r1).each do |row|
        (c0..c1).each do |col|
          @cells[row * @cols + col].each { |ld_index| yield ld_index }
        end
      end
    end

    def cell_col(x); ((x - @origin_x) / BLOCK_SIZE).to_i; end
    def cell_row(y); ((y - @origin_y) / BLOCK_SIZE).to_i; end
  end
end
