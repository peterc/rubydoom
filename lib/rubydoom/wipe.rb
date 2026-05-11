module Rubydoom
  # Vanilla DOOM's "melt" transition between scenes (f_wipe.c). The
  # previous frame is sliced into 2-pixel-wide columns; each column
  # has a random head-start delay then accelerates downward off the
  # bottom of the screen, revealing the new frame behind it. Used at
  # launch (wipe in from black) and between maps.
  #
  # The old frame is captured via Gosu.render into a real texture, then
  # diced into NUM_COLS subimages once. Each tic advances every column;
  # done? becomes true when the last column has fallen off.
  class Wipe
    SCREEN_WIDTH  = 320
    SCREEN_HEIGHT = 200
    COL_WIDTH     = 2
    NUM_COLS      = SCREEN_WIDTH / COL_WIDTH   # 160

    # Sits above the playfield, HUD, and damage tint — the wipe paints
    # the old screen *over* the new one as the new one is uncovered.
    Z_WIPE = 2000

    # Vanilla speed table: while the column's y < 16, dy = y + 1
    # (1, 2, 3, ... — gentle ease-in), then a flat dy = 8 thereafter.
    FAST_DY = 8
    EASE_IN_THRESHOLD = 16

    # Random head-start: column 0 picks a delay in [-15, 0]; each
    # neighbour drifts by -1, 0, or +1 from its predecessor, clamped
    # to the same range. Negative values are "still waiting to start"
    # — they count up to 0 at one-per-tic before the column moves.
    MAX_DELAY = 15

    def initialize(old_image, random: Random.new)
      @strips = NUM_COLS.times.map do |i|
        old_image.subimage(i * COL_WIDTH, 0, COL_WIDTH, SCREEN_HEIGHT)
      end
      @y    = init_y(random)
      @done = false
    end

    def done?
      @done
    end

    # Advance one tic. Returns true once every column has fallen off.
    def tick
      done = true
      NUM_COLS.times do |i|
        if @y[i] < 0
          @y[i] += 1
          done = false
        elsif @y[i] < SCREEN_HEIGHT
          dy = @y[i] < EASE_IN_THRESHOLD ? @y[i] + 1 : FAST_DY
          dy = SCREEN_HEIGHT - @y[i] if @y[i] + dy > SCREEN_HEIGHT
          @y[i] += dy
          done = false
        end
      end
      @done = done
    end

    # Drawn after the new scene; the strips fall down over it.
    def draw
      NUM_COLS.times do |i|
        @strips[i].draw(i * COL_WIDTH, @y[i], Z_WIPE)
      end
    end

    private

    def init_y(random)
      y = Array.new(NUM_COLS)
      y[0] = -random.rand(MAX_DELAY + 1)
      (1...NUM_COLS).each do |i|
        v = y[i - 1] + (random.rand(3) - 1)
        v = 0          if v > 0
        v = -MAX_DELAY if v < -MAX_DELAY
        y[i] = v
      end
      y
    end
  end
end
