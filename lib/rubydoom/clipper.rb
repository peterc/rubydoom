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
    end

    # Returns [final_x, final_y] after attempting to move from (x0, y0)
    # to (x1, y1). If the full move fails, tries sliding along each axis
    # independently before giving up and returning the start position.
    # Floor height of the subsector containing (x, y). Public because the
    # view-height smoother in App needs it to detect step-ups each tic.
    def floor_at(x, y)
      ss_index = @bsp.subsector_at(x, y)
      ss = @map.subsectors[ss_index]
      seg = @map.segs[ss.first_seg_index]
      ld = @map.linedefs[seg.linedef_index]
      sd_index = seg.direction.zero? ? ld.front_sidedef_index : ld.back_sidedef_index
      sd = @map.sidedefs[sd_index]
      @map.sectors[sd.sector_index].floor_height
    end

    def slide(x0, y0, x1, y1)
      dx = x1 - x0
      dy = y1 - y0
      return [x0, y0] if dx.zero? && dy.zero?

      current_floor = floor_at(x0, y0)
      return [x0, y0] if current_floor.nil?

      return [x1, y1] if try_move(x0, y0, current_floor, x1, y1)

      if dx != 0 && try_move(x0, y0, current_floor, x0 + dx, y0)
        return [x0 + dx, y0]
      end
      if dy != 0 && try_move(x0, y0, current_floor, x0, y0 + dy)
        return [x0, y0 + dy]
      end
      [x0, y0]
    end

    private

    def try_move(start_x, start_y, current_floor, x, y)
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

        # Step-up: only blocks when the move actually crosses the line.
        # Sliding parallel along a tall ledge with the radius brushing
        # it shouldn't trigger this check — otherwise a player who
        # fell into a pit can't navigate inside it.
        next if point_side(start_x, start_y, ld) == point_side(x, y, ld)
        return false if opening_bot - current_floor > MAX_STEP
      end
      true
    end

    # Cross product sign — returns 0 (front/right) or 1 (back/left).
    # Same convention as Bsp#point_on_side.
    def point_side(x, y, ld)
      a = @map.vertexes[ld.start_vertex_index]
      b = @map.vertexes[ld.end_vertex_index]
      cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
      cross > 0 ? 1 : 0
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
