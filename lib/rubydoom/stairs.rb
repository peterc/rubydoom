module Rubydoom
  # W1 Stairs Build (linedef type 8). Mirrors vanilla EV_BuildStairs
  # with the `build8` profile: each step rises 8 mu at FLOORSPEED/4 =
  # 0.25 mu/tic, and the staircase propagates from one sector to the
  # next via two-sided linedefs whose FRONT side faces the current
  # step. Propagation stops when no such linedef exists or the next
  # sector's floor texture differs from the starting sector's.
  #
  # All step movers spawn simultaneously, so steps further down the
  # chain reach their destination later — that's the wave-like growth
  # you see on the iconic E1M3 stairwell.
  class Stairs
    STEP_HEIGHT = 8.0
    SPEED       = 0.25   # FLOORSPEED / 4

    Mover = Struct.new(:sector, :dest, :done)

    def initialize(map)
      @map    = map
      @active = {}
    end

    def handle_cross(linedef)
      build(linedef.sector_tag)
    end

    def build(tag)
      fired = false
      @map.sectors.each do |sec|
        next unless sec.tag == tag
        next if @active[sec.object_id]
        texture = sec.floor_texture
        height  = sec.floor_height + STEP_HEIGHT
        @active[sec.object_id] = Mover.new(sec, height, false)
        fired = true

        cur = sec
        loop do
          nxt = find_next_step(cur, texture)
          break unless nxt
          break if @active[nxt.object_id]
          height += STEP_HEIGHT
          @active[nxt.object_id] = Mover.new(nxt, height, false)
          cur = nxt
        end
      end
      fired
    end

    def update_tic
      return if @active.empty?
      @active.each_value do |m|
        m.sector.floor_height += SPEED
        if m.sector.floor_height >= m.dest
          m.sector.floor_height = m.dest
          m.done = true
        end
      end
      @active.reject! { |_, m| m.done }
    end

    private

    # Vanilla rule: find a two-sided linedef whose FRONT sector is the
    # current step. The BACK sector is the next step — accepted only
    # if its floor texture matches the staircase's starting texture.
    # The directional front/back asymmetry is what keeps the chain
    # following the level designer's intended path instead of leaking
    # into arbitrary neighbours.
    def find_next_step(cur, texture)
      @map.linedefs.each do |ld|
        next unless ld.two_sided?
        front = @map.linedef_front_sector(ld)
        next unless front == cur
        back = @map.linedef_back_sector(ld)
        next if back.nil? || back == cur
        next unless back.floor_texture == texture
        return back
      end
      nil
    end
  end
end
