#!/usr/bin/env ruby

# Launch rubydoom into a 4096-square arena with the BFG9000, plenty
# of cells, and a few Barons of Hell to test it on.
#
#   rake playground:bfg
#   # or:
#   ruby -Ilib scripts/playground_bfg.rb
#
# Requires commercial doom.wad — the BFG / Baron / caco sprites are
# stripped from shareware doom1.wad.

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
    warn "[playground] using shareware doom1.wad — BFG / Baron sprites " \
         "are absent. Drop doom.wad in wads/ to see anything."
  end
end
abort "WAD not found (looked in wads/doom.wad, wads/doom1.wad)" unless wad_path && File.exist?(wad_path)

scenario = Rubydoom::Scenario.new(name: "BFGTEST")
             .size(2048, 2048)
             .floor(0).ceiling(256)
             .player(x: -300, y: 0, angle: 0)
             # Three Barons close enough that the 1024-unit spray
             # actually reaches them. The side pair spread wide enough
             # to land outside the direct-hit ball but inside the cone.
             .thing(3003, x:  600, y:    0)
             .thing(3003, x:  600, y:  200)
             .thing(3003, x:  600, y: -200)
             # BFG + cell packs right at the spawn so you can pick up
             # and fire without taking a step.
             .thing(2006, x: -250, y:    0)   # BFG9000 (doomednum 2006)
             .thing(17,   x: -200, y:    0)   # cell pack (100 cells)
             .thing(17,   x: -200, y:  100)
             .thing(17,   x: -200, y: -100)
             .build

Rubydoom::App.new(
  wad_path: wad_path,
  scenario: scenario,
).show
