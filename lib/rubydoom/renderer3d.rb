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

    # Per-seg record built during the wall pass so sprites and masked
    # midtex can clip against any wall in front of them. Mirrors vanilla
    # DOOM's `drawseg_t`: x1/x2 are the screen column range, scale1/2
    # are 1/cam_z * FOCAL_LENGTH at those columns (for depth comparison
    # via lerp). For one-sided walls `solid` is true and clip endpoints
    # are nil. For two-sided segs clip_top1/2 and clip_bot1/2 mark the
    # screen y of the PORTAL OPENING: clip_top = lower of (front_ceil,
    # back_ceil), clip_bot = higher of (front_floor, back_floor). Anything
    # outside this y range at the seg's columns is occluded by the front
    # sector's floor / ceiling visplane (visible across the gap) or by
    # the back-sector step wall.
    DrawSeg = Struct.new(:x1, :x2, :scale1, :scale2,
                         :solid,
                         :clip_top1, :clip_top2,
                         :clip_bot1, :clip_bot2)

    # Masked middle texture on a two-sided linedef. DOOM uses these as
    # transparent fences / grates (e.g. BRNBIGC bar grates in E1M1).
    # Front and back sectors are usually identical, so there's no
    # upper/lower step for the regular wall pass to draw — the midtex
    # is the only visible thing. Rendered after sprites with per-column
    # depth clipping against @drawsegs.
    MaskedSeg = Struct.new(:texture, :x1, :x2, :sx1, :span_x,
                           :inv_z1, :inv_z2, :uoz1, :uoz2,
                           :x_offset, :y_offset, :tex_top_world,
                           :portal_top_world, :portal_bot_world,
                           :light, :contrast,
                           keyword_init: true)

    VisSprite = Struct.new(:cam_z, :cam_x, :pic, :mirrored, :thing,
                           keyword_init: true)

    # Exposed for headless benchmarks: after a draw(present: false) the
    # pure-Ruby RGBA buffer is reachable here so callers can shasum it
    # without going through Gosu.
    attr_reader :framebuffer

    def initialize(map, bsp, textures: nil, flats: nil, palette: nil,
                   colormap: nil, sky: nil, sprites: nil)
      @map      = map
      @bsp      = bsp
      @textures = textures
      @flats    = flats
      @palette  = palette
      @colormap = colormap
      @sky      = sky
      @sprites  = sprites
      # Per-renderer persistent framebuffer. Allocating it fresh every
      # frame is ~163KB of String per tick — the dominant GC source
      # before pooling. We just clear() in place at the top of draw().
      @fb         = Framebuffer.new(SCREEN_WIDTH, PLAYFIELD_HEIGHT)
      @framebuffer = @fb  # public alias for headless callers
      # Same idea for the per-column clipping arrays and the drawseg /
      # masked-seg lists. These were small but allocated every frame;
      # reusing them takes another bite out of GC.
      @top_clip    = Array.new(SCREEN_WIDTH, 0)
      @bot_clip    = Array.new(SCREEN_WIDTH, PLAYFIELD_HEIGHT - 1)
      @drawsegs    = []
      @masked_segs = []
      # Row-major span scratchpad for visplane rasterization. Each
      # entry is a flat array of [x_start, x_end, x_start', x_end', ...]
      # pairs of inclusive x ranges, built once per plane in column-
      # ascending order so adjacent columns extend the previous pair
      # in place. Cleared and reused for every plane.
      @row_spans   = Array.new(PLAYFIELD_HEIGHT) { [] }
    end

    # `present: false` runs everything except the final GPU upload —
    # used by the headless benchmark so we measure Ruby work alone
    # (no GL context, no Gosu::Image allocation, no vsync). The pixel
    # buffer is still fully written; reach it via `#framebuffer`.
    def draw(player, present: true)
      fb = @fb
      @player_angle_deg = player.angle
      # Sky pre-fill on the upper half: anything ceiling-visplane-shaped
      # that doesn't get emitted (because a near seg projects off-screen
      # at extreme angles) still reads as "looking up" rather than as a
      # HOM hole. Walls and other visplanes overdraw normally. The
      # collision keeps the player ≥ PLAYER_RADIUS from every wall, so
      # in normal play this pre-fill is fully overwritten. ENV-var
      # debug positions can squeeze the camera into walls and may show
      # sky bleed there — known limitation, see TODO.
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

      top_clip   = @top_clip
      bot_clip   = @bot_clip
      top_clip.fill(0)
      bot_clip.fill(PLAYFIELD_HEIGHT - 1)
      visplanes  = Visplanes.new(SCREEN_WIDTH)
      @drawsegs.clear
      @masked_segs.clear
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
      draw_masked(fb, player, cos_a, sin_a, eye_y)

      fb.to_gosu_image.draw(0, 0, Z) if present
    end

    private

    def compute_eye_y(player)
      sector = sector_at(player.x, player.y)
      sector.floor_height + (player.view_height || EYE_HEIGHT) + (player.bob || 0.0)
    end

    def sector_at(x, y)
      ssec_idx = @bsp.subsector_at(x, y)
      ssec     = @map.subsectors[ssec_idx]
      seg      = @map.segs[ssec.first_seg_index]
      ld       = @map.linedefs[seg.linedef_index]
      sd_idx   = seg.direction == 0 ? ld.front_sidedef_index : ld.back_sidedef_index
      @map.sectors[@map.sidedefs[sd_idx].sector_index]
    end

    # Masked pass: sprites (billboards) and masked midtex (transparent
    # fences) drawn in a single back-to-front order so a sprite in
    # front of a grate correctly paints over the grate, and vice
    # versa. Per-column wall clipping against @drawsegs happens inside
    # each item's draw routine; that handles wall occlusion. The sort
    # here just resolves overlap between the masked items themselves.
    def draw_masked(fb, player, cos_a, sin_a, eye_y)
      vissprites = gather_vissprites(player, cos_a, sin_a)
      return if vissprites.empty? && @masked_segs.empty?

      items = []
      vissprites.each { |vs| items << [vs.cam_z, :sprite, vs] }
      @masked_segs.each do |ms|
        avg_cam_z = 0.5 * (1.0 / ms.inv_z1 + 1.0 / ms.inv_z2)
        items << [avg_cam_z, :masked, ms]
      end

      items.sort_by! { |it| -it[0] }
      items.each do |_, kind, payload|
        if kind == :sprite
          draw_billboard(fb, payload.pic, payload.mirrored,
                         payload.cam_x, payload.cam_z, payload.thing, eye_y)
        else
          draw_masked_seg(fb, payload, eye_y)
        end
      end
    end

    def gather_vissprites(player, cos_a, sin_a)
      return [] unless @sprites
      out = []
      @map.things.each do |thing|
        next if thing.removed
        spr, frm = sprite_lookup_for(thing)
        next unless spr
        frame = @sprites.frame_for(spr, frm)
        next unless frame

        dx = thing.x - player.x
        dy = thing.y - player.y
        cam_z =  dx * cos_a + dy * sin_a
        cam_x =  dx * sin_a - dy * cos_a
        next if cam_z < NEAR_Z

        pic, mirrored = pick_rotation(frame, thing, dx, dy)
        next unless pic

        out << VisSprite.new(cam_z: cam_z, cam_x: cam_x,
                             pic: pic, mirrored: mirrored, thing: thing)
      end
      out
    end

    # Sprite prefix + frame letter for a Thing — respects the runtime
    # overrides Combat uses for animated death sequences (barrel BEXP
    # cycle, monster death frames). Falls back to ThingTypes for the
    # static spawn-state sprite.
    def sprite_lookup_for(thing)
      if thing.sprite_override
        [thing.sprite_override, thing.frame_override || "A"]
      else
        info = ThingTypes[thing.type]
        info && [info.sprite, info.frame]
      end
    end

    # Vanilla R_ProjectSprite logic. ang = angle from camera to thing.
    # diff = (ang - thing.angle + 22.5°*9) mod 360°, divided by 45° to
    # quantize into 8 buckets (0..7); +1 to get the rotation digit
    # used in lump names (1..8). The +202.5° offset is what makes
    # rotation 1 = "thing facing the camera, we see its front".
    def pick_rotation(frame, thing, dx, dy)
      rotations = frame.rotations
      single    = rotations[0]
      return single if single

      ang  = Math.atan2(dy, dx) * 180.0 / Math::PI
      diff = (ang - thing.angle + 202.5) % 360
      idx  = (diff / 45.0).to_i
      rotations[1 + idx]
    end

    def draw_billboard(fb, pic, mirrored, cam_x, cam_z, thing, eye_y)
      sector  = sector_at(thing.x, thing.y)
      # Most things sit on the floor; projectiles supply an absolute
      # z via z_override so they render at the height they're flying at.
      thing_z = thing.z_override || sector.floor_height
      light   = sector.light_level

      scale     = FOCAL_LENGTH / cam_z
      inv_scale = cam_z / FOCAL_LENGTH

      sprite_top    = thing_z + pic.top_offset
      sprite_bottom = sprite_top - pic.height
      sy_top        = HALF_HEIGHT - (sprite_top    - eye_y) * scale
      sy_bottom     = HALF_HEIGHT - (sprite_bottom - eye_y) * scale

      cx_screen = HALF_WIDTH + (cam_x / cam_z) * FOCAL_LENGTH
      sx_left   = cx_screen - pic.left_offset * scale
      sx_right  = sx_left + pic.width * scale

      x_start = sx_left.ceil
      x_end   = sx_right.ceil - 1
      x_start = 0 if x_start < 0
      x_end   = SCREEN_WIDTH - 1 if x_end >= SCREEN_WIDTH
      return if x_start > x_end

      y_top_full = sy_top.ceil
      y_bot_full = sy_bottom.ceil - 1
      return if y_top_full > PLAYFIELD_HEIGHT - 1 || y_bot_full < 0

      # Build per-column clip bounds by walking the wall pass's drawseg
      # list. For each drawseg whose x range overlaps the sprite, lerp
      # its scale at this column and compare to the sprite's scale —
      # if the drawseg is closer (larger scale), apply its silhouette.
      spr_top, spr_bot = build_sprite_clip(scale, x_start, x_end)

      pal_colors = @palette ? @palette.colors : nil
      shade_row  = @colormap ? @colormap.row_for(light, 0, cam_z) : nil
      pixels     = pic.pixels
      pic_w      = pic.width
      pic_h      = pic.height

      x = x_start
      while x <= x_end
        clip_top = spr_top[x - x_start]
        clip_bot = spr_bot[x - x_start]
        if clip_top + 1 < clip_bot
          u = ((x - sx_left) * inv_scale).to_i
          if u >= 0 && u < pic_w
            uu = mirrored ? (pic_w - 1 - u) : u
            y  = y_top_full
            y  = clip_top + 1 if y < clip_top + 1
            y  = 0 if y < 0
            yend = y_bot_full
            yend = clip_bot - 1 if yend > clip_bot - 1
            yend = PLAYFIELD_HEIGHT - 1 if yend > PLAYFIELD_HEIGHT - 1
            while y <= yend
              v = ((y - sy_top) * inv_scale).to_i
              if v >= 0 && v < pic_h
                idx = pixels[v][uu]
                if idx && idx >= 0
                  if shade_row
                    r, g, b = @colormap.shaded(shade_row, idx)
                  else
                    r, g, b = pal_colors[idx]
                  end
                  fb.set_pixel(x, y, r, g, b)
                end
              end
              y += 1
            end
          end
        end
        x += 1
      end
    end

    # Returns (spr_top, spr_bot) pair of length (x_end-x_start+1).
    # `spr_top[i]` is "highest screen y the sprite must stay below at
    # column x_start+i" (sprite needs y > spr_top); spr_bot is the
    # opposite. Default no-clip: spr_top = -1, spr_bot = PLAYFIELD_HEIGHT.
    def build_sprite_clip(sp_scale, x_start, x_end)
      width   = x_end - x_start + 1
      spr_top = Array.new(width, -1)
      spr_bot = Array.new(width, PLAYFIELD_HEIGHT)

      @drawsegs.each do |ds|
        next if ds.x2 < x_start || ds.x1 > x_end
        ds_span = ds.x2 - ds.x1
        ds_span = 1 if ds_span == 0
        inv_span = 1.0 / ds_span

        ox_start = ds.x1 < x_start ? x_start : ds.x1
        ox_end   = ds.x2 > x_end   ? x_end   : ds.x2

        x = ox_start
        while x <= ox_end
          t = (x - ds.x1) * inv_span
          ds_scale = ds.scale1 + (ds.scale2 - ds.scale1) * t
          if ds_scale > sp_scale
            i = x - x_start
            if ds.solid
              spr_top[i] = PLAYFIELD_HEIGHT
              spr_bot[i] = -1
            else
              sy_t = (ds.clip_top1 + (ds.clip_top2 - ds.clip_top1) * t).floor
              spr_top[i] = sy_t if sy_t > spr_top[i]
              sy_b = (ds.clip_bot1 + (ds.clip_bot2 - ds.clip_bot1) * t).floor
              spr_bot[i] = sy_b if sy_b < spr_bot[i]
            end
          end
          x += 1
        end
      end

      [spr_top, spr_bot]
    end

    # Renders a single masked midtex seg. Per column: depth-clip against
    # @drawsegs (solid → skip, with silhouette → shrink y range), then
    # sample the texture column post-by-post so patch gaps show through.
    def draw_masked_seg(fb, ms, eye_y)
      texture = ms.texture
      tex_w   = texture.width
      tex_h   = texture.height
      cols    = texture.columns

      x = ms.x1
      while x <= ms.x2
        t     = (x - ms.sx1) / ms.span_x
        inv_z = ms.inv_z1 + (ms.inv_z2 - ms.inv_z1) * t
        z     = 1.0 / inv_z
        scale = inv_z * FOCAL_LENGTH

        occluded = false
        sil_top  = -1
        sil_bot  = PLAYFIELD_HEIGHT
        @drawsegs.each do |ds|
          next if ds.x2 < x || ds.x1 > x
          ds_span = ds.x2 - ds.x1
          ds_span = 1 if ds_span == 0
          ds_t    = (x - ds.x1).to_f / ds_span
          ds_scale = ds.scale1 + (ds.scale2 - ds.scale1) * ds_t
          next unless ds_scale > scale
          if ds.solid
            occluded = true
            break
          end
          sy_t = (ds.clip_top1 + (ds.clip_top2 - ds.clip_top1) * ds_t).floor
          sil_top = sy_t if sy_t > sil_top
          sy_b = (ds.clip_bot1 + (ds.clip_bot2 - ds.clip_bot1) * ds_t).floor
          sil_bot = sy_b if sy_b < sil_bot
        end
        if occluded
          x += 1
          next
        end

        sy_top_screen   = (HALF_HEIGHT - (ms.tex_top_world    - eye_y) * scale).ceil
        sy_portal_top   = (HALF_HEIGHT - (ms.portal_top_world - eye_y) * scale).ceil
        sy_portal_bot   = (HALF_HEIGHT - (ms.portal_bot_world - eye_y) * scale).floor

        y_top = sy_top_screen
        y_top = sy_portal_top if y_top < sy_portal_top
        y_top = sil_top + 1   if y_top < sil_top + 1
        y_top = 0             if y_top < 0

        y_bot = sy_top_screen + (tex_h * scale).to_i - 1
        y_bot = sy_portal_bot if y_bot > sy_portal_bot
        y_bot = sil_bot - 1   if y_bot > sil_bot - 1
        y_bot = PLAYFIELD_HEIGHT - 1 if y_bot > PLAYFIELD_HEIGHT - 1

        if y_top <= y_bot
          u   = (ms.uoz1 + (ms.uoz2 - ms.uoz1) * t) * z + ms.x_offset
          col = cols[u.floor % tex_w]

          step_v = z / FOCAL_LENGTH
          v      = (ms.tex_top_world - eye_y) - (HALF_HEIGHT - y_top) * step_v + ms.y_offset

          row = @colormap.row_for(ms.light, ms.contrast, z)

          sy = y_top
          while sy <= y_bot
            v_int = v.floor
            if v_int >= 0 && v_int < tex_h
              idx = col[v_int]
              if idx && idx >= 0
                rgb = @colormap.shaded(row, idx)
                fb.set_pixel(x, sy, rgb[0], rgb[1], rgb[2])
              end
            end
            v  += step_v
            sy += 1
          end
        end

        x += 1
      end
    end

    # Builds a DrawSeg from a seg that's about to be rendered.
    # Silhouette endpoints are computed at the integer column boundaries
    # (col_start..col_end) using the same 1/z lerp as the wall sampling,
    # so depth comparisons against sprites stay consistent.
    def record_drawseg(col_start, col_end, sx1, span_x, inv_z1, inv_z2,
                       back_sector,
                       back_ceil_world,  front_ceil_world,
                       back_floor_world, front_floor_world,
                       eye_y)
      t1 = (col_start - sx1) / span_x
      t2 = (col_end   - sx1) / span_x
      inv_z_x1 = inv_z1 + (inv_z2 - inv_z1) * t1
      inv_z_x2 = inv_z1 + (inv_z2 - inv_z1) * t2
      scale1   = inv_z_x1 * FOCAL_LENGTH
      scale2   = inv_z_x2 * FOCAL_LENGTH

      if back_sector.nil?
        @drawsegs << DrawSeg.new(col_start, col_end, scale1, scale2,
                                 true, nil, nil, nil, nil)
        return
      end

      portal_top_world = front_ceil_world  < back_ceil_world  ? front_ceil_world  : back_ceil_world
      portal_bot_world = front_floor_world > back_floor_world ? front_floor_world : back_floor_world

      rel_top = portal_top_world - eye_y
      rel_bot = portal_bot_world - eye_y

      clip_top1 = (HALF_HEIGHT - rel_top * inv_z_x1 * FOCAL_LENGTH).floor
      clip_top2 = (HALF_HEIGHT - rel_top * inv_z_x2 * FOCAL_LENGTH).floor
      clip_bot1 = (HALF_HEIGHT - rel_bot * inv_z_x1 * FOCAL_LENGTH).ceil
      clip_bot2 = (HALF_HEIGHT - rel_bot * inv_z_x2 * FOCAL_LENGTH).ceil

      @drawsegs << DrawSeg.new(col_start, col_end, scale1, scale2,
                               false, clip_top1, clip_top2, clip_bot1, clip_bot2)
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

      record_drawseg(col_start, col_end, sx1, span_x, inv_z1, inv_z2,
                     back_sector,
                     back_ceil_world,  front_ceil_world,
                     back_floor_world, front_floor_world,
                     eye_y)

      if back_sector
        mid_name = front_sd.middle_texture
        if mid_name && mid_name != "-" && !mid_name.empty?
          masked_tex = texture_for(mid_name)
          if masked_tex
            portal_top = front_ceil_world  < back_ceil_world  ? front_ceil_world  : back_ceil_world
            portal_bot = front_floor_world > back_floor_world ? front_floor_world : back_floor_world
            masked_top_world = linedef.lower_unpegged? ?
                                 portal_bot + masked_tex.height :
                                 portal_top
            @masked_segs << MaskedSeg.new(
              texture:           masked_tex,
              x1:                col_start,
              x2:                col_end,
              sx1:               sx1,
              span_x:            span_x,
              inv_z1:            inv_z1,
              inv_z2:            inv_z2,
              uoz1:              uoz1,
              uoz2:              uoz2,
              x_offset:          x_offset,
              y_offset:          y_offset,
              tex_top_world:     masked_top_world,
              portal_top_world:  portal_top,
              portal_bot_world:  portal_bot,
              light:             light,
              contrast:          contrast,
            )
          end
        end
      end

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

      # Direct framebuffer write: hoist rgba string and per-row offset
      # increment out of the inner loop. set_pixel was a measurable
      # self-time hotspot at per-pixel granularity.
      rgba   = fb.rgba
      stride = SCREEN_WIDTH * 4
      offset = (sy_top * SCREEN_WIDTH + x) * 4

      sy = sy_top
      while sy <= sy_bottom
        idx = col_data[v.floor % tex_h]
        if idx && idx >= 0
          rgb = @colormap.shaded(row, idx)
          rgba.setbyte(offset,     rgb[0])
          rgba.setbyte(offset + 1, rgb[1])
          rgba.setbyte(offset + 2, rgb[2])
          rgba.setbyte(offset + 3, 255)
        end
        v      += step_v
        sy     += 1
        offset += stride
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
        if plane.flat.sky?
          draw_sky_plane(fb, plane)
        else
          draw_plane(fb, plane, eye_y, player, cos_a, sin_a)
        end
      end
    end

    # Sky planes don't get the floor/ceiling rasterizer — they're
    # drawn column-by-column using the sky texture, indexed by the
    # player's view angle. The accumulated `plane.columns` already
    # encodes exactly the columns and y-ranges that should show sky;
    # we just iterate them.
    def draw_sky_plane(fb, plane)
      return unless @sky
      cols = plane.columns
      sx = 0
      while sx < SCREEN_WIDTH
        list = cols[sx]
        if list
          list.each do |range|
            @sky.fill_column(fb, sx, range[0], range[1],
                             @player_angle_deg, HALF_WIDTH, FOCAL_LENGTH, @palette)
          end
        end
        sx += 1
      end
    end

    # Visplane rasterizer. Row-major: walk plane.columns once to
    # materialize per-row span lists, then iterate rows and emit
    # contiguous x-runs directly into the framebuffer's underlying
    # byte string. No column_covers? scan in the inner loop, no
    # fb.set_pixel call per pixel — both were sizable self-time
    # contributors before this pass.
    def draw_plane(fb, plane, eye_y, player, cos_a, sin_a)
      pixels   = plane.flat.pixels
      ceiling  = plane.ceiling
      light    = plane.light
      dy_world = (plane.height - eye_y).abs
      return if dy_world < 0.5

      rows = @row_spans
      min_sy, max_sy = build_row_spans!(plane, rows)
      return if min_sy.nil?

      rgba   = fb.rgba
      stride = SCREEN_WIDTH * 4

      sy = min_sy
      while sy <= max_sy
        spans = rows[sy]
        if spans.empty?
          sy += 1
          next
        end

        sy_offset = ceiling ? (HALF_HEIGHT - sy) : (sy - HALF_HEIGHT)
        if sy_offset <= 0
          sy += 1
          next
        end

        z     = dy_world * FOCAL_LENGTH / sy_offset
        scale = z / FOCAL_LENGTH

        base_world_x = player.x + z * cos_a
        base_world_y = player.y + z * sin_a
        step_x       = scale * sin_a
        step_y       = -scale * cos_a

        # Z is constant across this whole row, so the colormap row is
        # too. Visplanes don't get fake contrast — that's a wall-only
        # trick.
        row_idx = @colormap.row_for(light, 0, z)

        sy_stride = sy * stride
        i = 0
        n = spans.length
        while i < n
          run_start = spans[i]
          run_end   = spans[i + 1]
          i += 2

          world_x = base_world_x + (run_start - HALF_WIDTH) * step_x
          world_y = base_world_y + (run_start - HALF_WIDTH) * step_y

          offset = sy_stride + run_start * 4
          sxi    = run_start
          while sxi <= run_end
            idx = pixels.getbyte(((world_y.floor & 63) << 6) | (world_x.floor & 63))
            rgb = @colormap.shaded(row_idx, idx)
            rgba.setbyte(offset,     rgb[0])
            rgba.setbyte(offset + 1, rgb[1])
            rgba.setbyte(offset + 2, rgb[2])
            rgba.setbyte(offset + 3, 255)
            world_x += step_x
            world_y += step_y
            sxi    += 1
            offset += 4
          end
        end

        sy += 1
      end
    end

    # Convert a plane's column-major coverage list into the supplied
    # row-major scratchpad. Each rows[sy] becomes a flat array
    # [x1, x2, x1', x2', ...] of inclusive x ranges in column-ascending
    # order. Adjacent columns extend the open run in place, so the
    # common contiguous case is one pair per row. Returns [min_sy,
    # max_sy] across all covered rows, or [nil, nil] if empty.
    def build_row_spans!(plane, rows)
      cols   = plane.columns
      min_sy = nil
      max_sy = nil

      # Reset only the rows we know we'll touch — clearing all
      # PLAYFIELD_HEIGHT every plane is fine (it's just nil-out on
      # short arrays) but it's cheaper to track dirty rows for the
      # next plane. We do clear everything here for simplicity; the
      # cost is negligible compared to the rasterizer.
      rows.each(&:clear)

      x = 0
      while x < SCREEN_WIDTH
        list = cols[x]
        if list
          list.each do |range|
            top = range[0]
            bot = range[1]
            sy = top
            while sy <= bot
              spans = rows[sy]
              if !spans.empty? && spans[-1] == x - 1
                spans[-1] = x       # extend run_end of the open pair
              else
                spans << x << x     # new pair [x, x]
              end
              sy += 1
            end
            min_sy = top if min_sy.nil? || top < min_sy
            max_sy = bot if max_sy.nil? || bot > max_sy
          end
        end
        x += 1
      end

      [min_sy, max_sy]
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
