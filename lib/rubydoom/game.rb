module Rubydoom
  # The simulation. Game owns every per-map subsystem (clipper, AI,
  # projectiles, weapons, ...), the assets parsed from the WAD, the
  # player, and the explicit ordered tic that advances all of them. It
  # deliberately doesn't require "gosu" or any window library so
  # alternative frontends only need to build an Input each tic, hand it
  # to Game#tick, and read state back off Game to render.
  #
  # Wiring contract: the frontend constructs Game with a `sound:` (the
  # only thing that's frontend-specific Game touches), assigns `game.hud`
  # before calling load_map (HUD's per-tic update is part of the tick
  # order), then calls load_map(name) before the first tick. After that
  # all per-frame work is Game#tick(input) plus reading back game.player /
  # game.map / game.bsp / etc. to render.
  class Game
    # DOOM's native tic rate. The whole game world advances in 1/35s
    # steps, so all speeds/timers are expressed in tics.
    TIC_RATE = 35
    TIC_DT   = 1.0 / TIC_RATE

    # Map units per tic. We use a direct (no-momentum, no-friction)
    # movement model — applying the player's input as an instantaneous
    # velocity rather than vanilla's accel-and-friction integration.
    # Vanilla's run forwardmove (0x32 = 50) is a thrust value, not a
    # velocity; after FRICTION = 0xE800 ≈ 0.90625 the terminal run
    # speed works out to about 16.7 mu/tic. Our 6.86 mu/tic sits
    # below vanilla terminal on purpose — the direct response feels
    # less floaty, even though the magnitude is lower.
    MOVE_SPEED_TIC    = 240.0 / TIC_RATE
    # Degrees of yaw per pixel of mouse movement.
    MOUSE_SENSITIVITY = 0.25
    # Keyboard turn rate. DOOM's normal turn is 640 BAM/tic ≈ 3.515°/tic;
    # we round up slightly so it feels responsive without a Shift modifier.
    KEY_TURN_PER_TIC  = 4.0

    # View bobbing. DOOM completes one bob cycle every 20 tics, so phase
    # advances 2π/20 per tic. Amplitude is a visual choice (calibrated
    # for our slower MOVE_SPEED). Ramp smooths amplitude up/down at
    # start/stop so the bob doesn't snap on and off.
    BOB_PHASE_PER_TIC = 2 * Math::PI / 20
    BOB_AMPLITUDE     = 2.5
    BOB_RAMP_TIME     = 0.12

    # View-height smoothing on step-ups (DOOM's deltaviewheight). When
    # the floor under the player changes, view_height absorbs the step
    # so the eye stays put, then climbs back to NOMINAL at an
    # accelerating rate (DELTA increment per tic). Mirrors p_user.c.
    DELTA_VIEW_INIT_DIV    = 8     # initial delta = (target - current) / 8
    DELTA_VIEW_ACCEL       = 0.25  # delta gains this per tic
    VIEW_HEIGHT_FLOOR_FRAC = 0.5   # don't dip below half nominal
    OOF_FALL_THRESHOLD     = 24    # single-tic drop bigger than this plays dsoof

    attr_reader :wad, :palette, :colormap, :graphics,
                :textures, :sprites, :flats,
                :map, :bsp, :clipper,
                :doors, :plats, :floors, :donuts, :stairs, :teleports,
                :switches, :scrollers,
                :sector_lights, :sector_effects, :pickups,
                :noise_alert, :combat, :sight,
                :monster_movement, :monster_ai, :projectiles,
                :hitscan, :weapons,
                :player
    attr_accessor :hud

    def initialize(wad:, sound: nil, skill: Map::SKILL_DEFAULT, rng: Random.new)
      @wad   = wad
      @sound = sound
      @skill = skill
      # One RNG shared across every per-map sim subsystem. With a seed
      # (RUBYDOOM_SEED), the entire simulation is reproducible — that's
      # the contract the demo-playback benchmark relies on. Tests that
      # want isolation pass their own rng directly to a subsystem.
      @rng   = rng

      # Asset state — palette, colormap, textures/flats/sprites caches —
      # persists across maps. Texture and flat animation phase carries
      # over too, which feels right (the slime flow doesn't snap on a
      # level change).
      @palette  = Palette.from_wad(@wad)
      @colormap = Colormap.from_wad(@wad, @palette)
      @graphics = Graphics.new(@wad, @palette)
      @textures = AnimatedTextures.new(Textures.new(@wad, @palette, @graphics))
      @sprites  = Sprites.new(@wad)
      @flats    = AnimatedFlats.new(Flats.new(@wad))

      @bob_phase = 0.0
      @bob_amp   = 0.0
      @delta_view_height = 0.0
    end

    # Build (or rebuild) every per-map subsystem. Asset state in the
    # constructor persists across maps; everything keyed off the map
    # geometry is rebuilt here. The previous player's inventory is
    # carried into the new map (vanilla single-player behavior — keys
    # reset, but weapons / ammo / backpack / armor / health all stick).
    #
    # `pistol_start: true` skips the inventory carry, giving the fresh
    # player the vanilla pistol-start kit (100 HP, fist + pistol, 50
    # bullets, no armor, no keys). Used by the death respawn path.
    # `arg` is either a map name (looked up in @wad via Map.load) or a
    # pre-built Rubydoom::Map — useful for `Scenario`-style synthetic
    # arenas where you build the geometry in Ruby and skip the WAD.
    def load_map(arg, pistol_start: false)
      carried_player = pistol_start ? nil : @player
      @map        = arg.is_a?(Map) ? arg : Map.load(@wad, arg, skill: @skill)
      @bsp        = Bsp.new(@map.nodes)
      @clipper    = Clipper.new(@map, @bsp)
      @clipper.on_cross = method(:handle_walk_cross)
      @doors      = Doors.new(@map)
      @plats      = Plats.new(@map)
      @floors     = Floors.new(@map)
      @donuts     = Donuts.new(@map)
      @stairs     = Stairs.new(@map)
      @teleports  = Teleports.new(@map, @clipper)
      @teleports.sound = @sound
      @switches   = Switches.new(@map)
      @switches.doors  = @doors
      @switches.plats  = @plats
      @switches.floors = @floors
      @switches.donuts = @donuts
      @switches.sound  = @sound
      @plats.sound = @sound
      @scrollers  = WallScrollers.new(@map)
      @sector_lights  = SectorLights.new(@map, rng: @rng)
      @sector_effects = SectorEffects.new(@clipper)
      @sector_effects.switches = @switches
      @pickups        = Pickups.new(@map)
      @pickups.sound  = @sound
      @player      = Player.from_thing(@map.player_start)
      carry_inventory_from(carried_player) if carried_player
      @noise_alert = NoiseAlert.new(@map)
      # Doors and walk-triggers propagate noise so monsters in the
      # next room aren't caught flat-footed when the player walks in.
      @doors.noise_alert = @noise_alert
      @doors.clipper     = @clipper
      @doors.sound       = @sound
      @doors.listener    = @player
      @switches.listener = @player
      @plats.listener    = @player
      @combat     = Combat.new(@map, sound: @sound, rng: @rng)
      @sight      = Sight.new(@map, @clipper)
      @monster_movement = MonsterMovement.new(@map, @clipper, @combat, rng: @rng)
      @monster_ai = MonsterAI.new(@map, @combat, @sight, @monster_movement,
                                  sound: @sound, noise_alert: @noise_alert,
                                  rng: @rng)
      @monster_ai.clipper = @clipper
      @monster_ai.floors  = @floors
      @combat.ai  = @monster_ai
      @projectiles = Projectiles.new(@map, @sight, @clipper, @combat,
                                     sound: @sound, rng: @rng)
      @monster_ai.projectiles = @projectiles
      @hitscan    = Hitscan.new(@map, @clipper, rng: @rng)
      @projectiles.hitscan = @hitscan
      @weapons    = Weapons.new(hitscan: @hitscan, combat: @combat,
                                sound: @sound, noise_alert: @noise_alert,
                                rng: @rng)
      @weapons.clipper = @clipper
      @weapons.projectiles = @projectiles
      @weapons.wall_hit_handler = method(:handle_gun_cross)
      @hud.weapons = @weapons if @hud

      @last_player_health = @player.health
      @last_floor_z       = @clipper.floor_at(@player.x, @player.y)
      @delta_view_height  = 0.0
      @player.view_height = NOMINAL_VIEW_HEIGHT.to_f
    end

    # One simulation tic. The order is the spec — list-driven so a
    # reviewer can see it at a glance:
    #
    #   1. Look (always, including dead).
    #   2. Movement / view-height (alive) or dead-camera collapse.
    #   3. Sector-moving + scrolling + lighting + damage floors.
    #   4. Pickups (alive only).
    #   5. Weapons / combat / projectiles.
    #   6. Pain sound (edge-detect on health drop).
    #   7. Texture / flat animation.
    #   8. HUD.
    #   9. Discrete edges (use / respawn / weapon-switch / debug).
    def tick(input)
      apply_look(input)
      if @player.dead?
        update_dead_view_height
      else
        apply_movement(input)
        update_view_height
      end
      @doors.update_tic
      @plats.update_tic
      @floors.update_tic
      @donuts.update_tic
      @stairs.update_tic
      @scrollers.update_tic
      @sector_lights.update_tic
      @sector_effects.update_tic(@player)
      @switches.update_tic
      @pickups.update_tic(@player) unless @player.dead?
      @weapons.fire_button = input.fire
      @weapons.update_tic(@player)
      @combat.update_tic(@player)
      @projectiles.update_tic(@player)
      handle_player_pain_sound
      @flats.update_tic
      @textures.update_tic
      @hud&.update_tic(@player)
      handle_edges(input.edges)
      @player.tic_screen_tints!
      @player.tic_powers!
    end

    # Death respawn. Mirrors vanilla single-player: the entire level
    # is reloaded — monsters back, doors closed, sectors at their
    # designer-given heights — and the player respawns pistol-start
    # (100 HP, fist + pistol, 50 bullets, no armor, no keys). Inputs
    # bound to `:respawn` only fire while the player is dead (see
    # App#read_input), but we no-op if called from elsewhere with a
    # live player so the cheat doesn't double-reset a live run.
    def respawn_player
      return unless @player.dead?
      load_map(@map.name, pistol_start: true)
    end

    # Reposition the player without going through a map load — used by
    # RUBYDOOM_X/Y/ANGLE env vars on initial spawn. Each kwarg is
    # ignored when nil; last_floor_z is recomputed so the next tic
    # doesn't see a phantom step.
    def debug_set_player(x: nil, y: nil, angle: nil)
      @player.x = x if x
      @player.y = y if y
      @player.angle = angle if angle
      @last_floor_z = @clipper.floor_at(@player.x, @player.y)
    end

    private

    # Carry the prior map's player inventory into the freshly-spawned
    # player at the new map's start. Vanilla single-player rules:
    #   * health, armor + armor_class, ammo + max_ammo (so backpack
    #     stays doubled), backpack flag, weapons_owned, current_weapon
    #     — all carry.
    #   * keys reset (each map has its own keyset).
    #   * pending_weapon clears — the old Weapons state machine is gone
    #     and we don't want a half-honored switch lingering.
    #   * x / y / angle / view_height / bob come from the new player_start
    #     (already set by Player.from_thing above).
    def carry_inventory_from(prev)
      @player.health      = prev.health
      @player.armor       = prev.armor
      @player.armor_class = prev.armor_class
      prev.ammo.each     { |k, v| @player.ammo[k]     = v }
      prev.max_ammo.each { |k, v| @player.max_ammo[k] = v }
      @player.backpack       = prev.backpack
      prev.weapons_owned.each { |k, v| @player.weapons_owned[k] = v }
      @player.current_weapon = prev.current_weapon
      @player.pending_weapon = nil
      @player.god_mode       = prev.god_mode
    end

    # Walk-trigger dispatch. Clipper calls this for each special
    # linedef the player crossed in the last successful slide. W1
    # (once-only) handlers clear special_type so the trigger can't
    # re-fire; WR handlers leave it intact.
    W1_LIGHT_TO_35   = 35
    W1_STAIRS_BUILD  = 8
    W1_EXIT_NORMAL   = 52
    W1_EXIT_SECRET   = 124

    def handle_walk_cross(ld, side = 0)
      fired =
        if @plats.handle_cross(ld)
          true  # WR — leave special intact.
        elsif (floor_result = @floors.handle_cross(ld))
          ld.special_type = 0 if floor_result == :w1
          true
        elsif (door_result = @doors.handle_cross(ld))
          ld.special_type = 0 if door_result == :w1
          true
        elsif @teleports.handle_cross(ld, @player, side)
          # WR teleport — leave special intact. The jump moves the
          # player to a new floor, so reset the camera step-up
          # smoothing or the next tic registers it as a giant step.
          @last_floor_z      = @clipper.floor_at(@player.x, @player.y)
          @delta_view_height = 0.0
          true
        elsif ld.special_type == W1_STAIRS_BUILD && @stairs.handle_cross(ld)
          ld.special_type = 0
          true
        elsif ld.special_type == W1_LIGHT_TO_35
          @sector_lights.set_tag_light(ld.sector_tag, 35)
          ld.special_type = 0
          true
        elsif ld.special_type == W1_EXIT_NORMAL
          @switches.request_exit!
          ld.special_type = 0
          true
        elsif ld.special_type == W1_EXIT_SECRET
          @switches.request_exit!(secret: true)
          ld.special_type = 0
          true
        else
          false
        end
      return unless fired
      # Any moving-sector trigger the player just stepped on is loud
      # enough to wake monsters in the destination room (lift starting
      # up, floor lowering, walk-trigger door opening). Same alert
      # path as a gunshot.
      sec_index = @clipper.sector_index_at(@player.x, @player.y)
      @noise_alert.alert(@player, sec_index)
    end

    # Gun-trigger dispatch. Weapons calls this for the nearest
    # blocking line of a hitscan when that line has a special. Type 46
    # (GR Door Open Stay) is currently the only gun-trigger we
    # recognise; the click + a noise alert run if it fires.
    def handle_gun_cross(ld)
      return unless @switches.try_shoot(ld)
      sec_index = @clipper.sector_index_at(@player.x, @player.y)
      @noise_alert.alert(@player, sec_index)
    end

    # Weapons whose assets are actually present in this WAD. Shareware
    # `doom1.wad` ships sprites for fist/pistol/shotgun/chaingun/
    # chainsaw/rocket but not plasma (PLSGA0) or BFG (BFGGA0) — those
    # are silently filtered so god mode doesn't hand the player a gun
    # whose idle sprite would crash the renderer. We check the idle
    # PSPR and, for the rocket, the in-flight projectile sprite the
    # renderer needs (any MISLA rotation).
    def present_weapons
      Weapons::INFO.each_key.select do |w|
        next false unless @wad.lump(Weapons::INFO[w][:idle])
        next false if w == :rocket && (1..8).none? { |r| @wad.lump("MISLA#{r}") }
        true
      end
    end

    # Edge-detect player-health drops between tics so we can play the
    # pain sound (vanilla dsplpain at <=quartered health, dsoof for
    # smaller hits; we just use dsplpain for any damage).
    def handle_player_pain_sound
      return unless @last_player_health
      if @player.health <= 0 && @last_player_health > 0
        @sound&.play(:pldeth, source: @player)
      elsif @player.health < @last_player_health
        @sound&.play(:plpain, source: @player)
      end
      @last_player_health = @player.health
    end

    # Apply this tic's look input — keyboard turn first, then mouse dx.
    # DOOM angle increases counter-clockwise (0=E, 90=N), so rightward
    # mouse movement (positive dx) decreases the angle, while Left key
    # increases it.
    def apply_look(input)
      if input.turn_axis != 0
        @player.angle = (@player.angle + input.turn_axis * KEY_TURN_PER_TIC) % 360.0
      end
      if input.look_dx != 0
        @player.angle = (@player.angle - input.look_dx * MOUSE_SENSITIVITY) % 360.0
      end
    end

    # WASD / arrows: W/S/Up/Down walk along the facing vector, A/D strafe
    # perpendicular to it. The proposed delta goes through the Clipper,
    # which blocks moves into walls / closed doors / overly-tall steps and
    # falls back to a one-axis slide when the full move is blocked.
    def apply_movement(input)
      moving = input.walk_axis != 0 || input.strafe_axis != 0
      update_bob(moving)
      return unless moving

      rad = @player.angle * Math::PI / 180.0
      forward_x =  Math.cos(rad); forward_y =  Math.sin(rad)
      right_x   =  Math.sin(rad); right_y   = -Math.cos(rad)

      target_x = @player.x + (forward_x * input.walk_axis + right_x * input.strafe_axis) * MOVE_SPEED_TIC
      target_y = @player.y + (forward_y * input.walk_axis + right_y * input.strafe_axis) * MOVE_SPEED_TIC
      result = @clipper.slide(@player.x, @player.y, target_x, target_y)
      @player.x, @player.y = result if result
    end

    # View-height descent while dead. Vanilla drops `viewheight` by
    # one map unit each tic until it hits DEAD_VIEW_HEIGHT, so the
    # camera collapses to the floor over about half a second.
    def update_dead_view_height
      target = DEAD_VIEW_HEIGHT.to_f
      if @player.view_height > target
        @player.view_height -= 1.0
        @player.view_height = target if @player.view_height < target
      end
      @last_floor_z = @clipper.floor_at(@player.x, @player.y)
    end

    # On a floor-height change under the player, view_height absorbs
    # the delta so the eye stays put in world space, then drifts back
    # to nominal at an accelerating rate (vanilla deltaviewheight).
    def update_view_height
      current_floor = @clipper.floor_at(@player.x, @player.y)
      step          = current_floor - @last_floor_z
      nominal       = NOMINAL_VIEW_HEIGHT.to_f

      # On a step (up OR down), absorb the floor change so the eye
      # stays put in absolute world space, then aim a delta back
      # toward nominal. Negative delta on drops, positive on climbs.
      if step != 0
        @player.view_height -= step
        @delta_view_height   = (nominal - @player.view_height) / DELTA_VIEW_INIT_DIV
        # Vanilla plays dsoof when the player's downward velocity at
        # impact exceeds GRAVITY*8 (~24 units/tic). Without z physics
        # we approximate by treating any single-tic drop bigger than
        # MAXSTEPMOVE as a fall. A descending lift moves at 2 u/tic so
        # it doesn't trigger.
        @sound&.play(:oof, source: @player) if step <= -OOF_FALL_THRESHOLD
      end

      prev = @player.view_height
      @player.view_height += @delta_view_height

      # Settle exactly when we cross nominal in the direction of
      # recovery — without this, the next floor lookup would re-trigger
      # the drift and the camera would never lock to nominal.
      if (prev < nominal && @player.view_height >= nominal) ||
         (prev > nominal && @player.view_height <= nominal)
        @player.view_height = nominal
        @delta_view_height  = 0.0
      end

      # Don't sink below half-nominal (matches vanilla's clamp).
      min_h = nominal * VIEW_HEIGHT_FLOOR_FRAC
      if @player.view_height < min_h
        @player.view_height = min_h
        @delta_view_height  = DELTA_VIEW_ACCEL if @delta_view_height <= 0
      end

      # Vanilla's deltaviewheight ticks up by 0.25 each tic, giving an
      # accelerating recovery. We mirror that in whichever direction
      # the recovery is heading.
      if @delta_view_height != 0
        sign = @delta_view_height > 0 ? 1 : -1
        @delta_view_height += sign * DELTA_VIEW_ACCEL
      end

      @last_floor_z = current_floor
    end

    # View-bob update. Amplitude eases toward BOB_AMPLITUDE while moving
    # and toward zero when stopped (exponential smoothing); phase ticks
    # forward at a constant rate so the sine output is continuous across
    # start/stop transitions instead of jumping back to phase 0.
    def update_bob(moving)
      target_amp = moving ? BOB_AMPLITUDE : 0.0
      alpha      = 1.0 - Math.exp(-TIC_DT / BOB_RAMP_TIME)
      @bob_amp  += (target_amp - @bob_amp) * alpha
      @bob_phase = (@bob_phase + BOB_PHASE_PER_TIC) % (2 * Math::PI)
      @player.bob = @bob_amp * Math.sin(@bob_phase)
    end

    # Apply queued semantic edges to the world. Order within a tic
    # doesn't matter — every edge here is independent (toggle, single
    # action, or pending request).
    def handle_edges(edges)
      edges.each do |edge|
        case edge
        when :toggle_god
          on = @player.toggle_god!
          @player.grant_weapons(present_weapons) if on
          puts "[god mode] #{on ? "ON" : "OFF"}"
        when :use
          @doors.try_use(@player) || @switches.try_use(@player)
        when :respawn
          respawn_player
        when :debug_hurt  then @player.take_damage(10)
        when :debug_heal  then @player.add_health(10)
        when :debug_armor then @player.add_armor(25, type: :green)
        when :weapon_1 then @weapons.request_switch(@player, "1")
        when :weapon_2 then @weapons.request_switch(@player, "2")
        when :weapon_3 then @weapons.request_switch(@player, "3")
        when :weapon_4 then @weapons.request_switch(@player, "4")
        when :weapon_5 then @weapons.request_switch(@player, "5")
        when :weapon_6 then @weapons.request_switch(@player, "6")
        when :weapon_7 then @weapons.request_switch(@player, "7")
        end
      end
    end
  end
end
