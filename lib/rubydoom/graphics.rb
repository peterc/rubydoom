module Rubydoom
  # Caches decoded Pictures by lump name. Engine-agnostic — does not know
  # about Gosu; the Gosu-aware cache layer sits above this.
  class Graphics
    def initialize(wad, palette)
      @wad = wad
      @palette = palette
      @pictures = {}
    end

    attr_reader :palette

    def picture(name)
      key = name.to_s.upcase
      @pictures[key] ||= begin
        bytes = @wad.bytes_for(key) or raise "WAD has no lump #{key}"
        Picture.parse(bytes)
      end
    end

    def has?(name)
      !@wad.lump(name).nil?
    end
  end
end
