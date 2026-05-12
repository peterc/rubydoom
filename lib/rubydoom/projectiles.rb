module Rubydoom
  # In-flight missiles — imp fireballs (MT_TROOPSHOT) and player
  # rockets (MT_ROCKET). A projectile is a synthetic Thing that gets
  # pushed into `map.things` so the renderer picks it up like any other
  # sprite, plus a parallel record carrying its velocity and animation
  # state.
  #
  # Each tic:
  #   * Advance position by (vx, vy, vz).
  #   * If the move would leave the sector ceiling / dive into the floor,
  #     or any wall blocks the line of flight, switch to the explosion
  #     animation at the impact point.
  #   * Otherwise check the player and every live monster for AABB
  #     overlap (skipping the owner). On contact, deal damage and
  #     explode.
  #   * Cap lifetime at MAX_TICS so a missile fired into open air with
  #     no obstacle eventually gives up.
  #
  # On explode the sprite cycles through BAL1 C / D / E (the vanilla
  # death frames, all bright) and then `thing.removed = true` so the
  # renderer drops it.
  #
  # Vanilla equivalents in linuxdoom-1.10:
  #   P_SpawnMissile          — spawn helper, aiming math
  #   P_XYMovement / ZMovement — per-tic motion
  #   P_ExplodeMissile         — switch to death state, play deathsound
  class Projectiles
    # Imp fireball stats from mobjinfo.h / info.c.
    IMP_FIREBALL_SPEED     = 10.0   # map units per tic
    IMP_FIREBALL_RADIUS    = 6.0
    IMP_FIREBALL_HEIGHT    = 8
    IMP_FIREBALL_DAMAGE_D  = 8      # damage = (rand % D + 1) * MULT
    IMP_FIREBALL_DAMAGE_M  = 3
    # 3/4 of imp body height (vanilla `z + height - height/4`).
    IMP_LAUNCH_Z_OFFSET    = 32

    # Flight-frame alternation timing. The vanilla imp-fireball state
    # pair runs 4 tics each — BAL1 A bright 4 ↔ BAL1 B bright 4.
    FLIGHT_FRAME_TICS      = 4

    # Fireball-specific frames.
    FIREBALL_FLIGHT_FRAMES = ["A", "B"].freeze
    FIREBALL_DEATH_FRAMES  = [
      ["BAL1", "C", 6],
      ["BAL1", "D", 6],
      ["BAL1", "E", 6],
    ].freeze

    # Rocket stats from MT_ROCKET (mobjinfo.h).
    ROCKET_SPEED          = 20.0
    ROCKET_DAMAGE_D       = 8       # direct hit = (rand%8 + 1) * MULT = 20..160
    ROCKET_DAMAGE_M       = 20
    ROCKET_LAUNCH_Z_OFFSET = 32      # ≈ floor + height/2 from the player's feet
    ROCKET_FLIGHT_FRAMES = ["A"].freeze
    ROCKET_DEATH_FRAMES  = [
      ["MISL", "B", 8],
      ["MISL", "C", 6],
      ["MISL", "D", 4],
    ].freeze

    # Baron of Hell fireball stats from MT_BRUISERSHOT. Faster and
    # heavier-damage than the imp's MT_TROOPSHOT.
    BRUISER_SHOT_SPEED     = 15.0
    BRUISER_SHOT_DAMAGE_D  = 8       # = (rand%8 + 1) * 8 = 8..64
    BRUISER_SHOT_DAMAGE_M  = 8
    # 3/4 of Baron body height (vanilla `z + height - height/4` with
    # height = 64).
    BRUISER_LAUNCH_Z_OFFSET = 48
    BRUISER_FLIGHT_FRAMES   = ["A", "B"].freeze
    BRUISER_DEATH_FRAMES    = [
      ["BAL7", "C", 6],
      ["BAL7", "D", 6],
      ["BAL7", "E", 6],
    ].freeze

    # BFG ball stats from MT_BFG (mobjinfo.h). Flight sprite BFS1 (the
    # floating green ball, two-frame A/B alternation), impact sprite
    # BFE1 (6-frame fireburst A..F). Direct-hit damage rolls
    # (rand%8 + 1) * 100 = 100..800. Spray-on-detonation (A_BFGSpray on
    # the BFE1 C frame, 40 hitscan tracers from the player position)
    # is intentionally NOT wired here — see TODO.txt; we just let the
    # death animation play through for now.
    BFG_SPEED       = 25.0
    BFG_DAMAGE_D    = 8
    BFG_DAMAGE_M    = 100
    BFG_LAUNCH_Z_OFFSET = 32
    BFG_FLIGHT_FRAMES = ["A", "B"].freeze
    BFG_DEATH_FRAMES  = [
      ["BFE1", "A", 8],
      ["BFE1", "B", 8],
      ["BFE1", "C", 8],
      ["BFE1", "D", 8],
      ["BFE1", "E", 8],
      ["BFE1", "F", 8],
    ].freeze

    # Cacodemon fireball stats from MT_HEADSHOT (mobjinfo.h). Speed
    # matches the imp's; damage rolls (rand%8 + 1) * 5 = 5..40. Sprite
    # is BAL2 (red-purple ball) with the same A/B alternation and
    # C/D/E death animation as MT_TROOPSHOT. Launch z is 3/4 of the
    # caco's body height — same fraction as the other shooters.
    HEADSHOT_SPEED       = 10.0
    HEADSHOT_DAMAGE_D    = 8
    HEADSHOT_DAMAGE_M    = 5
    HEADSHOT_LAUNCH_Z_OFFSET = 42
    HEADSHOT_FLIGHT_FRAMES = ["A", "B"].freeze
    HEADSHOT_DEATH_FRAMES  = [
      ["BAL2", "C", 6],
      ["BAL2", "D", 6],
      ["BAL2", "E", 6],
    ].freeze

    # Plasma bolt stats from MT_PLASMA (mobjinfo.h).
    PLASMA_SPEED          = 25.0
    PLASMA_DAMAGE_D       = 8       # direct hit = (rand%8 + 1) * MULT = 5..40
    PLASMA_DAMAGE_M       = 5
    PLASMA_LAUNCH_Z_OFFSET = 32
    PLASMA_FLIGHT_FRAMES   = ["A", "B"].freeze
    PLASMA_DEATH_FRAMES    = [
      ["PLSE", "A", 4],
      ["PLSE", "B", 4],
      ["PLSE", "C", 4],
      ["PLSE", "D", 4],
      ["PLSE", "E", 4],
    ].freeze

    # Hard cap so a projectile that doesn't hit anything (open sky-ish
    # geometry, or a target out of range) doesn't live forever. 175 tics
    # ≈ 5 seconds, which is plenty given the fireball's 10 mu/tic speed
    # and the rocket's 20.
    MAX_TICS               = 175

    # Internal projectile record: the synthetic Thing the renderer reads
    # plus the fields the system mutates each tic. `flight_frames` is
    # the list of frame letters cycled while flying (one entry = no
    # alternation). `death_frames` is the impact animation sequence.
    # `splash` enables P_RadiusAttack on detonation (rockets, not
    # fireballs).
    Proj = Struct.new(
      :thing, :owner, :z, :vx, :vy, :vz,
      :state, :frame_index, :frame_timer, :anim_phase, :tics_alive,
      :damage, :deathsound,
      :flight_frames, :death_frames, :splash, :spray,
    )

    # BFG A_BFGSpray parameters. 40 tracers in a 90° cone, fired from
    # the player's position (mo->target in vanilla) at the BFG ball's
    # flight angle. Each tracer rolls (rand%8 + 1) fifteen times and
    # sums — 15..120 damage. Range = 16 * 64 = 1024 map units.
    BFG_SPRAY_TRACERS      = 40
    BFG_SPRAY_CONE_DEG     = 90.0
    BFG_SPRAY_RANGE        = 16.0 * 64.0
    BFG_SPRAY_DAMAGE_ROLLS = 15
    BFG_SPRAY_FRAME_INDEX  = 2   # BFE1 C — vanilla A_BFGSpray fires here.

    def initialize(map, sight, clipper, combat, sound: nil, rng: Random.new)
      @map     = map
      @sight   = sight
      @clipper = clipper
      @combat  = combat
      @sound   = sound
      @rng     = rng
      @projs   = []
      @hitscan = nil
    end

    attr_reader :projs

    # Late-bound: Game constructs Projectiles before Hitscan (the rest
    # of the system already has that order), so the BFG spray hooks
    # this in once both exist.
    attr_writer :hitscan

    # Spawn an imp fireball from `owner` aimed at `target`. Both need
    # `x`, `y` accessors; target additionally needs a z (player view
    # height, or another monster's chest). Returns the Proj.
    def spawn_imp_fireball(owner_mobj, target, listener: target)
      sx = owner_mobj.thing.x.to_f
      sy = owner_mobj.thing.y.to_f
      sz = owner_z(owner_mobj) + IMP_LAUNCH_Z_OFFSET

      tx = target.x.to_f
      ty = target.y.to_f
      tz = target_eye_z(target)

      dx = tx - sx
      dy = ty - sy
      dist = Math.hypot(dx, dy)
      dist = 1.0 if dist < 1.0
      time_to_target = dist / IMP_FIREBALL_SPEED

      # Vanilla P_SpawnMissile MF_SHADOW perturbation — when firing at
      # an invisible target the XY angle is randomly fuzzed up to
      # ±22.5°. Vertical aim (slope) is unaffected.
      ang_rad = Math.atan2(dy, dx)
      if target.respond_to?(:has_power?) && target.has_power?(:invisibility)
        ang_rad += (@rng.rand - 0.5) * 2 * (22.5 * Math::PI / 180.0)
      end
      vx = IMP_FIREBALL_SPEED * Math.cos(ang_rad)
      vy = IMP_FIREBALL_SPEED * Math.sin(ang_rad)
      vz = (tz - sz) / time_to_target

      angle = ang_rad * 180.0 / Math::PI

      thing = Map::Thing.new(sx, sy, angle, 0, 0, false, "BAL1", "A", false, sz)
      proj  = Proj.new(thing, owner_mobj, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       fireball_damage, :firxpl,
                       FIREBALL_FLIGHT_FRAMES, FIREBALL_DEATH_FRAMES, false)
      @projs << proj
      @map.things << thing
      @sound&.play_at(:firsht, sx, sy, listener, source: owner_mobj)
      proj
    end

    # Spawn a Baron of Hell fireball. Same flight machinery as the
    # imp's missile — different sprite, speed, and damage. Reuses the
    # MF_SHADOW XY-fuzz rule when the target carries the invisibility
    # power.
    def spawn_bruiser_ball(owner_mobj, target, listener: target)
      sx = owner_mobj.thing.x.to_f
      sy = owner_mobj.thing.y.to_f
      sz = owner_z(owner_mobj) + BRUISER_LAUNCH_Z_OFFSET

      tx = target.x.to_f
      ty = target.y.to_f
      tz = target_eye_z(target)

      dx = tx - sx
      dy = ty - sy
      dist = Math.hypot(dx, dy)
      dist = 1.0 if dist < 1.0
      time_to_target = dist / BRUISER_SHOT_SPEED

      ang_rad = Math.atan2(dy, dx)
      if target.respond_to?(:has_power?) && target.has_power?(:invisibility)
        ang_rad += (@rng.rand - 0.5) * 2 * (22.5 * Math::PI / 180.0)
      end
      vx = BRUISER_SHOT_SPEED * Math.cos(ang_rad)
      vy = BRUISER_SHOT_SPEED * Math.sin(ang_rad)
      vz = (tz - sz) / time_to_target

      angle = ang_rad * 180.0 / Math::PI

      thing = Map::Thing.new(sx, sy, angle, 0, 0, false, "BAL7", "A", false, sz)
      proj  = Proj.new(thing, owner_mobj, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       bruiser_shot_damage, :firxpl,
                       BRUISER_FLIGHT_FRAMES, BRUISER_DEATH_FRAMES, false)
      @projs << proj
      @map.things << thing
      @sound&.play_at(:firsht, sx, sy, listener, source: owner_mobj)
      proj
    end

    # Spawn a cacodemon fireball (MT_HEADSHOT). Reuses the same flight
    # machinery as the imp / Baron projectiles — only sprite and stats
    # differ. MF_SHADOW XY-fuzz applies when the player has invisibility.
    def spawn_caco_ball(owner_mobj, target, listener: target)
      sx = owner_mobj.thing.x.to_f
      sy = owner_mobj.thing.y.to_f
      sz = owner_z(owner_mobj) + HEADSHOT_LAUNCH_Z_OFFSET

      tx = target.x.to_f
      ty = target.y.to_f
      tz = target_eye_z(target)

      dx = tx - sx
      dy = ty - sy
      dist = Math.hypot(dx, dy)
      dist = 1.0 if dist < 1.0
      time_to_target = dist / HEADSHOT_SPEED

      ang_rad = Math.atan2(dy, dx)
      if target.respond_to?(:has_power?) && target.has_power?(:invisibility)
        ang_rad += (@rng.rand - 0.5) * 2 * (22.5 * Math::PI / 180.0)
      end
      vx = HEADSHOT_SPEED * Math.cos(ang_rad)
      vy = HEADSHOT_SPEED * Math.sin(ang_rad)
      vz = (tz - sz) / time_to_target

      angle = ang_rad * 180.0 / Math::PI

      thing = Map::Thing.new(sx, sy, angle, 0, 0, false, "BAL2", "A", false, sz)
      proj  = Proj.new(thing, owner_mobj, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       headshot_damage, :firxpl,
                       HEADSHOT_FLIGHT_FRAMES, HEADSHOT_DEATH_FRAMES, false)
      @projs << proj
      @map.things << thing
      @sound&.play_at(:firsht, sx, sy, listener, source: owner_mobj)
      proj
    end

    # Spawn a player rocket along the player's facing, with the given
    # vertical autoaim slope. Direct-hit damage rolls 20..160; on
    # impact the rocket triggers a P_RadiusAttack splash (Combat#
    # radius_attack) using the player as the source, so the player can
    # rocket-jump (or kill themselves at point-blank).
    def spawn_rocket(player, slope: 0.0)
      ang = player.angle * Math::PI / 180.0
      dx  = Math.cos(ang)
      dy  = Math.sin(ang)
      sx  = player.x.to_f
      sy  = player.y.to_f
      sz  = (@clipper.floor_at(sx, sy) || 0) + ROCKET_LAUNCH_Z_OFFSET
      vx  = ROCKET_SPEED * dx
      vy  = ROCKET_SPEED * dy
      vz  = ROCKET_SPEED * slope

      thing = Map::Thing.new(sx, sy, player.angle, 0, 0, false, "MISL", "A", false, sz)
      proj  = Proj.new(thing, player, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       rocket_direct_damage, :barexp,
                       ROCKET_FLIGHT_FRAMES, ROCKET_DEATH_FRAMES, true)
      @projs << proj
      @map.things << thing
      @sound&.play_at(:rlaunc, sx, sy, player, source: player)
      proj
    end

    # Spawn a plasma bolt along the player's facing, autoaim slope
    # applied. Direct-hit damage 5..40, no splash — plasma is rapid-
    # fire single-target. Flight frames alternate PLSS A↔B; impact
    # plays the PLSE A..E animation.
    def spawn_plasma_bolt(player, slope: 0.0)
      ang = player.angle * Math::PI / 180.0
      dx  = Math.cos(ang)
      dy  = Math.sin(ang)
      sx  = player.x.to_f
      sy  = player.y.to_f
      sz  = (@clipper.floor_at(sx, sy) || 0) + PLASMA_LAUNCH_Z_OFFSET
      vx  = PLASMA_SPEED * dx
      vy  = PLASMA_SPEED * dy
      vz  = PLASMA_SPEED * slope

      thing = Map::Thing.new(sx, sy, player.angle, 0, 0, false, "PLSS", "A", false, sz)
      proj  = Proj.new(thing, player, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       plasma_direct_damage, :firxpl,
                       PLASMA_FLIGHT_FRAMES, PLASMA_DEATH_FRAMES, false)
      @projs << proj
      @map.things << thing
      @sound&.play_at(:plasma, sx, sy, player, source: player)
      proj
    end

    # Spawn a BFG ball along the player's facing with the given autoaim
    # slope. Direct-hit damage 100..800; no spray (yet). Flight frames
    # alternate BFS1 A↔B; impact plays BFE1 A..F.
    def spawn_bfg_ball(player, slope: 0.0)
      ang = player.angle * Math::PI / 180.0
      dx  = Math.cos(ang)
      dy  = Math.sin(ang)
      sx  = player.x.to_f
      sy  = player.y.to_f
      sz  = (@clipper.floor_at(sx, sy) || 0) + BFG_LAUNCH_Z_OFFSET
      vx  = BFG_SPEED * dx
      vy  = BFG_SPEED * dy
      vz  = BFG_SPEED * slope

      thing = Map::Thing.new(sx, sy, player.angle, 0, 0, false, "BFS1", "A", false, sz)
      proj  = Proj.new(thing, player, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       bfg_direct_damage, :rxplod,
                       BFG_FLIGHT_FRAMES, BFG_DEATH_FRAMES, false, true)
      @projs << proj
      @map.things << thing
      proj
    end

    # Tick every live projectile.
    def update_tic(player)
      @projs.each { |p| step(p, player) }
      # Drop projectiles whose death sequence finished. Their Thing was
      # already flagged `removed`, so the renderer is also ignoring them.
      @projs.reject! { |p| p.state == :dead }
    end

    private

    def step(proj, player)
      case proj.state
      when :flying    then step_flying(proj, player)
      when :exploding then step_exploding(proj)
      end
    end

    def step_flying(proj, player)
      proj.tics_alive += 1
      if proj.tics_alive > MAX_TICS
        explode(proj, player)
        return
      end

      ox = proj.thing.x
      oy = proj.thing.y
      oz = proj.z
      nx = ox + proj.vx
      ny = oy + proj.vy
      nz = oz + proj.vz

      # Sector floor / ceiling at the new XY. If z punched through
      # either, the fireball detonates against that surface.
      sector = @clipper.sector_at(nx, ny)
      if sector
        if nz <= sector.floor_height
          land_at(proj, nx, ny, sector.floor_height, player)
          return
        end
        if nz >= sector.ceiling_height
          land_at(proj, nx, ny, sector.ceiling_height, player)
          return
        end
      end

      # Wall blocker check. Vanilla P_LineOpening for a missile tests
      # the destination z (not an interpolated ray z), so a rocket
      # rising fast enough to clear a step-up at the destination point
      # passes — even if the segment from (ox, oy, oz) would graze the
      # step face mid-flight. Using @sight.visible? here (built for AI
      # eye-to-target line-of-sight) is too strict and explodes the
      # rocket against the front face of any ledge between launcher
      # and target.
      block_t, _block_ld = find_blocking_line(ox, oy, nx, ny, nz)
      if block_t
        # Park the rocket a touch short of the impact line so the
        # explosion sprite renders in front of the wall instead of
        # straddling it. 0.95 ≈ 1 mu pull-back at rocket speed.
        t = block_t * 0.95
        bx = ox + (nx - ox) * t
        by = oy + (ny - oy) * t
        bz = oz + (nz - oz) * t
        land_at(proj, bx, by, bz, player)
        return
      end

      # Commit the move first so target-overlap checks see the new pos.
      proj.thing.x = nx
      proj.thing.y = ny
      proj.z       = nz
      proj.thing.z_override = nz

      # Target overlap. Owner is excluded to stop the fireball from
      # immediately detonating against the imp that fired it.
      hit = hit_thing(proj, player)
      if hit
        damage_target(hit, proj.damage, source: proj.owner)
        explode(proj, player)
        return
      end

      advance_flight_anim(proj)
    end

    # Find the closest two-sided opening or one-sided wall on the
    # path (ox, oy)→(nx, ny) that the missile can't clear at z = nz.
    # Returns [t, linedef] with t ∈ (0, 1) or [nil, nil] if the path
    # is clear. Mirrors vanilla's missile P_LineOpening rule.
    def find_blocking_line(ox, oy, nx, ny, nz)
      best_t = nil
      best_ld = nil
      @clipper.each_linedef_in_path(ox, oy, nx, ny) do |ld|
        t = segment_t(ox, oy, nx, ny, ld)
        next if t.nil? || t <= 0 || t >= 1
        next if best_t && t >= best_t
        next unless blocks_missile?(ld, nz)
        best_t  = t
        best_ld = ld
      end
      [best_t, best_ld]
    end

    def segment_t(sx, sy, tx, ty, ld)
      v1 = @map.vertexes[ld.start_vertex_index]
      v2 = @map.vertexes[ld.end_vertex_index]
      sdx = v2.x - v1.x
      sdy = v2.y - v1.y
      dx  = tx - sx
      dy  = ty - sy
      denom = dx * sdy - dy * sdx
      return nil if denom.abs < 1e-9
      t = ((v1.x - sx) * sdy - (v1.y - sy) * sdx) / denom
      s = ((v1.x - sx) * dy  - (v1.y - sy) * dx)  / denom
      return nil if s < 0 || s > 1
      t
    end

    def blocks_missile?(ld, z)
      return true unless ld.two_sided?
      front = @map.linedef_front_sector(ld)
      back  = @map.linedef_back_sector(ld)
      return true if front.nil? || back.nil?
      opening_top = front.ceiling_height < back.ceiling_height ? front.ceiling_height : back.ceiling_height
      opening_bot = front.floor_height   > back.floor_height   ? front.floor_height   : back.floor_height
      z <= opening_bot || z >= opening_top
    end

    def step_exploding(proj)
      proj.frame_timer -= 1
      return if proj.frame_timer > 0

      proj.frame_index += 1
      if proj.frame_index >= proj.death_frames.size
        proj.thing.removed = true
        proj.state         = :dead
        return
      end
      sprite, frame, tics = proj.death_frames[proj.frame_index]
      proj.thing.sprite_override = sprite
      proj.thing.frame_override  = frame
      proj.frame_timer = tics

      # Vanilla A_BFGSpray fires from the BFE1 C frame — one fan per
      # ball, gated by the spray flag so other projectiles ignore it.
      fire_bfg_spray(proj) if proj.spray && proj.frame_index == BFG_SPRAY_FRAME_INDEX
    end

    def advance_flight_anim(proj)
      proj.frame_timer -= 1
      return if proj.frame_timer > 0
      frames = proj.flight_frames
      return if frames.length <= 1   # single-frame flight (rocket)
      proj.anim_phase = (proj.anim_phase + 1) % frames.length
      proj.thing.frame_override = frames[proj.anim_phase]
      proj.frame_timer = FLIGHT_FRAME_TICS
    end

    # Run the explosion animation in place — sound is played here too.
    def land_at(proj, x, y, z, player)
      proj.thing.x = x
      proj.thing.y = y
      proj.z       = z
      proj.thing.z_override = z
      explode(proj, player)
    end

    def explode(proj, player)
      # The listener for distance attenuation is the actual player
      # (something with .x / .y). Passing proj.owner here is wrong —
      # Mobj exposes position as .thing.x, not .x — and crashed Sound.
      if @sound && player
        @sound.play_at(proj.deathsound, proj.thing.x, proj.thing.y, player,
                       source: proj)
      end
      proj.state                 = :exploding
      proj.frame_index           = 0
      sprite, frame, tics        = proj.death_frames[0]
      proj.thing.sprite_override = sprite
      proj.thing.frame_override  = frame
      proj.frame_timer           = tics
      proj.vx = proj.vy = proj.vz = 0.0
      if proj.splash
        @combat.radius_attack(proj.thing.x.to_f, proj.thing.y.to_f,
                              source: proj.owner)
      end
    end

    # Test the projectile against the player and every live shootable
    # (monsters AND barrels), skipping the owner. Returns the hit
    # target or nil. The projectile is approximated as a small circle
    # in XY with a vertical body-overlap test for z.
    def hit_thing(proj, player)
      r = IMP_FIREBALL_RADIUS

      # Player. Player.z (= floor under player) + 0..view_height gives
      # the body's vertical extent, plus a small slop top and bottom.
      if player && player.health > 0 && proj.owner != player
        pr = Clipper::PLAYER_RADIUS
        if circle_overlap?(proj.thing.x, proj.thing.y, r,
                           player.x, player.y, pr)
          floor = @clipper.floor_at(player.x, player.y) || 0
          if proj.z >= floor && proj.z <= floor + 56  # player body height
            return player
          end
        end
      end

      # All live shootables — monsters and barrels — skip owner.
      # `shootables` yields [thing, radius, height]; we resolve back
      # to the mobj via `mobj_for` so damage_target can route to the
      # right path (Combat#damage handles barrel chain-explosions).
      @combat.shootables.each do |thing, mr, mh|
        mobj = @combat.mobj_for(thing)
        next if mobj.nil? || mobj == proj.owner
        next unless circle_overlap?(proj.thing.x, proj.thing.y, r,
                                    thing.x, thing.y, mr)
        mfloor = @clipper.floor_at(thing.x, thing.y) || 0
        next unless proj.z >= mfloor && proj.z <= mfloor + mh
        return mobj
      end
      nil
    end

    def circle_overlap?(ax, ay, ar, bx, by, br)
      dx = ax - bx
      dy = ay - by
      reach = ar + br
      dx * dx + dy * dy <= reach * reach
    end

    def damage_target(target, amount, source: nil)
      if target.respond_to?(:take_damage) && !target.respond_to?(:info)
        # Player path — Player#take_damage.
        target.take_damage(amount)
      else
        # Monster mobj path — go through Combat so pain / death and
        # the retarget-on-damage (infighting) rules fire correctly.
        @combat.damage(target, amount, source: source)
      end
    end

    def fireball_damage
      (@rng.rand(IMP_FIREBALL_DAMAGE_D) + 1) * IMP_FIREBALL_DAMAGE_M
    end

    def bruiser_shot_damage
      (@rng.rand(BRUISER_SHOT_DAMAGE_D) + 1) * BRUISER_SHOT_DAMAGE_M
    end

    def headshot_damage
      (@rng.rand(HEADSHOT_DAMAGE_D) + 1) * HEADSHOT_DAMAGE_M
    end

    def rocket_direct_damage
      (@rng.rand(ROCKET_DAMAGE_D) + 1) * ROCKET_DAMAGE_M
    end

    def plasma_direct_damage
      (@rng.rand(PLASMA_DAMAGE_D) + 1) * PLASMA_DAMAGE_M
    end

    def bfg_direct_damage
      (@rng.rand(BFG_DAMAGE_D) + 1) * BFG_DAMAGE_M
    end

    # Vanilla A_BFGSpray. Fires `BFG_SPRAY_TRACERS` rays from the
    # *player's* position (proj.owner), not the ball's, at angles
    # sweeping ±45° around the ball's flight angle. Each tracer that
    # hits a thing deals 15 rolls of (rand%8+1) = 15..120 damage. We
    # skip the MT_EXTRABFG decorative hit-sprite vanilla spawns at
    # each victim; that's pure visual.
    def fire_bfg_spray(proj)
      return unless @hitscan && @combat
      owner = proj.owner
      return unless owner && owner.respond_to?(:angle)

      base = proj.thing.angle.to_f
      step = BFG_SPRAY_CONE_DEG / BFG_SPRAY_TRACERS
      shootables = @combat.shootables
      BFG_SPRAY_TRACERS.times do |i|
        ang = base - (BFG_SPRAY_CONE_DEG * 0.5) + step * i
        result = @hitscan.fire(owner,
                               range:          BFG_SPRAY_RANGE,
                               shootables:     shootables,
                               angle_override: ang)
        next unless result && result[0] == :thing
        target_thing = result[1]
        mobj = @combat.mobj_for(target_thing)
        next unless mobj
        damage = 0
        BFG_SPRAY_DAMAGE_ROLLS.times { damage += (@rng.rand(8) + 1) }
        @combat.damage(mobj, damage, source: owner)
      end
    end

    def owner_z(owner_mobj)
      @clipper.floor_at(owner_mobj.thing.x, owner_mobj.thing.y) || 0
    end

    def target_eye_z(target)
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
  end
end
