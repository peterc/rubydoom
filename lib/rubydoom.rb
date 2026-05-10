module Rubydoom
end

require_relative "rubydoom/wad"
require_relative "rubydoom/palette"
require_relative "rubydoom/colormap"
require_relative "rubydoom/picture"
require_relative "rubydoom/graphics"
require_relative "rubydoom/textures"
require_relative "rubydoom/animated_textures"
require_relative "rubydoom/sky"
require_relative "rubydoom/flats"
require_relative "rubydoom/animated_flats"
require_relative "rubydoom/visplanes"
require_relative "rubydoom/map"
require_relative "rubydoom/bsp"
require_relative "rubydoom/clipper"
require_relative "rubydoom/doors"
require_relative "rubydoom/player"
require_relative "rubydoom/game_state"
require_relative "rubydoom/face"

# Gosu-dependent layers. Loaded last so non-graphical tools (asset dumps,
# tests) can `require "rubydoom/wad"` etc. directly without pulling Gosu.
require_relative "rubydoom/gosu_image_cache"
require_relative "rubydoom/framebuffer"
require_relative "rubydoom/hud"
require_relative "rubydoom/automap"
require_relative "rubydoom/renderer3d"
require_relative "rubydoom/app"
