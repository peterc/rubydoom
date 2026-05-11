require "gosu"

module Rubydoom
  # DOOM's native screen size is 320x200. We scale up via Gosu.scale so
  # the rendering code can keep using original coordinates everywhere.
  class App < Gosu::Window
    SCREEN_WIDTH  = 320
    SCREEN_HEIGHT = 200
    DEFAULT_SCALE = 3
    DEFAULT_MAP   = "E1M1"

    BACKGROUND_FILL = Gosu::Color.rgb(0, 0, 0)

    # DOOM's native tic rate. The whole game world advances in 1/35s
    # steps, so we drive Gosu's update loop at the same rate and express
    # speeds/timers in tics where they have a DOOM-spec value.
    TIC_RATE          = 35
    TIC_DT            = 1.0 / TIC_RATE

    # Map units per tic. DOOM run = 50 mu/tic, walk = 25 mu/tic; we sit
    # well below that since collision and AI aren't pressing us yet.
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

    def initialize(wad_path:, map_name: DEFAULT_MAP, scale: DEFAULT_SCALE,
                   dump_frame_to: nil, show_automap: false,
                   automap_mode: :lines)
      @scale = scale
      @dump_frame_to = dump_frame_to
      @show_automap = show_automap
      @automap_mode = automap_mode
      super(SCREEN_WIDTH * scale, SCREEN_HEIGHT * scale,
            update_interval: 1000.0 / TIC_RATE,
            resizable: true)
      @wad      = WAD.open(wad_path)
      @palette  = Palette.from_wad(@wad)
      @colormap = Colormap.from_wad(@wad, @palette)
      graphics  = Graphics.new(@wad, @palette)
      @textures = AnimatedTextures.new(Textures.new(@wad, @palette, graphics))
      @sprites  = Sprites.new(@wad)
      @flats    = AnimatedFlats.new(Flats.new(@wad))
      images    = GosuImageCache.new(graphics)
      @hud      = HUD.new(images)

      load_map(map_name)
      # Honour debug-spawn env vars on the initial map only; transitions
      # spawn the player at the new map's player_start.
      @player.x     = ENV["RUBYDOOM_X"].to_f     if ENV["RUBYDOOM_X"]
      @player.y     = ENV["RUBYDOOM_Y"].to_f     if ENV["RUBYDOOM_Y"]
      @player.angle = ENV["RUBYDOOM_ANGLE"].to_f if ENV["RUBYDOOM_ANGLE"]
      @last_floor_z = @clipper.floor_at(@player.x, @player.y)

      # Skip the first frame's mouse delta — cursor starts wherever the OS
      # left it, so the recenter would otherwise cause a sudden yaw jump.
      @mouse_centered = false
      # Click-to-capture: the window starts with the OS cursor visible
      # and mouse-look off, so the user can resize / move the window
      # without first wrestling control of the cursor away. Clicking in
      # the playfield captures; Esc (or losing focus) releases.
      @captured       = false
      @focused        = true

      @bob_phase = 0.0
      @bob_amp   = 0.0

      @delta_view_height = 0.0
    end

    # Build (or rebuild) every per-map subsystem. Asset state — palette,
    # colormap, textures/flats/sprites caches, the gosu image cache, the
    # HUD — persists across maps. Texture and flat animation
    # phase carries over too, which feels right (the slime flow doesn't
    # snap on a level change).
    def load_map(map_name)
      self.caption = "rubydoom — #{map_name}"
      @map        = Map.load(@wad, map_name)
      @bsp        = Bsp.new(@map.nodes)
      @clipper    = Clipper.new(@map, @bsp)
      @clipper.on_cross = method(:handle_walk_cross)
      @doors      = Doors.new(@map)
      @plats      = Plats.new(@map)
      @floors     = Floors.new(@map)
      @switches   = Switches.new(@map)
      @scrollers  = WallScrollers.new(@map)
      @sector_lights  = SectorLights.new(@map)
      @sector_effects = SectorEffects.new(@clipper)
      @pickups        = Pickups.new(@map)
      @player     = Player.from_thing(@map.player_start)
      @automap    = Automap.new(@map, bsp: @bsp)
      sky         = Sky.for_map(map_name, @textures)
      @renderer3d = Renderer3D.new(@map, @bsp,
                                   textures: @textures, flats: @flats,
                                   palette: @palette, colormap: @colormap,
                                   sky: sky, sprites: @sprites)
      @exit_announced = false
    end

    def needs_cursor?
      !@captured
    end

    def draw
      s  = current_scale
      ox = (width  - SCREEN_WIDTH  * s) / 2.0
      oy = (height - SCREEN_HEIGHT * s) / 2.0
      Gosu.translate(ox, oy) { Gosu.scale(s) { render_scene } }
      draw_fps unless @dump_frame_to
      dump_and_exit if @dump_frame_to
    end

    # Live FPS in the top-right, drawn outside Gosu.scale so the text
    # stays crisp regardless of window size. Cached font instance —
    # Gosu::Font allocation is non-trivial.
    def draw_fps
      @fps_font ||= Gosu::Font.new(14)
      text   = "FPS: #{Gosu.fps}"
      margin = 6
      w      = @fps_font.text_width(text)
      @fps_font.draw_text(text, width - w - margin, margin,
                          100, 1, 1, Gosu::Color::WHITE)
    end

    # Largest uniform scale that fits 320x200 inside the current
    # window. Anything left over becomes black letterbox bars (the
    # window's default clear colour).
    def current_scale
      sx = width.fdiv(SCREEN_WIDTH)
      sy = height.fdiv(SCREEN_HEIGHT)
      sx < sy ? sx : sy
    end

    def update
      return if @dump_frame_to
      handle_mouse_look
      handle_keyboard_turn
      handle_movement
      update_view_height
      @doors.update_tic
      @plats.update_tic
      @floors.update_tic
      @scrollers.update_tic
      @sector_lights.update_tic
      @sector_effects.update_tic(@player)
      @pickups.update_tic(@player)
      @flats.update_tic
      @textures.update_tic
      @hud.update_tic(@player)
      announce_exit_if_pending
    end

    def lose_focus
      @focused  = false
      @captured = false
    end

    def gain_focus
      @focused = true
    end

    def button_down(id)
      case id
      when Gosu::KB_ESCAPE
        @captured ? release_mouse : close
      when Gosu::MS_LEFT
        capture_mouse unless @captured
      when Gosu::KB_TAB    then @show_automap = !@show_automap
      when Gosu::KB_B      then @automap_mode = (@automap_mode == :bsp ? :lines : :bsp)
      when Gosu::KB_SPACE  then @doors.try_use(@player) || @switches.try_use(@player)
      when Gosu::KB_P
        puts "RUBYDOOM_X=#{@player.x} RUBYDOOM_Y=#{@player.y} RUBYDOOM_ANGLE=#{@player.angle}"
      # Debug shortcuts for verifying that HUD numbers track player
      # state. Will go away once pickups / damage floors / combat
      # drive these on their own.
      when Gosu::KB_LEFT_BRACKET   then @player.take_damage(10)
      when Gosu::KB_RIGHT_BRACKET  then @player.add_health(10)
      when Gosu::KB_BACKSLASH      then @player.add_armor(25, type: :green)
      end
    end

    def capture_mouse
      @captured       = true
      # Skip the first delta after capture — cursor was wherever the
      # user clicked, so the recenter would otherwise cause a yaw jump.
      @mouse_centered = false
    end

    def release_mouse
      @captured = false
    end

    private

    # Walk-trigger dispatch. Clipper calls this for each special
    # linedef the player crossed in the last successful slide. W1
    # (once-only) handlers clear special_type so the trigger can't
    # re-fire; WR handlers leave it intact.
    def handle_walk_cross(ld)
      if @plats.handle_cross(ld)
        # WR — leave special intact.
      elsif @floors.handle_cross(ld)
        ld.special_type = 0  # W1 — consumed.
      end
    end

    # On exit-switch fire, jump straight to whichever map's marker
    # lump comes next in the WAD directory (no intermission yet).
    # For doom1.wad the lumps happen to be stored in vanilla play
    # order, so this matches the intended progression; custom WADs
    # may sequence differently.
    def announce_exit_if_pending
      return if @exit_announced
      return unless @switches.exit_requested
      @exit_announced = true
      next_name = Map.next_in_wad(@wad, @map.name)
      if next_name
        puts "[exit] #{@map.name} → #{next_name}"
        load_map(next_name)
        @last_floor_z      = @clipper.floor_at(@player.x, @player.y)
        @delta_view_height = 0.0
        @player.view_height = NOMINAL_VIEW_HEIGHT.to_f
      else
        puts "[exit] no further map after #{@map.name}"
      end
    end

    def render_scene
      Gosu.draw_rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, BACKGROUND_FILL, -10)
      if @show_automap
        @automap.draw(@player, mode: @automap_mode)
      else
        @renderer3d.draw(@player)
      end
      @hud.draw(@player)
    end

    # Mouse-look: read the cursor's offset from the window center, convert
    # it to yaw, then snap the cursor back to center so it never escapes
    # the window. DOOM angle increases counter-clockwise (0=E, 90=N), so
    # rightward mouse movement (positive dx) decreases the angle.
    def handle_mouse_look
      return unless @captured && @focused
      cx = width  / 2
      cy = height / 2
      unless @mouse_centered
        self.mouse_x = cx
        self.mouse_y = cy
        @mouse_centered = true
        return
      end

      dx = mouse_x - cx
      if dx != 0
        @player.angle = (@player.angle - dx * MOUSE_SENSITIVITY) % 360.0
      end
      self.mouse_x = cx
      self.mouse_y = cy
    end

    # Left/right arrows yaw the player (DOOM keyboard-only style); the
    # rate matches vanilla's normal turn speed so it composes naturally
    # with mouse-look. Sign convention: DOOM angle increases CCW, so
    # Left increases it.
    def handle_keyboard_turn
      turn_axis = bool_axis(Gosu::KB_LEFT, Gosu::KB_RIGHT)
      return if turn_axis == 0
      @player.angle = (@player.angle + turn_axis * KEY_TURN_PER_TIC) % 360.0
    end

    # WASD / arrows: W/S/Up/Down walk along the facing vector, A/D strafe
    # perpendicular to it. The proposed delta goes through the Clipper,
    # which blocks moves into walls / closed doors / overly-tall steps and
    # falls back to a one-axis slide when the full move is blocked.
    def handle_movement
      walk_axis   = bool_axis2(Gosu::KB_W, Gosu::KB_UP, Gosu::KB_S, Gosu::KB_DOWN)
      strafe_axis = bool_axis(Gosu::KB_D, Gosu::KB_A)
      moving = walk_axis != 0 || strafe_axis != 0
      update_bob(moving)
      return unless moving

      rad = @player.angle * Math::PI / 180.0
      forward_x =  Math.cos(rad); forward_y =  Math.sin(rad)
      right_x   =  Math.sin(rad); right_y   = -Math.cos(rad)

      target_x = @player.x + (forward_x * walk_axis + right_x * strafe_axis) * MOVE_SPEED_TIC
      target_y = @player.y + (forward_y * walk_axis + right_y * strafe_axis) * MOVE_SPEED_TIC
      @player.x, @player.y = @clipper.slide(@player.x, @player.y, target_x, target_y)
    end

    # View-bob update. Amplitude eases toward BOB_AMPLITUDE while moving
    # and toward zero when stopped (exponential smoothing); phase ticks
    # forward at a constant rate so the sine output is continuous across
    # start/stop transitions instead of jumping back to phase 0.
    # Smooths the camera over step-ups (and step-downs, when we get
    # them). On a floor-height change the player snaps to the new floor
    # but view_height absorbs the delta so the eye stays put; then it
    # climbs back to nominal at an accelerating rate.
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

    def update_bob(moving)
      target_amp = moving ? BOB_AMPLITUDE : 0.0
      alpha      = 1.0 - Math.exp(-TIC_DT / BOB_RAMP_TIME)
      @bob_amp  += (target_amp - @bob_amp) * alpha
      @bob_phase = (@bob_phase + BOB_PHASE_PER_TIC) % (2 * Math::PI)
      @player.bob = @bob_amp * Math.sin(@bob_phase)
    end

    def bool_axis(positive_key, negative_key)
      (Gosu.button_down?(positive_key) ? 1 : 0) -
        (Gosu.button_down?(negative_key) ? 1 : 0)
    end

    # Two-key-per-direction variant for axes that accept either WASD or
    # arrow input — pressing keys on both sides cancels.
    def bool_axis2(pos_a, pos_b, neg_a, neg_b)
      pos = (Gosu.button_down?(pos_a) || Gosu.button_down?(pos_b)) ? 1 : 0
      neg = (Gosu.button_down?(neg_a) || Gosu.button_down?(neg_b)) ? 1 : 0
      pos - neg
    end

    # Renders one frame into an offscreen image, saves it, and quits.
    # Used to verify rendering without a human at the window.
    def dump_and_exit
      img = Gosu.record(SCREEN_WIDTH, SCREEN_HEIGHT) { render_scene }
      img.save(@dump_frame_to)
      close
    end
  end
end
