require "gosu"

module Rubydoom
  # Top-down line renderer for a Map. Renders into a Framebuffer and
  # uploads as a Gosu::Image, so it composes correctly with Gosu.record
  # and produces consistent 1-pixel lines regardless of GL driver.
  #
  # Line colors follow vanilla DOOM automap conventions:
  #   - one-sided (solid wall):     red
  #   - two-sided + floor change:   brown   (a step or pit)
  #   - two-sided + ceiling change: yellow  (a lintel / arch)
  #   - two-sided same heights:     dark grey (decorative line)
  class Automap
    SCREEN_WIDTH     = 320
    PLAYFIELD_HEIGHT = 168   # area above the status bar
    PADDING          = 8
    Z                = -1

    BACKGROUND       = [16,  16,  16].freeze
    COLOR_ONE_SIDED  = [220, 60,  60].freeze
    COLOR_STEP       = [165, 100, 30].freeze
    COLOR_LINTEL     = [220, 220, 60].freeze
    COLOR_SAME       = [90,  90,  90].freeze
    COLOR_PLAYER     = [60,  220, 60].freeze
    COLOR_THING      = [220, 220, 220].freeze
    COLOR_PSTART     = [60,  220, 60].freeze
    COLOR_DM_START   = [60,  220, 220].freeze
    COLOR_TELEPORT   = [180, 100, 220].freeze

    PLAYER_MARKER_RADIUS = 5
    THING_DOT_RADIUS     = 1

    def initialize(map, bsp: nil)
      @map = map
      @bsp = bsp
      @fb  = Framebuffer.new(SCREEN_WIDTH, PLAYFIELD_HEIGHT)
    end

    # mode: :lines (default) draws every linedef colored by wall type.
    #       :bsp draws only the segs, colored by front-to-back visit order
    #       from the player's position. Requires a Bsp to be passed in.
    def draw(player, mode: :lines)
      fb = @fb
      fb.clear(*BACKGROUND)

      project = projector
      case mode
      when :lines then draw_linedefs(fb, project)
      when :bsp   then draw_bsp(fb, project, player)
      else raise ArgumentError, "unknown automap mode: #{mode.inspect}"
      end

      draw_things(fb, project)

      px, py = project.call(player.x, player.y)
      draw_player_marker(fb, px, py, player.angle)

      fb.to_gosu_image.draw(0, 0, Z)
    end

    private

    def draw_linedefs(fb, project)
      @map.linedefs.each do |ld|
        v1, v2 = @map.linedef_endpoints(ld)
        next unless v1 && v2
        x1, y1 = project.call(v1.x, v1.y)
        x2, y2 = project.call(v2.x, v2.y)
        fb.draw_line(x1, y1, x2, y2, *color_for(ld))
      end
    end

    # Walks the BSP front-to-back from the player, drawing each subsector's
    # segs colored by visit order. Front (closest) = bright orange, back
    # (furthest) = dim purple — so you can see the depth ordering at a
    # glance.
    def draw_bsp(fb, project, player)
      raise "BSP visualization needs a Bsp passed to Automap.new" unless @bsp
      total = @map.subsectors.size

      # Faint context: every linedef in dark grey.
      ctx = [40, 40, 40]
      @map.linedefs.each do |ld|
        v1, v2 = @map.linedef_endpoints(ld)
        next unless v1 && v2
        x1, y1 = project.call(v1.x, v1.y)
        x2, y2 = project.call(v2.x, v2.y)
        fb.draw_line(x1, y1, x2, y2, *ctx)
      end

      order = 0
      @bsp.each_subsector_front_to_back(player.x, player.y) do |ssec_idx|
        color = bsp_color(order, total)
        ssec = @map.subsectors[ssec_idx]
        ssec.seg_count.times do |i|
          seg = @map.segs[ssec.first_seg_index + i]
          v1 = @map.vertexes[seg.start_vertex_index]
          v2 = @map.vertexes[seg.end_vertex_index]
          next unless v1 && v2
          x1, y1 = project.call(v1.x, v1.y)
          x2, y2 = project.call(v2.x, v2.y)
          fb.draw_line(x1, y1, x2, y2, *color)
        end
        order += 1
      end
    end

    # t=0 → bright orange-yellow; t=1 → dim purple-blue. Linear in HSV
    # over hue and value so adjacent subsectors are visibly distinct.
    def bsp_color(order, total)
      t = total > 1 ? order.to_f / (total - 1) : 0
      hue   = 30.0 + t * 240.0       # 30° (orange) → 270° (purple)
      value = 1.0 - t * 0.6          # 1.0 → 0.4
      hsv_to_rgb(hue, 1.0, value)
    end

    def hsv_to_rgb(h, s, v)
      c = v * s
      x = c * (1 - ((h / 60.0) % 2 - 1).abs)
      m = v - c
      r1, g1, b1 =
        case h
        when   0...60  then [c, x, 0]
        when  60...120 then [x, c, 0]
        when 120...180 then [0, c, x]
        when 180...240 then [0, x, c]
        when 240...300 then [x, 0, c]
        else                [c, 0, x]
        end
      [((r1 + m) * 255).to_i, ((g1 + m) * 255).to_i, ((b1 + m) * 255).to_i]
    end

    # Returns a lambda mapping (map_x, map_y) -> (screen_x, screen_y).
    # Fits the map into the playfield with uniform scaling. DOOM's y
    # axis points up; ours points down, so y is flipped.
    def projector
      bounds = @map.bounds
      map_w  = (bounds.right - bounds.left).to_f
      map_h  = (bounds.top   - bounds.bottom).to_f
      view_w = SCREEN_WIDTH - PADDING * 2
      view_h = PLAYFIELD_HEIGHT - PADDING * 2
      scale  = [view_w / map_w, view_h / map_h].min
      ox     = PADDING + (view_w - map_w * scale) / 2.0
      oy     = PADDING + (view_h - map_h * scale) / 2.0

      lambda do |x, y|
        [ox + (x - bounds.left) * scale,
         oy + (bounds.top - y)  * scale]
      end
    end

    def color_for(linedef)
      return COLOR_ONE_SIDED unless linedef.two_sided?

      front = @map.linedef_front_sector(linedef)
      back  = @map.linedef_back_sector(linedef)
      return COLOR_SAME unless front && back

      if front.floor_height != back.floor_height
        COLOR_STEP
      elsif front.ceiling_height != back.ceiling_height
        COLOR_LINTEL
      else
        COLOR_SAME
      end
    end

    # Plot every thing in the map as a small filled square. Player /
    # multiplayer / teleport-landing markers get distinct colors so the
    # standard layout is recognisable; everything else (monsters,
    # items, decorations) is a uniform white dot for now — categorising
    # by doomednum belongs in the sprite-info table (step 3).
    def draw_things(fb, project)
      @map.things.each do |t|
        cx, cy = project.call(t.x, t.y)
        color  = thing_color(t.type)
        r = THING_DOT_RADIUS
        ((-r)..r).each do |dy|
          ((-r)..r).each do |dx|
            fb.set_pixel((cx + dx).to_i, (cy + dy).to_i, *color)
          end
        end
      end
    end

    def thing_color(type)
      case type
      when 1     then COLOR_PSTART
      when 2..4  then COLOR_PSTART
      when 11    then COLOR_DM_START
      when 14    then COLOR_TELEPORT
      else            COLOR_THING
      end
    end

    # Triangle: tip in the facing direction, two back wings.
    def draw_player_marker(fb, cx, cy, angle_deg)
      angle = angle_deg * Math::PI / 180.0
      # DOOM angles: 0 = East (+x), 90 = North (+y). Screen y is flipped.
      fx =  Math.cos(angle)
      fy = -Math.sin(angle)
      r  = PLAYER_MARKER_RADIUS

      tip   = [cx + fx * r,         cy + fy * r]
      back  = [cx - fx * (r * 0.6), cy - fy * (r * 0.6)]
      perp  = [-fy, fx]
      wing1 = [back[0] + perp[0] * (r * 0.6), back[1] + perp[1] * (r * 0.6)]
      wing2 = [back[0] - perp[0] * (r * 0.6), back[1] - perp[1] * (r * 0.6)]

      r_, g_, b_ = COLOR_PLAYER
      fb.draw_line(tip[0],   tip[1],   wing1[0], wing1[1], r_, g_, b_)
      fb.draw_line(tip[0],   tip[1],   wing2[0], wing2[1], r_, g_, b_)
      fb.draw_line(wing1[0], wing1[1], wing2[0], wing2[1], r_, g_, b_)
    end
  end
end
