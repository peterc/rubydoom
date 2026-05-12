module Rubydoom
  # Action functions for the monster state machine. Combat decides when
  # to fire each action by reading the `action` field on the entered
  # state and calling `MonsterAI#run_action(symbol, mobj, player)`.
  # The handlers may mutate the mobj's position, target, move_dir, and
  # may issue further state transitions via `combat.enter_state`.
  #
  # Direct port of the corresponding A_* functions in
  # linuxdoom-1.10/p_enemy.c. Differences from vanilla:
  #
  #   * Targeting is single-player only (vanilla picks among 4 players
  #     in deathmatch).
  #   * No infighting — a hit-by-monster never retargets to that
  #     monster, only to a player.
  class MonsterAI
    # Sight range from p_enemy.c. Vanilla doesn't actually clamp by
    # range — A_Look only checks the sight ray. We use a generous cap to
    # avoid asking the sight system about half a level per tic.
    SIGHT_RANGE      = 2048.0
    MELEE_RANGE      = 64.0   # MELEERANGE in vanilla
    MISSILE_RANGE    = 1024.0 # approximate "in attack range"

    # Hitscan damage per A_PosAttack pellet: vanilla `((random()%5)+1)*3`
    # → 3, 6, 9, 12, 15.
    POS_DAMAGE_DICE  = (1..5)
    # Shotgun-guy attack: 3 pellets, same per-pellet dice.
    SPOS_PELLETS     = 3
    # Demon bite / imp claw: `((random()%10)+1)*4` → 4..40.
    MELEE_DAMAGE_DICE = (1..10)
    MELEE_DAMAGE_MULT = 4
    POS_DAMAGE_MULT   = 3

    # Vanilla zombie/SS pellet spread: 22.5° half-cone (BAM 4...). Slight
    # rounding; the original is computed off a uniform rand.
    POS_SPREAD_DEG    = 22.5

    # Action handler table: AI dispatch symbol → method name.
    ACTIONS = {
      look:           :a_look,
      chase:          :a_chase,
      face_target:    :a_face_target,
      pos_attack:     :a_pos_attack,
      spos_attack:    :a_spos_attack,
      troo_attack:    :a_troo_attack,
      sarg_attack:    :a_sarg_attack,
      bruisr_attack:  :a_bruisr_attack,
      boss_death:     :a_boss_death,
      pain:           :a_pain,
      scream:         :a_scream,
      fall:           :a_fall,
    }.freeze

    def initialize(map, combat, sight, movement, sound: nil,
                   noise_alert: nil, projectiles: nil, rng: Random.new)
      @map         = map
      @combat      = combat
      @sight       = sight
      @movement    = movement
      @sound       = sound
      @noise_alert = noise_alert
      @projectiles = projectiles
      @floors      = nil
      @rng         = rng
    end

    # Late-bind: App wires the Projectiles system after this AI is
    # constructed so the system's @combat ref can already point at the
    # finished Combat. The Floors handle is used by A_BossDeath to
    # lower tag-666 sectors when the E1M8 Baron arena is cleared.
    attr_writer :projectiles, :floors

    def run_action(symbol, mobj, player)
      method_name = ACTIONS[symbol]
      return unless method_name
      send(method_name, mobj, player)
    end

    private

    public

    # Late-bind the Clipper since Combat / Hitscan ordering means we
    # don't have it at construction time.
    attr_writer :clipper

    private

    # ---------- targeting / sight ----------

    # Eye height for the source of a sight ray — vanilla uses
    # `z + height - height/4` (3/4 of the body height). Floor is the
    # source's sector floor.
    def sight_z_for_mobj(mobj)
      floor = @clipper.floor_at(mobj.thing.x, mobj.thing.y) || 0
      h = mobj.info.height
      floor + h - (h / 4)
    end

    # Eye-height z for whatever the monster is looking at. Player uses
    # view_height; another mobj uses 3/4 of its body (vanilla rule).
    # Falls back to the floor z for arbitrary "things" without info.
    def player_eye(target)
      if target.respond_to?(:view_height)
        floor = @clipper.floor_at(target.x, target.y) || 0
        floor + target.view_height
      elsif target.respond_to?(:thing) && target.respond_to?(:info)
        floor = @clipper.floor_at(target.thing.x, target.thing.y) || 0
        floor + target.info.height - (target.info.height / 4)
      else
        @clipper.floor_at(target.x, target.y) || 0
      end
    end

    def can_see_player?(mobj, target)
      sz = sight_z_for_mobj(mobj)
      tx, ty = target_xy(target)
      tz = player_eye(target)
      @sight.visible?(mobj.thing.x, mobj.thing.y, sz, tx, ty, tz)
    end

    # Forward 180° check — only used by A_Look so a monster doesn't
    # acquire a target who's directly behind it (vanilla's rule unless
    # the monster has been noise-alerted).
    def in_front_of?(mobj, target)
      tx, ty = target_xy(target)
      ang_to_target = Math.atan2(ty - mobj.thing.y, tx - mobj.thing.x) * 180.0 / Math::PI
      diff = ((ang_to_target - mobj.thing.angle + 540) % 360) - 180
      diff.abs <= 90
    end

    # Distance to target (Chebyshev) — vanilla `P_ApproxDistance` uses
    # max(|dx|, |dy|) + min/2 to approximate Euclidean cheaply. Close
    # enough for the AI to make decisions on.
    def approx_dist(mobj, x, y)
      dx = (x - mobj.thing.x).abs
      dy = (y - mobj.thing.y).abs
      dx > dy ? dx + dy / 2 : dy + dx / 2
    end

    # ---------- A_Look ----------

    # Pre-target idle. Each tic, if reaction_time has ticked down and
    # either (a) the noise-alert flood reached our sector, or (b) the
    # player is in our forward cone with line of sight, acquire the
    # target and transition to the see_state.
    def a_look(mobj, player)
      return if mobj.reaction_time && mobj.reaction_time > 0
      return unless player.health > 0

      # Vanilla MF_AMBUSH ("deaf"): the noise-alert flood doesn't
      # wake this monster. They still wake on sight — fall through
      # to the in-front + line-of-sight check below.
      deaf = (mobj.thing.flags & Map::THING_FLAG_AMBUSH) != 0
      unless deaf
        noise_target = @noise_alert&.target_for(sector_index_for(mobj))
        if noise_target
          wake!(mobj, noise_target, player)
          return
        end
      end

      return unless in_front_of?(mobj, player)
      return unless can_see_player?(mobj, player)
      wake!(mobj, player, player)
    end

    # Acquire `target` and play the sight sound (vanilla A_See chains
    # into the see-state via S_StartSound). Distance is from the
    # monster to the listener (the actual player) so far-off shouts
    # fade with distance.
    def wake!(mobj, target, listener)
      mobj.target = target
      if @sound && mobj.info.see_sound
        @sound.play_at(mobj.info.see_sound, mobj.thing.x, mobj.thing.y, listener,
                       source: mobj)
      end
      @combat.enter_state(mobj, mobj.info.see_state)
    end

    # Sector containing the monster — looked up via Clipper.
    def sector_index_for(mobj)
      @clipper&.sector_index_at(mobj.thing.x, mobj.thing.y)
    end

    # ---------- A_Chase ----------

    # Per-tic chase + attack-decision. Vanilla shape:
    #   1. If we have no target, drop back to spawn state.
    #   2. If our target is dead, also drop back to spawn.
    #   3. If we're in melee range and have a melee state, attack.
    #   4. If we're in missile range and have a missile state, attack.
    #   5. Else move one step; reroll direction if blocked or move_count
    #      ran out.
    def a_chase(mobj, player)
      if mobj.target.nil? || (mobj.target.respond_to?(:health) && mobj.target.health <= 0)
        mobj.target = nil
        @combat.enter_state(mobj, mobj.info.spawn_state)
        return
      end
      target = mobj.target
      tx, ty = target_xy(target)

      # Decrement move_count; reroll on expiry, also reroll if last
      # walk hit a wall (handled inside try_walk by setting move_dir
      # to NODIR — we mirror that with a flag implicitly: if try_walk
      # returns false, pick a new direction).
      mobj.move_count -= 1 if mobj.move_count && mobj.move_count > 0

      # Face the target for attack range checks (vanilla doesn't do
      # this here, but it stabilises the attack-rolling).
      dist = approx_dist(mobj, tx, ty)

      # Vanilla P_CheckMeleeRange / P_CheckMissileRange both gate on
      # P_CheckSight to the target. Without that the monster fires
      # (and plays its loud attack sound) blind through walls — the
      # source of the "ghost shots from behind a closed door" report.
      # We cache the sight result so we only ask once per chase tic.
      target_in_sight = nil

      if mobj.info.melee_state && dist <= MELEE_RANGE
        target_in_sight = can_see_player?(mobj, target)
        if target_in_sight
          @combat.enter_state(mobj, mobj.info.melee_state)
          return
        end
      end

      if mobj.info.missile_state && dist <= MISSILE_RANGE
        # Vanilla rolls a missile-chance check based on distance; we
        # use a flat 1-in-4 chance for now to avoid them firing every
        # tic. The sight check (vanilla P_CheckMissileRange) must pass.
        target_in_sight = can_see_player?(mobj, target) if target_in_sight.nil?
        if target_in_sight && @rng.rand(4).zero?
          @combat.enter_state(mobj, mobj.info.missile_state)
          return
        end
      end

      # Try to step in our current direction.
      stepped = @movement.try_walk(mobj, player)
      if !stepped || mobj.move_count.nil? || mobj.move_count <= 0
        @movement.new_chase_dir(mobj, tx, ty, player)
        mobj.move_count = 15 + @rng.rand(16)  # vanilla: rand & 15
        # Try once more in the freshly-picked direction.
        @movement.try_walk(mobj, player)
      end

      # Update facing to match movement direction.
      if mobj.move_dir != MonsterMovement::DI_NODIR
        mobj.thing.angle = mobj.move_dir * 45.0
      end

      # Idle wandering grunts (posact / bgact / dmact). Vanilla rolls
      # P_Random() < 3 once per A_Chase tic, i.e. 3-in-256 ≈ 1.2% per
      # tic — roughly one grunt every ~6 seconds per monster.
      play_active_sound(mobj, player) if @rng.rand(256) < ACTIVE_SOUND_CHANCE
    end

    ACTIVE_SOUND_CHANCE = 3

    def play_active_sound(mobj, listener)
      return unless @sound && mobj.info.active_sound
      @sound.play_at(mobj.info.active_sound,
                     mobj.thing.x, mobj.thing.y, listener,
                     source: mobj)
    end

    # ---------- A_FaceTarget ----------

    # Vanilla MF_SHADOW fuzz when the target is invisible. P_Random()
    # range -255..+255 multiplied by 1<<21 BAM ≈ ±22.5° in worst case;
    # we sample uniformly in ±FUZZ_DEG_MAX for the same gameplay feel
    # (some attacks go wide, ranged combat becomes much harder).
    FUZZ_DEG_MAX = 22.5

    # Snap angle to point at the current target. When the target is
    # the player and they have invisibility (blursphere) active, the
    # aim is perturbed — this falls through to every monster attack
    # that uses `mobj.thing.angle` (hitscan and projectile alike).
    def a_face_target(mobj, _player)
      return unless mobj.target
      tx, ty = target_xy(mobj.target)
      ang = Math.atan2(ty - mobj.thing.y, tx - mobj.thing.x) * 180.0 / Math::PI
      if mobj.target.respond_to?(:has_power?) && mobj.target.has_power?(:invisibility)
        ang += (@rng.rand - 0.5) * 2 * FUZZ_DEG_MAX
      end
      mobj.thing.angle = ang % 360.0
    end

    # ---------- A_PosAttack / A_SPosAttack ----------

    # Zombieman: single bullet, fans by `angle + rand_spread` and fires
    # one hitscan at the player.
    def a_pos_attack(mobj, player)
      return unless mobj.target
      play_attack_sound(mobj, player)
      fire_bullet(mobj, player, spread_deg: POS_SPREAD_DEG, damage: pos_damage)
    end

    # Shotgun guy: 3 pellets, same spread / dice.
    def a_spos_attack(mobj, player)
      return unless mobj.target
      play_attack_sound(mobj, player)
      SPOS_PELLETS.times { fire_bullet(mobj, player, spread_deg: POS_SPREAD_DEG, damage: pos_damage) }
    end

    def play_attack_sound(mobj, listener)
      return unless @sound && mobj.info.attack_sound
      @sound.play_at(mobj.info.attack_sound,
                     mobj.thing.x, mobj.thing.y, listener,
                     source: mobj)
    end

    def pos_damage
      (1 + @rng.rand(5)) * POS_DAMAGE_MULT
    end

    # Cast a hitscan from the monster forward. Scans the ray for the
    # nearest target — the player, or any other live mobj — within
    # the spread cone. A monster shot that lands on another monster
    # routes through Combat#damage with `source: mobj`, which fires
    # the retarget-on-damage (infighting) logic so the victim turns
    # on its attacker.
    def fire_bullet(mobj, player, spread_deg:, damage:)
      sx = mobj.thing.x
      sy = mobj.thing.y
      ang = mobj.thing.angle + (@rng.rand - 0.5) * 2 * spread_deg
      rad = ang * Math::PI / 180.0
      dx  = Math.cos(rad)
      dy  = Math.sin(rad)

      best_t = nil
      best   = nil

      # Player as a candidate.
      pr = Clipper::PLAYER_RADIUS
      t_pl = ray_circle_t(sx, sy, dx, dy, player.x, player.y, pr)
      if t_pl
        best_t = t_pl
        best   = player
      end

      # Other live mobjs — skip the shooter; monsters and barrels
      # alike are valid bullet targets.
      @combat.shootables.each do |thing, mr, _mh|
        other = @combat.mobj_for(thing)
        next if other.nil? || other == mobj
        t = ray_circle_t(sx, sy, dx, dy, thing.x, thing.y, mr)
        next unless t
        next if best_t && t >= best_t
        best_t = t
        best   = other
      end

      return unless best

      # Wall blocking check via sight ray from monster eye to target
      # body centre.
      sz = sight_z_for_mobj(mobj)
      if best.respond_to?(:view_height)
        tx = best.x; ty = best.y; tz = player_eye(best)
      else
        tx = best.thing.x; ty = best.thing.y
        floor = @clipper.floor_at(tx, ty) || 0
        h = best.info ? best.info.height : Combat::BARREL_HEIGHT
        tz = floor + h / 2.0
      end
      return unless @sight.visible?(sx, sy, sz, tx, ty, tz)

      if best.respond_to?(:take_damage) && !best.respond_to?(:info)
        best.take_damage(damage)
      else
        @combat.damage(best, damage, source: mobj)
      end
    end

    # Target may be a Player (exposes .x / .y directly) or another
    # Mobj (.thing.x / .thing.y) once infighting kicks in. This
    # collapses both into an (x, y) pair so chase / face / attack
    # paths don't have to branch.
    def target_xy(target)
      if target.respond_to?(:thing) && target.respond_to?(:info)
        [target.thing.x, target.thing.y]
      else
        [target.x, target.y]
      end
    end

    def ray_circle_t(px, py, dx, dy, cx, cy, r)
      tx = cx - px
      ty = cy - py
      proj = tx * dx + ty * dy
      return nil if proj < 0
      perp_sq = tx * tx + ty * ty - proj * proj
      r_sq = r * r
      return nil if perp_sq > r_sq
      proj - Math.sqrt(r_sq - perp_sq)
    end

    # ---------- A_TroopAttack / A_SargAttack ----------

    # Imp: vanilla swipes for `(rand%8+1)*3` if in melee range, else
    # throws a fireball. Vanilla A_TroopAttack plays the bite sound only
    # on the melee hit and `sfx_firsht` (via P_SpawnMissile) on the
    # fireball; we keep that split — the claw sample comes through
    # play_attack_sound here, the firsht plays inside spawn_imp_fireball.
    def a_troo_attack(mobj, player)
      return unless mobj.target
      if approx_dist(mobj, player.x, player.y) <= MELEE_RANGE + 20
        play_attack_sound(mobj, player)
        damage = (1 + @rng.rand(8)) * 3
        player.take_damage(damage)
        return
      end
      # Out of melee — throw a fireball. If the projectile system isn't
      # wired (older test setups), fall back to the previous no-op so the
      # state machine still completes.
      @projectiles&.spawn_imp_fireball(mobj, player, listener: player)
    end

    # Baron of Hell: claw at melee range, else spits a green fireball
    # (MT_BRUISERSHOT). Vanilla A_BruisAttack: melee damage `(rand%8 +
    # 1) * 10` = 10..80, sound dsclaw on hit. Out of melee the missile
    # leaves on its own deathsound path; we don't play attack_sound
    # here because the missile path uses dsfirsht inside the spawn.
    def a_bruisr_attack(mobj, player)
      return unless mobj.target
      if approx_dist(mobj, player.x, player.y) <= MELEE_RANGE + 20
        play_attack_sound(mobj, player)   # dsclaw
        damage = (1 + @rng.rand(8)) * 10
        player.take_damage(damage)
        return
      end
      @projectiles&.spawn_bruiser_ball(mobj, player, listener: player)
    end

    # E1M8 boss-arena gate. Runs from the terminal Baron death frame
    # (S_BOSS_DIE7). Vanilla A_BossDeath gates by gameepisode+gamemap
    # and mobj type, walks every thinker to see whether any other live
    # mobj of the same type remains, and when the arena is clear fires
    # `EV_DoFloor(666, lowerFloorToLowest)`. We mirror that exactly,
    # minus the multiplayer "is a player still alive" check (we always
    # have a single live player) and minus the E2/E3/E4 / commercial
    # branches (we only ship E1).
    BARON_DOOMEDNUM = 3003

    def a_boss_death(mobj, _player)
      return unless @map.name == "E1M8"
      return unless mobj.info == MonsterInfo[BARON_DOOMEDNUM]
      other_alive = @combat.monsters.any? do |m|
        m.equal?(mobj) ? false : m.info == mobj.info && m.health > 0
      end
      return if other_alive
      @floors&.activate_lower_to_lowest(666)
    end

    # Demon: bite for melee damage when in range.
    def a_sarg_attack(mobj, player)
      return unless mobj.target
      play_attack_sound(mobj, player)
      return unless approx_dist(mobj, player.x, player.y) <= MELEE_RANGE + 20
      damage = (1 + @rng.rand(10)) * MELEE_DAMAGE_MULT
      player.take_damage(damage)
    end

    # ---------- A_Pain / A_Scream / A_Fall ----------

    # Vanilla A_Pain plays the species's pain-sound. Listener is the
    # player so the volume scales by distance.
    def a_pain(mobj, player)
      return unless @sound && mobj.info.pain_sound
      @sound.play_at(mobj.info.pain_sound, mobj.thing.x, mobj.thing.y, player,
                     source: mobj)
    end

    # Vanilla A_Scream plays the death sound — fired on the second
    # death frame, after the monster has dropped to the ground.
    def a_scream(mobj, player)
      return unless @sound && mobj.info.death_sound
      @sound.play_at(mobj.info.death_sound, mobj.thing.x, mobj.thing.y, player,
                     source: mobj)
    end

    # A_Fall clears MF_SOLID — corpses get walked over. Combat already
    # sets `thing.solid_override = false` at start_death, but vanilla
    # does it on this specific frame (later in the death sequence) so
    # the corpse is briefly still solid mid-fall. Match that timing
    # here: we already cleared it earlier; this is a no-op now.
    def a_fall(_mobj, _player); end
  end
end
