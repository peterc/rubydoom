module Rubydoom
  # Composes the DOOM status bar HUD using cached Gosu images.
  # All coordinates are in original DOOM 320x200 screen space — scaling is
  # the caller's responsibility (apply Gosu.scale around the draw call).
  #
  # Layout constants come from the vanilla DOOM source (st_stuff.c).
  class HUD
    STATUS_BAR_Y       = 168
    STATUS_BAR_HEIGHT  = 32

    BIG_NUM_Y          = 171
    AMMO_RIGHT_X       = 44
    HEALTH_RIGHT_X     = 90
    ARMOR_RIGHT_X      = 221

    ARMS_X             = 104
    ARMS_Y             = STATUS_BAR_Y

    FACE_X             = 143
    FACE_Y             = 168

    BIG_NUM_PREFIX     = "STTNUM"   # red, height 16
    SMALL_NUM_PREFIX   = "STYSNUM"  # yellow, height 6

    # Right-side ammo panel. Each row shows current / max for one
    # ammo type; the BULL / SHEL / RCKT / CELL labels are baked into
    # STBAR so we only draw the numbers. Coordinates from
    # linuxdoom-1.10/st_stuff.c (ST_AMMO0X / ST_MAXAMMO0X / spacing 6).
    AMMO_PANEL_TOP_Y       = 173
    AMMO_PANEL_ROW_DY      = 6
    AMMO_PANEL_CUR_RIGHT_X = 288
    AMMO_PANEL_MAX_RIGHT_X = 314
    AMMO_PANEL_TYPES       = %i[bullet shell rocket cell].freeze

    # Three stacked key icons between AMMO and FACE. Coords from
    # st_stuff.c (ST_KEY0X / ST_KEY0Y, spacing 10). Slot order is
    # blue, yellow, red — top to bottom. Each slot draws STKEYS0..2
    # for cards and STKEYS3..5 for skulls; if the player holds both
    # variants of a colour the skull is shown (vanilla rule — skull
    # check overwrites the card assignment in st_stuff.c).
    KEY_BOX_X    = 239
    KEY_BOX_TOP_Y = 171
    KEY_BOX_DY   = 10
    KEY_COLOURS  = %i[blue yellow red].freeze

    # Weapon ("psprite") position. DOOM positions weapon patches via
    #   screen_xy = psp_xy - patch_offset_xy
    # At rest psp->sx = 0 and psp->sy = WEAPONTOP = 32. There's also a
    # vertical correction: with the status bar visible vanilla uses
    # centery = viewheight/2 = 84 instead of the screen center 100, which
    # shifts psprites up by 16 pixels. We fold that into the y constant
    # rather than reproducing the full centery math here.
    PSP_IDLE_X         = 0
    PSP_IDLE_Y         = 32 - 16  # WEAPONTOP minus (SCREEN_CENTER_Y - VIEW_CENTER_Y)

    # Z layers — higher draws on top.
    Z_WEAPON           = 0
    Z_STATUS_BAR_BG    = 1
    Z_STATUS_BAR_FG    = 2

    def initialize(images, face: Face.new)
      @images = images
      @face   = face
      @weapons = nil
    end

    # The Weapons state machine drives the PSPR frame each tic. App
    # injects it after construction (per-map) since Weapons depends on
    # the per-map Hitscan instance. nil falls back to the weapon's
    # idle lump.
    attr_writer :weapons

    def update_tic(player)
      @face.update_tic(player.health)
    end

    def draw(player)
      draw_weapon(player)
      draw_status_bar(player)
    end

    private

    def draw_weapon(player)
      # Vanilla's death drops the weapon off-screen via the PSPR
      # state machine. We don't model that fully — just skip the
      # draw while dead. View height interpolates to DEAD_VIEW_HEIGHT
      # in parallel, so the camera is on the floor and the absent
      # weapon reads as "body collapsed."
      return if player.dead?
      lump = @weapons ? @weapons.display_lump(player) : weapon_lump_for(player.current_weapon)
      return unless lump
      sprite = @images[lump]
      sprite.draw_anchored(PSP_IDLE_X, PSP_IDLE_Y, Z_WEAPON)
    end

    def draw_status_bar(player)
      # All status-bar elements use draw_anchored, which mirrors vanilla
      # DOOM's V_DrawPatch (it applies the patch's left/top offsets).
      # STBAR / STARMS / STTNUM* have (0,0) offsets so it's a no-op for
      # them, but STFST00 has (-5,-2) and won't sit centered without it.
      @images["STBAR"].draw_anchored(0, STATUS_BAR_Y, Z_STATUS_BAR_BG)
      @images["STARMS"].draw_anchored(ARMS_X, ARMS_Y, Z_STATUS_BAR_FG)

      # Big AMMO is the current weapon's primary ammo count; melee
      # weapons (fist / chainsaw) have no ammo type so we leave the
      # slot blank rather than draw a zero.
      cur = player.current_ammo
      draw_big_number(cur, right_x: AMMO_RIGHT_X, y: BIG_NUM_Y) if cur

      draw_big_number(player.health, right_x: HEALTH_RIGHT_X, y: BIG_NUM_Y, percent: true)
      draw_big_number(player.armor,  right_x: ARMOR_RIGHT_X,  y: BIG_NUM_Y, percent: true)

      draw_ammo_panel(player)
      draw_keys(player)

      @images[@face.lump_name(player.health)].draw_anchored(FACE_X, FACE_Y, Z_STATUS_BAR_FG)
    end

    def draw_keys(player)
      KEY_COLOURS.each_with_index do |colour, i|
        slot = player.keys[colour]
        next unless slot[:card] || slot[:skull]
        lump_idx = slot[:skull] ? i + 3 : i
        y = KEY_BOX_TOP_Y + i * KEY_BOX_DY
        @images["STKEYS#{lump_idx}"].draw_anchored(KEY_BOX_X, y, Z_STATUS_BAR_FG)
      end
    end

    def draw_ammo_panel(player)
      AMMO_PANEL_TYPES.each_with_index do |type, i|
        y = AMMO_PANEL_TOP_Y + i * AMMO_PANEL_ROW_DY
        draw_small_number(player.ammo[type],     right_x: AMMO_PANEL_CUR_RIGHT_X, y: y)
        draw_small_number(player.max_ammo[type], right_x: AMMO_PANEL_MAX_RIGHT_X, y: y)
      end
    end

    def draw_small_number(value, right_x:, y:)
      cursor = right_x
      value.to_s.reverse.each_char do |digit|
        glyph = @images["#{SMALL_NUM_PREFIX}#{digit}"]
        cursor -= glyph.width
        glyph.draw_anchored(cursor, y, Z_STATUS_BAR_FG)
      end
    end

    # Right-aligned: rightmost digit's right edge sits at right_x. The
    # optional % glyph is drawn with its left edge at right_x (so the
    # digits are unaffected by adding the %).
    def draw_big_number(value, right_x:, y:, percent: false)
      if percent
        @images["STTPRCNT"].draw_anchored(right_x, y, Z_STATUS_BAR_FG)
      end
      cursor = right_x
      value.to_s.reverse.each_char do |digit|
        glyph = @images["#{BIG_NUM_PREFIX}#{digit}"]
        cursor -= glyph.width
        glyph.draw_anchored(cursor, y, Z_STATUS_BAR_FG)
      end
    end

    def weapon_lump_for(weapon)
      case weapon
      when :fist     then "PUNGA0"
      when :pistol   then "PISGA0"
      when :shotgun  then "SHTGA0"
      when :chaingun then "CHGGA0"
      when :rocket   then "MISGA0"
      when :plasma   then "PLSGA0"
      when :bfg      then "BFGGA0"
      when :chainsaw then "SAWGA0"
      end
    end
  end
end
