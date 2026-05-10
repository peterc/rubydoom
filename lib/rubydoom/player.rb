module Rubydoom
  # The player's position in map space and facing angle in degrees
  # (DOOM convention: 0 = East, 90 = North).
  #
  # `bob` is a vertical eye-height offset (world units) updated each
  # frame while walking, used to mimic DOOM's view-bob.
  #
  # `view_height` is the eye height above the player's current floor.
  # Nominally 41 (DOOM's VIEWHEIGHT) but transiently dips after a
  # step-up so the camera lifts smoothly instead of popping.
  NOMINAL_VIEW_HEIGHT = 41

  Player = Struct.new(:x, :y, :angle, :bob, :view_height) do
    def self.from_thing(thing)
      new(thing.x, thing.y, thing.angle, 0.0, NOMINAL_VIEW_HEIGHT.to_f)
    end
  end
end
