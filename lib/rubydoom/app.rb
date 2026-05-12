require "gosu"

module Rubydoom
  # The Gosu-specific frontend. App owns the window, the per-frame draw,
  # input polling (translated to a Game::Input each tic), and the
  # Gosu-backed render/audio/asset-cache plumbing. Everything else lives
  # in Game — App constructs a Game, hands it the HUD, and drives it via
  # game.tick(input) once per Gosu update callback.
  #
  # Gosu is firewalled to the frontend layer: app.rb plus the renderers
  # / framebuffer / image cache / HUD / sound driver / wipe (renderer3d.rb,
  # automap.rb, framebuffer.rb, gosu_image_cache.rb, hud.rb, sound.rb,
  # wipe.rb). Of those, app.rb, renderer3d.rb, automap.rb, and
  # gosu_image_cache.rb explicitly `require "gosu"`; framebuffer / hud /
  # sound / wipe use Gosu types at runtime via the transitive load. Game
  # and every per-map subsystem are pure Ruby — verifiable by loading
  # game.rb in a process that doesn't require "gosu" and calling
  # Game#tick with a synthetic Input. An alternative frontend (SDL2,
  # Raylib, headless) would replace App plus those rendering / audio
  # modules, but would leave Game and the rest of the simulation
  # untouched.
  class App < Gosu::Window
    # DOOM's native screen size is 320x200. We scale up via Gosu.scale so
    # the rendering code can keep using original coordinates everywhere.
    SCREEN_WIDTH  = 320
    SCREEN_HEIGHT = 200
    DEFAULT_SCALE = 3
    DEFAULT_MAP   = "E1M1"

    BACKGROUND_FILL = Gosu::Color.rgb(0, 0, 0)

    # Z-order for the full-screen damage/bonus tint. Has to sit above
    # the HUD (z = 100 inside hud.rb) so the wash covers the status bar
    # too, matching vanilla's whole-screen palette swap.
    Z_SCREEN_TINT = 1000

    # Title screen hold before the launch wipe kicks off. Vanilla shows
    # TITLEPIC for `pagetic = 170` tics (~4.85s at 35Hz); we use 105
    # (~3s) because the demo loop / credit pages aren't wired and three
    # seconds reads as a deliberate beat rather than a stall. Any
    # button-down on the title screen skips ahead to the wipe.
    TITLE_HOLD_TICS = 105
    TITLE_LUMP      = "TITLEPIC"
    Z_TITLE         = 0

    def initialize(wad_path:, map_name: DEFAULT_MAP, scale: DEFAULT_SCALE,
                   dump_frame_to: nil, show_automap: false,
                   automap_mode: :lines, skill: nil, scenario: nil)
      @scale         = scale
      @dump_frame_to = dump_frame_to
      @show_automap  = show_automap
      @automap_mode  = automap_mode
      # A pre-built `Rubydoom::Map` (typically from `Scenario#build`)
      # to load instead of resolving `map_name` against the WAD. When
      # set, map_name is overwritten by the scenario's own name for
      # captioning / sky-lookup purposes.
      @scenario      = scenario
      map_name       = @scenario.name if @scenario

      # Demo playback (RUBYDOOM_PLAY=path.rdm): the file's header decides
      # the map, skill, and seed — anything passed in is ignored so the
      # replay is faithful. RUBYDOOM_RECORD=path.rdm captures live input
      # to disk each tic. Mutually exclusive.
      @demo_player   = ENV["RUBYDOOM_PLAY"]   ? Demo::Player.new(ENV["RUBYDOOM_PLAY"]) : nil
      @demo_path     = ENV["RUBYDOOM_RECORD"]
      @demo_recorder = nil  # opened after we know the resolved skill/seed/map

      if @demo_player
        skill_level = @demo_player.header.skill
        seed        = @demo_player.header.seed
        map_name    = @demo_player.header.map_name
      else
        # Skill: CLI / kwarg, else env override, else vanilla default
        # (Hurt Me Plenty = 2). Range 0..4 — see Map::SKILL_DEFAULT.
        skill_level = (ENV["RUBYDOOM_SKILL"]&.to_i || skill || Map::SKILL_DEFAULT).to_i
        seed        = ENV["RUBYDOOM_SEED"]&.to_i
      end

      super(SCREEN_WIDTH * scale, SCREEN_HEIGHT * scale,
            update_interval: 1000.0 / Game::TIC_RATE,
            resizable: true)

      wad    = WAD.open(wad_path)
      # Mute sound effects during demo playback — playback wants a
      # deterministic, side-effect-free run. Live recording keeps audio.
      @sound = @demo_player ? nil : Sound.new(wad)
      # RUBYDOOM_SEED makes the whole sim deterministic — required for
      # the demo-record/playback benchmark to produce stable shasums.
      # Absent: fresh Random (vanilla "different every launch") behavior.
      # During playback the seed comes from the demo header instead.
      @seed  = seed
      @rng   = @seed ? Random.new(@seed) : Random.new
      @game  = Game.new(wad: wad, sound: @sound, skill: skill_level, rng: @rng)

      # HUD needs the Gosu-backed image cache, which needs Game's
      # parsed graphics. Build the Gosu side now, hand the HUD to Game
      # before the first load_map so the tick can include it. We keep
      # the image cache around for non-HUD draws too (title screen).
      @images  = GosuImageCache.new(@game.graphics)
      @hud     = HUD.new(@images, face: Face.new(rng: @rng))
      @game.hud = @hud

      load_map(map_name)

      # Open the recorder now that skill/seed/map are resolved. Recording
      # without a known seed is allowed but the demo won't replay
      # deterministically — emit one if missing so future-us can find out.
      if @demo_path
        rec_seed = @seed || Random.new_seed & 0xFFFFFFFFFFFFFFFF
        unless @seed
          warn "[demo] RUBYDOOM_SEED not set; using fresh seed #{rec_seed}. " \
               "Replay with RUBYDOOM_SEED=#{rec_seed} for determinism."
          @rng = Random.new(rec_seed)
          # Rebuild Game with the new RNG — we already constructed one
          # above with an unseeded RNG, so swap. Cheap because load_map
          # is what materializes the per-map subsystems.
          @game = Game.new(wad: wad, sound: @sound, skill: skill_level, rng: @rng)
          @game.hud = @hud
          load_map(map_name)
        end
        @demo_recorder = Demo::Recorder.new(@demo_path,
                                            skill:    skill_level,
                                            seed:     rec_seed,
                                            map_name: map_name)
        at_exit { @demo_recorder&.close }
      end
      # Honour debug-spawn env vars on the initial map only; transitions
      # spawn the player at the new map's player_start.
      @game.debug_set_player(
        x:     ENV["RUBYDOOM_X"]&.to_f,
        y:     ENV["RUBYDOOM_Y"]&.to_f,
        angle: ENV["RUBYDOOM_ANGLE"]&.to_f,
      )

      # Skip the first frame's mouse delta — cursor starts wherever the OS
      # left it, so the recenter would otherwise cause a sudden yaw jump.
      @mouse_centered = false
      # Click-to-capture: the window starts with the OS cursor visible
      # and mouse-look off, so the user can resize / move the window
      # without first wrestling control of the cursor away. Clicking in
      # the playfield captures; Esc (or losing focus) releases.
      @captured       = false
      @focused        = true
      # Set false so the first MS_LEFT after window-open captures
      # without also firing. Flips true once MS_LEFT has been released
      # at least once while captured.
      @mouse_fire_armed = false

      # Discrete button-down events queue up here between tics and are
      # drained into Input#edges once per Gosu update callback.
      @pending_edges = []

      # Launch sequence: show TITLEPIC for TITLE_HOLD_TICS, then melt
      # it into the first map. While the title is up, @title_tics_left
      # > 0 and the simulation is paused; any button press collapses
      # the timer to 0 so the wipe kicks off immediately. Skipped for
      # dump mode and demo playback — those want gameplay frames from
      # tic 0.
      @title_tics_left =
        (@dump_frame_to || @demo_player) ? 0 : TITLE_HOLD_TICS
    end

    # Load a new map: delegate the simulation work to Game, then
    # (re)build the Gosu-side renderers and update the window caption.
    def load_map(map_name)
      self.caption = "rubydoom — #{map_name}"
      # The scenario, if any, is only loaded the first time — subsequent
      # transitions fall back to looking up `map_name` in the WAD.
      target = @scenario || map_name
      @scenario = nil
      @game.load_map(target)
      sky = Sky.for_map(map_name, @game.textures)
      @renderer3d = Renderer3D.new(@game.map, @game.bsp,
                                   textures: @game.textures, flats: @game.flats,
                                   palette: @game.palette, colormap: @game.colormap,
                                   sky: sky, sprites: @game.sprites)
      @automap = Automap.new(@game.map, bsp: @game.bsp)
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
      # Title screen → wipe → gameplay. While the title is up the sim
      # is frozen; once the hold timer hits zero we bake the title
      # into a texture and hand it to Wipe as the "old" image. Then
      # the wipe runs (sim still frozen) until done, after which the
      # tick loop takes over normally.
      if @title_tics_left.positive?
        @title_tics_left -= 1
        @pending_edges.clear
        start_launch_wipe if @title_tics_left.zero?
        return
      end
      if @wipe
        @wipe.tick
        @pending_edges.clear
        @wipe = nil if @wipe.done?
        return
      end

      input = consume_input
      return unless input  # demo ended (handled inside consume_input)
      @game.tick(input)
      rebuild_renderer if @game.map_reloaded
      announce_exit_if_pending
    end

    # One tic's worth of input. In playback mode, read the next recorded
    # tic and close out cleanly at EOF. Otherwise sample Gosu and (if a
    # recorder is open) tee the result to disk before handing back.
    def consume_input
      if @demo_player
        if @demo_player.end_of_file?
          @demo_player.close
          close
          return nil
        end
        return @demo_player.next_input
      end
      input = build_input
      @demo_recorder << input if @demo_recorder
      input
    end

    def start_launch_wipe
      title = Gosu.render(SCREEN_WIDTH, SCREEN_HEIGHT) { draw_title }
      @wipe = Wipe.new(title)
    end

    def lose_focus
      @focused  = false
      @captured = false
    end

    def gain_focus
      @focused = true
    end

    # Translate one Gosu button press into either an immediate App-side
    # action (window/display state — close, mouse capture, automap toggle)
    # or a semantic edge that the game tic loop will consume. Everything
    # game-relevant goes through @pending_edges so the simulation never
    # sees a Gosu key code.
    def button_down(id)
      # Title-screen skip: any key (Esc still closes the game) ends the
      # hold early. Setting to 1 means the next update tic decrements
      # to zero and kicks off the launch wipe.
      if @title_tics_left.positive?
        if id == Gosu::KB_ESCAPE
          close
        else
          @title_tics_left = 1
        end
        return
      end

      # Window / display actions are App-only — they don't affect game
      # state, and they're honoured dead or alive.
      case id
      when Gosu::KB_ESCAPE
        @captured ? release_mouse : close
        return
      when Gosu::KB_TAB
        @show_automap = !@show_automap
        return
      when Gosu::KB_B
        @automap_mode = (@automap_mode == :bsp ? :lines : :bsp)
        return
      when Gosu::KB_P
        p = @game.player
        puts "RUBYDOOM_X=#{p.x} RUBYDOOM_Y=#{p.y} RUBYDOOM_ANGLE=#{p.angle}"
        return
      when Gosu::MS_LEFT
        if @captured
          # First left-click while dead respawns; while alive the held-
          # mouse state drives continuous fire, no edge to emit.
          @pending_edges << :respawn if @game.player.dead?
        else
          capture_mouse
        end
        return
      end

      # God-mode toggle is always available, including while dead, so a
      # fatal hit can't lock the player out of pressing G to resurrect.
      if id == Gosu::KB_G
        @pending_edges << :toggle_god
        return
      end

      # While dead, every action key collapses to respawn; movement /
      # weapon switch / debug shortcuts are suppressed.
      if @game.player.dead?
        case id
        when Gosu::KB_SPACE, Gosu::KB_LEFT_CONTROL, Gosu::KB_RIGHT_CONTROL
          @pending_edges << :respawn
        end
        return
      end

      case id
      when Gosu::KB_SPACE         then @pending_edges << :use
      # Debug shortcuts for verifying that HUD numbers track player
      # state. Will go away once pickups / damage floors / combat
      # drive these on their own.
      when Gosu::KB_LEFT_BRACKET  then @pending_edges << :debug_hurt
      when Gosu::KB_RIGHT_BRACKET then @pending_edges << :debug_heal
      when Gosu::KB_BACKSLASH     then @pending_edges << :debug_armor
      # Weapon selection — vanilla 1-7 keys. "1" cycles fist <->
      # chainsaw when both are owned; the rest map to a single weapon.
      # Switch is deferred to the next "ready" frame so a fire
      # animation in progress isn't interrupted.
      when Gosu::KB_1 then @pending_edges << :weapon_1
      when Gosu::KB_2 then @pending_edges << :weapon_2
      when Gosu::KB_3 then @pending_edges << :weapon_3
      when Gosu::KB_4 then @pending_edges << :weapon_4
      when Gosu::KB_5 then @pending_edges << :weapon_5
      when Gosu::KB_6 then @pending_edges << :weapon_6
      when Gosu::KB_7 then @pending_edges << :weapon_7
      end
    end

    def capture_mouse
      @captured       = true
      # Skip the first delta after capture — cursor was wherever the
      # user clicked, so the recenter would otherwise cause a yaw jump.
      @mouse_centered = false
      # Don't let the captures-click also fire the weapon: the button
      # is still held this tick. Wait for it to be released before
      # the mouse counts as a fire source again.
      @mouse_fire_armed = false
    end

    def release_mouse
      @captured = false
    end

    private

    def rebuild_renderer
      sky = Sky.for_map(@game.map.name, @game.textures)
      @renderer3d = Renderer3D.new(@game.map, @game.bsp,
                                   textures: @game.textures, flats: @game.flats,
                                   palette: @game.palette, colormap: @game.colormap,
                                   sky: sky, sprites: @game.sprites)
      @automap = Automap.new(@game.map, bsp: @game.bsp)
    end

    # On exit-switch fire, jump to the next map. Normal exits walk
    # forward in the WAD directory (`doom1.wad` happens to store the
    # lumps in vanilla play order). Secret exits in E1Mx jump to
    # ExM9 — vanilla's hand-coded secret-level routing, which the
    # WAD directory alone doesn't encode.
    def announce_exit_if_pending
      return if @exit_announced
      return unless @game.switches.exit_requested
      @exit_announced = true
      next_name = pick_next_map
      if next_name
        puts "[exit] #{@game.map.name} → #{next_name}"
        # Bake the current scene into a real texture (Gosu.render, not
        # Gosu.record — we need subimage support) BEFORE swapping the
        # map, then hand it to Wipe so the melt runs over the new map.
        old_screen = Gosu.render(SCREEN_WIDTH, SCREEN_HEIGHT) { render_scene }
        load_map(next_name)
        @wipe = Wipe.new(old_screen)
      else
        puts "[exit] no further map after #{@game.map.name}"
      end
    end

    def pick_next_map
      cur = @game.map.name
      if @game.switches.secret_exit_requested && cur =~ /\AE(\d)M\d\z/
        secret = "E#{$1}M9"
        return secret if @game.wad.lump(secret)
      end
      Map.next_in_wad(@game.wad, cur)
    end

    def render_scene
      # During the title hold we paint only the TITLEPIC — no playfield,
      # no HUD, no tint. Once it's done, the launch wipe captures this
      # same scene into a texture (see start_launch_wipe).
      if @title_tics_left.positive?
        draw_title
        return
      end
      Gosu.draw_rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, BACKGROUND_FILL, -10)
      player = @game.player
      if @show_automap
        @automap.draw(player, mode: @automap_mode)
      else
        @renderer3d.draw(player)
      end
      @hud.draw(player)
      draw_screen_tint(player)
      @wipe.draw if @wipe
    end

    def draw_title
      @images[TITLE_LUMP].draw_at(0, 0, Z_TITLE)
    end

    # Vanilla "V_SetPalette" — a translucent red wash after damage,
    # gold after pickups. Drawn last so it covers playfield + HUD,
    # matching the full-screen palette swap in the original.
    def draw_screen_tint(player)
      tint = player.screen_tint
      return unless tint
      r, g, b, a = tint
      Gosu.draw_rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT,
                     Gosu::Color.rgba(r, g, b, a),
                     Z_SCREEN_TINT)
    end

    # Build the Input value for this tic. All Gosu polling lives here —
    # everything downstream reads from the resulting struct.
    def build_input
      walk_axis   = bool_axis2(Gosu::KB_W, Gosu::KB_UP, Gosu::KB_S, Gosu::KB_DOWN)
      strafe_axis = bool_axis(Gosu::KB_D, Gosu::KB_A)
      turn_axis   = bool_axis(Gosu::KB_LEFT, Gosu::KB_RIGHT)
      look_dx     = consume_mouse_dx
      fire        = compute_fire_held
      edges       = @pending_edges
      @pending_edges = []
      Input.new(walk_axis, strafe_axis, turn_axis, look_dx, fire, edges)
    end

    # Mouse-look: read the cursor's offset from the window center, snap
    # the cursor back to center so it never escapes the window, and
    # return the raw pixel delta. Returns 0 when the cursor isn't
    # captured or the window isn't focused, and skips the first frame
    # after capture so the recenter doesn't produce a yaw jump.
    def consume_mouse_dx
      return 0 unless @captured && @focused
      cx = width  / 2
      cy = height / 2
      unless @mouse_centered
        self.mouse_x = cx
        self.mouse_y = cy
        @mouse_centered = true
        return 0
      end
      dx = mouse_x - cx
      self.mouse_x = cx
      self.mouse_y = cy
      dx
    end

    # Resolve "is the fire button held this tic?" from continuous polls.
    # Sources: left-ctrl (vanilla key bind), or mouse-left while the
    # cursor is captured (the same click captures, so this only fires
    # *after* the first click — pressing mouse-left from "released"
    # captures the mouse but doesn't fire that tic). Dead player can't
    # fire; the button is reserved for respawn, which is edge-triggered.
    def compute_fire_held
      return false if @game.player.dead?
      ms_held = @captured && Gosu.button_down?(Gosu::MS_LEFT)
      # The mouse only fires once the capture-click has been released.
      # Re-arming on release means subsequent presses fire normally;
      # without it, the click that captured the cursor would also dump
      # a shot the same tic.
      @mouse_fire_armed = true if @captured && !Gosu.button_down?(Gosu::MS_LEFT)
      ms_fire = ms_held && @mouse_fire_armed
      Gosu.button_down?(Gosu::KB_LEFT_CONTROL) ||
        Gosu.button_down?(Gosu::KB_RIGHT_CONTROL) ||
        ms_fire
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
      # Optional debug dumps:
      #   RUBYDOOM_DUMP_TITLE=1 — just render TITLEPIC, no playfield
      #   RUBYDOOM_WIPE_TICS=N — render the playfield with the title
      #                          mid-wipe at tic N. Used to verify the
      #                          wipe overlay composites correctly.
      if ENV["RUBYDOOM_DUMP_TITLE"]
        @title_tics_left = 1
      elsif (tics = ENV["RUBYDOOM_WIPE_TICS"]&.to_i)
        title = Gosu.render(SCREEN_WIDTH, SCREEN_HEIGHT) { draw_title }
        @wipe = Wipe.new(title)
        tics.times { @wipe.tick }
      end
      img = Gosu.record(SCREEN_WIDTH, SCREEN_HEIGHT) { render_scene }
      img.save(@dump_frame_to)
      close
    end
  end
end
