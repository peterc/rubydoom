module Rubydoom
  # Reads a DOOM WAD file. The format is:
  #   header: magic[4] ("IWAD"|"PWAD"), num_lumps[i32 LE], directory_offset[i32 LE]
  #   directory: num_lumps * { offset[i32 LE], size[i32 LE], name[8 ASCII null-padded] }
  class WAD
    Lump = Struct.new(:name, :offset, :size, :index) do
      def to_s
        "#<Lump #{name} size=#{size} index=#{index}>"
      end
    end

    attr_reader :type, :lumps

    def self.open(path)
      new(File.binread(path))
    end

    def initialize(bytes)
      @bytes = bytes.dup.force_encoding(Encoding::ASCII_8BIT)
      magic, num_lumps, directory_offset = @bytes.unpack("a4l<l<")
      unless %w[IWAD PWAD].include?(magic)
        raise "not a WAD (magic=#{magic.inspect})"
      end
      @type = magic
      @lumps = []
      @by_name = {}
      num_lumps.times do |i|
        entry = @bytes[directory_offset + i * 16, 16]
        offset, size, raw_name = entry.unpack("l<l<a8")
        name = raw_name.delete("\x00")
        lump = Lump.new(name, offset, size, i)
        @lumps << lump
        # First occurrence wins for ambiguous names. Map lumps share names
        # across episodes (THINGS, LINEDEFS, ...) so name lookups are not
        # appropriate for those — callers should use a map-aware index.
        @by_name[name] ||= lump
      end
    end

    def lump(name)
      @by_name[name.to_s.upcase]
    end

    def bytes_for(name)
      lump = lump(name)
      return nil unless lump
      @bytes[lump.offset, lump.size]
    end

    def bytes_for_lump(lump)
      @bytes[lump.offset, lump.size]
    end
  end
end
