module Rubydoom
  # WR Teleport (linedef type 97). Mirrors vanilla `EV_Teleport`:
  # crossing the linedef warps the player to a Teleport Destination
  # thing (doomednum 14, MT_TELEPORTMAN) inside a sector whose tag
  # matches the linedef's `sector_tag`. The destination thing's angle
  # becomes the player's angle so map designers can control which way
  # you face on exit. The teleport sound plays at the destination.
  #
  # Walk-trigger only — we don't propagate monster crossings (Clipper
  # fires `on_cross` for the player, not for AI movement), so the
  # classic "monster closet" reveal isn't implemented here.
  #
  # The teleport-fog visual (TFOG sprite + animation at source and
  # destination) is not modelled yet; vanilla feel of "blink + click"
  # is intentional minimalism.
  class Teleports
    WR_TELEPORT = 97
    TELEPORT_DEST_DOOMEDNUM = 14

    def initialize(map, clipper)
      @map     = map
      @clipper = clipper
      @sound   = nil
      @listener = nil
      build_dest_index
    end

    # Late-bound so Game can wire sound after construction.
    attr_writer :sound, :listener

    # Walk-cross dispatcher. Returns true iff a teleport fired (so
    # the caller can reset camera step-up smoothing). WR is
    # repeatable; the special isn't cleared.
    # Vanilla only fires from the front side (side 0); crossing the
    # back of the line is silently ignored so the player doesn't
    # re-trigger the teleporter from the landing side.
    def handle_cross(linedef, player, side = 0)
      return false unless linedef.special_type == WR_TELEPORT
      return false unless side == 0
      dest = @dests_by_tag[linedef.sector_tag]
      return false unless dest
      teleport_player(player, dest)
      true
    end

    private

    # Pre-compute a tag → destination-thing index at construction so
    # the per-cross dispatcher doesn't re-scan @map.things every time.
    # Vanilla `EV_Teleport` walks every thing for each call; ours
    # caches once because the destinations don't move.
    def build_dest_index
      @dests_by_tag = {}
      @map.things.each do |t|
        next unless t.type == TELEPORT_DEST_DOOMEDNUM
        sec = @clipper.sector_at(t.x, t.y)
        next unless sec
        @dests_by_tag[sec.tag] ||= t  # first one wins per sector
      end
    end

    def teleport_player(player, dest_thing)
      player.x = dest_thing.x.to_f
      player.y = dest_thing.y.to_f
      player.angle = dest_thing.angle.to_f
      @clipper.teleport_pending = true
      @sound&.play(:telept) if @sound
    end
  end
end
