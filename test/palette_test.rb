require "test_helper"

# PLAYPAL — 14 palettes of 256 RGB triples. Palette 0 is normal play;
# the other 13 are tinted variants for damage / pickup / radiation
# screen flashes.
class PaletteTest < Minitest::Test
  def test_default_palette_has_256_colors
    pal = Rubydoom::Palette.from_wad(TestHelper.wad)
    assert_equal 256, pal.colors.size
  end

  def test_each_color_is_a_frozen_rgb_triple_in_0_255
    pal = Rubydoom::Palette.from_wad(TestHelper.wad)
    pal.colors.each_with_index do |c, i|
      assert_equal 3, c.size,         "color #{i} should be a triple"
      assert c.frozen?,               "color #{i} should be frozen"
      c.each_with_index do |ch, j|
        assert_kind_of Integer, ch
        assert (0..255).cover?(ch),   "color #{i} channel #{j} = #{ch}"
      end
    end
  end

  def test_palette_index_0_is_black_in_vanilla
    pal = Rubydoom::Palette.from_wad(TestHelper.wad)
    assert_equal [0, 0, 0], pal[0]
  end

  def test_loads_each_of_the_14_palettes
    14.times do |i|
      pal = Rubydoom::Palette.from_wad(TestHelper.wad, index: i)
      assert_equal 256, pal.colors.size
    end
  end

  def test_out_of_range_palette_index_raises
    assert_raises(RuntimeError) { Rubydoom::Palette.from_wad(TestHelper.wad, index: 14) }
    assert_raises(RuntimeError) { Rubydoom::Palette.from_wad(TestHelper.wad, index: -1) }
  end

  def test_pickup_tint_palettes_differ_from_default
    base = Rubydoom::Palette.from_wad(TestHelper.wad, index: 0)
    # Palettes 1..8 are red damage tints, 9..12 are bonus pickup tints
    # (yellow), 13 is the radiation suit (green). All should differ
    # from palette 0 at the same index for at least most colors.
    [3, 9, 13].each do |idx|
      tinted = Rubydoom::Palette.from_wad(TestHelper.wad, index: idx)
      differing = base.colors.each_with_index.count { |c, i| c != tinted[i] }
      assert differing > 200, "tint palette #{idx} should differ from base for most colors"
    end
  end

  def test_brackets_returns_color_at_index
    pal = Rubydoom::Palette.from_wad(TestHelper.wad)
    assert_equal pal.colors[42], pal[42]
  end
end
