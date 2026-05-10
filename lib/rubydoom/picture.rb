module Rubydoom
  # A "picture" (DOOM's term: patch) is the column-major graphic format used
  # for sprites, wall patches, HUD elements, and most menu graphics.
  #
  # Format:
  #   header:  width[u16], height[u16], left_offset[i16], top_offset[i16]
  #   then:    width * column_offset[u32]   (offsets from start of patch lump)
  #   each column at its offset is a series of "posts":
  #     post:  topdelta[u8], length[u8], unused[u8],
  #            length * pixel[u8],
  #            unused[u8]
  #     A topdelta of 0xFF terminates the column.
  #
  # Pixels are palette indices. Anywhere a column has no post, the pixel is
  # transparent — we represent that with TRANSPARENT (-1).
  #
  # Note: "tall patches" (>=256 pixels) reinterpret topdelta as a delta
  # relative to the previous post. We don't need that for HUD graphics, so
  # we ignore it for now.
  class Picture
    TRANSPARENT = -1
    POST_TERMINATOR = 0xFF

    attr_reader :width, :height, :left_offset, :top_offset, :pixels

    def self.parse(bytes)
      width, height, left_offset, top_offset = bytes.unpack("v v s< s<")
      column_offsets = bytes[8, width * 4].unpack("V*")

      pixels = Array.new(height) { Array.new(width, TRANSPARENT) }

      width.times do |x|
        cursor = column_offsets[x]
        loop do
          topdelta = bytes.getbyte(cursor)
          break if topdelta == POST_TERMINATOR

          length = bytes.getbyte(cursor + 1)
          # cursor + 2 is an unused padding byte
          length.times do |i|
            y = topdelta + i
            pixels[y][x] = bytes.getbyte(cursor + 3 + i) if y < height
          end
          cursor += length + 4
        end
      end

      new(
        width: width, height: height,
        left_offset: left_offset, top_offset: top_offset,
        pixels: pixels,
      )
    end

    def initialize(width:, height:, left_offset:, top_offset:, pixels:)
      @width = width
      @height = height
      @left_offset = left_offset
      @top_offset = top_offset
      @pixels = pixels
    end

    # Returns an RGBA byte string (width * height * 4 bytes).
    def to_rgba(palette)
      buf = String.new(capacity: @width * @height * 4, encoding: Encoding::ASCII_8BIT)
      transparent = TRANSPARENT
      @pixels.each do |row|
        row.each do |index|
          if index == transparent
            buf << "\x00\x00\x00\x00".b
          else
            r, g, b = palette[index]
            buf << r.chr << g.chr << b.chr << "\xFF".b
          end
        end
      end
      buf
    end
  end
end
