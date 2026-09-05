# Additional map specials

This coverage pass adds the following actions, using the existing pure-Ruby
subsystems. No new gems or native dependencies are needed. Actions are read
from the WAD automatically; there are no new launch options.

S1/W1/G1 mean once-only switch/walk/gun triggers; SR/WR mean repeatable
switch/walk triggers. Walk dispatch clears W1 actions; switches are consumed
only when their action starts successfully.

| Types | Action |
| --- | --- |
| 7 (S1) | Build 8-unit stairs through the existing stair-chain system |
| 3/75 (W1/WR), 42 (SR) | Close tagged doors and leave them closed |
| 61 (SR) | Open tagged doors and leave them open |
| 10/21 (W1/S1) | Lower lift, wait 105 tics, return to starting height |
| 87/89 (WR) | Start/resume perpetual lifts; stop them without losing their state or wait timer |
| 14 (S1) | Raise 32 units at half speed, adopting the trigger's front-sector floor texture |
| 19/38 (W1) | Lower to highest/lowest neighboring floor |
| 24 (G1) | Raise to the existing low-ceiling destination |
| 30 (W1) | Raise by shortest lower-wall texture height, checking both sides of bordering lines |
| 37 (W1) | Lower to lowest floor and adopt destination neighbor's texture and special on completion |
| 56 (W1) | Raise to 8 units below the low ceiling, with periodic crush damage |
| 58/59 (W1) | Raise 24 units; type 59 immediately copies the trigger's front-sector texture and special |

Sector special 4 now combines fast strobing (5 bright / 15 dark tics) with
20 damage every 32 tics. The sector retains its special while blinking.
Radiation suits usually protect against it, with a seeded 5-in-256 leakage
roll; god mode and invulnerability still protect the player.

## Verification

`bundle exec rake test` includes `test/additional_specials_test.rb`:
destinations, speeds, property-transfer timing, once-only/repeatable
dispatch, lift pause/resume, crush damage, and sector-4 lighting/damage.
The stair-switch test uses the actual E1M8 shareware map. Other new unit
tests use small synthetic fixtures and do not require the commercial WAD.

A manual headless smoke check also dispatched one actual E1–E3 linedef
of each of the 18 added types from `wads/doom.wad`, advancing the moving
systems for 1,500 tics each. This checks loading and dispatch, not complete
level playability: some actions need earlier switches to change the map,
and temporary lifts return to their original height.

The existing 1,526-tic demo still ends with frame SHA1
`856d8b980f5d1fe4245e5c02a448ecb9d2937769`.

## Remaining limitations

- Players and monsters remain floor-bound. Crushing checks sector membership
  and actor height, not a full vertical/radius collision model. It does not
  implement vanilla's blocked-mover slowdown or all corpse/item handling.
- Moving systems still have separate ownership: doors, floors, stairs, and
  lifts do not share a sector lock or resolve every interaction with actors.
- Type 14 uses the floor mover, so it does not gain vanilla platform
  obstruction handling. Existing sound behavior is unchanged for floor moves.
- Existing approximate mappings (including 86, 90, 91, and 98), moving-ceiling
  actions, additional teleports, and other TODO entries remain separate work.

Behavior was checked against id Software's original
[floor/stair actions](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_floor.c),
[platform actions](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_plats.c),
[switch dispatch](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_switch.c),
and [walk/sector specials](https://github.com/id-Software/DOOM/blob/master/linuxdoom-1.10/p_spec.c).
