module Rubydoom
  # Touch-driven item pickups. Every tic we walk the list of
  # not-yet-picked-up pickup things and check AABB overlap with the
  # player (the same radius math `Clipper#thing_blocks?` uses, except
  # against the non-solid set). On overlap, the doomednum dispatches
  # to a `pickup_*` method on Player, which decides whether the item
  # was actually absorbed (e.g. a stimpack at full health isn't,
  # leaving the pickup on the floor for later). Absorbed items get
  # `removed = true` set; the renderer skips them and we drop them
  # from our scan list.
  #
  # Currently implements (E1M1 set + a few more):
  #   Health: stimpack, medikit, soulsphere, health bonus
  #   Armor:  green armor, blue armor, armor bonus
  #   Ammo:   clip, 4 shells, box of bullets, box of shells,
  #           box of rockets, backpack
  #   Keys:   blue/yellow/red cards + skull variants — locked doors
  #           in `Doors` consult `player.has_key?(:colour)`.
  #   Weapons: shotgun / chaingun / rocket launcher / chainsaw — set
  #           the weapon as owned and grant starting ammo; vanilla's
  #           auto-switch is requested via `player.pending_weapon`,
  #           consumed by the Weapons state machine.
  #
  # Not yet (in TODO.txt): powerups (need timer system).
  class Pickups
    # Weapon doomednums get `dswpnup`; everything else (health, ammo,
    # armor, keys, backpack) gets `dsitemup`. Powerups, when we have
    # them, will play `dsgetpow` — none of those types appear here yet.
    WEAPON_DOOMEDNUMS = [2001, 2002, 2003, 2004, 2005].freeze
    POWERUP_DOOMEDNUMS = [2022, 2023, 2024, 2025].freeze

    def initialize(map)
      @map     = map
      @pending = collect_pickups
      @sound   = nil
    end

    # Late-bound so App can construct Pickups before Sound exists.
    attr_writer :sound

    def update_tic(player)
      @pending.reject! do |thing|
        next true if thing.removed
        next false unless touches?(player, thing)
        if apply(player, thing)
          thing.removed = true
          player.flash_bonus!
          play_pickup_sound(thing)
          true
        else
          false  # leave it on the floor; player can come back
        end
      end
    end

    private

    # All map things that are flagged non-solid AND have a known
    # pickup effect. Filters out decorations like the candle (which
    # is non-solid but isn't a pickup).
    def collect_pickups
      @map.things.select do |t|
        info = ThingTypes[t.type]
        info && !info.solid && pickup?(t.type)
      end
    end

    def touches?(player, thing)
      info  = ThingTypes[thing.type]
      range = Clipper::PLAYER_RADIUS + info.radius
      (player.x - thing.x).abs < range && (player.y - thing.y).abs < range
    end

    # Dispatch on doomednum. Returns true if the item was absorbed
    # (and should be removed from the world); false if the pickup
    # was a no-op (player already maxed) so the item stays put.
    def apply(player, thing)
      case thing.type
      # ---- Health ----
      when 2011 then player.add_health(10)                          # stimpack
      when 2012 then player.add_health(25)                          # medikit
      when 2013 then player.add_health(100, max: 200)               # soulsphere
      when 2014 then player.add_health(1,   max: 200)               # health bonus

      # ---- Armor ----
      when 2018 then player.pickup_armor_pack(100, type: :green)    # green armor
      when 2019 then player.pickup_armor_pack(200, type: :blue)     # blue armor
      when 2015 then player.add_armor(1, max: 200)                  # armor bonus

      # ---- Ammo ----
      when 2007 then player.add_ammo(:bullet, 10) > 0               # clip
      when 2048 then player.add_ammo(:bullet, 50) > 0               # box of bullets
      when 2008 then player.add_ammo(:shell,   4) > 0               # 4 shells
      when 2049 then player.add_ammo(:shell,  20) > 0               # box of shells
      when 2046 then player.add_ammo(:rocket,  5) > 0               # box of rockets
      when 2047 then player.add_ammo(:cell,   20) > 0               # cell
      when   17 then player.add_ammo(:cell,  100) > 0               # cell pack
      when    8 then player.pickup_backpack                         # backpack

      # ---- Keys ----
      when    5 then player.pickup_key(:blue,   :card)              # blue card
      when    6 then player.pickup_key(:yellow, :card)              # yellow card
      when   13 then player.pickup_key(:red,    :card)              # red card
      when   40 then player.pickup_key(:blue,   :skull)             # blue skull
      when   39 then player.pickup_key(:yellow, :skull)             # yellow skull
      when   38 then player.pickup_key(:red,    :skull)             # red skull

      # ---- Weapons ----
      when 2001 then player.pickup_weapon(:shotgun)                 # shotgun
      when 2002 then player.pickup_weapon(:chaingun)                # chaingun
      when 2003 then player.pickup_weapon(:rocket)                  # rocket launcher
      when 2004 then player.pickup_weapon(:plasma)                  # plasma rifle
      when 2005 then player.pickup_weapon(:chainsaw)                # chainsaw

      # ---- Powerups ----
      when 2022 then player.grant_power(:invulnerability)           # invulnerability sphere
      when 2023 then pickup_berserk(player)                         # berserk pack
      when 2024 then player.grant_power(:invisibility)              # blursphere
      when 2025 then player.grant_power(:radsuit)                   # radsuit / biosuit
      else
        false
      end
    end

    def pickup?(doomednum)
      PICKUP_DOOMEDNUMS.include?(doomednum)
    end

    def play_pickup_sound(thing)
      return unless @sound
      name =
        if WEAPON_DOOMEDNUMS.include?(thing.type)
          :wpnup
        elsif POWERUP_DOOMEDNUMS.include?(thing.type)
          :getpow
        else
          :itemup
        end
      # Pickup happens at point-blank range; just play at full volume.
      @sound.play(name)
    end

    PICKUP_DOOMEDNUMS = [
      2011, 2012, 2013, 2014,                   # health
      2018, 2019, 2015,                         # armor
      2007, 2048, 2008, 2049, 2046, 2047, 17, 8, # ammo + backpack
      5, 6, 13, 38, 39, 40,                     # keys (cards + skulls)
      2001, 2002, 2003, 2004, 2005,             # weapons (shotgun/chaingun/rocket/plasma/chainsaw)
      2022, 2023, 2024, 2025,                    # powerups (invuln, berserk, blursphere, radsuit)
    ].freeze

    # Vanilla `P_GivePower(pw_strength)` plus the berserk pack's
    # secondary effects: heals to 100 if below, switches to the fist
    # so the player can feel the bonus immediately. Always absorbed.
    def pickup_berserk(player)
      player.grant_power(:berserk)
      player.add_health(100) if player.health < 100
      player.pending_weapon = :fist
      true
    end
  end
end
