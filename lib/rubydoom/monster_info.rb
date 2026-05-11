module Rubydoom
  # Per-monster constants pulled from linuxdoom-1.10/info.c's `mobjinfo[]`.
  # We carry only what the AI/combat code touches — health, collision
  # radius/height, movement speed, pain-on-hit chance, the entry-point
  # state names for the major behaviour transitions, and the per-attack
  # sound effect (folded in here even though we don't play sounds yet —
  # the field reserves a place for them).
  #
  # `reaction_time` is the initial tic delay before A_Look will react to
  # a sighted player — vanilla 8 for everything in E1. `pain_chance` is
  # rolled against `rand(256)` on damage; below it triggers the pain
  # state. `speed` is map units per movement tic (a chase-step happens
  # every few tics, not every tic).
  module MonsterInfo
    Info = Struct.new(
      :doomednum, :health, :radius, :height, :speed, :pain_chance,
      :reaction_time,
      :spawn_state, :see_state, :pain_state, :melee_state,
      :missile_state, :death_state, :xdeath_state, :raise_state,
      :see_sound, :pain_sound, :death_sound, :attack_sound, :active_sound,
      :flags,
      keyword_init: true,
    )

    # MF_COUNTKILL is the "this counts toward the level's KILLS stat"
    # flag — every monster gets it. We don't have a kills counter yet,
    # but tagging mobjs with it now keeps the door open.
    FLAG_COUNTKILL = 1

    ENTRIES = [
      # Zombieman (POSS) — health 20, hitscan attacker.
      Info.new(
        doomednum: 3004, health: 20, radius: 20, height: 56,
        speed: 8, pain_chance: 200, reaction_time: 8,
        spawn_state:   :poss_stnd,
        see_state:     :poss_run1,
        pain_state:    :poss_pain,
        missile_state: :poss_atk1,
        death_state:   :poss_die1,
        see_sound:    :posit1, pain_sound: :popain,
        death_sound:  :podth1, attack_sound: :pistol,
        active_sound: :posact,
        flags: FLAG_COUNTKILL,
      ),
      # Shotgun guy (SPOS) — health 30, 3-pellet hitscan.
      Info.new(
        doomednum: 9, health: 30, radius: 20, height: 56,
        speed: 8, pain_chance: 170, reaction_time: 8,
        spawn_state:   :spos_stnd,
        see_state:     :spos_run1,
        pain_state:    :spos_pain,
        missile_state: :spos_atk1,
        death_state:   :spos_die1,
        see_sound:    :bgsit1, pain_sound: :popain,
        death_sound:  :bgdth1, attack_sound: :shotgn,
        active_sound: :bgact,
        flags: FLAG_COUNTKILL,
      ),
      # Imp (TROO) — health 60, melee claw + (vanilla) fireball missile.
      # We have no projectile system yet, so the missile state runs the
      # animation but doesn't actually spawn a fireball; the imp instead
      # falls back to its claw if the player is in melee range.
      Info.new(
        doomednum: 3001, health: 60, radius: 20, height: 56,
        speed: 8, pain_chance: 200, reaction_time: 8,
        spawn_state:   :troo_stnd,
        see_state:     :troo_run1,
        pain_state:    :troo_pain,
        melee_state:   :troo_atk1,
        missile_state: :troo_atk1,
        death_state:   :troo_die1,
        see_sound:    :bgsit1, pain_sound: :popain,
        death_sound:  :bgdth1, attack_sound: :claw,
        active_sound: :bgact,
        flags: FLAG_COUNTKILL,
      ),
      # Demon (SARG) — health 150, melee only, faster than the others.
      Info.new(
        doomednum: 3002, health: 150, radius: 30, height: 56,
        speed: 10, pain_chance: 180, reaction_time: 8,
        spawn_state:   :sarg_stnd,
        see_state:     :sarg_run1,
        pain_state:    :sarg_pain,
        melee_state:   :sarg_atk1,
        death_state:   :sarg_die1,
        see_sound:    :sgtsit, pain_sound: :dmpain,
        death_sound:  :sgtdth, attack_sound: :sgtatk,
        active_sound: :dmact,
        flags: FLAG_COUNTKILL,
      ),
      # Spectre (also SARG, partial-invisibility flag in vanilla; we
      # don't have the invisibility render yet, so it just acts the
      # same as a demon).
      Info.new(
        doomednum: 58, health: 150, radius: 30, height: 56,
        speed: 10, pain_chance: 180, reaction_time: 8,
        spawn_state:   :sarg_stnd,
        see_state:     :sarg_run1,
        pain_state:    :sarg_pain,
        melee_state:   :sarg_atk1,
        death_state:   :sarg_die1,
        see_sound:    :sgtsit, pain_sound: :dmpain,
        death_sound:  :sgtdth, attack_sound: :sgtatk,
        active_sound: :dmact,
        flags: FLAG_COUNTKILL,
      ),
    ].freeze

    BY_DOOMEDNUM = ENTRIES.each_with_object({}) { |info, h| h[info.doomednum] = info }.freeze

    def self.[](doomednum)
      BY_DOOMEDNUM[doomednum]
    end

    def self.monster?(doomednum)
      BY_DOOMEDNUM.key?(doomednum)
    end
  end
end
