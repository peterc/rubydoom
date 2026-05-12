module Rubydoom
  # Maps a doomednum (the integer in the THINGS lump) to the sprite
  # data needed to render the thing as a billboard. This is a port of
  # a subset of `mobjinfo[]` and `states[]` from the original DOOM
  # source (linuxdoom-1.10/info.c) — specifically the spawn-state
  # sprite frame for each thing type that appears in the shareware
  # episode (E1).
  #
  # We only carry the static spawn frame here. AI states and animation
  # cycles will need the full state table; for billboarded rendering
  # of stationary monsters/items/decor, just the spawn frame is enough.
  #
  # Doomednums of player / multiplayer starts (1-4, 11) and the
  # teleport landing pad (14) are intentionally absent — they have no
  # sprite to render.
  module ThingTypes
    # `sprite` is the 4-letter prefix; `frame` is the spawn frame
    # letter (frame A unless otherwise stated). `radius` is the
    # collision radius from mobjinfo; we don't use it yet but it's
    # cheap to carry forward and we'll need it for thing-vs-wall
    # clipping when sprites land in the 3D renderer.
    # `solid` mirrors vanilla DOOM's MF_SOLID flag: true things block the
    # player's AABB, false things are walked through. Pickups, corpses,
    # and the tiny candle prop are not solid.
    Info = Struct.new(:doomednum, :sprite, :frame, :radius, :solid, keyword_init: true)

    ENTRIES = [
      # Monsters (E1) — radius 20, height 56 in vanilla.
      Info.new(doomednum: 3004, sprite: "POSS", frame: "A", radius: 20, solid: true),  # zombieman
      Info.new(doomednum:    9, sprite: "SPOS", frame: "A", radius: 20, solid: true),  # shotgun guy
      Info.new(doomednum: 3001, sprite: "TROO", frame: "A", radius: 20, solid: true),  # imp
      Info.new(doomednum: 3002, sprite: "SARG", frame: "A", radius: 30, solid: true),  # demon
      Info.new(doomednum:   58, sprite: "SARG", frame: "A", radius: 30, solid: true),  # spectre
      Info.new(doomednum: 3003, sprite: "BOSS", frame: "A", radius: 24, solid: true),  # baron of hell
      Info.new(doomednum: 3005, sprite: "HEAD", frame: "A", radius: 31, solid: true),  # cacodemon

      # Weapons — pickups, MF_SPECIAL only.
      Info.new(doomednum: 2001, sprite: "SHOT", frame: "A", radius: 20, solid: false),  # shotgun
      Info.new(doomednum: 2002, sprite: "MGUN", frame: "A", radius: 20, solid: false),  # chaingun
      Info.new(doomednum: 2003, sprite: "LAUN", frame: "A", radius: 20, solid: false),  # rocket launcher
      Info.new(doomednum: 2004, sprite: "PLAS", frame: "A", radius: 20, solid: false),  # plasma rifle
      Info.new(doomednum: 2005, sprite: "CSAW", frame: "A", radius: 20, solid: false),  # chainsaw
      Info.new(doomednum: 2006, sprite: "BFUG", frame: "A", radius: 20, solid: false),  # BFG9000

      # Ammo — pickups.
      Info.new(doomednum: 2007, sprite: "CLIP", frame: "A", radius: 20, solid: false),  # clip
      Info.new(doomednum: 2008, sprite: "SHEL", frame: "A", radius: 20, solid: false),  # 4 shells
      Info.new(doomednum: 2046, sprite: "BROK", frame: "A", radius: 20, solid: false),  # box of rockets
      Info.new(doomednum: 2047, sprite: "CELL", frame: "A", radius: 20, solid: false),  # cell
      Info.new(doomednum: 2048, sprite: "AMMO", frame: "A", radius: 20, solid: false),  # box of bullets
      Info.new(doomednum: 2049, sprite: "SBOX", frame: "A", radius: 20, solid: false),  # box of shells
      Info.new(doomednum:   17, sprite: "CELP", frame: "A", radius: 20, solid: false),  # cell pack
      Info.new(doomednum:    8, sprite: "BPAK", frame: "A", radius: 20, solid: false),  # backpack

      # Health & armor — pickups.
      Info.new(doomednum: 2011, sprite: "STIM", frame: "A", radius: 20, solid: false),  # stimpack
      Info.new(doomednum: 2012, sprite: "MEDI", frame: "A", radius: 20, solid: false),  # medikit
      Info.new(doomednum: 2013, sprite: "SOUL", frame: "A", radius: 20, solid: false),  # soulsphere
      Info.new(doomednum: 2014, sprite: "BON1", frame: "A", radius: 20, solid: false),  # health bonus
      Info.new(doomednum: 2015, sprite: "BON2", frame: "A", radius: 20, solid: false),  # armor bonus
      Info.new(doomednum: 2018, sprite: "ARM1", frame: "A", radius: 20, solid: false),  # green armor
      Info.new(doomednum: 2019, sprite: "ARM2", frame: "A", radius: 20, solid: false),  # blue armor

      # Powerups — pickups.
      Info.new(doomednum: 2022, sprite: "PINV", frame: "A", radius: 20, solid: false),  # invulnerability sphere
      Info.new(doomednum: 2023, sprite: "PSTR", frame: "A", radius: 20, solid: false),  # berserk pack
      Info.new(doomednum: 2024, sprite: "PINS", frame: "A", radius: 20, solid: false),  # invisibility (blursphere)
      Info.new(doomednum: 2025, sprite: "SUIT", frame: "A", radius: 20, solid: false),  # radsuit / biosuit

      # Keys — pickups. Both card (flat) and skull variants of each
      # colour exist; doom1 door specials accept either.
      Info.new(doomednum:    5, sprite: "BKEY", frame: "A", radius: 20, solid: false),  # blue card
      Info.new(doomednum:    6, sprite: "YKEY", frame: "A", radius: 20, solid: false),  # yellow card
      Info.new(doomednum:   13, sprite: "RKEY", frame: "A", radius: 20, solid: false),  # red card
      Info.new(doomednum:   38, sprite: "RSKU", frame: "A", radius: 20, solid: false),  # red skull
      Info.new(doomednum:   39, sprite: "YSKU", frame: "A", radius: 20, solid: false),  # yellow skull
      Info.new(doomednum:   40, sprite: "BSKU", frame: "A", radius: 20, solid: false),  # blue skull

      # Decorations / props — MF_SOLID in vanilla except the small candle.
      Info.new(doomednum: 2035, sprite: "BAR1", frame: "A", radius: 10, solid: true),   # exploding barrel
      Info.new(doomednum: 2028, sprite: "COLU", frame: "A", radius: 16, solid: true),   # floor lamp
      Info.new(doomednum:   34, sprite: "CAND", frame: "A", radius: 20, solid: false),  # candle
      Info.new(doomednum:   35, sprite: "CBRA", frame: "A", radius: 16, solid: true),   # candelabra
      Info.new(doomednum:   44, sprite: "TBLU", frame: "A", radius: 16, solid: true),   # tall blue torch
      Info.new(doomednum:   45, sprite: "TGRN", frame: "A", radius: 16, solid: true),   # tall green torch
      Info.new(doomednum:   46, sprite: "TRED", frame: "A", radius: 16, solid: true),   # tall red torch
      Info.new(doomednum:   55, sprite: "SMBT", frame: "A", radius: 16, solid: true),   # short blue torch
      Info.new(doomednum:   56, sprite: "SMGT", frame: "A", radius: 16, solid: true),   # short green torch
      Info.new(doomednum:   57, sprite: "SMRT", frame: "A", radius: 16, solid: true),   # short red torch
      Info.new(doomednum:   47, sprite: "SMIT", frame: "A", radius: 16, solid: true),   # stalagmite
      Info.new(doomednum:   48, sprite: "ELEC", frame: "A", radius: 16, solid: true),   # tech column
      Info.new(doomednum:   54, sprite: "TRE2", frame: "A", radius: 32, solid: true),   # big brown tree
      Info.new(doomednum:   43, sprite: "TRE1", frame: "A", radius: 16, solid: true),   # burned tree

      # Corpses / gore — not solid, walked over.
      Info.new(doomednum:   15, sprite: "PLAY", frame: "N", radius: 16, solid: false),  # dead player
      Info.new(doomednum:   10, sprite: "PLAY", frame: "W", radius: 16, solid: false),  # bloody mess 1
      Info.new(doomednum:   12, sprite: "PLAY", frame: "W", radius: 16, solid: false),  # bloody mess 2
      Info.new(doomednum:   24, sprite: "POL5", frame: "A", radius: 16, solid: false),  # pool of blood/flesh
    ].freeze

    BY_DOOMEDNUM = ENTRIES.each_with_object({}) { |info, h| h[info.doomednum] = info }.freeze

    def self.[](doomednum)
      BY_DOOMEDNUM[doomednum]
    end
  end
end
