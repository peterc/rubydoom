module Rubydoom
  # S1 Donut (special type 9). Mirrors vanilla EV_DoDonut.
  #
  # A "donut" is a central pillar sector P surrounded by a ring sector
  # R. Pressing the switch:
  #   * P's floor lowers to the model sector M's floor height (M is
  #     any sector that borders R but isn't P or R itself).
  #   * R's floor raises to the same height, and inherits M's floor
  #     texture and sector special.
  #
  # Both move at FLOORSPEED/2 = 0.5 mu/tic. Once the ring's
  # texture/special are transferred the donut is complete.
  class Donuts
    SPEED = 0.5

    Mover = Struct.new(:sector, :dest, :direction, :done,
                       :new_texture, :new_special)

    def initialize(map)
      @map    = map
      @active = {}
    end

    # Switch dispatcher entry. Returns true iff at least one donut
    # started moving.
    def handle_use(linedef)
      activate(linedef.sector_tag)
    end

    def activate(tag)
      fired = false
      @map.sectors.each do |pillar|
        next unless pillar.tag == tag
        next if @active[pillar.object_id]
        ring, model = find_ring_and_model(pillar)
        next unless ring && model
        next if @active[ring.object_id]
        dest = model.floor_height
        @active[pillar.object_id] =
          Mover.new(pillar, dest, :down, false, nil, nil)
        @active[ring.object_id] =
          Mover.new(ring, dest, :up, false, model.floor_texture, model.special_type)
        fired = true
      end
      fired
    end

    def update_tic
      return if @active.empty?
      @active.each_value do |m|
        if m.direction == :up
          m.sector.floor_height += SPEED
          if m.sector.floor_height >= m.dest
            m.sector.floor_height = m.dest
            m.sector.floor_texture = m.new_texture if m.new_texture
            m.sector.special_type  = m.new_special unless m.new_special.nil?
            m.done = true
          end
        else
          m.sector.floor_height -= SPEED
          if m.sector.floor_height <= m.dest
            m.sector.floor_height = m.dest
            m.done = true
          end
        end
      end
      @active.reject! { |_, m| m.done }
    end

    private

    # Vanilla EV_DoDonut uses `pillar->lines[0]` to find the ring,
    # then walks the ring's lines for the first one whose other side
    # isn't the pillar — that's the model. We don't carry per-sector
    # linedef lists, so we sweep @map.linedefs in order for the first
    # match. Same result for any donut whose pillar is surrounded by
    # one ring (the common case, and what E1M2 has).
    def find_ring_and_model(pillar)
      ring = neighbor_through_two_sided(pillar) { |other| other != pillar }
      return [nil, nil] unless ring
      model = neighbor_through_two_sided(ring) { |other| other != pillar && other != ring }
      [ring, model]
    end

    def neighbor_through_two_sided(sector)
      @map.linedefs.each do |ld|
        next unless ld.two_sided?
        f = @map.linedef_front_sector(ld)
        b = @map.linedef_back_sector(ld)
        next if f.nil? || b.nil?
        if f == sector && yield(b)
          return b
        elsif b == sector && yield(f)
          return f
        end
      end
      nil
    end
  end
end
