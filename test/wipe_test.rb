require "test_helper"

# The wipe is pure Ruby; the only Gosu touch-point is calling
# .subimage on the source image during construction. We stub that
# with FakeImage so the test doesn't need an OpenGL context.
class WipeTest < Minitest::Test
  class FakeImage
    def subimage(*_args)
      :stub_strip
    end
  end

  W = Rubydoom::Wipe

  def fresh(seed: 0)
    W.new(FakeImage.new, random: Random.new(seed))
  end

  def y_of(wipe)
    wipe.instance_variable_get(:@y)
  end

  def force_y!(wipe, value)
    wipe.instance_variable_set(:@y, Array.new(W::NUM_COLS, value))
  end

  def test_initial_y_values_stay_in_vanilla_range
    y = y_of(fresh(seed: 42))
    assert_equal W::NUM_COLS, y.length
    y.each { |v| assert_includes(-W::MAX_DELAY..0, v, "y=#{v} out of range") }
  end

  def test_neighbouring_columns_differ_by_at_most_one
    y = y_of(fresh(seed: 7))
    (1...y.length).each do |i|
      assert (y[i] - y[i - 1]).abs <= 1,
             "cols #{i-1}/#{i} drift by more than 1: #{y[i-1]} → #{y[i]}"
    end
  end

  def test_done_is_false_at_start
    refute fresh.done?
  end

  def test_negative_columns_count_up_by_one_per_tic
    wipe = fresh
    force_y!(wipe, -5)
    wipe.tick
    assert_equal(-4, y_of(wipe).first)
  end

  def test_ease_in_speed_below_threshold_is_y_plus_one
    wipe = fresh
    # Vanilla: while y < 16, dy = y + 1. So y=4 → dy=5 → 9.
    force_y!(wipe, 4)
    wipe.tick
    assert_equal 9, y_of(wipe).first
  end

  def test_fast_speed_at_or_above_threshold_is_eight
    wipe = fresh
    # Vanilla: y >= 16 → dy = 8. So y=16 → 24.
    force_y!(wipe, W::EASE_IN_THRESHOLD)
    wipe.tick
    assert_equal 24, y_of(wipe).first
  end

  def test_dy_clamps_so_y_never_exceeds_screen_height
    wipe = fresh
    force_y!(wipe, W::SCREEN_HEIGHT - 3)
    wipe.tick
    y_of(wipe).each { |v| assert_equal W::SCREEN_HEIGHT, v }
  end

  def test_already_at_screen_height_does_not_advance
    wipe = fresh
    force_y!(wipe, W::SCREEN_HEIGHT)
    wipe.tick
    y_of(wipe).each { |v| assert_equal W::SCREEN_HEIGHT, v }
  end

  def test_wipe_eventually_reports_done
    wipe = fresh(seed: 1)
    completed = 400.times.any? { wipe.tick && wipe.done? }
    assert completed, "wipe did not finish in 400 tics"
  end

  def test_when_done_every_column_is_at_screen_height
    wipe = fresh(seed: 1)
    400.times { wipe.tick; break if wipe.done? }
    assert wipe.done?
    y_of(wipe).each { |v| assert_equal W::SCREEN_HEIGHT, v }
  end

  def test_seeded_random_is_deterministic
    a = fresh(seed: 99)
    b = fresh(seed: 99)
    assert_equal y_of(a), y_of(b)
  end
end
