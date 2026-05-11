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
  NOMINAL_VIEW_HEIGHT = 41

  Player = Struct.new(:x, :y, :angle, :bob, :view_height,
                      :health, :armor, :armor_class,
                      :ammo, :max_ammo,
                      :current_weapon,
                      :secrets_found) do
    DEFAULT_MAX_HEALTH = 100
    SOULSPHERE_MAX     = 200
    DEFAULT_MAX_ARMOR  = 200

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

    def self.from_thing(thing)
      new(thing.x, thing.y, thing.angle, 0.0, NOMINAL_VIEW_HEIGHT.to_f,
          DEFAULT_MAX_HEALTH, 0, nil,
          DEFAULT_AMMO.dup, DEFAULT_MAX_AMMO.dup,
          :pistol,
          0)
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
    # its class is cleared. Health clamps at 0.
    def take_damage(amount)
      return if amount <= 0
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
    end

    # Heal up to a cap. No-op if already at or above the cap (vanilla
    # behaviour for stimpack/medikit on a full-health player).
    def add_health(amount, max: DEFAULT_MAX_HEALTH)
      return if health >= max
      self.health = [health + amount, max].min
    end

    # Add armor points, optionally setting the class. Passing `type:`
    # nil keeps the current class (armor bonus); a value of :green or
    # :blue switches the absorption rate to match. Capped at `max`.
    def add_armor(amount, type: nil, max: DEFAULT_MAX_ARMOR)
      return if armor >= max
      self.armor = [armor + amount, max].min
      self.armor_class = type if type
      self.armor_class ||= :green  # an armor point with no class still has to absorb
    end
  end
end
