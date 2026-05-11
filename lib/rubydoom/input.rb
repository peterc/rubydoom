module Rubydoom
  # One tic's worth of player input, produced by the frontend and consumed
  # by the simulation. Decoupling the two ends means the tick logic never
  # touches Gosu (or any other window library), so an alternative frontend
  # only needs to build this same struct from whatever input API it has.
  #
  # Continuous fields are sampled at the tic boundary:
  #   walk_axis    -1 / 0 / +1   backwards / forwards
  #   strafe_axis  -1 / 0 / +1   left / right
  #   turn_axis    -1 / 0 / +1   keyboard yaw
  #   look_dx      raw mouse-yaw delta in pixels for this tic
  #   fire         fire button held (continuous trigger for the weapon
  #                state machine)
  #
  # Edge-triggered events accumulate between tics in `edges` and are
  # consumed once per tic. Known symbols:
  #   :use, :respawn, :toggle_god, :weapon_1..:weapon_7,
  #   :debug_hurt, :debug_heal, :debug_armor
  Input = Struct.new(:walk_axis, :strafe_axis, :turn_axis,
                     :look_dx, :fire, :edges) do
    def self.empty
      new(0, 0, 0, 0, false, [])
    end
  end
end
