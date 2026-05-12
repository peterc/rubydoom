module Rubydoom
  # Per-tic sector specials that act on the player when the player
  # stands in the sector. Mirrors a subset of P_PlayerInSpecialSector
  # from linuxdoom-1.10/p_user.c.
  #
  # Currently implements:
  #   * type 5  — 10% damage slime. Radsuit negates.
  #   * type 7  — 5% damage nukage. Slime/nukage corridors in E1M1.
  #   * type 9  — secret. On first entry, increments the player's
  #              secrets_found counter and clears the sector's
  #              special so it doesn't count again.
  #   * type 11 — 20% damage + end-of-level on death. The E1M8 brain
  #              floor: god mode is cleared each tic, radsuit is
  #              ignored, and crossing health<=10 fires the exit.
  #   * type 16 — 20% damage super-nukage / blood. E1M3 has five of
  #              these. Same 32-tic period as the lighter tier.
  #
  # Vanilla checks `leveltime & 0x1f == 0` so damage tics across all
  # damage sectors fall on the same frame; we keep our own counter
  # for the same effect, started fresh on every level transition.
  class SectorEffects
    SLIME_DAMAGE  = 5
    NUKAGE_DAMAGE = 7
    SECRET        = 9
    END_LEVEL     = 11
    SUPER_DAMAGE  = 16

    DAMAGE_PERIOD_TICS  = 32
    SLIME_AMOUNT        = 10
    NUKAGE_AMOUNT       = 5
    END_LEVEL_AMOUNT    = 20
    END_LEVEL_THRESHOLD = 10

    def initialize(clipper)
      @clipper  = clipper
      @leveltime = 0
      @switches  = nil
    end

    # Late-bound so Game can wire SectorEffects before Switches exists
    # in init order (not currently the case, but symmetric with the
    # other subsystems). Used by type 11 to request the level exit.
    attr_writer :switches

    # Called each tic with the player. Player position has already
    # been advanced for this tic, so the sector lookup reflects
    # wherever the player ended up.
    def update_tic(player)
      @leveltime += 1
      sec = @clipper.sector_at(player.x, player.y)
      return unless sec

      case sec.special_type
      when SLIME_DAMAGE
        damage_floor(player, SLIME_AMOUNT)
      when NUKAGE_DAMAGE
        damage_floor(player, NUKAGE_AMOUNT)
      when SUPER_DAMAGE
        damage_floor(player, END_LEVEL_AMOUNT)
      when END_LEVEL
        damage_end_level(player)
      when SECRET
        player.secrets_found += 1
        sec.special_type = 0
        puts "[secret] #{player.secrets_found} found"
      end
    end

    private

    # Apply periodic damage from a hazardous floor. Vanilla DOOM gates
    # damage tics on `leveltime & 0x1f` so every damage sector
    # delivers on the same frame. The radiation suit (`pw_ironfeet`)
    # negates damage entirely while active.
    def damage_floor(player, amount)
      return if player.has_power?(:radsuit)
      return unless (@leveltime & (DAMAGE_PERIOD_TICS - 1)).zero?
      player.take_damage(amount)
    end

    # Type 11 brain floor (E1M8). Vanilla strips god mode each tic so
    # the player can't survive, ignores the radsuit, then exits the
    # level once health drops to <= 10. We mirror that exactly.
    def damage_end_level(player)
      player.god_mode = false
      if (@leveltime & (DAMAGE_PERIOD_TICS - 1)).zero?
        player.take_damage(END_LEVEL_AMOUNT)
      end
      @switches&.request_exit! if player.health <= END_LEVEL_THRESHOLD
    end
  end
end
