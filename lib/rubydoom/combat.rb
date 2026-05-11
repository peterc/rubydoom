module Rubydoom
  # Per-thing combat state — health, death animation, splash damage.
  # Currently the only thing it manages is the exploding barrel, but the
  # shape (per-mobj health + state machine, indexed for lookup, exposes
  # `shootables` to Hitscan) is what monster AI will plug into.
  #
  # On lethal damage the barrel:
  #   1. immediately stops blocking the player (vanilla clears MF_SOLID
  #      on death — `thing.solid_override = false`),
  #   2. starts cycling the BEXP A → E death sprite via the renderer's
  #      sprite/frame override fields,
  #   3. deals radius damage to the player and any other live barrels
  #      within 128 units (chain reactions),
  #   4. on the last death frame, sets `thing.removed = true` so the
  #      renderer skips it and the mobj is effectively gone.
  #
  # Damage falloff for the explosion is linear with distance, capped at
  # the EXPLOSION_MAX_DAMAGE constant. Vanilla DOOM uses a max-axis
  # `(damage - dist)` formula; the linear version is close enough at
  # the radii barrels actually reach.
  class Combat
    BARREL_DOOMEDNUM     = 2035
    BARREL_HEALTH        = 20
    EXPLOSION_RADIUS     = 128.0
    EXPLOSION_MAX_DAMAGE = 128

    # Vanilla barrel death frames: BEXP A/B/C 5 tics, D/E 10 tics. The
    # last two are long enough that the player can register the
    # explosion visually before it vanishes.
    DEATH_FRAMES = [
      ["BEXP", "A", 5],
      ["BEXP", "B", 5],
      ["BEXP", "C", 5],
      ["BEXP", "D", 10],
      ["BEXP", "E", 10],
    ].freeze

    Mobj = Struct.new(:thing, :health, :state, :frame_index, :frame_timer, :kind)

    def initialize(map)
      @map   = map
      @mobjs = map.things.filter_map do |t|
        if t.type == BARREL_DOOMEDNUM
          Mobj.new(t, BARREL_HEALTH, :alive, 0, 0, :barrel)
        end
      end
      @by_thing = @mobjs.each_with_object({}) { |m, h| h[m.thing] = m }
    end

    # List of [thing, radius] for hitscan to test against. Only alive
    # mobjs participate; once a barrel is :dying it's still rendered
    # (death animation) but no longer absorbs bullets.
    def shootables
      out = []
      @mobjs.each do |m|
        next unless m.state == :alive
        info = ThingTypes[m.thing.type]
        next unless info
        out << [m.thing, info.radius]
      end
      out
    end

    def mobj_for(thing)
      @by_thing[thing]
    end

    # Apply `amount` damage to a mobj. `source` is the player (used for
    # the explosion-damage path); pass nil if the damage isn't routed
    # through anyone (e.g. chain-reaction barrel damaging another
    # barrel, then the player happens to be in range and gets hurt).
    def damage(mobj, amount, source: nil)
      return unless mobj.state == :alive
      mobj.health -= amount
      start_death(mobj, source) if mobj.health <= 0
    end

    def update_tic(_player)
      @mobjs.each do |m|
        next unless m.state == :dying
        m.frame_timer -= 1
        advance_death_frame(m) if m.frame_timer <= 0
      end
    end

    private

    def start_death(mobj, source)
      mobj.state         = :dying
      mobj.frame_index   = 0
      apply_death_frame(mobj)
      # MF_SOLID cleared on death — player can walk through wreckage.
      mobj.thing.solid_override = false
      explode(mobj, source) if mobj.kind == :barrel
    end

    def apply_death_frame(mobj)
      sprite, frame, tics = DEATH_FRAMES[mobj.frame_index]
      mobj.thing.sprite_override = sprite
      mobj.thing.frame_override  = frame
      mobj.frame_timer = tics
    end

    def advance_death_frame(mobj)
      mobj.frame_index += 1
      if mobj.frame_index >= DEATH_FRAMES.size
        mobj.state         = :dead
        mobj.thing.removed = true
      else
        apply_death_frame(mobj)
      end
    end

    def explode(mobj, source)
      cx = mobj.thing.x.to_f
      cy = mobj.thing.y.to_f
      # Player splash. The source is just used for "who killed who";
      # we don't have an attribution chain yet, so the player takes
      # damage regardless.
      if source
        damage_amt = falloff_damage(cx, cy, source.x, source.y)
        source.take_damage(damage_amt) if damage_amt > 0
      end
      # Chain reaction: every other live mobj within range takes a
      # capped hit. Capture the list first so iterating while mutating
      # `@mobjs` (or the per-mobj state) is safe.
      @mobjs.select { |m| m != mobj && m.state == :alive }.each do |other|
        d = Math.hypot(other.thing.x - cx, other.thing.y - cy)
        damage(other, EXPLOSION_MAX_DAMAGE, source: source) if d < EXPLOSION_RADIUS
      end
    end

    def falloff_damage(cx, cy, tx, ty)
      d = Math.hypot(tx - cx, ty - cy)
      return 0 if d >= EXPLOSION_RADIUS
      ((EXPLOSION_RADIUS - d) / EXPLOSION_RADIUS * EXPLOSION_MAX_DAMAGE).to_i
    end
  end
end
