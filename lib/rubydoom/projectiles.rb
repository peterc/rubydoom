module Rubydoom
  # In-flight monster missiles. Today: just the imp fireball
  # (MT_TROOPSHOT). A projectile is a synthetic Thing that gets pushed
  # into `map.things` so the renderer picks it up like any other sprite,
  # plus a parallel record carrying its velocity and animation state.
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

    # Flight-frame alternation timing. The vanilla state pair runs
    # 4 tics each — BAL1 A bright 4 ↔ BAL1 B bright 4.
    FLIGHT_FRAME_TICS      = 4

    # Death frames after impact: BAL1 C / D / E at 6 tics each.
    DEATH_FRAMES = [
      ["BAL1", "C", 6],
      ["BAL1", "D", 6],
      ["BAL1", "E", 6],
    ].freeze

    # Hard cap so a fireball that doesn't hit anything (open sky-ish
    # geometry, or a target out of range) doesn't live forever. 175 tics
    # ≈ 5 seconds, which is plenty given the fireball's 10 mu/tic speed.
    MAX_TICS               = 175

    # Internal projectile record: the synthetic Thing the renderer reads
    # plus the fields the system mutates each tic.
    Proj = Struct.new(
      :thing, :owner, :z, :vx, :vy, :vz,
      :state, :frame_index, :frame_timer, :anim_phase, :tics_alive,
      :damage, :deathsound,
    )

    def initialize(map, sight, clipper, combat, sound: nil, rng: Random.new)
      @map     = map
      @sight   = sight
      @clipper = clipper
      @combat  = combat
      @sound   = sound
      @rng     = rng
      @projs   = []
    end

    attr_reader :projs

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

      vx = IMP_FIREBALL_SPEED * dx / dist
      vy = IMP_FIREBALL_SPEED * dy / dist
      vz = (tz - sz) / time_to_target

      angle = Math.atan2(dy, dx) * 180.0 / Math::PI

      thing = Map::Thing.new(sx, sy, angle, 0, 0, false, "BAL1", "A", false, sz)
      proj  = Proj.new(thing, owner_mobj, sz, vx, vy, vz,
                       :flying, 0, FLIGHT_FRAME_TICS, 0, 0,
                       roll_damage, :firxpl)
      @projs << proj
      @map.things << thing
      @sound&.play_at(:firsht, sx, sy, listener, source: owner_mobj)
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

      # Wall blocker check — same line-of-sight ray Sight uses.
      unless @sight.visible?(ox, oy, oz, nx, ny, nz)
        # Stop at midpoint (good-enough approximation; we don't compute
        # the exact intersection along the segment).
        mx = (ox + nx) * 0.5
        my = (oy + ny) * 0.5
        mz = (oz + nz) * 0.5
        land_at(proj, mx, my, mz, player)
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
        damage_target(hit, proj.damage)
        explode(proj, player)
        return
      end

      advance_flight_anim(proj)
    end

    def step_exploding(proj)
      proj.frame_timer -= 1
      return if proj.frame_timer > 0

      proj.frame_index += 1
      if proj.frame_index >= DEATH_FRAMES.size
        proj.thing.removed = true
        proj.state         = :dead
        return
      end
      sprite, frame, tics = DEATH_FRAMES[proj.frame_index]
      proj.thing.sprite_override = sprite
      proj.thing.frame_override  = frame
      proj.frame_timer = tics
    end

    def advance_flight_anim(proj)
      proj.frame_timer -= 1
      return if proj.frame_timer > 0
      proj.anim_phase = proj.anim_phase.zero? ? 1 : 0
      proj.thing.frame_override = proj.anim_phase.zero? ? "A" : "B"
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
      sprite, frame, tics        = DEATH_FRAMES[0]
      proj.thing.sprite_override = sprite
      proj.thing.frame_override  = frame
      proj.frame_timer           = tics
      proj.vx = proj.vy = proj.vz = 0.0
    end

    # Test the projectile's AABB against the player and every live
    # monster (skipping the owner). Returns the hit target or nil. We
    # approximate the projectile as a small circle in XY and check
    # vertical overlap separately.
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

      # Monsters — skip owner and only hit live ones.
      @combat.monsters.each do |m|
        next if m == proj.owner
        next unless m.state == :alive
        mr = m.info.radius.to_f
        next unless circle_overlap?(proj.thing.x, proj.thing.y, r,
                                    m.thing.x, m.thing.y, mr)
        mfloor = @clipper.floor_at(m.thing.x, m.thing.y) || 0
        next unless proj.z >= mfloor && proj.z <= mfloor + m.info.height
        return m
      end
      nil
    end

    def circle_overlap?(ax, ay, ar, bx, by, br)
      dx = ax - bx
      dy = ay - by
      reach = ar + br
      dx * dx + dy * dy <= reach * reach
    end

    def damage_target(target, amount)
      if target.respond_to?(:take_damage) && !target.respond_to?(:info)
        # Player path — Player#take_damage.
        target.take_damage(amount)
      else
        # Monster mobj path — go through Combat so pain / death works.
        @combat.damage(target, amount)
      end
    end

    def roll_damage
      (@rng.rand(IMP_FIREBALL_DAMAGE_D) + 1) * IMP_FIREBALL_DAMAGE_M
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
