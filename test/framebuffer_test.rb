require "test_helper"

class FramebufferTest < Minitest::Test
  def test_rectangles_clip_to_framebuffer_without_changing_other_pixels
    [[1, 1, 2, 2], [0, 1, 5, 2], [-1, -1, 7, 6],
     [-2, -1, 4, 3], [3, 2, 5, 5],
     [6, 0, 2, 2], [0, 5, 2, 2], [-5, 0, 2, 2],
     [0, -5, 2, 2], [1, 1, 0, 2], [1, 1, 2, -1]].each do |x, y, w, h|
      fb = Rubydoom::Framebuffer.new(5, 4)
      fb.clear(1, 2, 3, 4)
      fb.fill_rect(x, y, w, h, 10, 20, 30, 40)
      assert_equal 80, fb.rgba.bytesize
      4.times do |py|
        5.times do |px|
          inside = px >= x && px < x + w && py >= y && py < y + h
          expected = inside ? [10, 20, 30, 40] : [1, 2, 3, 4]
          assert_equal expected, fb.rgba.byteslice((py * 5 + px) * 4, 4).bytes
        end
      end
    end
  end
end
