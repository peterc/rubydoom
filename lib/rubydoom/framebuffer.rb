module Rubydoom
  # A plain RGBA pixel buffer with primitive drawing routines, intended
  # to be uploaded as a Gosu::Image via #to_gosu_image. Used for things
  # we want full pixel control over (automap, eventually the 3D wall
  # renderer) without fighting Gosu's GL line/quad primitives.
  class Framebuffer
    BYTES_PER_PIXEL = 4

    attr_reader :width, :height

    def initialize(width, height)
      @width  = width
      @height = height
      byte_count = width * height * BYTES_PER_PIXEL
      @rgba   = String.new("\x00".b * byte_count,
                           encoding: Encoding::ASCII_8BIT)
      # Cache of fully-filled clear strings keyed by RGBA tuple. Building
      # one costs ~163KB of pack/`*` allocation; reusing it costs zero
      # and turns clear() into an in-place String#replace.
      @clear_templates = {}
    end

    # In-place clear. The previous `clear` allocated a fresh w*h*4 byte
    # String on every frame (`pack("C*") * pixel_count`), which was the
    # single biggest contributor to GC pressure. We now keep a per-
    # colour template around and just replace bytes from it.
    def clear(r, g, b, a = 255)
      template = (@clear_templates[[r, g, b, a]] ||=
                  ([r, g, b, a].pack("C*") * (@width * @height))
                    .force_encoding(Encoding::ASCII_8BIT))
      @rgba.replace(template)
    end

    def set_pixel(x, y, r, g, b, a = 255)
      return if x < 0 || x >= @width || y < 0 || y >= @height
      offset = (y * @width + x) * BYTES_PER_PIXEL
      @rgba.setbyte(offset,     r)
      @rgba.setbyte(offset + 1, g)
      @rgba.setbyte(offset + 2, b)
      @rgba.setbyte(offset + 3, a)
    end

    # Bresenham. Coordinates are floored to integers.
    def draw_line(x1, y1, x2, y2, r, g, b, a = 255)
      x1 = x1.to_i; y1 = y1.to_i
      x2 = x2.to_i; y2 = y2.to_i
      dx =  (x2 - x1).abs
      dy = -(y2 - y1).abs
      sx = x1 < x2 ? 1 : -1
      sy = y1 < y2 ? 1 : -1
      err = dx + dy
      x, y = x1, y1
      loop do
        set_pixel(x, y, r, g, b, a)
        break if x == x2 && y == y2
        e2 = err * 2
        if e2 >= dy
          err += dy
          x += sx
        end
        if e2 <= dx
          err += dx
          y += sy
        end
      end
    end

    def fill_vertical_line(x, y_start, y_end, r, g, b, a = 255)
      return if x < 0 || x >= @width
      y_start = 0           if y_start < 0
      y_end   = @height - 1 if y_end >= @height
      return if y_start > y_end
      offset = (y_start * @width + x) * BYTES_PER_PIXEL
      stride = @width * BYTES_PER_PIXEL
      (y_end - y_start + 1).times do
        @rgba.setbyte(offset,     r)
        @rgba.setbyte(offset + 1, g)
        @rgba.setbyte(offset + 2, b)
        @rgba.setbyte(offset + 3, a)
        offset += stride
      end
    end

    def fill_rect(x, y, w, h, r, g, b, a = 255)
      x_end = [x + w - 1, @width - 1].min
      y_end = [y + h - 1, @height - 1].min
      x = 0 if x < 0
      y = 0 if y < 0
      (x..x_end).each do |xi|
        fill_vertical_line(xi, y, y_end, r, g, b, a)
      end
    end

    def to_gosu_image
      Gosu::Image.from_blob(@width, @height, @rgba)
    end
  end
end
