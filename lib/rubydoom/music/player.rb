require_relative "cache"

module Rubydoom
  module Music
    # The only playback adapter. WAD access and song construction are
    # injected; the parser, synth and cache know nothing about Gosu/Game.
    class Player
      def initialize(wad:, song_factory:, cache: Cache.new, volume: 0.4, log: $stderr)
        @wad, @song_factory, @cache, @volume, @log = wad, song_factory, cache, volume, log
      end

      def play_map(map_name)
        name = "D_#{map_name.to_s.upcase}"
        return if @name == name
        stop
        bytes = @wad.bytes_for(name)
        unless bytes
          @log.puts "[music] no track #{name}; continuing without music"
          return
        end
        path = @cache.fetch(bytes) { @log.puts "[music] rendering #{name} in Ruby (cached for next time)…" }
        @song = @song_factory.call(path)
        @song.volume = @volume
        @song.play(true)
        @name = name
      rescue StandardError => e
        stop
        @log.puts "[music] #{name}: #{e.message}; continuing without music"
      end

      def stop
        @song&.stop
        @song = @name = nil
      end
    end
  end
end
