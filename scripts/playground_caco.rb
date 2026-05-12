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

# Prefer the commercial doom.wad — shareware doom1.wad doesn't ship
# the HEAD sprites (cacos don't appear in E1), so the playground room
# would render empty against it. Fall back to doom1.wad with a clear
# warning so the user understands why they can't see the monster.
COMMERCIAL = File.expand_path("../wads/doom.wad",  __dir__)
SHAREWARE  = File.expand_path("../wads/doom1.wad", __dir__)

wad_path = ARGV[0]
if wad_path.nil?
  if File.exist?(COMMERCIAL)
    wad_path = COMMERCIAL
  elsif File.exist?(SHAREWARE)
    wad_path = SHAREWARE
    warn "[playground] using shareware doom1.wad — caco sprites are " \
         "absent, the monster will spawn invisibly. Drop doom.wad in " \
         "wads/ to see it."
  end
end
abort "WAD not found (looked in wads/doom.wad, wads/doom1.wad)" unless wad_path && File.exist?(wad_path)

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
