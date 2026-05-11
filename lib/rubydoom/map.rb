module Rubydoom
  # A loaded DOOM map. Each map in a WAD is a marker lump (E1M1, MAP01, ...)
  # followed immediately by a fixed sequence of data lumps:
  #   THINGS, LINEDEFS, SIDEDEFS, VERTEXES, SEGS, SSECTORS, NODES, SECTORS,
  #   REJECT, BLOCKMAP
  # We don't load REJECT or BLOCKMAP yet — we don't need them for the
  # automap or BSP traversal. They'll come in when we do collision and
  # multiplayer monster sight checks.
  class Map
    BBox = Struct.new(:top, :bottom, :left, :right)

    Vertex = Struct.new(:x, :y)

    Thing = Struct.new(:x, :y, :angle, :type, :flags, :removed)

    LineDef = Struct.new(
      :start_vertex_index, :end_vertex_index,
      :flags, :special_type, :sector_tag,
      :front_sidedef_index, :back_sidedef_index,
    ) do
      NO_SIDEDEF = 0xFFFF

      # DOOM "ML_BLOCKING": impassable to players and monsters even when
      # the line is two-sided with a usable opening. Used for things like
      # the entrance-hall window slits — visually open, physically solid.
      FLAG_IMPASSABLE = 0x0001
      # DOOM "ML_DONTPEGTOP": upper texture pegged so its TOP aligns with
      # the upper sector's ceiling (texture hangs down from there) instead
      # of its bottom aligning with the lower ceiling. The naming is the
      # historical mess from the original engine.
      FLAG_UPPER_UNPEGGED = 0x0008
      # DOOM "ML_DONTPEGBOTTOM": for one-sided mid texture, anchors the
      # texture's bottom to the floor (rather than its top to the ceiling).
      # For lower textures on two-sided walls, anchors texture so that its
      # top sits at the upper-ceiling level so a continuous texture run
      # from upper through lower stays aligned.
      FLAG_LOWER_UNPEGGED = 0x0010

      def two_sided?;       back_sidedef_index != NO_SIDEDEF; end
      def impassable?;      (flags & FLAG_IMPASSABLE)    != 0; end
      def upper_unpegged?;  (flags & FLAG_UPPER_UNPEGGED) != 0; end
      def lower_unpegged?;  (flags & FLAG_LOWER_UNPEGGED) != 0; end
    end

    SideDef = Struct.new(
      :x_offset, :y_offset,
      :upper_texture, :lower_texture, :middle_texture,
      :sector_index,
    )

    Sector = Struct.new(
      :floor_height, :ceiling_height,
      :floor_texture, :ceiling_texture,
      :light_level, :special_type, :tag,
    )

    Seg = Struct.new(
      :start_vertex_index, :end_vertex_index,
      :angle, :linedef_index, :direction, :offset,
    )

    SubSector = Struct.new(:seg_count, :first_seg_index)

    # BSP node. The two children encode either a subsector index (when the
    # SUBSECTOR_FLAG high bit is set) or another node index.
    Node = Struct.new(
      :partition_x, :partition_y,
      :partition_dx, :partition_dy,
      :right_bbox, :left_bbox,
      :right_child, :left_child,
    ) do
      SUBSECTOR_FLAG = 0x8000

      def right_is_subsector?; (right_child & SUBSECTOR_FLAG) != 0; end
      def left_is_subsector?;  (left_child  & SUBSECTOR_FLAG) != 0; end
      def right_index; right_child & 0x7FFF; end
      def left_index;  left_child  & 0x7FFF; end
    end

    EXPECTED_LUMPS = %w[THINGS LINEDEFS SIDEDEFS VERTEXES SEGS SSECTORS NODES SECTORS]

    THING_PLAYER_1_START = 1

    attr_reader :name, :things, :linedefs, :sidedefs, :vertexes,
                :segs, :subsectors, :nodes, :sectors

    # Vanilla DOOM doesn't store level ordering in the WAD — the
    # next-map table is hardcoded in `g_game.c`. We approximate by
    # walking the lump directory forward from the current map's
    # marker and returning the next lump whose name matches the
    # ExMy / MAPxx pattern. This happens to match the vanilla
    # progression for the stock IWADs because the maps are stored
    # in order; for custom WADs with branching (secret exits) or
    # out-of-order maps it'll do the wrong thing.
    MAP_NAME_PATTERN = /\A(E\dM\d|MAP\d\d)\z/

    def self.next_in_wad(wad, current_name)
      idx = wad.lumps.index { |l| l.name == current_name.upcase }
      return nil unless idx
      ((idx + 1)...wad.lumps.size).each do |i|
        name = wad.lumps[i].name
        return name if MAP_NAME_PATTERN.match?(name)
      end
      nil
    end

    def self.load(wad, name)
      marker_index = wad.lumps.index { |l| l.name == name.upcase }
      raise "WAD has no map marker #{name.inspect}" unless marker_index

      lumps = {}
      EXPECTED_LUMPS.each_with_index do |expected, i|
        lump = wad.lumps[marker_index + 1 + i]
        unless lump && lump.name == expected
          raise "map #{name}: expected #{expected} at offset #{i + 1}, " \
                "got #{lump&.name.inspect}"
        end
        lumps[expected] = lump
      end

      new(
        name:       name.upcase,
        things:     parse_things(   wad.bytes_for_lump(lumps["THINGS"])),
        linedefs:   parse_linedefs( wad.bytes_for_lump(lumps["LINEDEFS"])),
        sidedefs:   parse_sidedefs( wad.bytes_for_lump(lumps["SIDEDEFS"])),
        vertexes:   parse_vertexes( wad.bytes_for_lump(lumps["VERTEXES"])),
        segs:       parse_segs(     wad.bytes_for_lump(lumps["SEGS"])),
        subsectors: parse_subsectors(wad.bytes_for_lump(lumps["SSECTORS"])),
        nodes:      parse_nodes(    wad.bytes_for_lump(lumps["NODES"])),
        sectors:    parse_sectors(  wad.bytes_for_lump(lumps["SECTORS"])),
      )
    end

    def initialize(name:, things:, linedefs:, sidedefs:, vertexes:,
                   segs:, subsectors:, nodes:, sectors:)
      @name       = name
      @things     = things
      @linedefs   = linedefs
      @sidedefs   = sidedefs
      @vertexes   = vertexes
      @segs       = segs
      @subsectors = subsectors
      @nodes      = nodes
      @sectors    = sectors
    end

    def bounds
      @bounds ||= begin
        xs = @vertexes.map(&:x)
        ys = @vertexes.map(&:y)
        BBox.new(ys.max, ys.min, xs.min, xs.max)
      end
    end

    def linedef_endpoints(linedef)
      [@vertexes[linedef.start_vertex_index], @vertexes[linedef.end_vertex_index]]
    end

    def linedef_front_sector(linedef)
      sd = @sidedefs[linedef.front_sidedef_index] or return nil
      @sectors[sd.sector_index]
    end

    def linedef_back_sector(linedef)
      return nil unless linedef.two_sided?
      sd = @sidedefs[linedef.back_sidedef_index] or return nil
      @sectors[sd.sector_index]
    end

    def player_start
      @things.find { |t| t.type == THING_PLAYER_1_START }
    end

    # ----- parsers -----

    class << self
      private

      def each_record(bytes, size)
        (bytes.bytesize / size).times do |i|
          yield bytes[i * size, size]
        end
      end

      def parse_things(bytes)
        out = []
        each_record(bytes, 10) do |chunk|
          x, y, angle, type, flags = chunk.unpack("s<s<S<S<S<")
          out << Thing.new(x, y, angle, type, flags)
        end
        out
      end

      def parse_linedefs(bytes)
        out = []
        each_record(bytes, 14) do |chunk|
          sv, ev, flags, type, tag, front, back = chunk.unpack("S<S<S<S<S<S<S<")
          out << LineDef.new(sv, ev, flags, type, tag, front, back)
        end
        out
      end

      def parse_sidedefs(bytes)
        out = []
        each_record(bytes, 30) do |chunk|
          x_off, y_off = chunk[0, 4].unpack("s<s<")
          upper  = chunk[4, 8].delete("\x00")
          lower  = chunk[12, 8].delete("\x00")
          middle = chunk[20, 8].delete("\x00")
          sector = chunk[28, 2].unpack1("S<")
          out << SideDef.new(x_off, y_off, upper, lower, middle, sector)
        end
        out
      end

      def parse_vertexes(bytes)
        out = []
        each_record(bytes, 4) do |chunk|
          x, y = chunk.unpack("s<s<")
          out << Vertex.new(x, y)
        end
        out
      end

      def parse_segs(bytes)
        out = []
        each_record(bytes, 12) do |chunk|
          sv, ev, angle, ld, dir, offset = chunk.unpack("S<S<s<S<S<s<")
          out << Seg.new(sv, ev, angle, ld, dir, offset)
        end
        out
      end

      def parse_subsectors(bytes)
        out = []
        each_record(bytes, 4) do |chunk|
          count, first = chunk.unpack("S<S<")
          out << SubSector.new(count, first)
        end
        out
      end

      def parse_nodes(bytes)
        out = []
        each_record(bytes, 28) do |chunk|
          px, py, pdx, pdy = chunk[0, 8].unpack("s<s<s<s<")
          rt, rb, rl, rr   = chunk[8, 8].unpack("s<s<s<s<")
          lt, lb, ll, lr   = chunk[16, 8].unpack("s<s<s<s<")
          rc, lc           = chunk[24, 4].unpack("S<S<")
          out << Node.new(
            px, py, pdx, pdy,
            BBox.new(rt, rb, rl, rr),
            BBox.new(lt, lb, ll, lr),
            rc, lc,
          )
        end
        out
      end

      def parse_sectors(bytes)
        out = []
        each_record(bytes, 26) do |chunk|
          floor_h, ceil_h        = chunk[0, 4].unpack("s<s<")
          floor_tex              = chunk[4, 8].delete("\x00")
          ceil_tex               = chunk[12, 8].delete("\x00")
          light, special, tag    = chunk[20, 6].unpack("s<s<s<")
          out << Sector.new(floor_h, ceil_h, floor_tex, ceil_tex, light, special, tag)
        end
        out
      end
    end
  end
end
