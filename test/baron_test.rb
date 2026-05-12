require "test_helper"

# Baron of Hell (MT_BRUISER) + MT_BRUISERSHOT + A_BossDeath. Vanilla
# E1M8 contract: two Barons, one tag-666 sector. Killing the last
# Baron lowers that floor to its lowest neighbour. Killing only one
# leaves the floor alone. The action is a no-op outside E1M8.
class BaronTest < Minitest::Test
  def test_baron_mobjinfo_registered
    info = Rubydoom::MonsterInfo[3003]
    refute_nil info, "Baron mobjinfo present"
    assert_equal 1000, info.health
    assert_equal 24,   info.radius
    assert_equal 64,   info.height
    assert_equal :boss_atk1, info.melee_state
    assert_equal :boss_atk1, info.missile_state
  end

  def test_baron_state_table_has_boss_death_action_on_terminal_die
    s = Rubydoom::MonsterStates[:boss_die7]
    refute_nil s
    assert_equal :boss_death, s.action
    assert_nil   s.tics, "terminal die frame holds (tics = nil)"
  end

  def test_e1m8_has_two_barons_and_a_tag666_sector
    game = fresh_game(map: "E1M8")
    barons = game.combat.monsters.select { |m| m.info == Rubydoom::MonsterInfo[3003] }
    assert_equal 2, barons.size
    refute_empty game.map.sectors.select { |s| s.tag == 666 }
  end

  def test_killing_one_baron_does_not_lower_the_floor
    game = fresh_game(map: "E1M8")
    floor_before = game.map.sectors.find { |s| s.tag == 666 }.floor_height
    barons = game.combat.monsters.select { |m| m.info == Rubydoom::MonsterInfo[3003] }
    game.combat.damage(barons.first, 10_000, source: game.player)
    # Tic enough for the full death sequence (7 frames × 8 tics = 56).
    100.times { game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [])) }
    floor_after = game.map.sectors.find { |s| s.tag == 666 }.floor_height
    assert_equal floor_before, floor_after,
                 "tag-666 floor stays put while a Baron is alive"
  end

  def test_killing_both_barons_lowers_tag666_to_lowest_neighbor
    game = fresh_game(map: "E1M8")
    sec = game.map.sectors.find { |s| s.tag == 666 }
    floor_before = sec.floor_height
    barons = game.combat.monsters.select { |m| m.info == Rubydoom::MonsterInfo[3003] }
    barons.each { |b| game.combat.damage(b, 10_000, source: game.player) }
    # Drive the death sequence + the floor descent to its new height.
    300.times { game.tick(Rubydoom::Input.new(0, 0, 0, 0, false, [])) }
    assert sec.floor_height < floor_before,
           "tag-666 floor dropped after last Baron died"
  end

  def test_boss_death_is_noop_outside_e1m8
    game = fresh_game(map: "E1M1")
    # Synthesize a Baron mobj on E1M1 — there are no Barons in the map,
    # but we can spawn one via combat's add path by reusing an imp
    # thing. Simpler: just call a_boss_death directly with a stub mobj.
    info = Rubydoom::MonsterInfo[3003]
    Struct.new(:info, :health) unless defined?(StubMobj)
    mobj = Struct.new(:info, :health).new(info, 0)
    # Wire @floors so the test can detect calls.
    floors = RecordingFloors.new
    game.monster_ai.floors = floors
    game.monster_ai.send(:a_boss_death, mobj, game.player)
    assert_empty floors.calls,
                 "A_BossDeath on a non-E1M8 map is a no-op"
  end

  def test_bruisr_attack_melee_at_close_range_damages_player
    game = fresh_game(map: "E1M8")
    baron = game.combat.monsters.find { |m| m.info == Rubydoom::MonsterInfo[3003] }
    refute_nil baron
    baron.target = game.player
    # Move player adjacent (within MELEE_RANGE + 20). MELEE_RANGE=64.
    game.player.x = baron.thing.x + 50
    game.player.y = baron.thing.y
    hp_before = game.player.health
    game.monster_ai.instance_variable_set(:@rng, Random.new(42))
    game.monster_ai.send(:a_bruisr_attack, baron, game.player)
    assert game.player.health < hp_before, "player took claw damage"
  end

  def test_bruisr_attack_at_long_range_spawns_a_fireball
    game = fresh_game(map: "E1M8")
    baron = game.combat.monsters.find { |m| m.info == Rubydoom::MonsterInfo[3003] }
    refute_nil baron
    baron.target = game.player
    # Push the player far from the baron so it falls into the missile
    # branch (well beyond MELEE_RANGE).
    game.player.x = baron.thing.x + 600
    game.player.y = baron.thing.y
    before = game.projectiles.projs.size
    game.monster_ai.send(:a_bruisr_attack, baron, game.player)
    assert_equal before + 1, game.projectiles.projs.size,
                 "bruiser ball queued"
    bal = game.projectiles.projs.last
    assert_equal "BAL7", bal.thing.sprite_override
  end

  # Records every activate_lower_to_lowest call so a_boss_death tests
  # can assert it wasn't called without needing a full Floors flow.
  class RecordingFloors
    attr_reader :calls
    def initialize; @calls = []; end
    def activate_lower_to_lowest(tag); @calls << tag; true; end
  end
end
