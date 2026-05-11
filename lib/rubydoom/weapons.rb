module Rubydoom
  # Player weapon state machine + PSPR animation.
  #
  # Each weapon has an "idle" lump (drawn while ready) and a "fire
  # sequence" — a list of [lump, tics, action?] frames played in order
  # when the fire button is pressed. The optional action symbol fires
  # on the tic the frame is entered: it consumes ammo and resolves the
  # hitscan; later frames in the same sequence are pure animation.
  #
  # When the sequence finishes:
  #   * if a weapon switch is pending (player picked up a new weapon
  #     or pressed a number key), snap to it and idle;
  #   * else if the fire button is still held AND we still have ammo,
  #     restart the sequence (vanilla A_ReFire);
  #   * else go idle.
  #
  # `display_lump(player)` is what `HUD#draw_weapon` should render — it
  # returns the current frame's lump while firing, or the weapon's idle
  # lump otherwise.
  #
  # Hitscan damage values mirror vanilla DOOM:
  #   pistol / chaingun:   5 * (1 + rand(3))           → 5/10/15
  #   shotgun:             7 pellets, each 5 * (1+rand(3)), ±5° spread
  #   chainsaw:            2 * (1 + rand(10))          → 2..20
  #   fist:                2 * (1 + rand(10))          → 2..20
  # Damage is computed but currently has no target — Hitscan returns the
  # wall hit point only. Once monsters / shootable barrels exist, that's
  # where the damage lands.
  class Weapons
    INFO = {
      fist: {
        idle: "PUNGA0",
        fire_seq: [
          ["PUNGB0", 4],
          ["PUNGC0", 4, :punch],
          ["PUNGD0", 5],
          ["PUNGC0", 4],
          ["PUNGB0", 5],
        ],
        ammo: nil,
      },
      pistol: {
        idle: "PISGA0",
        # Each frame's tic count comes from vanilla DOOM states
        # (S_PISTOL1..4). The trailing PISGA0 idle hold is a refire
        # cooldown so holding fire doesn't loop a hair faster than
        # the actual gun does in vanilla.
        fire_seq: [
          ["PISGA0", 4, :fire_pistol],
          ["PISFA0", 1],
          ["PISGB0", 6],
          ["PISGC0", 4],
          ["PISGD0", 5],
          ["PISGA0", 5],
        ],
        ammo: :bullet,
      },
      shotgun: {
        idle: "SHTGA0",
        fire_seq: [
          ["SHTGA0", 3, :fire_shotgun],
          ["SHTFA0", 7],
          ["SHTGB0", 5],
          ["SHTGC0", 5],
          ["SHTGD0", 4],
          ["SHTGC0", 5],
          ["SHTGB0", 5],
          ["SHTGA0", 3],
          ["SHTGA0", 7],
        ],
        ammo: :shell,
      },
      chaingun: {
        idle: "CHGGA0",
        fire_seq: [
          ["CHGGA0", 4, :fire_chaingun],
          ["CHGFA0", 1],
          ["CHGGB0", 4, :fire_chaingun],
          ["CHGFB0", 1],
          ["CHGGA0", 3],
        ],
        ammo: :bullet,
      },
      chainsaw: {
        idle: "SAWGA0",
        fire_seq: [
          ["SAWGC0", 4, :saw],
          ["SAWGD0", 4, :saw],
        ],
        ammo: nil,
      },
      rocket: {
        # Rocket launcher fires a projectile, not a hitscan; we don't
        # have a projectile system yet, so trigger-pull is a no-op
        # animation that returns to idle. Pickup logic still works.
        idle: "MISGA0",
        fire_seq: [],
        ammo: :rocket,
      },
      plasma: { idle: "PLSGA0", fire_seq: [], ammo: :cell },
      bfg:    { idle: "BFGGA0", fire_seq: [], ammo: :cell },
    }.freeze

    # Vanilla weapon-key bindings. 1 cycles fist <-> chainsaw if both
    # owned; the others map straight to a single weapon.
    KEY_BINDINGS = {
      "1" => [:fist, :chainsaw],
      "2" => [:pistol],
      "3" => [:shotgun],
      "4" => [:chaingun],
      "5" => [:rocket],
      "6" => [:plasma],
      "7" => [:bfg],
    }.freeze

    # Sound name per firing action. Looked up at action-frame entry to
    # play the right DSxxxx lump (and to label the noise alert in logs).
    FIRE_SOUNDS = {
      fire_pistol:   :pistol,
      fire_shotgun:  :shotgn,
      fire_chaingun: :pistol,   # vanilla chaingun uses the pistol sample
      punch:         :punch,
      saw:           :sawful,
    }.freeze

    def initialize(hitscan:, combat: nil, sound: nil, noise_alert: nil, rng: Random.new)
      @hitscan      = hitscan
      @combat       = combat
      @sound        = sound
      @noise_alert  = noise_alert
      @rng          = rng
      @state        = :ready
      @seq_index    = 0
      @frame_timer  = 0
      @display_lump = nil
      @fire_button  = false
    end

    # The Clipper is needed at fire time so we can compute which sector
    # the player is in (for the noise alert flood entry). Late-bound
    # because App constructs Weapons before it has a Clipper handy in
    # any specific load_map flow.
    attr_writer :clipper

    # Lump name to render this frame. While firing, returns the current
    # frame's lump; otherwise returns the weapon's idle lump. `player`
    # is needed for the idle fallback (which weapon to look up).
    def display_lump(player)
      @display_lump || INFO[player.current_weapon][:idle]
    end

    # Caller signals fire-button state each tic. The state machine only
    # checks this at frame boundaries (start-of-sequence and end-of-
    # sequence refire), so transient presses can be missed — that
    # matches vanilla's per-tic input model.
    def fire_button=(down)
      @fire_button = down
    end

    # Request a weapon switch via key press. Defers the actual change
    # until the next "ready" frame so the fire animation can complete.
    # Ignores requests for weapons the player doesn't own. The "1" key
    # cycles fist <-> chainsaw when both are owned.
    def request_switch(player, key_char)
      candidates = KEY_BINDINGS[key_char]
      return unless candidates
      # Pick the first owned candidate that isn't the current weapon;
      # if only the current is owned, no-op.
      target = candidates.find { |w| player.weapons_owned[w] && w != player.current_weapon }
      target ||= candidates.find { |w| player.weapons_owned[w] }
      return if target.nil? || target == player.current_weapon
      player.pending_weapon = target
    end

    def update_tic(player)
      if @state == :firing
        @frame_timer -= 1
        advance_frame(player) if @frame_timer <= 0
      end

      if @state == :ready
        # Honour any pending weapon switch first — pickups and number
        # keys queue these via player.pending_weapon.
        if player.pending_weapon
          player.current_weapon = player.pending_weapon
          player.pending_weapon = nil
          @display_lump = nil
        end
        # Then try to start a new fire if the button is held.
        start_fire(player) if @fire_button && can_fire?(player)
      end
    end

    private

    def can_fire?(player)
      info = INFO[player.current_weapon]
      return false if info[:fire_seq].empty?
      ammo_type = info[:ammo]
      return true if ammo_type.nil?
      player.ammo[ammo_type] > 0
    end

    def start_fire(player)
      @state     = :firing
      @seq_index = 0
      apply_frame(player)
    end

    def apply_frame(player)
      info = INFO[player.current_weapon]
      lump, tics, action = info[:fire_seq][@seq_index]
      @display_lump = lump
      @frame_timer  = tics
      do_action(action, player) if action
    end

    def advance_frame(player)
      @seq_index += 1
      info = INFO[player.current_weapon]
      if @seq_index >= info[:fire_seq].size
        # End of sequence — refire if button still held & ammo good
        # & no switch pending. Otherwise drop to ready.
        if player.pending_weapon.nil? && @fire_button && can_fire?(player)
          @seq_index = 0
          apply_frame(player)
        else
          @state        = :ready
          @display_lump = nil
        end
      else
        apply_frame(player)
      end
    end

    def do_action(action, player)
      play_fire_sfx(action, player)
      emit_noise(player) if FIRE_SOUNDS.key?(action)
      case action
      when :fire_pistol   then fire_pistol(player)
      when :fire_shotgun  then fire_shotgun(player)
      when :fire_chaingun then fire_chaingun(player)
      when :punch         then punch(player)
      when :saw           then saw(player)
      end
    end

    def play_fire_sfx(action, player)
      name = FIRE_SOUNDS[action]
      return unless name && @sound
      @sound.play_at(name, player.x, player.y, player)
    end

    # Vanilla P_NoiseAlert: every firing action wakes monsters whose
    # sectors are reachable from the player's sector via two-sided open
    # lines (gated by ML_SOUNDBLOCK).
    def emit_noise(player)
      return unless @noise_alert && @clipper
      sec_index = @clipper.sector_index_at(player.x, player.y)
      @noise_alert.alert(player, sec_index)
    end

    def consume_ammo(player, type, amount = 1)
      player.ammo[type] = [player.ammo[type] - amount, 0].max
    end

    # 5 * (1 + rand(3)) = 5, 10, or 15. Vanilla P_GunShot.
    def bullet_damage
      5 * (1 + @rng.rand(3))
    end

    # 2 * (1 + rand(10)) = 2..20. Vanilla A_Punch / A_Saw.
    def melee_damage
      2 * (1 + @rng.rand(10))
    end

    def shoot(player, damage, range: Hitscan::DEFAULT_RANGE, spread_deg: 0.0)
      result = @hitscan.fire(player,
                             range: range,
                             spread_deg: spread_deg,
                             shootables: @combat&.shootables)
      return unless @combat && result && result[0] == :thing
      mobj = @combat.mobj_for(result[1])
      @combat.damage(mobj, damage, source: player) if mobj
    end

    def fire_pistol(player)
      consume_ammo(player, :bullet)
      shoot(player, bullet_damage)
    end

    def fire_chaingun(player)
      # Each chaingun frame fires one bullet; the sequence has two
      # firing frames so a full cycle eats two bullets.
      return if player.ammo[:bullet] <= 0
      consume_ammo(player, :bullet)
      shoot(player, bullet_damage, spread_deg: 5.6)
    end

    def fire_shotgun(player)
      consume_ammo(player, :shell)
      # 7 pellets, ±5.6° horizontal spread (vanilla SHOTGUNSPREAD).
      7.times { shoot(player, bullet_damage, spread_deg: 5.6) }
    end

    def punch(player)
      shoot(player, melee_damage, range: 64.0)
    end

    def saw(player)
      shoot(player, melee_damage, range: 64.0)
    end
  end
end
