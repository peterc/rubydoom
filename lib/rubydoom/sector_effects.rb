module Rubydoom
  # Per-tic sector specials that act on the player when the player
  # stands in the sector. Mirrors a subset of P_PlayerInSpecialSector
  # from linuxdoom-1.10/p_user.c.
  #
  # Currently implements:
  #   * type 7 — 5% damage nukage. 5 HP every 32 tics (about once a
  #              second). Slime/nukage corridors in E1M1.
  #   * type 9 — secret. On first entry, increments the player's
  #              secrets_found counter and clears the sector's
  #              special so it doesn't count again.
  #
  # Vanilla checks `leveltime & 0x1f == 0` so damage tics across all
  # damage sectors fall on the same frame; we keep our own counter
  # for the same effect, started fresh on every level transition.
  class SectorEffects
    NUKAGE_DAMAGE = 7
    SECRET        = 9

    DAMAGE_PERIOD_TICS  = 32
    NUKAGE_AMOUNT       = 5

    def initialize(clipper)
      @clipper  = clipper
      @leveltime = 0
    end

    # Called each tic with the player. Player position has already
    # been advanced for this tic, so the sector lookup reflects
    # wherever the player ended up.
    def update_tic(player)
      @leveltime += 1
      sec = @clipper.sector_at(player.x, player.y)
      return unless sec

      case sec.special_type
      when NUKAGE_DAMAGE
        if (@leveltime & (DAMAGE_PERIOD_TICS - 1)).zero?
          player.take_damage(NUKAGE_AMOUNT)
        end
      when SECRET
        player.secrets_found += 1
        sec.special_type = 0
        puts "[secret] #{player.secrets_found} found"
      end
    end
  end
end
