module Rubydoom
  # DOOM sky rendering.
  #
  # The sky is a 256×128 wall-style texture mapped onto an imaginary
  # cylinder around the player: 90° of player rotation maps to one full
  # texture width. With FOV=90° that means the FOV spans one full
  # texture cycle, with the seam landing at the screen centre — which
  # is fine because the sky textures are designed to tile horizontally.
  #
  # Sky pixels render at full bright (no colormap shading), and the
  # vertical mapping is direct: screen row N samples texture row N.
  #
  # Texture name comes from the map name: SKY1 for E1Mx (Knee-Deep),
  # SKY2 for E2 (Shores of Hell), SKY3 for E3 (Inferno), SKY4 for E4
  # (Thy Flesh Consumed). DOOM 2 uses RSKY1/2/3 keyed by map number;
  # we don't worry about that here.
  class Sky
    DEFAULT_NAME = "SKY1"

    def self.for_map(map_name, textures)
      name =
        case map_name.to_s.upcase
        when /\AE1M\d/ then "SKY1"
        when /\AE2M\d/ then "SKY2"
        when /\AE3M\d/ then "SKY3"
        when /\AE4M\d/ then "SKY4"
        else DEFAULT_NAME
        end
      tex = textures && textures[name]
      tex && new(tex)
    end

    def initialize(texture)
      @texture = texture
      @tex_w   = texture.width
      @tex_h   = texture.height
    end

    # Fill column x of the framebuffer between sy_top..sy_bottom with
    # the appropriate sky pixels for the player's current facing.
    # focal_length / half_width come from the renderer so we don't
    # hard-code its constants here.
    def fill_column(fb, x, sy_top, sy_bottom, player_angle_deg,
                    half_width, focal_length, palette)
      cam_x  = x - half_width
      offset = Math.atan2(cam_x, focal_length) * 180.0 / Math::PI
      world  = player_angle_deg - offset
      # 90° = one full texture cycle. floor and modulo so the texture
      # tiles cleanly across the seam at screen centre.
      u = (world * @tex_w / 90.0).floor % @tex_w
      col_data = @texture.columns[u]
      pal = palette.colors

      sy = sy_top
      while sy <= sy_bottom
        idx = col_data[sy % @tex_h]
        if idx && idx >= 0
          rgb = pal[idx]
          fb.set_pixel(x, sy, rgb[0], rgb[1], rgb[2])
        end
        sy += 1
      end
    end
  end
end
