#!/usr/bin/env ruby
# Optional offline pre-render. Loads only the WAD reader and Ruby music
# modules: no Gosu, game engine, external executable or audio device.
RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?
require_relative "../lib/rubydoom/wad"
require_relative "../lib/rubydoom/music/cache"

abort "Usage: ruby scripts/render_music.rb [E1M1|D_INTER|--all] [wad]" if ARGV.length > 2
selection = (ARGV[0] || "E1M1").upcase
wad = Rubydoom::WAD.open(ARGV[1] || File.expand_path("../wads/doom1.wad", __dir__))
names = selection == "--ALL" ? wad.lumps.map(&:name).select { |n| n.start_with?("D_") } :
  [selection.start_with?("D_") ? selection : "D_#{selection}"]
cache = Rubydoom::Music::Cache.new
names.each do |name|
  bytes = wad.bytes_for(name) or abort "No music lump #{name}"
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  path = cache.fetch(bytes) { warn "[music] rendering #{name}…" }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  puts "#{name}: #{path} (#{format('%.2f', elapsed)}s)"
end
