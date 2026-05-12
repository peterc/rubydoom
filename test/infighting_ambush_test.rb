require "test_helper"

# Two vanilla AI nuances that affect every map:
#   1. Infighting — when one monster damages another, the victim
#      retargets the attacker. Same-species attacks don't infight
#      (two imps won't fight each other).
#   2. MF_AMBUSH ("deaf") monsters don't wake on the noise-alert
#      flood — only on sight.
class InfightingAmbushTest < Minitest::Test
  def setup
    @game = fresh_game(map: "E1M3")
  end

  def test_imp_fireball_into_zombieman_triggers_infighting
    imp = @game.combat.monsters.find { |m| m.thing.type == 3001 }
    zom = @game.combat.monsters.find { |m| m.thing.type == 3004 }
    refute_nil imp
    refute_nil zom
    assert_nil zom.target

    # Simulate the fireball-hits-zombieman damage path that
    # Projectiles#damage_target now routes through Combat.
    @game.combat.damage(zom, 5, source: imp)
    assert_equal imp, zom.target, "victim retargets the cross-species attacker"
  end

  def test_same_species_attack_does_not_retarget
    imps = @game.combat.monsters.select { |m| m.thing.type == 3001 }
    skip "need two imps" if imps.size < 2
    imp_a, imp_b = imps[0], imps[1]
    imp_b.target = nil

    @game.combat.damage(imp_b, 5, source: imp_a)
    assert_nil imp_b.target, "imp-on-imp damage doesn't retarget"
  end

  def test_player_damage_always_retargets
    imp = @game.combat.monsters.find { |m| m.thing.type == 3001 }
    imp.target = nil
    @game.combat.damage(imp, 5, source: @game.player)
    assert_equal @game.player, imp.target
  end

  def test_deaf_monster_ignores_noise_alert
    imp = @game.combat.monsters.find { |m| m.thing.type == 3001 }
    imp.thing.flags |= Rubydoom::Map::THING_FLAG_AMBUSH
    imp.target = nil
    imp.reaction_time = 0

    # Force the sight path to fail so we only see the noise path.
    ai = @game.monster_ai
    ai.singleton_class.send(:define_method, :in_front_of?)    { |_, _| false }
    ai.singleton_class.send(:define_method, :can_see_player?) { |_, _| false }

    # Directly seed the noise flood for the imp's sector so we know
    # the wake path would otherwise fire.
    isec = ai.send(:sector_index_for, imp)
    @game.noise_alert.instance_variable_get(:@soundtarget)[isec] = @game.player

    ai.send(:a_look, imp, @game.player)
    assert_nil imp.target, "deaf imp ignores noise alert"
  end

  def test_hearing_monster_wakes_on_noise_alert
    imp = @game.combat.monsters.find { |m| m.thing.type == 3001 }
    imp.thing.flags &= ~Rubydoom::Map::THING_FLAG_AMBUSH
    imp.target = nil
    imp.reaction_time = 0

    ai = @game.monster_ai
    ai.singleton_class.send(:define_method, :in_front_of?)    { |_, _| false }
    ai.singleton_class.send(:define_method, :can_see_player?) { |_, _| false }

    isec = ai.send(:sector_index_for, imp)
    @game.noise_alert.instance_variable_get(:@soundtarget)[isec] = @game.player

    ai.send(:a_look, imp, @game.player)
    assert_equal @game.player, imp.target, "non-deaf imp wakes on noise"
  end

  def test_deaf_monster_still_wakes_on_sight
    imp = @game.combat.monsters.find { |m| m.thing.type == 3001 }
    imp.thing.flags |= Rubydoom::Map::THING_FLAG_AMBUSH
    imp.target = nil
    imp.reaction_time = 0

    ai = @game.monster_ai
    ai.singleton_class.send(:define_method, :in_front_of?)    { |_, _| true  }
    ai.singleton_class.send(:define_method, :can_see_player?) { |_, _| true  }

    ai.send(:a_look, imp, @game.player)
    assert_equal @game.player, imp.target,
                 "deaf flag only blocks noise, not sight"
  end
end
