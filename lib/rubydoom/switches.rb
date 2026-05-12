module Rubydoom
  # Use-action handler for switch linedefs. Mirrors the Doors ray:
  # cast forward USE_RANGE units, take the first linedef hit, dispatch
  # by special_type. A non-passable hit that isn't a switch stops the
  # ray cold — so a switch hidden behind a wall isn't reachable.
  #
  # On activation we swap the front sidedef's switch texture (SW1xxx
  # ↔ SW2xxx) so the player gets visual feedback. Once-only ("S1")
  # specials clear their special_type after firing so they can't be
  # used twice.
  #
  # Currently implements:
  #   * type 11  — S1 Exit Level. Sets exit_requested; the game loop
  #     reads it.
  #   * type 103 — S1 Door Open Stay (remote, by tag). Opens any
  #     sector tagged the same as this linedef, as a stay-open door.
  #   * type 62  — SR Lift (Lower Wait Raise, by tag). Repeatable
  #     switch variant of the WR walk-trigger lift (88) — same plat
  #     behaviour, just triggered by Use instead of crossing.
  #   * type 20  — S1 Floor Raise To Next Higher (Change Tex & Type),
  #     delegated to Floors. Used by switches in E1M3.
  #   * type 9   — S1 Donut, delegated to Donuts. Used in E1M2's
  #     nukage-ring secret.
  #
  # Gun-trigger specials (G*) come in through `try_shoot` instead of
  # `try_use`. They share the texture-swap and once-only machinery:
  #   * type 46  — GR Door Open Stay (remote). Repeatable; bullets
  #     against the linedef open every sector with the matching tag.
  class Switches
    USE_RANGE = 64.0

    S1_EXIT_LEVEL        = 11
    S1_EXIT_SECRET       = 51
    S1_DOOR_OPEN_STAY    = 103
    S1_DOOR_OPEN_CLOSE   = 29
    SR_DOOR_OPEN_CLOSE   = 63
    SR_LIFT_LOWER_RAISE  = 62
    S1_FLOOR_RAISE_NEXT  = 20
    S1_FLOOR_RAISE_NEXT_PLAIN = 18
    S1_FLOOR_LOWER_LOWEST = 23
    S1_FLOOR_LOWER_HIGHEST = 102
    SR_FLOOR_LOWER_FAST  = 70
    S1_DONUT             = 9
    GR_DOOR_OPEN_STAY    = 46

    # Vanilla BUTTONTIME: the depressed (SW2) texture of a repeatable
    # switch springs back to SW1 after one second. Once-only switches
    # stay depressed forever.
    BUTTON_REVERT_TICS = 35

    # Once-only switches (S1*) get their special_type cleared after
    # firing so they can't be re-used. Repeatable switches (SR*/GR*)
    # leave the special intact; we still swap the texture so the
    # player gets the click animation.
    ONCE_ONLY = [
      S1_EXIT_LEVEL, S1_EXIT_SECRET, S1_DOOR_OPEN_STAY, S1_DOOR_OPEN_CLOSE,
      S1_FLOOR_RAISE_NEXT, S1_FLOOR_RAISE_NEXT_PLAIN, S1_FLOOR_LOWER_LOWEST,
      S1_FLOOR_LOWER_HIGHEST, S1_DONUT,
    ].freeze

    attr_reader :exit_requested, :secret_exit_requested

    # External request hook. Sector special 11 (end-of-level on death)
    # uses this to trigger the same exit path a switch would.
    def request_exit!(secret: false)
      @exit_requested = true
      @secret_exit_requested = true if secret
    end

    def initialize(map)
      @map = map
      @exit_requested = false
      @secret_exit_requested = false
      @doors  = nil
      @plats  = nil
      @floors = nil
      @donuts = nil
      @sound  = nil
      @listener = nil
      @pending_reverts = {}
    end

    # Tick BUTTON_REVERT_TICS for every pressed repeatable switch.
    # When the timer expires, swap the texture back to SW1 and play
    # the click again. Hash keyed by linedef object_id so a re-press
    # of the same switch just resets the timer instead of stacking
    # entries (otherwise a second press would unswap immediately as
    # the older entry fires).
    def update_tic
      return if @pending_reverts.empty?
      @pending_reverts.each_value { |entry| entry[1] -= 1 }
      @pending_reverts.reject! do |_, (ld, t)|
        next false if t > 0
        swap_switch_texture(ld)
        play_switch_sound(ld, :swtchn)
        true
      end
    end

    # Late-bound to avoid initialization-order dependencies in Game#load_map.
    # `sound`/`listener` let the click play attenuated at the switch
    # position; without them we fall back to silent.
    attr_writer :doors, :plats, :floors, :donuts, :sound, :listener

    def try_use(player)
      rad = player.angle * Math::PI / 180.0
      dx = Math.cos(rad); dy = Math.sin(rad)
      hits = ray_hits(player.x, player.y, dx, dy, USE_RANGE)
      hits.each do |_t, ld|
        fired =
          case ld.special_type
          when S1_EXIT_LEVEL
            @exit_requested = true
            true
          when S1_EXIT_SECRET
            @exit_requested = true
            @secret_exit_requested = true
            true
          when S1_DOOR_OPEN_STAY
            @doors&.open_tagged(ld.sector_tag, kind: :d1)
          when S1_DOOR_OPEN_CLOSE
            @doors&.open_tagged(ld.sector_tag, kind: :dr)
          when SR_DOOR_OPEN_CLOSE
            @doors&.open_tagged(ld.sector_tag, kind: :dr)
          when SR_LIFT_LOWER_RAISE
            @plats&.activate_tag(ld.sector_tag)
          when S1_FLOOR_RAISE_NEXT, S1_FLOOR_RAISE_NEXT_PLAIN,
               S1_FLOOR_LOWER_LOWEST, S1_FLOOR_LOWER_HIGHEST, SR_FLOOR_LOWER_FAST
            @floors&.handle_use(ld)
          when S1_DONUT
            @donuts&.handle_use(ld)
          end
        if fired
          # Capture the type before we clear it so the exit-switch
          # picks the louder, more emphatic `dsswtchx` sample.
          exit_switch = [S1_EXIT_LEVEL, S1_EXIT_SECRET].include?(ld.special_type)
          play_switch_sound(ld, exit_switch ? :swtchx : :swtchn)
          swap_switch_texture(ld)
          if ONCE_ONLY.include?(ld.special_type)
            ld.special_type = 0
          else
            queue_revert(ld)
          end
          return true
        end
        return false if !ld.two_sided? || ld.impassable?
      end
      false
    end

    # Gun-trigger dispatcher. Called by Weapons when a hitscan's
    # nearest blocking line carries a G* special. Mirrors try_use's
    # texture-swap / sound / once-only handling. Returns true iff the
    # special fired.
    def try_shoot(ld)
      fired =
        case ld.special_type
        when GR_DOOR_OPEN_STAY
          @doors&.open_tagged(ld.sector_tag, kind: :d1)
        end
      return false unless fired
      play_switch_sound(ld, :swtchn)
      swap_switch_texture(ld)
      if ONCE_ONLY.include?(ld.special_type)
        ld.special_type = 0
      else
        queue_revert(ld)
      end
      true
    end

    private

    def queue_revert(ld)
      @pending_reverts[ld.object_id] = [ld, BUTTON_REVERT_TICS]
    end

    # Play the switch click at the linedef's midpoint so the volume
    # attenuates from the actual switch, not the player.
    def play_switch_sound(ld, sound_name)
      return unless @sound
      v1 = @map.vertexes[ld.start_vertex_index]
      v2 = @map.vertexes[ld.end_vertex_index]
      mx = (v1.x + v2.x) * 0.5
      my = (v1.y + v2.y) * 0.5
      if @listener
        @sound.play_at(sound_name, mx, my, @listener, source: ld)
      else
        @sound.play(sound_name, source: ld)
      end
    end

    # Swap SW1xxx <-> SW2xxx on whichever of upper/middle/lower
    # textures of the front sidedef is currently set to a switch.
    def swap_switch_texture(ld)
      sd = @map.sidedefs[ld.front_sidedef_index]
      %i[upper_texture middle_texture lower_texture].each do |attr|
        name = sd.send(attr)
        next if name.nil? || name.empty? || name == "-"
        if name.start_with?("SW1")
          sd.send("#{attr}=", "SW2" + name[3..])
        elsif name.start_with?("SW2")
          sd.send("#{attr}=", "SW1" + name[3..])
        end
      end
    end

    def ray_hits(x, y, dx, dy, max_t)
      hits = []
      @map.linedefs.each do |ld|
        v1 = @map.vertexes[ld.start_vertex_index]
        v2 = @map.vertexes[ld.end_vertex_index]
        sdx = v2.x - v1.x
        sdy = v2.y - v1.y
        denom = dx * sdy - dy * sdx
        next if denom.abs < 1e-9
        t = ((v1.x - x) * sdy - (v1.y - y) * sdx).fdiv(denom)
        next if t < 0 || t > max_t
        s = ((v1.x - x) * dy - (v1.y - y) * dx).fdiv(denom)
        next if s < 0 || s > 1
        hits << [t, ld]
      end
      hits.sort_by!(&:first)
      hits
    end
  end
end
