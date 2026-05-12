module Rubydoom
  # DOOM HUD face animation. Vanilla's state machine in st_stuff.c has
  # nine prioritized states; we implement the five that don't require
  # plumbing damage-source direction or rampage tracking:
  #
  #   * Dead       (STFDEAD0)            — health <= 0
  #   * God        (STFGOD0)             — invulnerable / IDDQD
  #   * Ouch       (STFOUCH{P})          — took > 20 damage in one tic
  #   * Evil grin  (STFEVL{P})           — just picked up a new weapon
  #   * Wander     (STFST{P}{D})         — default; cycles direction
  #
  # Not yet wired:
  #   * Turn-toward-attacker (STFTR / STFTL) — needs the damage source
  #     to be piped through Player#take_damage so we can compute
  #     "is the attacker on my left or right?".
  #   * Rampage (STFKILL{P}) — needs a fired-without-damage counter.
  #
  # `P` is a 0..4 pain offset derived from health bands; `D` is a
  # 0..2 wander direction (center / right / left).
  class Face
    # Stand-still wander direction sticks for this many tics before
    # re-rolling. Vanilla varies between ~17 and ~70 depending on
    # state; one second sits in that window and reads as natural.
    WANDER_TICS = 35

    # How long the ouch / evil-grin face overrides the default
    # state, in tics. Vanilla constants: ST_TURNCOUNT = 26 (for ouch
    # in st_stuff.c, called "TURN" because it shares the timer with
    # the turn face), ST_EVILGRINCOUNT = 2*TICRATE = 70.
    OUCH_TICS     = 35
    EVILGRIN_TICS = 70

    # Vanilla ST_MUCHPAIN: a single hit over 20 HP triggers the ouch
    # face. Smaller hits use other states (pain / turn) we haven't
    # wired yet, so for now they just fall through to the default.
    OUCH_DAMAGE_THRESHOLD = 20

    DIRECTIONS = 3   # 0=center, 1=right, 2=left

    DEAD_LUMP = "STFDEAD0"
    GOD_LUMP  = "STFGOD0"

    def initialize(rng: Random.new)
      @tics_left          = 0
      @direction          = 0
      @ouch_left          = 0
      @evilgrin_left      = 0
      @prev_health        = nil
      @prev_weapons_count = nil
      @random             = rng
    end

    def update_tic(player)
      health        = player.health
      weapons_count = player.weapons_owned.count { |_, v| v }

      # Big hit since last frame → ouch face for the next OUCH_TICS.
      # Skip the first frame (no prior history to diff against).
      if @prev_health
        drop = @prev_health - health
        @ouch_left = OUCH_TICS if drop > OUCH_DAMAGE_THRESHOLD
      end

      # Weapon count went UP since last frame → evil grin. We diff the
      # count instead of asking Pickups directly so we don't need a
      # callback wired through; respawn drops the count back to 2 and
      # we correctly don't trigger then (it has to *increase*).
      if @prev_weapons_count && weapons_count > @prev_weapons_count
        @evilgrin_left = EVILGRIN_TICS
      end

      @prev_health        = health
      @prev_weapons_count = weapons_count

      @ouch_left     -= 1 if @ouch_left     > 0
      @evilgrin_left -= 1 if @evilgrin_left > 0

      return if health <= 0
      @tics_left -= 1
      return if @tics_left > 0
      @direction = @random.rand(DIRECTIONS)
      @tics_left = WANDER_TICS
    end

    def lump_name(player)
      return DEAD_LUMP if player.health <= 0
      return GOD_LUMP  if player.god_mode || player.has_power?(:invulnerability)
      pain = pain_offset(player.health)
      return "STFOUCH#{pain}" if @ouch_left     > 0
      return "STFEVL#{pain}"  if @evilgrin_left > 0
      "STFST#{pain}#{@direction}"
    end

    private

    # Vanilla ST_calcPainOffset: `(ST_NUMPAINFACES * (100 - health)) / 101`
    # with ST_NUMPAINFACES = 5, then clamped 0..4. Puts band edges at
    # h = 80 / 60 / 40 / 20 — well-known DOOM thresholds.
    def pain_offset(health)
      h = health.clamp(0, 100)
      (((100 - h) * 5) / 101).clamp(0, 4)
    end
  end
end
