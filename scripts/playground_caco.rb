#!/usr/bin/env ruby

# Launch rubydoom into a 2048-square synthetic arena with one cacodemon
# and god mode on. Useful for poking at one monster in isolation.
#
#   ruby -Ilib scripts/playground_caco.rb
#
# Pass a different WAD as ARGV[0] to use commercial doom.wad (the caco
# sprites are present in both shareware and commercial, so the
# shareware WAD works fine here).

RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?

require_relative "../lib/rubydoom"

wad_path = ARGV[0] || File.expand_path("../wads/doom1.wad", __dir__)
abort "WAD not found at #{wad_path}" unless File.exist?(wad_path)

scenario = Rubydoom::Scenario.new(name: "ARENA")
             .size(2048, 2048)
             .floor(0).ceiling(192)
             .player(x: -800, y: 0, angle: 0)
             .thing(3005, x: 600, y: 0)   # cacodemon
             .build

Rubydoom::App.new(
  wad_path: wad_path,
  scenario: scenario,
).show
