require "test_helper"

# Toggling god mode on hands the player every weapon whose assets
# are present in the WAD, and tops their ammo up to max. Plasma and
# BFG are absent from shareware doom1.wad and must be filtered.
class GodModeWeaponsTest < Minitest::Test
  def setup
    @game = fresh_game(map: "E1M1")
    @player = @game.player
  end

  def test_toggle_god_grants_present_weapons_and_max_ammo
    # Start: vanilla pistol-start arsenal (fist + pistol only).
    refute @player.weapons_owned[:shotgun],   "starts without shotgun"
    refute @player.weapons_owned[:chaingun],  "starts without chaingun"
    refute @player.weapons_owned[:rocket],    "starts without rocket launcher"
    refute @player.weapons_owned[:chainsaw],  "starts without chainsaw"

    # Drain ammo so we can detect the top-up.
    @player.ammo.each_key { |k| @player.ammo[k] = 0 }

    capture_stdout { @game.tick(input_with_edge(:toggle_god)) }
    assert @player.god_mode

    %i[fist pistol shotgun chaingun rocket chainsaw].each do |w|
      assert @player.weapons_owned[w], "god mode granted #{w}"
    end
    # Shareware doom1.wad lacks PLSGA0 / BFGGA0, so those are skipped.
    refute @player.weapons_owned[:plasma], "plasma stays missing in shareware"
    refute @player.weapons_owned[:bfg],    "BFG stays missing in shareware"

    # Only ammo for granted weapons gets topped up. Cell stays at 0
    # in shareware because neither plasma nor BFG were granted.
    %i[bullet shell rocket].each do |t|
      assert_equal @player.max_ammo[t], @player.ammo[t],
                   "#{t} ammo topped to max"
    end
    assert_equal 0, @player.ammo[:cell],
                 "cell stays empty without plasma/BFG"
  end

  def test_toggling_god_off_keeps_the_weapons
    capture_stdout { @game.tick(input_with_edge(:toggle_god)) }   # on
    @player.ammo[:shell] = 0
    capture_stdout { @game.tick(input_with_edge(:toggle_god)) }   # off
    refute @player.god_mode
    assert @player.weapons_owned[:shotgun], "shotgun kept after god off"
    assert_equal 0, @player.ammo[:shell],   "no re-grant on god off"
  end

  private

  def input_with_edge(edge)
    Rubydoom::Input.new(0, 0, 0, 0, false, [edge])
  end

  # Game#toggle_god prints "[god mode] ON" — swallow it.
  def capture_stdout
    orig = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = orig
  end
end
