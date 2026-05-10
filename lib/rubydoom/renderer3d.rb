require "gosu"

module Rubydoom
  # Textured wall + flat (floor / ceiling) renderer.
  #
  # Walks the BSP front-to-back. For each visible seg, projects it,
  # samples wall textures column-by-column, and emits horizontal-span
  # entries into a Visplanes accumulator for the front sector's floor
  # and ceiling. After the BSP walk, every accumulated visplane is
  # rasterized row-by-row (z is constant per row, so the per-pixel
  # world step is constant across each run).
  #
  # Coordinate model:
  #   World:  DOOM-native, +y north (up on automap).
  #   Camera: origin at player, +z forward, +x right. World → camera is
  #     translate by -player + rotate by -player_angle:
  #       cam_z =  dx * cos_a + dy * sin_a
  #       cam_x =  dx * sin_a - dy * cos_a
  #     The inverse used for visplane sampling is:
  #       world_x = player.x + cam_x * sin_a + cam_z * cos_a
  #       world_y = player.y - cam_x * cos_a + cam_z * sin_a
  #   Screen: 320×168, origin top-left.
  #
  # Projection: FOV = 90° → focal length f = HALF_WIDTH = 160 px.
  #   sx = HALF_WIDTH  + (cam_x / cam_z) * f
  #   sy = HALF_HEIGHT - ((world_h - eye_y) / cam_z) * f
  #
  # Visibility / occlusion:
  #   Per-column [top_clip, bot_clip] is the still-visible vertical
  #   range. Drawing a wall in a column shrinks the range; a solid wall
  #   collapses it to empty. Front-to-back BSP traversal stops once
  #   every column is collapsed.
  #
  # Visplane spans:
  #   For each visible column on each seg, before drawing the wall
  #   portion(s) we emit:
  #     - ceiling span: [top_clip[x], sy_front_ceil - 1]
  #     - floor span:   [sy_front_floor + 1, bot_clip[x]]
  #   keyed by (front_sector.ceiling_flat / floor_flat, height,
  #   light_level). The wall draws its mid / upper / lower section in
  #   between, then top_clip / bot_clip are pushed inward as appropriate.
  class Renderer3D
    SCREEN_WIDTH     = 320
    PLAYFIELD_HEIGHT = 168

    HALF_WIDTH       = SCREEN_WIDTH / 2
    HALF_HEIGHT      = PLAYFIELD_HEIGHT / 2

    FOCAL_LENGTH     = HALF_WIDTH.to_f
    EYE_HEIGHT       = 41
    NEAR_Z           = 1.0
    MIN_LIGHT        = 0.25

    SKY_COLOR        = [70,  70,  120].freeze
    FLOOR_COLOR      = [40,  35,  30].freeze

    Z = -2

    def initialize(map, bsp, textures: nil, flats: nil, palette: nil, colormap: nil, sky: nil)
      @map      = map
      @bsp      = bsp
      @textures = textures
      @flats    = flats
      @palette  = palette
      @colormap = colormap
      @sky      = sky
    end

    def draw(player)
      fb = Framebuffer.new(SCREEN_WIDTH, PLAYFIELD_HEIGHT)
      @player_angle_deg = player.angle
      if @sky
        x = 0
        while x < SCREEN_WIDTH
          @sky.fill_column(fb, x, 0, HALF_HEIGHT - 1,
                           @player_angle_deg, HALF_WIDTH, FOCAL_LENGTH, @palette)
          x += 1
        end
      else
        fb.fill_rect(0, 0, SCREEN_WIDTH, HALF_HEIGHT, *SKY_COLOR)
      end
      fb.fill_rect(0, HALF_HEIGHT, SCREEN_WIDTH, PLAYFIELD_HEIGHT - HALF_HEIGHT, *FLOOR_COLOR)

      eye_y = compute_eye_y(player)
      angle = player.angle * Math::PI / 180.0
      cos_a = Math.cos(angle)
      sin_a = Math.sin(angle)

      top_clip   = Array.new(SCREEN_WIDTH, 0)
      bot_clip   = Array.new(SCREEN_WIDTH, PLAYFIELD_HEIGHT - 1)
      visplanes  = Visplanes.new(SCREEN_WIDTH)
      open_columns = SCREEN_WIDTH

      @bsp.each_subsector_front_to_back(player.x, player.y) do |ssec_idx|
        break if open_columns <= 0
        ssec = @map.subsectors[ssec_idx]
        ssec.seg_count.times do |i|
          seg = @map.segs[ssec.first_seg_index + i]
          ld  = @map.linedefs[seg.linedef_index]
          open_columns -= render_seg(fb, seg, ld, player, cos_a, sin_a,
                                     eye_y, top_clip, bot_clip, visplanes)
        end
      end

      draw_visplanes(fb, visplanes, eye_y, player, cos_a, sin_a)

      fb.to_gosu_image.draw(0, 0, Z)
    end

    private

    def compute_eye_y(player)
      ssec_idx = @bsp.subsector_at(player.x, player.y)
      ssec     = @map.subsectors[ssec_idx]
      seg      = @map.segs[ssec.first_seg_index]
      ld       = @map.linedefs[seg.linedef_index]
      sd_idx   = seg.direction == 0 ? ld.front_sidedef_index : ld.back_sidedef_index
      sector   = @map.sectors[@map.sidedefs[sd_idx].sector_index]
      sector.floor_height + (player.view_height || EYE_HEIGHT) + (player.bob || 0.0)
    end

    def render_seg(fb, seg, linedef, player, cos_a, sin_a, eye_y, top_clip, bot_clip, visplanes)
      v1 = @map.vertexes[seg.start_vertex_index]
      v2 = @map.vertexes[seg.end_vertex_index]

      # Backface cull. Cross of (v2-v1) × (player-v1): positive means
      # player is on the seg's left (back) side.
      cross = (v2.x - v1.x) * (player.y - v1.y) -
              (v2.y - v1.y) * (player.x - v1.x)
      return 0 if cross >= 0

      front_sd_idx = seg.direction == 0 ? linedef.front_sidedef_index : linedef.back_sidedef_index
      back_sd_idx  = seg.direction == 0 ? linedef.back_sidedef_index  : linedef.front_sidedef_index
      front_sd     = @map.sidedefs[front_sd_idx]
      front_sector = @map.sectors[front_sd.sector_index]

      back_sd      = nil
      back_sector  = nil
      if linedef.two_sided?
        back_sd     = @map.sidedefs[back_sd_idx]
        back_sector = @map.sectors[back_sd.sector_index]
      end

      proj = project_seg(v1, v2, player, cos_a, sin_a, seg.offset)
      return 0 unless proj
      sx1, sx2, z1, z2, u1, u2 = proj

      col_start = sx1.ceil
      col_end   = sx2.floor
      col_start = 0                if col_start < 0
      col_end   = SCREEN_WIDTH - 1 if col_end   > SCREEN_WIDTH - 1
      return 0 if col_start > col_end

      front_ceil_world  = front_sector.ceiling_height
      front_floor_world = front_sector.floor_height
      back_ceil_world   = back_sector  && back_sector.ceiling_height
      back_floor_world  = back_sector  && back_sector.floor_height

      has_upper = back_sector && back_ceil_world  < front_ceil_world
      has_lower = back_sector && back_floor_world > front_floor_world

      mid_tex   = back_sector ? nil : texture_for(front_sd.middle_texture)
      upper_tex = has_upper   ? texture_for(front_sd.upper_texture) : nil
      lower_tex = has_lower   ? texture_for(front_sd.lower_texture) : nil

      ceiling_flat      = flat_for(front_sector.ceiling_texture)
      floor_flat        = flat_for(front_sector.floor_texture)
      back_ceiling_flat = back_sector && flat_for(back_sector.ceiling_texture)

      # DOOM "sky hack": when an upper texture would sit between two
      # sky-ceiling sectors, don't draw it — show sky through instead.
      # That's what makes outdoor walls feel infinitely tall.
      sky_hack_upper = has_upper && ceiling_flat&.sky? && back_ceiling_flat&.sky?

      mid_top_world =
        if mid_tex
          linedef.lower_unpegged? ? front_floor_world + mid_tex.height : front_ceil_world
        end
      upper_top_world =
        if upper_tex
          linedef.upper_unpegged? ? front_ceil_world : back_ceil_world + upper_tex.height
        end
      lower_top_world =
        if lower_tex
          linedef.lower_unpegged? ? front_ceil_world : back_floor_world
        end

      x_offset = front_sd.x_offset
      y_offset = front_sd.y_offset
      light    = front_sector.light_level

      # DOOM "fake contrast": vertical (N–S) walls render one light step
      # brighter, horizontal (E–W) walls one step darker. Adds a lot of
      # visual variety to flat-lit corridors.
      contrast = if    v1.x == v2.x then  1
                 elsif v1.y == v2.y then -1
                 else                     0
                 end

      ceil_front_rel  = front_ceil_world  - eye_y
      floor_front_rel = front_floor_world - eye_y
      ceil_back_rel   = back_sector  && back_ceil_world  - eye_y
      floor_back_rel  = back_sector  && back_floor_world - eye_y

      base_color = wall_base_color(front_sd.sector_index, front_sector)

      inv_z1   = 1.0 / z1
      inv_z2   = 1.0 / z2
      span_x   = sx2 - sx1
      span_x   = 1e-6 if span_x.abs < 1e-6
      uoz1     = u1 * inv_z1
      uoz2     = u2 * inv_z2

      newly_closed = 0
      x = col_start
      while x <= col_end
        if top_clip[x] <= bot_clip[x]
          t     = (x - sx1) / span_x
          inv_z = inv_z1 + (inv_z2 - inv_z1) * t
          z     = 1.0 / inv_z
          u     = (uoz1 + (uoz2 - uoz1) * t) * z
          tex_u = u + x_offset

          if back_sector
            newly_closed += render_two_sided_column(
              fb, x, z, tex_u, y_offset, light, contrast,
              ceil_front_rel, floor_front_rel,
              ceil_back_rel,  floor_back_rel,
              has_upper, has_lower,
              upper_tex, upper_top_world,
              lower_tex, lower_top_world,
              front_ceil_world, front_floor_world,
              ceiling_flat, floor_flat,
              eye_y, base_color,
              top_clip, bot_clip, visplanes,
              sky_hack_upper,
            )
          else
            newly_closed += render_solid_column(
              fb, x, z, tex_u, y_offset, light, contrast,
              ceil_front_rel, floor_front_rel,
              mid_tex, mid_top_world,
              front_ceil_world, front_floor_world,
              ceiling_flat, floor_flat,
              eye_y, base_color,
              top_clip, bot_clip, visplanes,
            )
          end
        end
        x += 1
      end

      newly_closed
    end

    def render_solid_column(fb, x, z, tex_u, y_offset, light, contrast,
                            ceil_rel, floor_rel,
                            texture, tex_top_world,
                            ceil_world, floor_world,
                            ceiling_flat, floor_flat,
                            eye_y, base_color,
                            top_clip, bot_clip, visplanes)
      sy_top    = (HALF_HEIGHT - ceil_rel  * FOCAL_LENGTH / z).ceil
      sy_bottom = (HALF_HEIGHT - floor_rel * FOCAL_LENGTH / z).floor

      emit_visplane_spans(visplanes, x, top_clip, bot_clip,
                          sy_top, sy_bottom,
                          ceiling_flat, ceil_world,
                          floor_flat,   floor_world,
                          light)

      y_top    = sy_top    < top_clip[x] ? top_clip[x] : sy_top
      y_bottom = sy_bottom > bot_clip[x] ? bot_clip[x] : sy_bottom

      if y_top <= y_bottom
        if texture
          fill_textured_column(fb, x, y_top, y_bottom, z, tex_u, y_offset,
                               texture, tex_top_world, eye_y, light, contrast)
        else
          r, g, b = shade_color(base_color, light, z)
          fb.fill_vertical_line(x, y_top, y_bottom, r, g, b)
        end
      end

      top_clip[x] = bot_clip[x] + 1
      1
    end

    def render_two_sided_column(fb, x, z, tex_u, y_offset, light, contrast,
                                ceil_front_rel, floor_front_rel,
                                ceil_back_rel,  floor_back_rel,
                                has_upper, has_lower,
                                upper_tex, upper_top_world,
                                lower_tex, lower_top_world,
                                ceil_world, floor_world,
                                ceiling_flat, floor_flat,
                                eye_y, base_color,
                                top_clip, bot_clip, visplanes,
                                sky_hack_upper)
      sy_front_ceil  = (HALF_HEIGHT - ceil_front_rel  * FOCAL_LENGTH / z).ceil
      sy_front_floor = (HALF_HEIGHT - floor_front_rel * FOCAL_LENGTH / z).floor

      emit_visplane_spans(visplanes, x, top_clip, bot_clip,
                          sy_front_ceil, sy_front_floor,
                          ceiling_flat, ceil_world,
                          floor_flat,   floor_world,
                          light)

      # Push clip past front ceiling / floor so the upper / lower drawing
      # below uses the right base.
      top_clip[x] = sy_front_ceil  if sy_front_ceil  > top_clip[x]
      bot_clip[x] = sy_front_floor if sy_front_floor < bot_clip[x]

      if has_upper
        sy_back_ceil = (HALF_HEIGHT - ceil_back_rel * FOCAL_LENGTH / z).floor
        y_top    = top_clip[x]
        y_bottom = sy_back_ceil > bot_clip[x] ? bot_clip[x] : sy_back_ceil
        if y_top <= y_bottom
          if sky_hack_upper
            if @sky
              @sky.fill_column(fb, x, y_top, y_bottom,
                               @player_angle_deg, HALF_WIDTH, FOCAL_LENGTH, @palette)
            else
              fb.fill_vertical_line(x, y_top, y_bottom, *SKY_COLOR)
            end
          elsif upper_tex
            fill_textured_column(fb, x, y_top, y_bottom, z, tex_u, y_offset,
                                 upper_tex, upper_top_world, eye_y, light, contrast)
          else
            r, g, b = shade_color(base_color, light, z)
            fb.fill_vertical_line(x, y_top, y_bottom, r, g, b)
          end
          new_top = sy_back_ceil + 1
          top_clip[x] = new_top if new_top > top_clip[x]
        end
      end

      if has_lower
        sy_back_floor = (HALF_HEIGHT - floor_back_rel * FOCAL_LENGTH / z).ceil
        y_top    = sy_back_floor < top_clip[x] ? top_clip[x] : sy_back_floor
        y_bottom = bot_clip[x]
        if y_top <= y_bottom
          if lower_tex
            fill_textured_column(fb, x, y_top, y_bottom, z, tex_u, y_offset,
                                 lower_tex, lower_top_world, eye_y, light, contrast)
          else
            r, g, b = shade_color(base_color, light, z)
            fb.fill_vertical_line(x, y_top, y_bottom, r, g, b)
          end
          new_bot = sy_back_floor - 1
          bot_clip[x] = new_bot if new_bot < bot_clip[x]
        end
      end

      top_clip[x] > bot_clip[x] ? 1 : 0
    end

    def emit_visplane_spans(visplanes, x, top_clip, bot_clip,
                            sy_front_ceil, sy_front_floor,
                            ceiling_flat, ceil_world,
                            floor_flat, floor_world, light)
      ceil_top = top_clip[x]
      ceil_bot = sy_front_ceil - 1
      ceil_bot = bot_clip[x] if ceil_bot > bot_clip[x]
      if ceiling_flat && ceil_top <= ceil_bot
        visplanes.add_span(ceiling_flat, ceil_world, light, true,
                           x, ceil_top, ceil_bot)
      end

      floor_top = sy_front_floor + 1
      floor_top = top_clip[x] if floor_top < top_clip[x]
      floor_bot = bot_clip[x]
      if floor_flat && floor_top <= floor_bot
        visplanes.add_span(floor_flat, floor_world, light, false,
                           x, floor_top, floor_bot)
      end
    end

    def fill_textured_column(fb, x, sy_top, sy_bottom, z, tex_u, y_offset,
                             texture, tex_top_world, eye_y, light, contrast)
      tex_w    = texture.width
      tex_h    = texture.height
      col_data = texture.columns[tex_u.floor % tex_w]

      step_v   = z / FOCAL_LENGTH
      tex_top_rel = tex_top_world - eye_y
      v        = tex_top_rel - (HALF_HEIGHT - sy_top) * step_v + y_offset

      # Z is constant across this wall column, so the colormap row is
      # too — pick it once.
      row = @colormap.row_for(light, contrast, z)

      sy = sy_top
      while sy <= sy_bottom
        idx = col_data[v.floor % tex_h]
        if idx && idx >= 0
          rgb = @colormap.shaded(row, idx)
          fb.set_pixel(x, sy, rgb[0], rgb[1], rgb[2])
        end
        v  += step_v
        sy += 1
      end
    end

    def project_seg(v1, v2, player, cos_a, sin_a, seg_offset)
      dx1 = v1.x - player.x; dy1 = v1.y - player.y
      dx2 = v2.x - player.x; dy2 = v2.y - player.y
      z1  =  dx1 * cos_a + dy1 * sin_a
      cx1 =  dx1 * sin_a - dy1 * cos_a
      z2  =  dx2 * cos_a + dy2 * sin_a
      cx2 =  dx2 * sin_a - dy2 * cos_a

      return nil if z1 < NEAR_Z && z2 < NEAR_Z

      seg_length = Math.sqrt((v2.x - v1.x)**2 + (v2.y - v1.y)**2)
      u1 = seg_offset.to_f
      u2 = u1 + seg_length

      if z1 < NEAR_Z
        t   = (NEAR_Z - z1) / (z2 - z1)
        cx1 = cx1 + t * (cx2 - cx1)
        u1  = u1  + t * (u2  - u1)
        z1  = NEAR_Z
      elsif z2 < NEAR_Z
        t   = (NEAR_Z - z2) / (z1 - z2)
        cx2 = cx2 + t * (cx1 - cx2)
        u2  = u2  + t * (u1  - u2)
        z2  = NEAR_Z
      end

      sx1 = HALF_WIDTH + (cx1 / z1) * FOCAL_LENGTH
      sx2 = HALF_WIDTH + (cx2 / z2) * FOCAL_LENGTH

      if sx1 > sx2
        sx1, sx2 = sx2, sx1
        z1,  z2  = z2,  z1
        u1,  u2  = u2,  u1
      end

      [sx1, sx2, z1, z2, u1, u2]
    end

    # ----- Visplane rasterization -----

    def draw_visplanes(fb, visplanes, eye_y, player, cos_a, sin_a)
      visplanes.each_plane do |plane|
        next if plane.flat.sky?
        draw_plane(fb, plane, eye_y, player, cos_a, sin_a)
      end
    end

    def draw_plane(fb, plane, eye_y, player, cos_a, sin_a)
      pixels    = plane.flat.pixels
      cols      = plane.columns
      ceiling   = plane.ceiling
      light     = plane.light
      dy_world  = (plane.height - eye_y).abs
      return if dy_world < 0.5

      min_top = nil
      max_bot = nil
      cols.each do |list|
        next unless list
        list.each do |range|
          min_top = range[0] if min_top.nil? || range[0] < min_top
          max_bot = range[1] if max_bot.nil? || range[1] > max_bot
        end
      end
      return unless min_top

      sy = min_top
      while sy <= max_bot
        sy_offset = ceiling ? (HALF_HEIGHT - sy) : (sy - HALF_HEIGHT)
        if sy_offset <= 0
          sy += 1
          next
        end

        z      = dy_world * FOCAL_LENGTH / sy_offset
        scale  = z / FOCAL_LENGTH

        base_world_x = player.x + z * cos_a
        base_world_y = player.y + z * sin_a
        step_x       = scale * sin_a
        step_y       = -scale * cos_a

        # Z is constant for this row of the visplane, so colormap row
        # is too. Visplanes don't get fake contrast — that's a
        # wall-only trick.
        row = @colormap.row_for(light, 0, z)

        sx = 0
        while sx < SCREEN_WIDTH
          while sx < SCREEN_WIDTH
            break if column_covers?(cols[sx], sy)
            sx += 1
          end
          break if sx >= SCREEN_WIDTH

          run_start = sx
          while sx < SCREEN_WIDTH
            break unless column_covers?(cols[sx], sy)
            sx += 1
          end
          run_end = sx - 1

          world_x = base_world_x + (run_start - HALF_WIDTH) * step_x
          world_y = base_world_y + (run_start - HALF_WIDTH) * step_y
          sxi = run_start
          while sxi <= run_end
            idx = pixels.getbyte(((world_y.floor & 63) << 6) | (world_x.floor & 63))
            rgb = @colormap.shaded(row, idx)
            fb.set_pixel(sxi, sy, rgb[0], rgb[1], rgb[2])
            world_x += step_x
            world_y += step_y
            sxi += 1
          end
        end

        sy += 1
      end
    end

    def column_covers?(list, sy)
      return false unless list
      list.each do |range|
        return true if range[0] <= sy && sy <= range[1]
      end
      false
    end

    # ----- helpers -----

    def texture_for(name)
      return nil unless @textures
      @textures[name]
    end

    def flat_for(name)
      return nil unless @flats
      @flats[name]
    end

    def shade_color(base_color, light, z)
      f = light_factor(light) * distance_factor(z)
      f = MIN_LIGHT if f < MIN_LIGHT
      [(base_color[0] * f).to_i,
       (base_color[1] * f).to_i,
       (base_color[2] * f).to_i]
    end

    def light_factor(light_level)
      light_level / 255.0
    end

    def distance_factor(z)
      1.0 / (1.0 + z * 0.005)
    end

    # Throwaway color scheme for missing wall textures: low-saturation hue
    # from sector index, value driven by light_level.
    def wall_base_color(sector_idx, sector)
      hue   = (sector_idx * 53) % 360
      value = 0.4 + (sector.light_level / 255.0) * 0.6
      hsv_to_rgb(hue, 0.35, value)
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
  end
end
