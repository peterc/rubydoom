module Rubydoom
  # Demo record / playback. A demo is a per-tic stream of Input values
  # captured during one play session; replaying it under the same seed,
  # skill, and starting map reproduces the simulation bit-for-bit. That
  # reproducibility is what makes this project usable as a Ruby/JIT
  # benchmark — same workload, same render output, just different runtime.
  #
  # File format (all multi-byte fields big-endian):
  #
  #   header:
  #     "RDM1"           magic, 4 bytes
  #     version          u8       (1)
  #     skill            u8       (0..4)
  #     seed             u64      (RNG seed used for the recording)
  #     map_len          u8       (length of map name, e.g. "E1M1" → 4)
  #     map_name         u8[]     (ASCII)
  #
  #   per-tic record (repeats until EOF):
  #     walk             s8       (-1 / 0 / +1)
  #     strafe           s8       (-1 / 0 / +1)
  #     turn             s8       (-1 / 0 / +1)
  #     fire             u8       (0 or 1)
  #     look_dx          s16      (mouse-yaw pixel delta)
  #     edge_count       u8
  #     edges            u8[]     (codes from EDGE_CODES)
  #
  # Edges that don't have a code are silently dropped — only the
  # game-affecting ones are persisted. Window-level actions (mouse
  # capture, automap toggle) are App-side and never reach Input#edges.
  module Demo
    MAGIC   = "RDM1".b.freeze
    VERSION = 1

    # Stable code table — adding new edges appends, never reorders, so
    # old demos keep replaying.
    EDGE_CODES = {
      use:          1,
      respawn:      2,
      toggle_god:   3,
      weapon_1:     4,
      weapon_2:     5,
      weapon_3:     6,
      weapon_4:     7,
      weapon_5:     8,
      weapon_6:     9,
      weapon_7:    10,
      debug_hurt:  11,
      debug_heal:  12,
      debug_armor: 13,
    }.freeze
    EDGE_SYMBOLS = EDGE_CODES.invert.freeze

    Header = Struct.new(:version, :skill, :seed, :map_name)

    # Append-only writer. One per-tic record is `<< input` while the
    # game runs; close() flushes and shuts the file. Header is written
    # at open() so a crash mid-recording still leaves a parseable file.
    class Recorder
      def initialize(path, skill:, seed:, map_name:)
        @io = File.open(path, "wb")
        write_header(skill, seed, map_name)
      end

      def <<(input)
        edges = (input.edges || []).filter_map { |e| EDGE_CODES[e] }
        edges = edges.take(255)  # u8 ceiling — never expected to fire
        walk   = clamp_axis(input.walk_axis)
        strafe = clamp_axis(input.strafe_axis)
        turn   = clamp_axis(input.turn_axis)
        fire   = input.fire ? 1 : 0
        look   = clamp_s16(input.look_dx.to_i)
        @io.write([walk, strafe, turn, fire, look, edges.length]
                    .pack("ccccs>C"))
        @io.write(edges.pack("C*")) unless edges.empty?
      end

      def close
        @io&.close
        @io = nil
      end

      private

      def write_header(skill, seed, map_name)
        name = map_name.to_s.b
        raise ArgumentError, "map name too long" if name.bytesize > 255
        @io.write(MAGIC)
        @io.write([VERSION, skill, seed, name.bytesize].pack("CCQ>C"))
        @io.write(name)
      end

      def clamp_axis(v)
        v = v.to_i
        return -1 if v < -1
        return  1 if v >  1
        v
      end

      def clamp_s16(v)
        return -32768 if v < -32768
        return  32767 if v >  32767
        v
      end
    end

    # Read-only player. Construct with a path, read the header, then
    # call next_input each tic until end_of_file? returns true.
    class Player
      attr_reader :header

      def initialize(path)
        @io = File.open(path, "rb")
        @header = read_header
        # Pre-allocate the per-tic Input so playback doesn't allocate.
        # edges is reused; callers that need a stable snapshot can dup.
        @input  = Input.new(0, 0, 0, 0, false, [])
      end

      def end_of_file?
        @io.eof?
      end

      # Returns a reused Input struct. Caller must not retain it across
      # tics — the next call overwrites it.
      def next_input
        bytes = @io.read(7)
        return nil if bytes.nil? || bytes.bytesize < 7
        walk, strafe, turn, fire, look, n = bytes.unpack("ccccs>C")
        edges = @input.edges
        edges.clear
        if n > 0
          codes = @io.read(n)
          raise EOFError, "demo truncated mid-record" if codes.nil? || codes.bytesize < n
          codes.each_byte do |c|
            sym = EDGE_SYMBOLS[c]
            edges << sym if sym
          end
        end
        @input.walk_axis   = walk
        @input.strafe_axis = strafe
        @input.turn_axis   = turn
        @input.look_dx     = look
        @input.fire        = fire != 0
        @input
      end

      def close
        @io&.close
        @io = nil
      end

      private

      def read_header
        magic = @io.read(4)
        raise ArgumentError, "not a rubydoom demo: bad magic #{magic.inspect}" unless magic == MAGIC
        version, skill, seed, map_len = @io.read(11).unpack("CCQ>C")
        raise ArgumentError, "unsupported demo version #{version}" unless version == VERSION
        name = @io.read(map_len).force_encoding(Encoding::UTF_8)
        Header.new(version, skill, seed, name)
      end
    end
  end
end
