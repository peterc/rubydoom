module Rubydoom
  # Monster movement helpers — ported from linuxdoom-1.10/p_enemy.c's
  # `P_NewChaseDir` / `P_TryWalk` / `P_Move`. Each tic, A_Chase asks this
  # module to take one step toward the target and (if it fails) to pick a
  # fresh direction.
  #
  # Direction is encoded as 0..7, matching DI_* constants in vanilla:
  #   0 = East, 1 = NE, 2 = N, 3 = NW, 4 = W, 5 = SW, 6 = S, 7 = SE.
  # (DOOM uses +y = North; the unit-vector table matches our angle
  # convention.) `DI_NODIR = 8` means "no chosen direction".
  #
  # Mobj-vs-mobj collision is approximate: we check the mobj's new
  # position against the player AABB and against every other live
  # monster mobj's circle. Vanilla's PE_Mobj search uses the blockmap
  # for things; the radius the monsters live at means there are usually
  # only a handful to test anyway.
  class MonsterMovement
    DI_EAST  = 0
    DI_NE    = 1
    DI_NORTH = 2
    DI_NW    = 3
    DI_WEST  = 4
    DI_SW    = 5
    DI_SOUTH = 6
    DI_SE    = 7
    DI_NODIR = 8

    # Unit vector per direction. DOOM angle convention: x = cos, y = sin.
    DX = [ 1,  1,  0, -1, -1, -1,  0,  1].freeze
    DY = [ 0,  1,  1,  1,  0, -1, -1, -1].freeze

    # Opposite-direction table for P_NewChaseDir's "don't pick the
    # opposite of where I came from unless desperate" rule.
    OPPOSITE = [
      DI_WEST, DI_SW, DI_SOUTH, DI_SE,
      DI_EAST, DI_NE, DI_NORTH, DI_NW,
      DI_NODIR,
    ].freeze

    # Vanilla P_NewChaseDir's table of "diagonal first" preferences when
    # both x and y deltas are sizeable. Index encodes signs of dx/dy.
    DIAGONALS = {
      [ 1,  1] => DI_NE,
      [ 1, -1] => DI_SE,
      [-1,  1] => DI_NW,
      [-1, -1] => DI_SW,
    }.freeze

    def initialize(map, clipper, combat)
      @map     = map
      @clipper = clipper
      @combat  = combat
    end

    # Try to take one step in `mobj.move_dir`. Returns true if the step
    # succeeded (mobj moved); false otherwise. On failure the AI is
    # expected to call new_chase_dir to pick a fresh direction.
    def try_walk(mobj, player)
      return false if mobj.move_dir == DI_NODIR
      step  = mobj.info.speed
      tx    = mobj.thing.x + DX[mobj.move_dir] * step
      ty    = mobj.thing.y + DY[mobj.move_dir] * step
      return false unless position_clear?(mobj, tx, ty, player)
      mobj.thing.x = tx
      mobj.thing.y = ty
      true
    end

    # Pick a new movement direction toward (target_x, target_y).
    # Ported from P_NewChaseDir — the gist is:
    #   1. Compute the dominant axis pull toward target.
    #   2. Try the diagonal that combines both pulls.
    #   3. Fall back to the better cardinal.
    #   4. As a desperate measure, try the orthogonal pair, then the
    #      opposite of where we came from.
    # Sets mobj.move_dir; on total failure leaves it at DI_NODIR.
    def new_chase_dir(mobj, target_x, target_y, player)
      old_dir = mobj.move_dir
      turn_around = OPPOSITE[old_dir]

      delta_x = target_x - mobj.thing.x
      delta_y = target_y - mobj.thing.y

      d1 =
        if delta_x >  10 then DI_EAST
        elsif delta_x < -10 then DI_WEST
        else DI_NODIR end
      d2 =
        if delta_y < -10 then DI_SOUTH
        elsif delta_y >  10 then DI_NORTH
        else DI_NODIR end

      # Diagonal first if both axes pulled.
      if d1 != DI_NODIR && d2 != DI_NODIR
        signs = [delta_x <=> 0, delta_y <=> 0]
        diag = DIAGONALS[signs]
        if diag && diag != turn_around
          mobj.move_dir = diag
          return if try_walk_dir(mobj, player)
        end
      end

      # Pick the axis with the bigger pull, try it as a cardinal.
      ordered =
        if delta_x.abs > delta_y.abs
          [d1, d2]
        else
          [d2, d1]
        end
      ordered = [ordered[1], ordered[0]] if rand(2).zero?  # vanilla coin-flip
      ordered.each do |dir|
        next if dir == DI_NODIR
        next if dir == turn_around
        mobj.move_dir = dir
        return if try_walk_dir(mobj, player)
      end

      # Side-step search: walk along all 8 dirs as fallbacks.
      dirs = (0..7).to_a
      dirs.shuffle!  # vanilla picks one of two orderings; full shuffle is fine
      dirs.each do |dir|
        next if dir == turn_around
        mobj.move_dir = dir
        return if try_walk_dir(mobj, player)
      end

      # Last resort: about-face.
      if turn_around != DI_NODIR
        mobj.move_dir = turn_around
        return if try_walk_dir(mobj, player)
      end

      mobj.move_dir = DI_NODIR
    end

    private

    def try_walk_dir(mobj, player)
      try_walk(mobj, player)
    end

    # Step destination is clear iff:
    #   - the Clipper allows a thing of mobj.info.radius at that point
    #     (no wall, no step too high, no closed door, etc.)
    #   - the AABB doesn't overlap the player's
    #   - the radii don't overlap another live monster
    def position_clear?(mobj, x, y, player)
      r = mobj.info.radius
      current_floor = @clipper.floor_at(mobj.thing.x, mobj.thing.y) || 0
      return false unless @clipper.position_valid?(x, y, current_floor, r)

      # Don't walk into the player. Use AABB intersection — the
      # player is also AABB-modelled by Clipper.
      pr = Clipper::PLAYER_RADIUS + r
      return false if (x - player.x).abs < pr && (y - player.y).abs < pr

      # Don't pile into another live monster.
      @combat.monsters.each do |other|
        next if other.equal?(mobj)
        next if other.state != :alive
        oradius = other.info.radius + r
        next if (x - other.thing.x).abs >= oradius
        next if (y - other.thing.y).abs >= oradius
        return false
      end
      true
    end
  end
end
