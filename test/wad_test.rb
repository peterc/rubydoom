require "test_helper"

# WAD lump directory parsing. Asserts against the shareware doom1.wad —
# regressions in the parser would either fail to find lumps or report
# wrong sizes, both of which break test setup elsewhere too. But this
# is the direct check.
class WadTest < Minitest::Test
  def setup
    @wad = TestHelper.wad
  end

  def test_recognises_iwad_magic
    assert_equal "IWAD", @wad.type
  end

  def test_directory_is_non_empty
    refute_empty @wad.lumps
    assert @wad.lumps.size > 1000, "shareware WAD has > 1000 lumps"
  end

  def test_canonical_lumps_exist
    %w[PLAYPAL COLORMAP TEXTURE1 PNAMES ENDOOM].each do |name|
      refute_nil @wad.lump(name), "expected lump #{name}"
    end
  end

  def test_playpal_is_14_palettes_of_768_bytes
    lump = @wad.lump("PLAYPAL")
    refute_nil lump
    assert_equal 14 * 768, lump.size
    bytes = @wad.bytes_for("PLAYPAL")
    assert_equal 14 * 768, bytes.bytesize
  end

  def test_colormap_is_34_tables_of_256_bytes
    # 32 light-level tables + 2 specials (invuln-inverse + nothing).
    lump = @wad.lump("COLORMAP")
    refute_nil lump
    assert_equal 34 * 256, lump.size
  end

  def test_e1_map_markers_all_present
    %w[E1M1 E1M2 E1M3 E1M4 E1M5 E1M6 E1M7 E1M8 E1M9].each do |name|
      refute_nil @wad.lump(name), "expected map marker #{name}"
    end
  end

  def test_bytes_for_returns_exactly_the_lump_size
    lump  = @wad.lump("PLAYPAL")
    bytes = @wad.bytes_for("PLAYPAL")
    assert_equal lump.size, bytes.bytesize
  end

  def test_unknown_lump_returns_nil
    assert_nil @wad.lump("NOPE12345")
    assert_nil @wad.bytes_for("NOPE12345")
  end

  def test_lookup_is_case_insensitive
    assert_equal @wad.lump("PLAYPAL"), @wad.lump("playpal")
  end

  def test_lump_names_have_no_null_padding_leaked
    refute @wad.lumps.any? { |l| l.name.include?("\x00") },
           "names should be stripped of null pad bytes"
  end
end
