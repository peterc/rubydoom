module Rubydoom
  module Music
    # MUS is a timed event stream, at 140 ticks/second (not game tics).
    # Format reference: chocolate-doom/src/mus2mid.c. We consume MUS
    # directly; there is no MIDI conversion or external synthesizer.
    class Score
      TICKS_PER_SECOND = 140
      Event = Struct.new(:tick, :type, :channel, :a, :b)
      attr_reader :events, :ticks

      def initialize(bytes)
        raise ArgumentError, "not a MUS score" unless bytes.bytesize >= 16 && bytes.start_with?("MUS\x1a")
        length, start, _, _, instruments = bytes.byteslice(4, 10).unpack("v5")
        raise ArgumentError, "invalid MUS score bounds" unless start >= 16 + instruments * 2 && start + length <= bytes.bytesize
        @data = bytes.byteslice(start, length)
        @cursor = 0
        @events = []
        @ticks = 0
        velocity = Array.new(16, 127)
        loop do
          descriptor = byte
          channel = descriptor & 15
          type = (descriptor >> 4) & 7
          case type
          when 0
            @events << Event.new(@ticks, :off, channel, byte & 127)
          when 1
            note = byte
            velocity[channel] = byte & 127 if note & 128 != 0
            @events << Event.new(@ticks, :on, channel, note & 127, velocity[channel])
          when 2
            @events << Event.new(@ticks, :bend, channel, byte)
          when 3
            control = byte
            raise ArgumentError, "invalid MUS system event" unless (10..14).cover?(control)
            @events << Event.new(@ticks, :control, channel, control, 0)
          when 4
            control, value = byte, byte
            raise ArgumentError, "invalid MUS controller" unless (0..9).cover?(control)
            @events << Event.new(@ticks, :control, channel, control, [value, 127].min)
          when 6
            break
          else
            raise ArgumentError, "unsupported MUS event #{type}"
          end
          if descriptor & 128 != 0
            delay = 0
            count = 0
            loop do
              part = byte
              delay = (delay << 7) | (part & 127)
              count += 1
              raise ArgumentError, "MUS delay too long" if count > 4
              break if part & 128 == 0
            end
            @ticks += delay
            raise ArgumentError, "MUS score exceeds 30 minutes" if @ticks > 140 * 1800
          end
        end
        @events.each(&:freeze)
        @events.freeze
        @data = nil
      end

      private

      def byte
        value = @data.getbyte(@cursor)
        raise ArgumentError, "truncated MUS score" unless value
        @cursor += 1
        value
      end
    end
  end
end
