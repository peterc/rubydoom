module Rubydoom
  # Builds a Rubydoom::Map in memory without going through a WAD lump,
  # for ad-hoc playtesting and tests that want specific geometry.
  #
  # Scope (current): axis-aligned single-sector rectangles. The room is
  # centred at the origin by default, sized by `.size(w, h)` (defaults
  # to a 2048-square box). Walls are one-sided, floor and ceiling are
  # flat. A single partition line down the centre splits the rectangle
  # into two subsectors — the minimum a valid BSP needs.
  #
  # Anything more complex (concave rooms, multiple sectors, doors,
  # sector tags) would need a real node builder and is out of scope
  # here. The point of this class is to spin up a controlled arena in
  # a few lines of Ruby, not to author full maps.
  #
  # Texture names default to stock-doom flats / wall textures
  # (STARTAN3 / FLOOR4_8 / CEIL3_5) so the renderer can look them up
  # without complaint.
  #
  # Example:
  #
  #   scene = Scenario.new(name: "ARENA")
  #             .size(2048, 2048).floor(0).ceiling(192)
  #             .player(x: -800, y: 0, angle: 0)
  #             .thing(3005, x: 600, y: 0)   # cacodemon
  #             .build
  #   Game#load_map(scene)
  class Scenario
    DEFAULT_WALL_TEXTURE    = "STARTAN3".freeze
    DEFAULT_FLOOR_TEXTURE   = "FLOOR4_8".freeze
    DEFAULT_CEILING_TEXTURE = "CEIL3_5".freeze
    DEFAULT_LIGHT_LEVEL     = 192

    PLAYER_START_TYPE = 1

    def initialize(name: "ARENA")
      @name           = name.to_s.upcase
      @half_w         = 1024
      @half_h         = 1024
      @floor_height   = 0
      @ceiling_height = 192
      @wall_tex       = DEFAULT_WALL_TEXTURE
      @floor_tex      = DEFAULT_FLOOR_TEXTURE
      @ceiling_tex    = DEFAULT_CEILING_TEXTURE
      @light          = DEFAULT_LIGHT_LEVEL
      @player         = { x: 0, y: 0, angle: 0 }
      @extra_things   = []
    end

    # Set the rectangle's full width / height (map units). Internally
    # we keep half-extents because the room is centred at the origin.
    def size(w, h = w)
      @half_w = (w / 2.0).to_i
      @half_h = (h / 2.0).to_i
      self
    end

    def floor(z)
      @floor_height = z
      self
    end

    def ceiling(z)
      @ceiling_height = z
      self
    end

    def textures(wall: nil, floor: nil, ceiling: nil)
      @wall_tex    = wall    if wall
      @floor_tex   = floor   if floor
      @ceiling_tex = ceiling if ceiling
      self
    end

    def light(level)
      @light = level
      self
    end

    def player(x: 0, y: 0, angle: 0)
      @player = { x: x, y: y, angle: angle }
      self
    end

    # Drop a Thing of the given doomednum into the room. `flags`
    # defaults to "appear in skill 2 (HMP) — single-player only", which
    # matches `Map::SKILL_DEFAULT` so the thing is kept by the skill
    # filter at load time.
    def thing(doomednum, x:, y:, angle: 0,
              flags: Map::THING_FLAG_EASY | Map::THING_FLAG_NORMAL | Map::THING_FLAG_HARD)
      @extra_things << { type: doomednum, x: x, y: y, angle: angle, flags: flags }
      self
    end

    def build
      vertexes   = build_vertexes
      sectors    = [build_sector]
      sidedefs   = build_sidedefs
      linedefs   = build_linedefs
      segs       = build_segs
      subsectors = build_subsectors
      nodes      = [build_root_node]
      things     = build_things

      Map.new(
        name: @name,
        things: things, linedefs: linedefs, sidedefs: sidedefs,
        vertexes: vertexes, segs: segs, subsectors: subsectors,
        nodes: nodes, sectors: sectors,
      )
    end

    private

    # Six vertexes:
    #   v0 BL, v1 BR, v2 TR, v3 TL — the rectangle corners.
    #   v4 mid-S, v5 mid-N        — the split points where the partition
    #                                line meets the south and north walls.
    def build_vertexes
      [
        Map::Vertex.new(-@half_w, -@half_h),  # v0
        Map::Vertex.new( @half_w, -@half_h),  # v1
        Map::Vertex.new( @half_w,  @half_h),  # v2
        Map::Vertex.new(-@half_w,  @half_h),  # v3
        Map::Vertex.new(       0, -@half_h),  # v4
        Map::Vertex.new(       0,  @half_h),  # v5
      ]
    end

    def build_sector
      Map::Sector.new(@floor_height, @ceiling_height,
                      @floor_tex, @ceiling_tex,
                      @light, 0, 0)
    end

    # Four sidedefs, one per wall — every one of them points at sector 0
    # with the chosen wall texture on the middle slot.
    def build_sidedefs
      Array.new(4) do
        Map::SideDef.new(0, 0, "-", "-", @wall_tex, 0)
      end
    end

    # Four linedefs (W, N, E, S), traversed so that the front sidedef
    # (right side of v1→v2) faces inward:
    #   ld0 (W): v0→v3
    #   ld1 (N): v3→v2
    #   ld2 (E): v2→v1
    #   ld3 (S): v1→v0
    def build_linedefs
      [
        Map::LineDef.new(0, 3, 0, 0, 0, 0, Map::NO_SIDEDEF),
        Map::LineDef.new(3, 2, 0, 0, 0, 1, Map::NO_SIDEDEF),
        Map::LineDef.new(2, 1, 0, 0, 0, 2, Map::NO_SIDEDEF),
        Map::LineDef.new(1, 0, 0, 0, 0, 3, Map::NO_SIDEDEF),
      ]
    end

    # Six segs. The N and S walls each cross the partition (x=0) so they
    # split into two pieces; the W and E walls live entirely on one side.
    #
    # Layout — segs in subsector order so first_seg_index works out:
    #   0  E wall (v2→v1)             — right subsector
    #   1  S right half (v1→v4)       — right subsector
    #   2  N right half (v5→v2)       — right subsector
    #   3  W wall (v0→v3)             — left subsector
    #   4  S left half (v4→v0)        — left subsector
    #   5  N left half (v3→v5)        — left subsector
    #
    # `offset` is the seg's start distance along its linedef. For the
    # right-half S seg, that's 0 (linedef starts at v1, same vertex).
    # For the left-half S seg, the linedef has already covered @half_w
    # units before reaching v4. Same logic for N.
    def build_segs
      [
        # Right subsector
        Map::Seg.new(2, 1, 0, 2, 0, 0),                  # E wall
        Map::Seg.new(1, 4, 0, 3, 0, 0),                  # S right half
        Map::Seg.new(5, 2, 0, 1, 0, @half_w),            # N right half
        # Left subsector
        Map::Seg.new(0, 3, 0, 0, 0, 0),                  # W wall
        Map::Seg.new(4, 0, 0, 3, 0, @half_w),            # S left half
        Map::Seg.new(3, 5, 0, 1, 0, 0),                  # N left half
      ]
    end

    def build_subsectors
      [
        Map::SubSector.new(3, 0),  # right subsector — segs 0..2
        Map::SubSector.new(3, 3),  # left  subsector — segs 3..5
      ]
    end

    # One node. Partition line: vertical through x=0 from (0, -H) going
    # north for 2H units. Cross-product sign with (0, +2H) for an
    # arbitrary point (x, y): cross = 0*(y+H) − 2H*x = −2Hx. So x > 0
    # yields cross < 0 → Bsp#point_on_side returns 0 → right_child.
    # Right subsector (index 0) lives at x > 0, so right_child = 0.
    def build_root_node
      right_bb = Map::BBox.new(@ceiling_height, @floor_height, 0, @half_w)
      left_bb  = Map::BBox.new(@ceiling_height, @floor_height, -@half_w, 0)
      Map::Node.new(
        0, -@half_h, 0, 2 * @half_h,
        right_bb, left_bb,
        0 | Map::SUBSECTOR_FLAG,    # right_child → subsector 0
        1 | Map::SUBSECTOR_FLAG,    # left_child  → subsector 1
      )
    end

    def build_things
      list = []
      list << Map::Thing.new(@player[:x], @player[:y], @player[:angle],
                             PLAYER_START_TYPE,
                             Map::THING_FLAG_EASY | Map::THING_FLAG_NORMAL |
                             Map::THING_FLAG_HARD,
                             false, nil, nil, nil, nil)
      @extra_things.each do |t|
        list << Map::Thing.new(t[:x], t[:y], t[:angle], t[:type], t[:flags],
                               false, nil, nil, nil, nil)
      end
      list
    end
  end
end
