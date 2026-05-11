require "test_helper"

# Key inventory + key-locked door behaviour. Vanilla DOOM:
#   * Each colour has card / skull variants but a locked door accepts
#     either — has_key?(:blue) is true if either is held.
#   * DR keyed doors (26/27/28) re-fire on use and don't clear their
#     special; D1 keyed doors (32/33/34) clear special_type after one use.
class KeysTest < Minitest::Test
  def setup
    @player = Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(0, 0, 0)
    )
  end

  def test_fresh_player_holds_no_keys
    refute @player.has_key?(:blue)
    refute @player.has_key?(:yellow)
    refute @player.has_key?(:red)
  end

  def test_pickup_key_absorbs_once_per_variant
    assert       @player.pickup_key(:blue, :card),   "blue card new"
    assert       @player.has_key?(:blue)
    refute       @player.pickup_key(:blue, :card),   "dup blue card NOT absorbed"
    assert       @player.pickup_key(:blue, :skull),  "blue skull new (separate slot)"
    refute       @player.has_key?(:yellow)
  end

  def test_pickup_dispatch_absorbs_blue_card_only_once
    # Find a map with a blue card spawn (E1M2 has one).
    map = first_map_with_thing_type(5)
    skip "no map has blue card type 5" unless map

    blue_card = map.things.find { |t| t.type == 5 }
    pickups = Rubydoom::Pickups.new(map)
    pp = at(map, blue_card)
    pickups.update_tic(pp)

    assert pp.has_key?(:blue)
    assert pp.keys[:blue][:card]
    refute pp.keys[:blue][:skull]
    assert_equal true, blue_card.removed

    # Re-do with a player who already holds the card — should NOT remove.
    map2     = Rubydoom::Map.load(TestHelper.wad, map.name)
    card2    = map2.things.find { |t| t.type == 5 }
    pickups2 = Rubydoom::Pickups.new(map2)
    pp2      = at(map2, card2)
    pp2.pickup_key(:blue, :card)
    pickups2.update_tic(pp2)
    assert_nil card2.removed
  end

  def test_dr_blue_door_refuses_without_key_opens_with_one
    mn, ld, map = find_special(26)
    skip "no DR blue door (26) in shareware" unless ld

    doors = Rubydoom::Doors.new(map)
    back  = map.linedef_back_sector(ld)
    start_ceil = back.ceiling_height
    pp = stand_in_front_of(map, ld)

    refute       doors.try_use(pp),       "refused without blue key"
    assert_equal start_ceil, back.ceiling_height
    assert_equal 26,         ld.special_type, "DR special intact"

    pp.pickup_key(:blue, :card)
    assert       doors.try_use(pp),       "opened with blue key"
    assert_equal 26,         ld.special_type, "DR keeps its special after use"

    60.times { doors.update_tic }
    assert back.ceiling_height > start_ceil, "ceiling rose after use"
  end

  def test_d1_keyed_door_stays_open_and_clears_special
    [32, 33, 34].each do |spec|
      mn, ld, map = find_special(spec)
      next unless ld
      colour = { 32 => :blue, 33 => :red, 34 => :yellow }[spec]
      doors  = Rubydoom::Doors.new(map)
      back   = map.linedef_back_sector(ld)
      start_ceil = back.ceiling_height
      pp = stand_in_front_of(map, ld)
      pp.pickup_key(colour, :card)

      assert       doors.try_use(pp),       "#{spec}/#{colour} opened"
      assert_equal 0,          ld.special_type, "D1 special cleared"
      500.times { doors.update_tic }
      assert back.ceiling_height > start_ceil, "stayed open past DR timer"
      return
    end
    skip "no D1 keyed door (32/33/34) in shareware"
  end

  def test_plain_dr_door_opens_without_keys_and_keeps_special
    mn, ld, map = find_special(1)
    skip "no plain DR door (special 1)" unless ld

    doors = Rubydoom::Doors.new(map)
    pp    = stand_in_front_of(map, ld)
    assert       doors.try_use(pp)
    assert_equal 1, ld.special_type, "DR (1) does not clear special"
  end

  private

  def at(map, thing)
    Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(thing.x, thing.y, 0)
    )
  end

  def first_map_with_thing_type(type)
    %w[E1M2 E1M3 E1M4 E1M5 E1M6 E1M7].each do |mn|
      m = Rubydoom::Map.load(TestHelper.wad, mn)
      return m if m.things.any? { |t| t.type == type }
    end
    nil
  end

  # [map_name, linedef, map] — the first E1 map with that linedef special.
  def find_special(spec)
    %w[E1M1 E1M2 E1M3 E1M4 E1M5 E1M6 E1M7 E1M8 E1M9].each do |mn|
      m  = Rubydoom::Map.load(TestHelper.wad, mn)
      ld = m.linedefs.find { |l| l.special_type == spec && l.two_sided? }
      return [mn, ld, m] if ld
    end
    [nil, nil, nil]
  end

  # Place the player 16 units in front of the linedef midpoint, facing it.
  def stand_in_front_of(map, ld)
    v1 = map.vertexes[ld.start_vertex_index]
    v2 = map.vertexes[ld.end_vertex_index]
    dx = v2.x - v1.x; dy = v2.y - v1.y
    len = Math.hypot(dx, dy)
    nx = dy / len; ny = -dx / len
    mid_x = (v1.x + v2.x) / 2.0
    mid_y = (v1.y + v2.y) / 2.0
    Rubydoom::Player.from_thing(
      Struct.new(:x, :y, :angle).new(
        mid_x + nx * 16.0,
        mid_y + ny * 16.0,
        Math.atan2(-ny, -nx) * 180.0 / Math::PI
      )
    )
  end
end
