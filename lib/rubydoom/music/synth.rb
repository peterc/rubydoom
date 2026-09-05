require_relative "score"

module Rubydoom
  module Music
    # Small wavetable synth, intentionally not an OPL/FM emulator. All
    # sequencing, oscillators, envelopes, percussion and mixing are Ruby.
    class Synth
      VERSION = "simple-1"
      SAMPLE_RATE = 22_050
      TABLE_SIZE = 2048
      BLOCK_SIZE = 2048
      # Six simple harmonic timbres: keys, bells, organ, guitar,
      # bass, and winds/strings. Harmonic amplitudes, not sample assets.
      HARMONICS = [
        [1.0, 0.25, 0.12], [1.0, 0.0, 0.35, 0.0, 0.15],
        [1.0, 0.35, 0.2, 0.1], [1.0, 0.4, 0.3, 0.15, 0.1],
        [1.0, 0.15, 0.05], [1.0, 0.0, 0.18, 0.0, 0.06],
      ].map(&:freeze).freeze
      TABLES = HARMONICS.map do |harmonics|
        norm = harmonics.sum
        Array.new(TABLE_SIZE) do |i|
          angle = i * 2 * Math::PI / TABLE_SIZE
          harmonics.each_with_index.sum { |a, h| a * Math.sin(angle * (h + 1)) } / norm
        end.freeze
      end.freeze
      Channel = Struct.new(:program, :volume, :expression, :bend, :sustain)

      class Voice
        attr_reader :channel, :note
        attr_accessor :key_down

        def initialize(channel, note, velocity, program, rate, random)
          @channel, @note, @rate = channel, note, rate
          @key_down = true
          @phase = 0.0
          @age = 0
          @level = 0.0
          @gain = velocity / 127.0
          @release = false
          @release_step = 0.0
          @step = 440.0 * 2.0**((note - 69) / 12.0) * TABLE_SIZE / rate
          family = case program
                   when 0..7 then 0
                   when 8..15 then 1
                   when 16..23 then 2
                   when 24..31 then 3
                   when 32..39 then 4
                   else 5
                   end
          @table = TABLES[family]
          @attack_samples = (rate * (family == 5 ? 0.018 : 0.004)).ceil
          @attack = 1.0 / @attack_samples
          @decay = Math.exp(-1.0 / (rate * (family == 1 ? 0.35 : 0.8)))
          @sustain = [0.25, 0.0, 0.8, 0.3, 0.55, 0.65][family]
          if channel == 15
            # Short one-shot percussion, with a local RNG. Drums never
            # consume simulation randomness or require sound samples.
            duration = [42, 44, 46].include?(note) ? 0.10 : 0.28
            count = (rate * duration).to_i
            @drum = Array.new(count) do |i|
              t = i.to_f / rate
              envelope = Math.exp(-8.0 * i / count)
              noise = random.rand * 2.0 - 1.0
              tone = Math.sin(2 * Math::PI * (note <= 36 ? 65 : 150) * t)
              value = note <= 36 ? tone : (note == 38 || note == 40 ? noise * 0.7 + tone * 0.3 : noise)
              value * envelope * [i / (rate * 0.002), 1.0].min
            end
          end
        end

        def release
          return if @release
          @release = true
          @release_step = @level / (@rate * 0.08)
        end

        def done?
          @drum ? @age >= @drum.length : @release && @level <= 0.0
        end

        def mix!(buffer, count, state)
          gain = @gain * state.volume * state.expression
          step = @step * state.bend
          i = 0
          while i < count
            if @drum
              break if @age >= @drum.length
              value = @drum[@age]
            else
              if @release
                @level -= @release_step
                break if @level <= 0.0
              elsif @age < @attack_samples
                @level = [@level + @attack, 1.0].min
              else
                @level = @sustain + (@level - @sustain) * @decay
              end
              value = @table[@phase.to_i] * @level
              @phase = (@phase + step) % TABLE_SIZE
            end
            buffer[i] += value * gain
            @age += 1
            i += 1
          end
        end
      end

      def initialize(sample_rate: SAMPLE_RATE)
        raise ArgumentError, "invalid sample rate" unless (8000..48_000).cover?(sample_rate)
        @rate = sample_rate
      end

      # Write incrementally, keeping memory independent of song duration.
      # Score time maps to absolute sample positions, avoiding timing drift.
      def write(score, io)
        @channels = Array.new(16) { Channel.new(0, 1.0, 1.0, 1.0, false) }
        @voices = []
        @random = Random.new(0)
        total = score.ticks * @rate / Score::TICKS_PER_SECOND
        raise ArgumentError, "empty music score" if total.zero?
        io.write(wav_header(total * 2))
        position = 0
        score.events.each do |event|
          target = event.tick * @rate / Score::TICKS_PER_SECOND
          render(io, position, target, total)
          position = target
          dispatch(event)
        end
        render(io, position, total, total)
        total
      end

      private

      def dispatch(event)
        ch = @channels[event.channel]
        case event.type
        when :on
          if event.b.zero?
            release_note(event.channel, event.a)
          else
            @voices.shift if @voices.length >= 64
            @voices << Voice.new(event.channel, event.a, event.b, ch.program, @rate, @random)
          end
        when :off
          release_note(event.channel, event.a)
        when :bend
          ch.bend = 2.0**((event.a - 128) / 128.0 * 2.0 / 12.0)
        when :control
          case event.a
          when 0 then ch.program = event.b
          when 3 then ch.volume = event.b / 127.0
          when 5 then ch.expression = event.b / 127.0
          when 8
            ch.sustain = event.b >= 64
            @voices.each { |v| v.release if v.channel == event.channel && !v.key_down } unless ch.sustain
          when 10
            @voices.reject! { |v| v.channel == event.channel }
          when 11, 12, 13
            @voices.each { |v| release_note(v.channel, v.note) if v.channel == event.channel }
          when 14
            ch.volume = ch.expression = ch.bend = 1.0
            ch.sustain = false
            @voices.each { |v| v.release if v.channel == event.channel && !v.key_down }
          end
          # Bank/modulation/pan/reverb/chorus/soft-pedal are intentionally
          # ignored by this first, mono synth. Their events still parse.
        end
      end

      def release_note(channel, note)
        @voices.each do |voice|
          next unless voice.channel == channel && voice.note == note
          voice.key_down = false
          voice.release unless @channels[channel].sustain
        end
      end

      def render(io, position, target, total)
        while position < target
          count = [BLOCK_SIZE, target - position].min
          mix = Array.new(count, 0.0)
          @voices.each { |v| v.mix!(mix, count, @channels[v.channel]) }
          @voices.reject!(&:done?)
          fade = @rate * 0.005
          pcm = mix.each_with_index.map do |sample, i|
            # Gentle soft limiting and a 5ms edge fade prevent clipping
            # and loop-boundary clicks without extending the score time.
            sample *= 0.22
            edge = [1.0, (position + i) / fade, (total - position - i - 1) / fade].min
            (sample / (1.0 + sample.abs) * 30_000 * edge).round
          end
          io.write(pcm.pack("s<*"))
          position += count
        end
      end

      def wav_header(size)
        "RIFF" + [36 + size].pack("V") + "WAVEfmt " +
          [16, 1, 1, @rate, @rate * 2, 2, 16].pack("VvvVVvv") +
          "data" + [size].pack("V")
      end
    end
  end
end
