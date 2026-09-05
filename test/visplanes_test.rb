require "test_helper"

class VisplanesTest < Minitest::Test
  def test_disjoint_spans_preserve_the_gap_and_adjacent_spans_merge
    planes = Rubydoom::Visplanes.new(4)
    flat = Object.new
    [[2, 4], [9, 12], [3, 6], [1, 1]].each do |top, bot|
      planes.add_span(flat, 0, 128, false, 0, top, bot)
    end
    result = []
    planes.each_plane { |p| result << p }
    assert_equal 1, result.size
    assert_equal [[1, 6], [9, 12]], result.first.columns[0]
  end

  def test_grouping_preserves_flat_identity_height_light_and_side
    planes = Rubydoom::Visplanes.new(4)
    flat = [1]
    other = [1]
    [[flat, 0, 128, false], [flat, 0, 128, true],
     [flat, 1, 128, false], [flat, 0, 144, false],
     [other, 0, 128, false]].each do |args|
      planes.add_span(*args, 0, 1, 2)
      planes.add_span(*args, 1, 3, 4)
    end
    result = []
    planes.each_plane { |p| result << p }
    assert_equal 5, result.size
    result.each do |p|
      assert_equal [[1, 2]], p.columns[0]
      assert_equal [[3, 4]], p.columns[1]
    end
  end
end
