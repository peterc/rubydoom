require "test_helper"

# S1 Donut (special type 9). E1M2's nukage-ring secret: pressing the
# switch lowers the central pillar to the model sector's floor height
# and raises the surrounding nukage ring to meet it, transferring the
# model's floor texture and (lack of) damage onto the ring — so the
# player can walk across what was just a damaging pool.
class DonutsTest < Minitest::Test
  def setup
    @map    = Rubydoom::Map.load(TestHelper.wad, "E1M2", skill: 3)
    @donuts = Rubydoom::Donuts.new(@map)
  end

  def test_donut_lowers_pillar_raises_ring_and_transfers_texture
    pillar = @map.sectors.find { |s| s.tag == 8 }
    refute_nil pillar, "E1M2 has the tag-8 donut pillar"
    ring, model = find_ring_and_model(pillar)
    refute_nil ring,  "donut ring found"
    refute_nil model, "donut model found"

    pillar_floor_start = pillar.floor_height
    ring_floor_start   = ring.floor_height
    ring_tex_start     = ring.floor_texture
    ring_spec_start    = ring.special_type
    dest               = model.floor_height

    # Sanity on the E1M2 fixture: the pillar starts above and the ring
    # below the model, and the ring carries the nukage-damage special.
    assert pillar_floor_start > dest, "pillar starts above model"
    assert ring_floor_start   < dest, "ring starts below model"
    assert_equal 7, ring_spec_start, "ring starts with nukage damage"

    assert @donuts.activate(8), "donut fired"

    travel_steps = ([pillar_floor_start - dest, dest - ring_floor_start].max /
                    Rubydoom::Donuts::SPEED).ceil + 4
    travel_steps.times { @donuts.update_tic }

    assert_equal dest, pillar.floor_height, "pillar reached model height"
    assert_equal dest, ring.floor_height,   "ring reached model height"
    assert_equal model.floor_texture, ring.floor_texture,
                 "ring inherited model floor texture"
    refute_equal ring_tex_start, ring.floor_texture, "texture actually changed"
    assert_equal model.special_type, ring.special_type,
                 "ring inherited model special (clears nukage)"
  end

  private

  def find_ring_and_model(pillar)
    ring = neighbor_through_two_sided(pillar) { |s| s != pillar }
    return [nil, nil] unless ring
    model = neighbor_through_two_sided(ring) { |s| s != pillar && s != ring }
    [ring, model]
  end

  def neighbor_through_two_sided(sector)
    @map.linedefs.each do |ld|
      next unless ld.two_sided?
      f = @map.linedef_front_sector(ld)
      b = @map.linedef_back_sector(ld)
      next if f.nil? || b.nil?
      if f == sector && yield(b)
        return b
      elsif b == sector && yield(f)
        return f
      end
    end
    nil
  end
end
