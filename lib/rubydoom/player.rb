module Rubydoom
  # The player's full state — position, orientation, view-mechanics,
  # and inventory/stats that the HUD reflects. Mirrors the subset of
  # vanilla DOOM's `player_t` we currently care about.
  #
  # Position / orientation:
  #   x, y, angle — map space; angle in degrees, DOOM convention
  #   (0 = East, 90 = North).
  #
  # View mechanics:
  #   bob — vertical eye-height wobble while walking.
  #   view_height — eye above current floor. Nominal 41 (VIEWHEIGHT);
  #     transiently dips after a step-up so the camera lifts smoothly.
  #
  # Inventory / stats (HUD-visible):
  #   health — 0..max_health. 0 = dead.
  #   armor — current armor points, 0..max_armor.
  #   armor_class — :green (1/3 absorb) / :blue (1/2 absorb) / nil
  #     (no armor). DOOM uses an integer; we use symbols for clarity.
  #   ammo / max_ammo — hashes keyed by :bullet / :shell / :rocket /
  #     :cell. The HUD's right panel shows all four current / max
  #     pairs; the big AMMO box shows whichever the current weapon
  #     consumes (nil for melee).
  #   current_weapon — symbol matching HUD#weapon_lump_for.
  #
  # Run-stats (level/episode totals):
  #   secrets_found — number of secret sectors entered. Vanilla calls
  #     this `secretcount`; intermission shows it as `% found`.
  #
  # Keys:
  #   keys — hash of colour -> {card:, skull:} booleans. Locked doors
  #     check `has_key?(:blue / :yellow / :red)`, which is true if
  #     either variant is held. We track card-vs-skull separately so
  #     future Doom 2 specials that care about the distinction can
  #     check `keys[colour][:card]` / `[:skull]` directly.
  #
  # Weapons:
  #   weapons_owned — hash of weapon symbol -> bool. Starts with fist
  #     and pistol owned. Vanilla calls this `weaponowned[]`.
  #   pending_weapon — symbol set by pickup or switch keypress; the
  #     `Weapons` state machine consumes it on the next "ready" frame
  #     and updates `current_weapon`. nil means no switch pending.
  NOMINAL_VIEW_HEIGHT = 41
  # Vanilla "deathviewheight" — the camera drops to this above the
  # floor on death, simulating the body collapsing.
  DEAD_VIEW_HEIGHT    = 8

  Player = Struct.new(:x, :y, :angle, :bob, :view_height,
                      :health, :armor, :armor_class,
                      :ammo, :max_ammo,
                      :current_weapon,
                      :backpack,
                      :secrets_found,
                      :keys,
                      :weapons_owned,
                      :pending_weapon,
                      :god_mode,
                      :damage_count, :bonus_count) do
    DEFAULT_MAX_HEALTH = 100
    SOULSPHERE_MAX     = 200
    DEFAULT_MAX_ARMOR  = 200

    # Screen-tint counters (vanilla `damagecount` / `bonuscount`). Each
    # decays by 1/tic and the displayed palette/overlay is chosen from
    # whichever is non-zero. `damage_count` bumps by `amount` on every
    # hit (capped at 100); `bonus_count` resets to BONUSADD on every
    # successful pickup.
    DAMAGE_COUNT_CAP = 100
    BONUSADD         = 6

    # Maps each weapon to the ammo type it consumes; melee weapons
    # have no ammo (nil). The HUD reads this to decide what to show
    # in the big AMMO slot.
    WEAPON_AMMO = {
      fist:     nil,
      chainsaw: nil,
      pistol:   :bullet,
      shotgun:  :shell,
      chaingun: :bullet,
      rocket:   :rocket,
      plasma:   :cell,
      bfg:      :cell,
    }.freeze

    # Vanilla pistol-start defaults. Maxes match DOOM's ammo caps
    # before backpack pickup (backpack doubles them).
    DEFAULT_AMMO     = { bullet:  50, shell:  0, rocket:  0, cell:   0 }.freeze
    DEFAULT_MAX_AMMO = { bullet: 200, shell: 50, rocket: 50, cell: 300 }.freeze

    # Starting weapons match vanilla: pistol-start gives you fist and
    # pistol, no others.
    DEFAULT_WEAPONS = {
      fist: true, pistol: true,
      shotgun: false, chaingun: false, rocket: false,
      plasma: false, bfg: false, chainsaw: false,
    }.freeze

    # Vanilla clip sizes — one "clip" of each ammo type. P_GiveAmmo
    # gives `2 * CLIPAMMO[type]` on first weapon pickup, half that on
    # ammo-only items like CLIP / SHEL / BROK / CELL.
    CLIPAMMO = { bullet: 10, shell: 4, rocket: 1, cell: 20 }.freeze

    # Per-weapon pickup amount (ammo type + clip count). Used by
    # pickup_weapon; weapons with no ammo (fist, chainsaw) skip this.
    WEAPON_PICKUP_AMMO = {
      shotgun:  [:shell,  2],
      chaingun: [:bullet, 2],
      rocket:   [:rocket, 2],
      plasma:   [:cell,   2],
      bfg:      [:cell,   2],
      chainsaw: [nil,     0],
    }.freeze

    def self.from_thing(thing)
      new(thing.x, thing.y, thing.angle, 0.0, NOMINAL_VIEW_HEIGHT.to_f,
          DEFAULT_MAX_HEALTH, 0, nil,
          DEFAULT_AMMO.dup, DEFAULT_MAX_AMMO.dup,
          :pistol,
          false,
          0,
          empty_keys,
          DEFAULT_WEAPONS.dup,
          nil,
          false,
          0, 0)
    end

    # Fresh key inventory: no colour, no variant.
    def self.empty_keys
      { blue:   { card: false, skull: false },
        yellow: { card: false, skull: false },
        red:    { card: false, skull: false } }
    end

    # True iff the player holds either variant (card or skull) of this
    # colour. Doom 1 keyed doors accept either; that's what locked-door
    # specials check.
    def has_key?(colour)
      k = keys[colour]
      k && (k[:card] || k[:skull])
    end

    # Picks up a key card/skull. Returns true if absorbed (i.e. the
    # player didn't already hold this exact variant); vanilla's rule
    # is that a duplicate key never disappears from the floor.
    def pickup_key(colour, variant)
      slot = keys[colour]
      return false if slot[variant]
      slot[variant] = true
      true
    end

    # Picks up a weapon (sets owned, gives starting ammo, auto-switches
    # if new). Returns true if anything was absorbed — either the weapon
    # itself was new, or the bundled ammo went into a non-full slot.
    # Vanilla rule (P_GiveWeapon): always set pendingweapon to the new
    # weapon on first pickup; on a duplicate, only the ammo matters.
    def pickup_weapon(weapon)
      ammo_type, clips = WEAPON_PICKUP_AMMO[weapon]
      gave_ammo = false
      if ammo_type && clips > 0
        gave_ammo = add_ammo(ammo_type, clips * CLIPAMMO[ammo_type]) > 0
      end
      if weapons_owned[weapon]
        gave_ammo
      else
        weapons_owned[weapon] = true
        self.pending_weapon = weapon
        true
      end
    end

    def has_weapon?(weapon)
      weapons_owned[weapon] ? true : false
    end

    # Dead = no health. Mirrors vanilla's `playerstate == PST_DEAD`
    # gate on movement and combat actions.
    def dead?
      health <= 0
    end

    # IDDQD-style god mode toggle. Turning it on heals to full health
    # if needed (vanilla refills HP to 100, doesn't touch armor/ammo).
    # Returns the new state for the caller to display.
    def toggle_god!
      self.god_mode = !god_mode
      self.health = DEFAULT_MAX_HEALTH if god_mode && health < DEFAULT_MAX_HEALTH
      god_mode
    end

    # Reset back to pistol-start state. Used on respawn — vanilla
    # single-player restarts the level entirely; we just bring the
    # player back at their last known map_start with default stats
    # and leave the map state (open doors, dead monsters) intact.
    def reset_to_start!(start_thing)
      self.x = start_thing.x
      self.y = start_thing.y
      self.angle = start_thing.angle
      self.bob = 0.0
      self.view_height = NOMINAL_VIEW_HEIGHT.to_f
      self.health = DEFAULT_MAX_HEALTH
      self.armor  = 0
      self.armor_class = nil
      DEFAULT_AMMO.each { |k, v| self.ammo[k] = v }
      self.current_weapon = :pistol
      self.pending_weapon = nil
      DEFAULT_WEAPONS.each { |k, v| self.weapons_owned[k] = v }
      self.keys = self.class.empty_keys
      self.backpack = false
      DEFAULT_MAX_AMMO.each { |k, v| self.max_ammo[k] = v }
      self.damage_count = 0
      self.bonus_count  = 0
    end

    # Count for the current weapon's ammo type, or nil for melee.
    def current_ammo
      type = WEAPON_AMMO[current_weapon]
      type ? ammo[type] : nil
    end

    # Add ammo of one type, clamped to max. Returns the amount
    # actually absorbed (so caller can tell if the pickup did
    # anything — pickups in vanilla are consumed only on overflow).
    def add_ammo(type, amount)
      cap = max_ammo[type]
      before = ammo[type]
      ammo[type] = [before + amount, cap].min
      ammo[type] - before
    end

    # Apply damage. Armor absorbs a fraction first — 1/3 for green,
    # 1/2 for blue (vanilla P_DamageMobj). Once armor is exhausted
    # its class is cleared. Health clamps at 0. God mode (vanilla
    # IDDQD) short-circuits the whole path so no armor or health is
    # ever spent.
    def take_damage(amount)
      return if amount <= 0
      return if god_mode
      raw = amount
      if armor.positive? && armor_class
        frac  = (armor_class == :blue) ? 0.5 : (1.0 / 3.0)
        saved = (amount * frac).to_i
        if saved >= armor
          saved = armor
          self.armor_class = nil
        end
        self.armor = armor - saved
        amount -= saved
      end
      self.health = [health - amount, 0].max
      # Drive the red screen flash. Vanilla uses the raw incoming
      # damage (pre-armor), capped at 100.
      self.damage_count = [damage_count + raw, DAMAGE_COUNT_CAP].min
    end

    # Reset the bonus-pickup yellow flash counter. Called by Pickups
    # after any successful absorbtion (item / armor / ammo / key / weapon).
    def flash_bonus!
      self.bonus_count = BONUSADD
    end

    # Per-tic decay for screen-tint counters. Game.tick calls this once
    # per tic, after all damage / pickup events have been applied.
    def tic_screen_tints!
      self.damage_count = damage_count - 1 if damage_count > 0
      self.bonus_count  = bonus_count  - 1 if bonus_count  > 0
    end

    # Translucent RGBA overlay color for the current frame, or nil if no
    # tint is active. Red flash dominates a yellow one — vanilla applies
    # them in the same priority order (damage trumps bonus). The math
    # mirrors vanilla's V_SetPalette: count → 1..8 (red) or 1..4 (bonus).
    def screen_tint
      red = (damage_count + 7) >> 3
      red = 8 if red > 8
      return [255, 0, 0, red * 16] if red > 0

      bonus = (bonus_count + 7) >> 3
      bonus = 4 if bonus > 4
      return [215, 186, 69, bonus * 12] if bonus > 0

      nil
    end

    # Heal up to a cap. Returns true iff health actually went up
    # (i.e. wasn't already at/above the cap). Pickups use the
    # return value to decide whether to consume the item.
    def add_health(amount, max: DEFAULT_MAX_HEALTH)
      return false if health >= max
      self.health = [health + amount, max].min
      true
    end

    # Add armor points, optionally setting the class. Passing `type:`
    # nil keeps the current class (armor bonus); a value of :green or
    # :blue switches the absorption rate to match. Capped at `max`.
    # Returns whether anything changed (false when already at cap).
    def add_armor(amount, type: nil, max: DEFAULT_MAX_ARMOR)
      return false if armor >= max
      self.armor = [armor + amount, max].min
      self.armor_class = type if type
      self.armor_class ||= :green  # an armor point with no class still has to absorb
      true
    end

    # Green / blue armor pickup. Sets armor to `amount` and switches
    # class — does NOT add. Returns false (and changes nothing) if
    # player already has at least that many points, mirroring vanilla:
    # picking up green armor at 100+ is a no-op, blue at 200 is too.
    def pickup_armor_pack(amount, type:)
      return false if armor >= amount
      self.armor = amount
      self.armor_class = type
      true
    end

    # Backpack: doubles every ammo max (first pickup only) and gives
    # one standard "clip" of each type (10/4/1/20 — vanilla
    # `clipammo[]`). Subsequent backpacks still give ammo but don't
    # re-double the caps. Returns true if anything was absorbed.
    def pickup_backpack
      absorbed = false
      unless backpack
        max_ammo.each_key { |k| max_ammo[k] *= 2 }
        self.backpack = true
        absorbed = true
      end
      absorbed = true if add_ammo(:bullet, 10) > 0
      absorbed = true if add_ammo(:shell,   4) > 0
      absorbed = true if add_ammo(:rocket,  1) > 0
      absorbed = true if add_ammo(:cell,   20) > 0
      absorbed
    end
  end
end
