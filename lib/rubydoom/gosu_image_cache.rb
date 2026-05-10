require "gosu"

module Rubydoom
  # Wraps a Gosu::Image with the patch's left/top offset metadata.
  # DOOM uses these offsets for sprite positioning (3D view weapons,
  # actors). HUD graphics are typically drawn at fixed coordinates and
  # ignore offsets.
  class Sprite
    attr_reader :image, :left_offset, :top_offset, :width, :height

    def initialize(image:, left_offset:, top_offset:, width:, height:)
      @image = image
      @left_offset = left_offset
      @top_offset = top_offset
      @width = width
      @height = height
    end

    # Draws with top-left at (x, y), ignoring the patch's offsets.
    def draw_at(x, y, z = 0)
      @image.draw(x, y, z)
    end

    # Draws so that the patch's "anchor" (left_offset, top_offset)
    # lands at (x, y). This is how DOOM positions sprites and weapons.
    def draw_anchored(x, y, z = 0)
      @image.draw(x - @left_offset, y - @top_offset, z)
    end
  end

  # Lazily turns named patches into Gosu::Images. One image per patch is
  # reused across draws.
  class GosuImageCache
    def initialize(graphics)
      @graphics = graphics
      @cache = {}
    end

    def [](name)
      key = name.to_s.upcase
      @cache[key] ||= build(key)
    end

    private

    def build(name)
      pic = @graphics.picture(name)
      rgba = pic.to_rgba(@graphics.palette)
      image = Gosu::Image.from_blob(pic.width, pic.height, rgba)
      Sprite.new(
        image: image,
        left_offset: pic.left_offset,
        top_offset: pic.top_offset,
        width: pic.width,
        height: pic.height,
      )
    end
  end
end
