module Rubydoom
  # Per-monster state machine ported from linuxdoom-1.10/info.c's
  # `states[]` table. Each state is one row:
  #
  #   key (symbol) → State.new(sprite, frame, tics, action?, next)
  #
  # `sprite` is the 4-letter prefix (always the monster's prefix here
  # since we only carry the rows for POSS/SPOS/TROO/SARG); `frame` is
  # the frame letter the renderer's sprite_override/frame_override pair
  # ends up at. `tics` is the duration in tics — vanilla "−1" (sit on
  # this frame forever) is encoded as `nil` here, and action `nil` means
  # the state has no on-enter code.
  #
  # The renderer's rotation logic (renderer3d.rb#pick_rotation) reads
  # `thing.angle` and picks the appropriate A1..A8 lump at draw time,
  # so this table holds only the frame letter — never a rotation digit.
  #
  # We collapsed two parts of vanilla:
  #   * idle/standing cycle ("STND"/"STND2") is one state that loops to
  #     itself with A_Look. Saves a row without changing behaviour.
  #   * 8-step running cycle ("RUN1..RUN8") matches vanilla so each
  #     A_Chase fires on its own tic — total cycle length is the same.
  #
  # XDIE (gory blown-apart) frames aren't included yet — overkill damage
  # falls through to the normal death sequence for now.
  module MonsterStates
    State = Struct.new(:sprite, :frame, :tics, :action, :next, keyword_init: true)

    # Build a row. `action` is a method-symbol on MonsterAI; `nxt` is
    # the key of the next state (or :null to terminate).
    def self.s(sprite, frame, tics, action, nxt)
      State.new(sprite: sprite, frame: frame, tics: tics,
                action: action, next: nxt)
    end

    # Common death-stop sentinel: nil tics + nil next means "stay here
    # forever". Vanilla uses tics=-1 with next pointing at itself.
    NULL = State.new(sprite: nil, frame: nil, tics: nil, action: nil, next: nil)

    TABLE = {
      # --- Zombieman (POSS) ---
      poss_stnd:  s("POSS", "A", 10, :look,  :poss_stnd2),
      poss_stnd2: s("POSS", "B", 10, :look,  :poss_stnd),
      poss_run1:  s("POSS", "A", 4,  :chase, :poss_run2),
      poss_run2:  s("POSS", "A", 4,  :chase, :poss_run3),
      poss_run3:  s("POSS", "B", 4,  :chase, :poss_run4),
      poss_run4:  s("POSS", "B", 4,  :chase, :poss_run5),
      poss_run5:  s("POSS", "C", 4,  :chase, :poss_run6),
      poss_run6:  s("POSS", "C", 4,  :chase, :poss_run7),
      poss_run7:  s("POSS", "D", 4,  :chase, :poss_run8),
      poss_run8:  s("POSS", "D", 4,  :chase, :poss_run1),
      poss_atk1:  s("POSS", "E", 10, :face_target, :poss_atk2),
      poss_atk2:  s("POSS", "F", 8,  :pos_attack,  :poss_atk3),
      poss_atk3:  s("POSS", "E", 8,  nil,    :poss_run1),
      poss_pain:  s("POSS", "G", 3,  nil,    :poss_pain2),
      poss_pain2: s("POSS", "G", 3,  :pain,  :poss_run1),
      poss_die1:  s("POSS", "H", 5,  nil,    :poss_die2),
      poss_die2:  s("POSS", "I", 5,  :scream,:poss_die3),
      poss_die3:  s("POSS", "J", 5,  :fall,  :poss_die4),
      poss_die4:  s("POSS", "K", 5,  nil,    :poss_die5),
      poss_die5:  s("POSS", "L", nil,nil,    nil),

      # --- Shotgun guy (SPOS) ---
      spos_stnd:  s("SPOS", "A", 10, :look,  :spos_stnd2),
      spos_stnd2: s("SPOS", "B", 10, :look,  :spos_stnd),
      spos_run1:  s("SPOS", "A", 3,  :chase, :spos_run2),
      spos_run2:  s("SPOS", "A", 3,  :chase, :spos_run3),
      spos_run3:  s("SPOS", "B", 3,  :chase, :spos_run4),
      spos_run4:  s("SPOS", "B", 3,  :chase, :spos_run5),
      spos_run5:  s("SPOS", "C", 3,  :chase, :spos_run6),
      spos_run6:  s("SPOS", "C", 3,  :chase, :spos_run7),
      spos_run7:  s("SPOS", "D", 3,  :chase, :spos_run8),
      spos_run8:  s("SPOS", "D", 3,  :chase, :spos_run1),
      spos_atk1:  s("SPOS", "E", 10, :face_target, :spos_atk2),
      spos_atk2:  s("SPOS", "F", 10, :spos_attack, :spos_atk3),
      spos_atk3:  s("SPOS", "E", 10, nil,    :spos_run1),
      spos_pain:  s("SPOS", "G", 3,  nil,    :spos_pain2),
      spos_pain2: s("SPOS", "G", 3,  :pain,  :spos_run1),
      spos_die1:  s("SPOS", "H", 5,  nil,    :spos_die2),
      spos_die2:  s("SPOS", "I", 5,  :scream,:spos_die3),
      spos_die3:  s("SPOS", "J", 5,  :fall,  :spos_die4),
      spos_die4:  s("SPOS", "K", 5,  nil,    :spos_die5),
      spos_die5:  s("SPOS", "L", nil,nil,    nil),

      # --- Imp (TROO) ---
      # Vanilla TROO has a missile (fireball) state at S_TROO_ATK1..3;
      # since we have no projectiles, we map both melee_state and
      # missile_state to the same row and treat it as a melee swipe
      # whenever it fires within range. Out of melee range the AI falls
      # back to chase (no missile to fling).
      troo_stnd:  s("TROO", "A", 10, :look,  :troo_stnd2),
      troo_stnd2: s("TROO", "B", 10, :look,  :troo_stnd),
      troo_run1:  s("TROO", "A", 3,  :chase, :troo_run2),
      troo_run2:  s("TROO", "A", 3,  :chase, :troo_run3),
      troo_run3:  s("TROO", "B", 3,  :chase, :troo_run4),
      troo_run4:  s("TROO", "B", 3,  :chase, :troo_run5),
      troo_run5:  s("TROO", "C", 3,  :chase, :troo_run6),
      troo_run6:  s("TROO", "C", 3,  :chase, :troo_run7),
      troo_run7:  s("TROO", "D", 3,  :chase, :troo_run8),
      troo_run8:  s("TROO", "D", 3,  :chase, :troo_run1),
      troo_atk1:  s("TROO", "E", 8,  :face_target, :troo_atk2),
      troo_atk2:  s("TROO", "F", 8,  :face_target, :troo_atk3),
      troo_atk3:  s("TROO", "G", 6,  :troo_attack, :troo_run1),
      troo_pain:  s("TROO", "H", 2,  nil,    :troo_pain2),
      troo_pain2: s("TROO", "H", 2,  :pain,  :troo_run1),
      troo_die1:  s("TROO", "I", 8,  nil,    :troo_die2),
      troo_die2:  s("TROO", "J", 8,  :scream,:troo_die3),
      troo_die3:  s("TROO", "K", 6,  nil,    :troo_die4),
      troo_die4:  s("TROO", "L", 6,  :fall,  :troo_die5),
      troo_die5:  s("TROO", "M", nil,nil,    nil),

      # --- Demon (SARG) ---
      sarg_stnd:  s("SARG", "A", 10, :look,  :sarg_stnd2),
      sarg_stnd2: s("SARG", "B", 10, :look,  :sarg_stnd),
      sarg_run1:  s("SARG", "A", 2,  :chase, :sarg_run2),
      sarg_run2:  s("SARG", "A", 2,  :chase, :sarg_run3),
      sarg_run3:  s("SARG", "B", 2,  :chase, :sarg_run4),
      sarg_run4:  s("SARG", "B", 2,  :chase, :sarg_run5),
      sarg_run5:  s("SARG", "C", 2,  :chase, :sarg_run6),
      sarg_run6:  s("SARG", "C", 2,  :chase, :sarg_run7),
      sarg_run7:  s("SARG", "D", 2,  :chase, :sarg_run8),
      sarg_run8:  s("SARG", "D", 2,  :chase, :sarg_run1),
      sarg_atk1:  s("SARG", "E", 8,  :face_target, :sarg_atk2),
      sarg_atk2:  s("SARG", "F", 8,  :face_target, :sarg_atk3),
      sarg_atk3:  s("SARG", "G", 8,  :sarg_attack, :sarg_run1),
      sarg_pain:  s("SARG", "H", 2,  nil,    :sarg_pain2),
      sarg_pain2: s("SARG", "H", 2,  :pain,  :sarg_run1),
      sarg_die1:  s("SARG", "I", 8,  nil,    :sarg_die2),
      sarg_die2:  s("SARG", "J", 8,  :scream,:sarg_die3),
      sarg_die3:  s("SARG", "K", 4,  nil,    :sarg_die4),
      sarg_die4:  s("SARG", "L", 4,  :fall,  :sarg_die5),
      sarg_die5:  s("SARG", "M", 4,  nil,    :sarg_die6),
      sarg_die6:  s("SARG", "N", nil,nil,    nil),

      # --- Baron of Hell (BOSS) ---
      # 8 stand + 8 run + 3 attack + 2 pain + 7 death. Skips the 7
      # raise states (S_BOSS_RAISE1..7) since we don't implement
      # archvile resurrection. Terminal die state fires :boss_death,
      # which checks E1M8 + last-Baron gating before EV_DoFloor on
      # tag 666 (vanilla A_BossDeath).
      boss_stnd:  s("BOSS", "A", 10, :look,  :boss_stnd2),
      boss_stnd2: s("BOSS", "B", 10, :look,  :boss_stnd),
      boss_run1:  s("BOSS", "A", 3,  :chase, :boss_run2),
      boss_run2:  s("BOSS", "A", 3,  :chase, :boss_run3),
      boss_run3:  s("BOSS", "B", 3,  :chase, :boss_run4),
      boss_run4:  s("BOSS", "B", 3,  :chase, :boss_run5),
      boss_run5:  s("BOSS", "C", 3,  :chase, :boss_run6),
      boss_run6:  s("BOSS", "C", 3,  :chase, :boss_run7),
      boss_run7:  s("BOSS", "D", 3,  :chase, :boss_run8),
      boss_run8:  s("BOSS", "D", 3,  :chase, :boss_run1),
      boss_atk1:  s("BOSS", "E", 8,  :face_target,   :boss_atk2),
      boss_atk2:  s("BOSS", "F", 8,  :face_target,   :boss_atk3),
      boss_atk3:  s("BOSS", "G", 8,  :bruisr_attack, :boss_run1),
      boss_pain:  s("BOSS", "H", 2,  nil,    :boss_pain2),
      boss_pain2: s("BOSS", "H", 2,  :pain,  :boss_run1),
      boss_die1:  s("BOSS", "I", 8,  nil,    :boss_die2),
      boss_die2:  s("BOSS", "J", 8,  :scream,:boss_die3),
      boss_die3:  s("BOSS", "K", 8,  nil,    :boss_die4),
      boss_die4:  s("BOSS", "L", 8,  :fall,  :boss_die5),
      boss_die5:  s("BOSS", "M", 8,  nil,    :boss_die6),
      boss_die6:  s("BOSS", "N", 8,  nil,    :boss_die7),
      boss_die7:  s("BOSS", "O", nil,:boss_death, nil),
    }.freeze

    def self.[](key)
      TABLE[key]
    end

    # Helper to assert at load time that every key we point to actually
    # exists in TABLE. Catches typos in `next` pointers during dev.
    def self.validate!
      TABLE.each do |key, st|
        nxt = st.next
        next if nxt.nil?
        unless TABLE.key?(nxt)
          raise "MonsterStates: #{key.inspect} → unknown next #{nxt.inspect}"
        end
      end
    end

    validate!
  end
end
