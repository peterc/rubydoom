require "test_helper"

# Picture (DOOM patch) parsing — column-encoded RLE format used for
# sprites, wall patches, and HUD graphics. We verify dimensions of a
# few known lumps and that the transparent-sentinel mechanism works.
class PictureTest < Minitest::Test
  def test_stbar_is_320_by_32
    bytes = TestHelper.wad.bytes_for("STBAR")
    refute_nil bytes
    pic = Rubydoom::Picture.parse(bytes)
    assert_equal 320, pic.width
    assert_equal 32,  pic.height
  end

  def test_titlepic_is_320_by_200
    bytes = TestHelper.wad.bytes_for("TITLEPIC")
    skip "no TITLEPIC in this WAD" unless bytes
    pic = Rubydoom::Picture.parse(bytes)
    assert_equal 320, pic.width
    assert_equal 200, pic.height
  end

  def test_pixels_is_a_height_by_width_grid
    bytes = TestHelper.wad.bytes_for("STBAR")
    pic = Rubydoom::Picture.parse(bytes)
    assert_equal pic.height, pic.pixels.size
    assert_equal pic.width,  pic.pixels.first.size
  end

  def test_all_pixels_are_palette_indices_or_transparent
    bytes = TestHelper.wad.bytes_for("STBAR")
    pic = Rubydoom::Picture.parse(bytes)
    pic.pixels.each_with_index do |row, y|
      row.each_with_index do |idx, x|
        next if idx == Rubydoom::Picture::TRANSPARENT
        assert (0..255).cover?(idx), "pixel (#{x},#{y}) = #{idx} should be in 0..255"
      end
    end
  end

  def test_stbar_has_no_transparency_status_bar_is_fully_opaque
    bytes = TestHelper.wad.bytes_for("STBAR")
    pic = Rubydoom::Picture.parse(bytes)
    transparent_count = pic.pixels.sum { |row| row.count(Rubydoom::Picture::TRANSPARENT) }
    assert_equal 0, transparent_count, "STBAR is solid — no transparent pixels"
  end

  def test_a_sprite_patch_has_some_transparent_pixels
    # PISGA0 = pistol idle sprite, frame A. Sprites are non-rectangular
    # so they always have transparent pixels around the figure.
    bytes = TestHelper.wad.bytes_for("PISGA0")
    refute_nil bytes
    pic = Rubydoom::Picture.parse(bytes)
    transparent_count = pic.pixels.sum { |row| row.count(Rubydoom::Picture::TRANSPARENT) }
    assert transparent_count > 0, "sprite has at least some transparent pixels"
  end

  def test_to_rgba_produces_width_height_4_bytes
    bytes = TestHelper.wad.bytes_for("STBAR")
    pic = Rubydoom::Picture.parse(bytes)
    pal = Rubydoom::Palette.from_wad(TestHelper.wad)
    rgba = pic.to_rgba(pal)
    assert_equal pic.width * pic.height * 4, rgba.bytesize
  end

  def test_to_rgba_emits_zero_alpha_for_transparent_pixels
    # Take a sprite with known transparency; assert at least one zero-
    # alpha pixel exists in the RGBA output.
    bytes = TestHelper.wad.bytes_for("PISGA0")
    pic = Rubydoom::Picture.parse(bytes)
    pal = Rubydoom::Palette.from_wad(TestHelper.wad)
    rgba = pic.to_rgba(pal)
    # Inspect the alpha channel — byte index (y*w + x)*4 + 3.
    found_transparent = false
    (3...rgba.bytesize).step(4) do |i|
      if rgba.getbyte(i) == 0
        found_transparent = true
        break
      end
    end
    assert found_transparent, "sprite RGBA has at least one alpha=0 pixel"
  end
end
