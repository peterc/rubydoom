module Rubydoom
  # DOOM HUD face animation. Vanilla cycles through STFST{P}{D} where
  # P is a pain level derived from health (0 = healthy, 4 = critical)
  # and D is a wander direction (0 = forward, 1 = right, 2 = left).
  #
  # The full state machine in st_stuff.c also covers ouch / turn /
  # rampage / evil-grin / god / dead — we don't have damage, pickups,
  # or rampage detection yet, so for now we just animate the wander.
  # Health goes through `pain_offset` so a hypothetical future
  # health-changing event will already cycle through the pain levels.
  class Face
    # How long a single direction sticks before we roll a new one.
    # Vanilla varies between ~17 and ~70 tics depending on state; one
    # second is in that window and looks right for a non-combat HUD.
    WANDER_TICS = 35

    DIRECTIONS = 3   # 0=center, 1=right, 2=left

    DEAD_LUMP = "STFDEAD0"

    def initialize
      @tics_left = 0
      @direction = 0
      @random    = Random.new
    end

    def update_tic(health)
      return if health <= 0
      @tics_left -= 1
      return if @tics_left > 0
      @direction = @random.rand(DIRECTIONS)
      @tics_left = WANDER_TICS
    end

    def lump_name(health)
      return DEAD_LUMP if health <= 0
      "STFST#{pain_offset(health)}#{@direction}"
    end

    private

    # Vanilla ST_calcPainOffset: clamps health, divides 0-100 into 5
    # bands, returns 0..4 with 0 = full health.
    def pain_offset(health)
      h = health.clamp(0, 100)
      4 - (h * 4 / 100)
    end
  end
end
