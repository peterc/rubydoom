#!/usr/bin/env ruby

# Launch rubydoom into a synthetic arena with a handful of lost souls.
# Useful for confirming the MF_SKULLFLY dive — let them wake, watch
# them charge, see them bash off walls when the player sidesteps.
#
#   rake playground:skull
#   # or:
#   ruby -Ilib scripts/playground_skull.rb
#
# Requires commercial doom.wad — the SKUL sprites are stripped from
# shareware doom1.wad (no lost souls in episode 1).

RubyVM::YJIT.enable if defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?

require_relative "../lib/rubydoom"

COMMERCIAL = File.expand_path("../wads/doom.wad",  __dir__)
SHAREWARE  = File.expand_path("../wads/doom1.wad", __dir__)

wad_path = ARGV[0]
if wad_path.nil?
  if File.exist?(COMMERCIAL)
    wad_path = COMMERCIAL
  elsif File.exist?(SHAREWARE)
    wad_path = SHAREWARE
    warn "[playground] using shareware doom1.wad — lost soul sprites " \
         "are absent. Drop doom.wad in wads/ to see anything."
  end
end
abort "WAD not found (looked in wads/doom.wad, wads/doom1.wad)" unless wad_path && File.exist?(wad_path)

# Wide arena so souls have room to wind up the dive. Five lost souls
# spread across the far side so the player can take a couple at once
# without the wave being trivial. Box of shells + shotgun at spawn so
# the playground is winnable without god mode (the dive deals 3..24 per
# bash and pain_chance is 256, so a chainsaw fight is rough).
scenario = Rubydoom::Scenario.new(name: "SKULTEST")
             .size(2048, 2048)
             .floor(0).ceiling(256)
             .player(x: -800, y: 0, angle: 0)
             # Souls face west (angle 180) so A_Look's 90° forward
             # cone catches the player from tic 1 — without that they
             # only wake when the player fires a gun (noise alert).
             .thing(3006, x:  600, y:    0, angle: 180)   # lost soul (MT_SKULL)
             .thing(3006, x:  600, y:  200, angle: 180)
             .thing(3006, x:  600, y: -200, angle: 180)
             .thing(3006, x:  800, y:  100, angle: 180)
             .thing(3006, x:  800, y: -100, angle: 180)
             .thing(2001, x: -600, y:    0)   # shotgun (doomednum 2001)
             .thing(2008, x: -550, y:   60)   # shell pack
             .thing(2008, x: -550, y:  -60)
             .thing(2049, x: -550, y:  120)   # box of shells
             .build

Rubydoom::App.new(
  wad_path: wad_path,
  scenario: scenario,
).show
