# Prophet Car Trap playtest guide

**Experimental, with live Arcade proof.** The owner confirmed readable warnings, both sets of three cars at the faster speed, and damage to the player and enemies. Logs confirmed each set was fully removed and the trap ended with zero surviving actors. v0.3.1 fixes the native warning's authored scale and destroyed-actor detection, and doubles driving speed while keeping the full warning time. Other arenas, transitions and Linux/Proton still need the checks below.

Prophet Car Trap is **off by default**. After testing, add `Prophet Car Trap` to `enabled_traps` when generating a multiworld. An older mod keeps received car items queued and asks for an update.

One item requests **two sets of three native Prophet cars**, crossing in an X pattern. The first set runs 45° to one side of your initial facing; the second crosses it at the opposite angle. Both use the same starting center, even if you move or turn. Each set marks three parallel routes, gives a two-second warning, then sends the cars along those routes in about 1.25 seconds. Move out of the marked lanes. The second set waits until every first-set car and warning has disappeared, followed by a one-second gap. Each diagonal appears separately. The single-car probe keeps your initial facing.

The cars hurt **both you and enemies**, using the game's ordinary car collisions and damage. The owner confirmed both in Arcade. Configuration reads show 10 player damage and 1,000 enemy damage; exact health deltas were not measured. There is no added replacement damage. Collision reliability across frame rates and route clearance in other arenas remain live checks.

The whole trap occupies one effect slot and consumes one AP item when accepted. Other traps wait. Pausing should stop its game-time timers; leaving the run should remove the cars and warnings and cancel the remaining set. Reconnecting should not replay an accepted item. These behaviors are part of the candidate and require the checks below.

## Test sequence

With the game and Dead as Disco Client closed, extract `DeadAsDiscoAP-v0.3.1.zip` to a new folder and run its `Install.bat` (or `Install-Linux.sh`). Install the included `dead_as_disco.apworld` through the Archipelago Launcher. An existing v0.3.0 APWorld is compatible with these game-side fixes. Use this package's installer: the normal updater follows the published main branch. Keep the v0.2.0 package available for returning to the proven meteor build.

Use the updated **Dead as Disco Client** command box. Manual tests spend no AP item. Start grounded in active Arcade combat, in an open arena with no other effect active.

1. **One car first:** enter `/testeffect car`. Check that one readable lane appears on the floor for roughly two unpaused seconds before the car rushes along it. Move aside and watch it finish. The car, warning and attached effects should all disappear. Stop testing if the warning is missing, the car floats/sinks, or its path differs from the marked lane.
2. **Native damage:** repeat the single-car probe. Record health before and after deliberately remaining in the lane; separately arrange an ordinary enemy in the route and check its health or death. A visual collision alone does not prove damage. Check that the same pass does not repeatedly hit one target. Hazard resistance and native invulnerability can change results; record them if present.
3. **Two sets:** enter `/testeffect cars`. Count three cars in the first set, then three in the second. Confirm all first-set cars **and their warnings** vanish before the second set appears. Move and turn between sets: the second set should cross the first at 90° through the original center, with its own full warning. There should be no looping or returning cars.
4. **Pause and queue:** pause during a warning and during a rush, then resume without skipped warnings or a sudden second-set burst. A duplicate manual command should be refused while a trap is active. Two received AP car items should run separately and consume one item each. Check a car item queued behind a meteor too.
5. **Transitions and cramped arenas:** leave to the menu, die, change songs, and restart a run during separate tests. No car or warning should follow into the next run. Repeat near walls/arena edges and watch for paths through walls or floating warnings. This candidate validates component geometry but does not trace arena walls or terrain; native movement is unswept. Stop and report unsuitable routes. An AP item received outside active combat should wait; a manual test outside a run should be refused. Disconnect/reconnect after the first set starts and confirm it does not replay.

After the manual tests pass, the server host can use `/send YourSlotName Prophet Car Trap` for one controlled AP delivery. Confirm one item acknowledgement and both sets, then test two deliveries close together. Native kills and deaths should continue through the existing kill checks and normal DeathLink rules.

For any failure, record the arena/song, command or item, set number, health before/after, and what remained onscreen. Keep `Pagoda/Binaries/Win64/ue4ss/UE4SS.log` and the client's `logs/DeadAsDiscoClient_*.txt`.

[Native research and remaining unknowns](cars-research.md)
