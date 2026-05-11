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
    Mobj = Struct.new(
      :thing, :health, :state, :frame_index, :frame_timer, :kind,
      :info, :state_key, :target, :move_dir, :move_count, :reaction_time,
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

      # Targets the source if the source is a player (vanilla also
      # supports monster-vs-monster infighting; we don't yet).
      mobj.target = source if source.respond_to?(:x) && source.respond_to?(:y)

      # Roll pain — pain_chance is out of 256. We bail out if the mobj
      # is already in the pain sequence (vanilla's MF_JUSTHIT logic).
      if @rng.rand(256) < mobj.info.pain_chance && mobj.info.pain_state
        enter_state(mobj, mobj.info.pain_state)
      end
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
      mobj.frame_timer -= 1
      return if mobj.frame_timer > 0
      advance_monster_state(mobj)
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
      @sound&.play_at(:barexp, cx, cy, source, source: mobj) if source
      if source
        damage_amt = falloff_damage(cx, cy, source.x, source.y)
        source.take_damage(damage_amt) if damage_amt > 0
      end
      # Damage every other live mobj within range with the same
      # linear falloff vanilla P_RadiusAttack uses — barrel does
      # 128 max at point-blank, 0 at 128 units. This means a barrel
      # can kill a POSS (20 HP) at up to ~100 units, take a SPOS
      # (30 HP) out at ~96, and seriously hurt a TROO (60 HP) up
      # close. Chain-detonation between barrels still works because
      # barrels at near-zero distance take >>20 damage.
      @mobjs.select { |m| m != mobj && m.state == :alive }.each do |other|
        amt = falloff_damage(cx, cy, other.thing.x.to_f, other.thing.y.to_f)
        damage(other, amt, source: source) if amt > 0
      end
    end

    def falloff_damage(cx, cy, tx, ty)
      d = Math.hypot(tx - cx, ty - cy)
      return 0 if d >= EXPLOSION_RADIUS
      ((EXPLOSION_RADIUS - d) / EXPLOSION_RADIUS * EXPLOSION_MAX_DAMAGE).to_i
    end
  end
end
