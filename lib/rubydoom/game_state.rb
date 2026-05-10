module Rubydoom
  # Mock player state for HUD rendering. Will get replaced / extended once
  # there's an actual game loop.
  GameState = Struct.new(
    :health, :armor, :ammo,
    :current_weapon,
    keyword_init: true,
  ) do
    def self.default
      new(health: 100, armor: 50, ammo: 50, current_weapon: :pistol)
    end
  end
end
