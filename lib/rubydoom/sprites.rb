module Rubydoom
  # Sprite lump loader. DOOM stores all sprite patches between the
  # S_START and S_END markers (with optional SS_START/SS_END inner
  # markers in some IWADs). Each lump name encodes which thing-type
  # frame and rotation it represents:
  #
  #   PPPP F R           (6 chars) — frame F at rotation R
  #   PPPP F R F2 R2     (8 chars) — same lump used for two rotations,
  #                                  the second one drawn mirrored
  #
  # PPPP is a 4-letter prefix (e.g. POSS, IMP, BAR1), F is a frame
  # letter (A-Z+), R is a rotation digit:
  #
  #   0 = no rotation, lump always faces the camera
  #   1..8 = 8 view angles, rotation 1 faces the camera (front view),
  #          increasing CCW around the thing
  #
  # The mirror trick saves disk: front-left and front-right look the
  # same flipped, so DOOM stores one lump under e.g. "POSSC2C8".
  class Sprites
    START_MARKERS = %w[S_START SS_START].freeze
    END_MARKERS   = %w[S_END   SS_END].freeze

    # One animation frame's data. `rotations[0]` holds the single
    # always-faces-camera lump (when present); otherwise indices 1..8
    # are populated with [picture, mirrored] pairs.
    Frame = Struct.new(:rotations) do
      def lookup(rot)
        rotations[rot]
      end

      def single?
        !rotations[0].nil?
      end
    end

    def initialize(wad)
      @frames = Hash.new { |h, k| h[k] = {} }   # prefix → {frame_letter → Frame}
      load(wad)
    end

    # Find the Frame for a given 4-letter prefix and 1-letter frame.
    # Returns nil if absent.
    def frame_for(prefix, frame_letter)
      @frames[prefix.to_s.upcase]&.[](frame_letter.to_s.upcase)
    end

    # Total number of distinct prefixes loaded (for sanity-checking).
    def prefix_count
      @frames.size
    end

    private

    def load(wad)
      depth = 0
      wad.lumps.each do |lump|
        if START_MARKERS.include?(lump.name)
          depth += 1
        elsif END_MARKERS.include?(lump.name)
          depth -= 1
        elsif depth > 0 && lump.size > 0
          register(lump.name, wad.bytes_for_lump(lump))
        end
      end
    end

    def register(name, bytes)
      return if name.length < 6
      pic = Picture.parse(bytes)
      add(name[0, 4], name[4], char_to_rot(name[5]), pic, mirrored: false)
      if name.length >= 8
        add(name[0, 4], name[6], char_to_rot(name[7]), pic, mirrored: true)
      end
    end

    def add(prefix, frame_letter, rot, pic, mirrored:)
      return if rot.nil?
      frame = (@frames[prefix][frame_letter] ||= Frame.new(Array.new(9)))
      frame.rotations[rot] = [pic, mirrored]
    end

    def char_to_rot(ch)
      n = ch.ord - "0".ord
      return n if n.between?(0, 8)
      nil
    end
  end
end
