# Dead as Disco (Arcade Milestones)

Fifteen song-independent Arcade checks: waves 1, 2, 3, 5, 10, 15, 20, 25, 30,
40, 50, 75, 100, 150 and 200. Each is awarded once per seed/team/slot/profile.
A clear requires its verified contiguous run history and confirming next-round
advance. Song identity and replay counts never create checks.

The goal defaults to wave 20. Set goal_wave to any listed milestone. Higher
milestones remain optional after the goal; collecting every check is not needed
to finish. All movement, attacks, defenses, weapons and abilities stay available.
The 15 Set Credit filler items have no game or save effect. In multiworld these
checks can send other players' items; receipt of any item cannot complete the goal.

The client reports victory only after a legitimate selected-goal clear is
acknowledged by AP. Generation-only reachability events do not prove gameplay.
Use profile arcade_milestones_v1, integration version 3. Previous proof and
three-wave clients/states are incompatible. Install this package instead of the
historical three-wave package; they share a Python package basename.

```yaml
name: DiscoMilestones
game: Dead as Disco (Arcade Milestones)
Dead as Disco (Arcade Milestones):
  accessibility: full
  goal_wave: 20
```

No ability gate or enemy-specific challenge is enabled. Starting inventory,
item links and item plando are unsupported; leave these empty. A real first-wave
AP check and three-wave callback calibration were previously observed, but this
expanded milestone profile has not had live milestone acceptance. Generation,
package and offline boundary tests are not proof of extended live play.
