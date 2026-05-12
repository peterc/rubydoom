module Rubydoom
  # Per-thing combat state: health, current animation state, the few
  # AI-only fields (target, move_dir, ...), and the lifecycle that takes
  # a thing from :alive → :dying → :dead.
  #
  # Two kinds of mobj live here today:
  #
  #   :barrel — exploding barrel (doomednum 2035). Walks through a
  #             fixed BEXP A..E death sequence on lethal damage, deals
  #             splash damage on detonation, chain-reacts to other live
  #             barrels in range, and `thing.removed = true` on the
  #             last frame.
  #
  #   :monster — POSS / SPOS / TROO / SARG. Driven by the
  #              `MonsterStates` table; transitions are decided by the
  #              `MonsterAI` action handlers, which Combat dispatches to
  #              when a state's `action` symbol fires. On lethal damage
  #              the mobj's `state_key` is reset to the species' death
  #              state and the state machine just runs through; the last
  #              frame has tics = nil so it sits forever (corpse stays
  #              in the world). MF_SOLID is cleared on death.
  #
  # `shootables` exposes the [thing, radius] pairs Hitscan needs.
  # Monsters in :dying / :dead drop out of that list immediately.
  class Combat
    BARREL_DOOMEDNUM     = 2035
    BARREL_HEALTH        = 20
    EXPLOSION_RADIUS     = 128.0
    EXPLOSION_MAX_DAMAGE = 128

    BARREL_DEATH_FRAMES = [
      ["BEXP", "A", 5],
      ["BEXP", "B", 5],
      ["BEXP", "C", 5],
      ["BEXP", "D", 10],
      ["BEXP", "E", 10],
    ].freeze

    # A unified mobj record. Barrel fields:
    #   thing, health, state, frame_index, frame_timer, kind
    # Monster fields additionally use:
    #   info        — MonsterInfo entry
    #   state_key   — current MonsterStates row key (symbol)
    #   target      — Player when the monster has acquired one
    #   move_dir    — 0..7 cardinal/diagonal index, or 8 (no direction)
    #   move_count  — tics-since-last-newchasedir; vanilla rerolls at 0
    #   reaction_time — tics before A_Look will react (set on damage too)
    # Lost soul dive fields (`skullfly`, `vx`, `vy`, `vz`, `skull_z`) sit
    # idle for every other mobj kind. When a lost soul fires
    # A_SkullAttack, MonsterAI sets `skullfly = true` and assigns the
    # per-tic velocity; Combat#advance_skullfly then runs the dive on
    # top of the normal state machine until the soul collides with
    # something (player, monster, wall) and the bash resolves.
    Mobj = Struct.new(
      :thing, :health, :state, :frame_index, :frame_timer, :kind,
      :info, :state_key, :target, :move_dir, :move_count, :reaction_time,
      :skullfly, :vx, :vy, :vz, :skull_z,
    )

    # No-direction sentinel matching vanilla DI_NODIR.
    DI_NODIR = 8

    def initialize(map, sound: nil, rng: Random.new)
      @map   = map
      @sound = sound
      @rng   = rng
      @mobjs = []
      # Identity-keyed: Thing is a Struct, and Struct.hash is value-based,
      # so when the renderer/AI mutates a thing's sprite_override or
      # frame_override the hash changes and a plain hash lookup misses
      # the bucket. compare_by_identity locks lookups to object_id, which
      # is what we actually want here (one mobj per Thing instance).
      @by_thing = {}.compare_by_identity
      @ai = nil

      map.things.each do |t|
        m =
          if t.type == BARREL_DOOMEDNUM
            spawn_barrel(t)
          elsif (info = MonsterInfo[t.type])
            spawn_monster(t, info)
          end
        next unless m
        @mobjs << m
        @by_thing[t] = m
      end
    end

    # The MonsterAI uses Combat as its window into damage / radius
    # damage / state transitions, and Combat dispatches state-action
    # symbols to the AI. Wiring is two-way and registered post-init.
    attr_accessor :ai

    # Late-bound: Game sets the clipper after Combat init so the
    # skullfly motion step can ask "is this destination legal?". When
    # nil (older test setups), the dive just commits every step without
    # wall checks.
    attr_accessor :clipper

    # [thing, radius, height] for each live mobj. The third element is
    # needed by Hitscan's vertical aim — a shot has a slope and the
    # target's vertical extent decides whether the ray actually enters
    # the body at the line's t. Barrels are 42 tall in vanilla
    # (mobjinfo MT_BARREL); monsters carry their own height.
    BARREL_HEIGHT = 42.0
    def shootables
      out = []
      @mobjs.each do |m|
        next unless m.state == :alive
        radius = m.info ? m.info.radius : ThingTypes[m.thing.type]&.radius
        next unless radius
        height = m.info ? m.info.height.to_f : BARREL_HEIGHT
        out << [m.thing, radius.to_f, height]
      end
      out
    end

    def monsters
      @mobjs.select { |m| m.kind == :monster }
    end

    def mobj_for(thing)
      @by_thing[thing]
    end

    # Apply `amount` damage. `source` is the attacker (Player for player
    # weapons, another Mobj's source for radius damage). For monsters,
    # damage also flips them into "see" mode (target acquired) and may
    # punt them into the pain state.
    def damage(mobj, amount, source: nil)
      return if mobj.state != :alive
      mobj.health -= amount
      if mobj.health <= 0
        start_death(mobj, source)
        return
      end
      return unless mobj.kind == :monster

      # Retarget the attacker so the victim turns to fight. Vanilla
      # rule: skip retarget when source and target are the same
      # species (two imps don't infight). A player source always
      # retargets; a monster source retargets only when its info
      # struct differs from the victim's.
      mobj.target = source if retarget_on_damage?(mobj, source)

      # Roll pain — pain_chance is out of 256. We bail out if the mobj
      # is already in the pain sequence (vanilla's MF_JUSTHIT logic).
      if @rng.rand(256) < mobj.info.pain_chance && mobj.info.pain_state
        enter_state(mobj, mobj.info.pain_state)
      end
    end

    # True iff `target` should switch its target field to `source`
    # after taking damage. Player sources always count; monster sources
    # only count when they're a different species.
    def retarget_on_damage?(target, source)
      return false if source.nil? || source == target
      # Player exposes position via .x/.y directly; mobjs go through
      # .thing.x. Use that as a fast type discriminator.
      return true if source.respond_to?(:x) && source.respond_to?(:y) &&
                     !source.respond_to?(:info)
      return false unless source.respond_to?(:info) && source.info
      source.info != target.info
    end

    def update_tic(player)
      @player = player
      @mobjs.each do |m|
        case m.kind
        when :barrel
          tick_barrel(m)
        when :monster
          tick_monster(m)
        end
      end
    end

    # Dispatched by the AI when an action handler decides to switch
    # state (e.g. A_Chase deciding to enter the attack sequence). Also
    # what Combat itself calls on pain/death.
    def enter_state(mobj, state_key)
      mobj.state_key = state_key
      st = MonsterStates[state_key]
      if st.nil? || st.tics.nil?
        # Terminal state (tics = nil): sit forever. For corpses this is
        # the final death frame.
        if st
          apply_monster_frame(mobj, st)
        end
        mobj.frame_timer = 0
        # State is :dying if we were transitioning into the death
        # sequence; once on the last frame it's :dead and immutable.
        if mobj.state == :dying
          mobj.state = :dead
        end
        # Terminal-frame actions still need to run — A_BossDeath fires
        # from the last Baron death frame to drop the tag-666 floor.
        if st && st.action && @ai && @player
          @ai.run_action(st.action, mobj, @player)
        end
        return
      end
      apply_monster_frame(mobj, st)
      mobj.frame_timer = st.tics
      # Action fires on entry. The AI may itself decide to immediately
      # transition (e.g. A_Chase calling enter_state(missile_state));
      # if it does, we don't want to overwrite that — apply_action
      # returns true if it issued its own transition.
      #
      # @player is set each update_tic and is nil before the first tic
      # (and in test code that pre-positions monsters via enter_state).
      # Actions that read player state would NPE in that case, so we
      # only fire actions when we have a player to hand them.
      if st.action && @ai && @player
        before = mobj.state_key
        @ai.run_action(st.action, mobj, @player)
        return if mobj.state_key != before
      end
    end

    # Vanilla P_RadiusAttack with linear falloff (EXPLOSION_MAX_DAMAGE
    # at the center, 0 at EXPLOSION_RADIUS). `source` is the attacker
    # that gets credit for kills and is also subject to self-damage if
    # it's a Player (rocket-jump). `ignore` is excluded — used by
    # barrels so they don't damage themselves mid-explosion. Public
    # so Projectiles can detonate rockets through the same path.
    def radius_attack(cx, cy, source: nil, ignore: nil)
      if source && source.respond_to?(:take_damage) && !source.respond_to?(:info)
        # Player path — pseudo-mobj with .x/.y and #take_damage.
        amt = falloff_damage(cx, cy, source.x, source.y)
        source.take_damage(amt) if amt > 0
      end
      @mobjs.each do |other|
        next if other == ignore || other.state != :alive
        amt = falloff_damage(cx, cy, other.thing.x.to_f, other.thing.y.to_f)
        damage(other, amt, source: source) if amt > 0
      end
    end

    private

    def spawn_barrel(thing)
      Mobj.new(thing, BARREL_HEALTH, :alive, 0, 0, :barrel,
               nil, nil, nil, nil, nil, nil)
    end

    def spawn_monster(thing, info)
      mobj = Mobj.new(thing, info.health, :alive, 0, 0, :monster,
                      info, info.spawn_state, nil, DI_NODIR, 0,
                      info.reaction_time)
      # Place the mobj on its spawn-state frame immediately so the
      # renderer can pick the right sprite from tic 0.
      st = MonsterStates[info.spawn_state]
      apply_monster_frame(mobj, st)
      mobj.frame_timer = st.tics
      mobj
    end

    def tick_barrel(mobj)
      return unless mobj.state == :dying
      mobj.frame_timer -= 1
      advance_barrel_frame(mobj) if mobj.frame_timer <= 0
    end

    def tick_monster(mobj)
      return if mobj.state == :dead
      # Reaction-time countdown is shared across alive states; A_Look
      # checks it before acquiring a target.
      mobj.reaction_time -= 1 if mobj.reaction_time && mobj.reaction_time > 0
      # Lost soul dive runs every tic, independent of the state-machine
      # timer that animates the dive sprite. advance_skullfly may end
      # the dive and transition to spawn_state — in that case skip the
      # frame-timer advance so we don't immediately step off the fresh
      # state's first frame.
      if mobj.skullfly
        was_flying = true
        advance_skullfly(mobj)
        return if !mobj.skullfly && was_flying
      end
      mobj.frame_timer -= 1
      return if mobj.frame_timer > 0
      advance_monster_state(mobj)
    end

    # Lost soul bash damage: vanilla A_SkullAttack uses
    # `(P_Random() % 8 + 1) * mobj->info->damage` with damage = 3,
    # i.e. 3..24. Applied to the first thing the dive overlaps.
    SKULL_DAMAGE_DICE = 8
    SKULL_DAMAGE_MULT = 3

    # Per-tic dive step. The skullfly motion runs in addition to the
    # state machine — the soul keeps cycling SKUL C/D while moving.
    # End-of-dive conditions, in priority order:
    #
    #   1. Body overlap with the player → damage player, end dive.
    #   2. Body overlap with another live mobj (skip self) → damage
    #      that mobj via #damage (so pain/death/infighting all fire),
    #      end dive.
    #   3. Destination position is invalid (wall, closed door, step too
    #      tall) → end dive, no damage. Vanilla's "skull bashes against
    #      the wall, gets stunned" behavior.
    #   4. New z punched through the sector floor / ceiling → end dive.
    def advance_skullfly(mobj)
      nx = mobj.thing.x + (mobj.vx || 0.0)
      ny = mobj.thing.y + (mobj.vy || 0.0)
      nz = (mobj.skull_z || 0.0) + (mobj.vz || 0.0)

      if @player && @player.health > 0 && skull_overlaps_player?(nx, ny, mobj.info.radius)
        damage_amount = skull_bash_damage
        @player.take_damage(damage_amount)
        end_skullfly(mobj)
        return
      end

      victim = skull_overlaps_other_mobj(mobj, nx, ny)
      if victim
        damage(victim, skull_bash_damage, source: mobj)
        end_skullfly(mobj)
        return
      end

      if @clipper
        current_floor = @clipper.floor_at(mobj.thing.x, mobj.thing.y) || 0
        unless @clipper.position_valid?(
          nx, ny, current_floor, mobj.info.radius,
          start_x: mobj.thing.x, start_y: mobj.thing.y,
          allow_dropoff: true,
        )
          end_skullfly(mobj)
          return
        end
        sector = @clipper.sector_at(nx, ny)
        if sector && (nz <= sector.floor_height || nz + mobj.info.height >= sector.ceiling_height)
          end_skullfly(mobj)
          return
        end
      end

      mobj.thing.x = nx
      mobj.thing.y = ny
      mobj.skull_z = nz
      mobj.thing.z_override = nz
    end

    # End the dive: clear flying flag, zero velocity, drop z_override so
    # the renderer sits the soul back on the floor, and (if still alive)
    # reset to the spawn state — vanilla's `P_SetMobjState(actor,
    # info->spawnstate)` after MF_SKULLFLY clears.
    def end_skullfly(mobj)
      mobj.skullfly = false
      mobj.vx = mobj.vy = mobj.vz = 0.0
      mobj.thing.z_override = nil
      return unless mobj.state == :alive
      enter_state(mobj, mobj.info.spawn_state)
    end

    def skull_bash_damage
      (@rng.rand(SKULL_DAMAGE_DICE) + 1) * SKULL_DAMAGE_MULT
    end

    def skull_overlaps_player?(nx, ny, skr)
      return false unless @player
      reach = skr + Clipper::PLAYER_RADIUS
      (nx - @player.x).abs < reach && (ny - @player.y).abs < reach
    end

    def skull_overlaps_other_mobj(mobj, nx, ny)
      r = mobj.info.radius
      @mobjs.each do |other|
        next if other.equal?(mobj) || other.state != :alive
        oradius = (other.info ? other.info.radius : 0).to_f
        next if oradius.zero?
        reach = r + oradius
        next if (nx - other.thing.x).abs >= reach
        next if (ny - other.thing.y).abs >= reach
        return other
      end
      nil
    end

    def advance_monster_state(mobj)
      st = MonsterStates[mobj.state_key]
      nxt = st.next
      if nxt.nil?
        # Terminal frame: nothing to advance. Make sure we're marked dead.
        mobj.state = :dead if mobj.state == :dying
        return
      end
      enter_state(mobj, nxt)
    end

    def apply_monster_frame(mobj, st)
      return unless st && st.sprite
      mobj.thing.sprite_override = st.sprite
      mobj.thing.frame_override  = st.frame
    end

    def start_death(mobj, source)
      mobj.state = :dying
      mobj.thing.solid_override = false
      if mobj.kind == :barrel
        mobj.frame_index = 0
        apply_barrel_frame(mobj)
        explode(mobj, source)
      elsif mobj.kind == :monster
        # Vanilla also has an "extreme death" path for overkill damage;
        # we ignore it for now and fall through to the normal death
        # sequence.
        if mobj.info.death_state
          enter_state(mobj, mobj.info.death_state)
        else
          mobj.state = :dead
        end
      end
    end

    def apply_barrel_frame(mobj)
      sprite, frame, tics = BARREL_DEATH_FRAMES[mobj.frame_index]
      mobj.thing.sprite_override = sprite
      mobj.thing.frame_override  = frame
      mobj.frame_timer = tics
    end

    def advance_barrel_frame(mobj)
      mobj.frame_index += 1
      if mobj.frame_index >= BARREL_DEATH_FRAMES.size
        mobj.state         = :dead
        mobj.thing.removed = true
      else
        apply_barrel_frame(mobj)
      end
    end

    def explode(mobj, source)
      cx = mobj.thing.x.to_f
      cy = mobj.thing.y.to_f
      @sound&.play_at(:barexp, cx, cy, @player, source: mobj) if @player
      radius_attack(cx, cy, source: source, ignore: mobj)
    end

    def falloff_damage(cx, cy, tx, ty)
      d = Math.hypot(tx - cx, ty - cy)
      return 0 if d >= EXPLOSION_RADIUS
      ((EXPLOSION_RADIUS - d) / EXPLOSION_RADIUS * EXPLOSION_MAX_DAMAGE).to_i
    end
  end
end
