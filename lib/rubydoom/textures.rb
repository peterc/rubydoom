module Rubydoom
  # A composed wall texture. Stored column-major and palette-indexed so
  # the wall renderer can do fast vertical sampling and so a future
  # COLORMAP-based lighting pass can remap palette indices in-place.
  #
  # columns[col][row] is a palette index 0..255, or -1 for transparent.
  # Most wall textures are fully opaque; transparency only matters for
  # midtex fences, switches with a transparent backing, etc.
  class Texture
    TRANSPARENT = -1

    attr_reader :name, :width, :height, :columns

    def initialize(name, width, height, columns)
      @name    = name
      @width   = width
      @height  = height
      @columns = columns
    end
  end

  # Parses TEXTURE1 / TEXTURE2 + PNAMES from a WAD and composes each
  # texture record into a Texture by stamping its constituent patches
  # into a (width × height) buffer at their (origin_x, origin_y) offsets.
  #
  # TEXTURE1 layout:
  #   header:    count[u32]
  #              count * offset[u32]   (file-relative offsets into TEXTURE1)
  #   record:    name[8], unused[4], width[u16], height[u16], unused[4],
  #              patchcount[u16],
  #              patchcount * { origin_x[i16], origin_y[i16],
  #                             pname_index[u16], unused[4] }
  #
  # PNAMES layout:
  #   count[u32], count * name[8]
  class Textures
    def initialize(wad, palette, graphics)
      @wad      = wad
      @palette  = palette
      @graphics = graphics
      @pnames   = parse_pnames
      @by_name  = {}
      parse_texture_lump("TEXTURE1") if @wad.lump("TEXTURE1")
      parse_texture_lump("TEXTURE2") if @wad.lump("TEXTURE2")
    end

    def [](name)
      key = name.to_s.upcase
      return nil if key.empty? || key == "-"
      @by_name[key]
    end

    def names
      @by_name.keys
    end

    private

    def parse_pnames
      bytes = @wad.bytes_for("PNAMES") or raise "WAD has no PNAMES lump"
      count = bytes.unpack1("V")
      Array.new(count) do |i|
        bytes.byteslice(4 + i * 8, 8).delete("\x00").upcase
      end
    end

    def parse_texture_lump(lump_name)
      bytes  = @wad.bytes_for(lump_name)
      count  = bytes.unpack1("V")
      record_offsets = bytes.byteslice(4, count * 4).unpack("V*")
      record_offsets.each do |off|
        tex = parse_texture_record(bytes, off)
        @by_name[tex.name] = tex if tex
      end
    end

    def parse_texture_record(bytes, off)
      name        = bytes.byteslice(off,      8).delete("\x00").upcase
      width       = bytes.byteslice(off + 12, 2).unpack1("v")
      height      = bytes.byteslice(off + 14, 2).unpack1("v")
      patch_count = bytes.byteslice(off + 20, 2).unpack1("v")

      patches    = []
      patch_off  = off + 22
      patch_count.times do
        ox    = bytes.byteslice(patch_off,     2).unpack1("s<")
        oy    = bytes.byteslice(patch_off + 2, 2).unpack1("s<")
        idx   = bytes.byteslice(patch_off + 4, 2).unpack1("v")
        patches << [ox, oy, @pnames[idx]]
        patch_off += 10
      end

      compose_texture(name, width, height, patches)
    end

    def compose_texture(name, width, height, patch_specs)
      columns = Array.new(width) { Array.new(height, Texture::TRANSPARENT) }

      patch_specs.each do |origin_x, origin_y, patch_name|
        next if patch_name.nil? || patch_name.empty?
        next unless @graphics.has?(patch_name)
        pic = @graphics.picture(patch_name)
        stamp_patch(columns, width, height, pic, origin_x, origin_y)
      end

      Texture.new(name, width, height, columns)
    end

    def stamp_patch(columns, tex_w, tex_h, pic, origin_x, origin_y)
      pic.width.times do |sx|
        dest_col = origin_x + sx
        next if dest_col < 0 || dest_col >= tex_w
        target = columns[dest_col]
        pic.height.times do |sy|
          dest_row = origin_y + sy
          next if dest_row < 0 || dest_row >= tex_h
          idx = pic.pixels[sy][sx]
          next if idx == Picture::TRANSPARENT
          target[dest_row] = idx
        end
      end
    end
  end
end
