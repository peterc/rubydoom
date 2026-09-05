require "digest"
require "fileutils"
require "tempfile"
require_relative "synth"

module Rubydoom
  module Music
    class Cache
      DEFAULT_DIRECTORY = File.expand_path("../../../tmp/music", __dir__)

      def initialize(directory: DEFAULT_DIRECTORY)
        @directory = directory
      end

      def fetch(bytes)
        key = Digest::SHA256.hexdigest("#{Synth::VERSION}:#{Synth::SAMPLE_RATE}:".b + bytes)
        path = File.join(@directory, "#{key}.wav")
        return path if valid_wav?(path)
        score = Score.new(bytes)
        FileUtils.mkdir_p(@directory)
        # Only publish a complete file. Interrupted renders can never be
        # mistaken for a cached song on the next launch.
        Tempfile.create(["music-", ".wav"], @directory) do |file|
          file.binmode
          yield if block_given?
          Synth.new.write(score, file)
          file.close
          File.rename(file.path, path)
        end
        path
      end

      private

      def valid_wav?(path)
        return false unless File.file?(path)
        header = File.binread(path, 44)
        header.bytesize == 44 && header.start_with?("RIFF") &&
          header.byteslice(8, 8) == "WAVEfmt " &&
          header.byteslice(36, 4) == "data" &&
          header.byteslice(40, 4).unpack1("V") == File.size(path) - 44
      end
    end
  end
end
