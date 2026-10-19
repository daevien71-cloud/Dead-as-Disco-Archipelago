# Meteor Trap playtest guide

Meteor Trap brings **a random 1–5 of Aurora's native meteors** into Arcade Mode per item. It is **off by default**: add `Meteor Trap` to `enabled_traps` when generating a multiworld. Update both the game mod and APWorld first. An older mod keeps received meteor items queued and asks you to update.

Friends send it through ordinary Archipelago checks in their games. Finding an unknown trap can be accidental; deliberately clearing a known trap location sends it the same way. For a controlled AP delivery test, the host can use `/send YourSlotName Meteor Trap` in the server console. One item always rolls one random batch; the sender does not select its size.

Each meteor targets your grounded position when it starts. Watch the native ground warning, then move: the measured fall is about **two seconds**, and that landing point stays fixed. After impact, face a standing enemy and strike or kick the remnant toward it. Native aiming follows your character's facing direction; an enemy behind you or already knocked down may not be selected.

Meteors arrive **one at a time**. The next waits until the previous meteor and remnant are gone, at least three seconds of game time have passed since the previous launch, and you are grounded in active combat. Each remnant has an 11-second timer, allowing approximately eight seconds to strike it; that exact usable window has not been timed separately. Each meteor has a 16-second game-time cap, and the whole batch is capped at `20 × chosen count + 10` seconds. Pausing preserves these game-time budgets. A later blocked spawn is skipped.

The batch occupies one effect slot and consumes **one AP item when its first meteor starts**. Reconnecting must not replay that item. Leaving the run removes the current meteor and cancels the rest of its batch. If the game fails to report a remnant or a native timer fails, the batch stops to avoid stacking hazards.

**Verified:** earlier native probes showed a readable warning, approximately 1.98-second fall, player impact damage of **10 HP**, enemy impact damage of **60 HP**, and a kicked remnant hitting NPCs. A real AP server → client → installed-game test passed for the earlier **single-meteor** version, including start/end acknowledgements and saved item consumption. The player saw the text and may have dodged; that test added no damage proof. **The new random batch has not yet been live-tested.** Gold Record behavior and existing item IDs are unchanged. Cars remain a later feature.

## Test it

In the updated Dead as Disco client, enter **`/testeffect meteor`** while grounded in an active Arcade run. This requests a local batch smoke test; it is refused outside a run or while another effect is active. Received AP items instead wait in the queue. Repeat the real AP-item test with the new batch version.

1. **Count and pacing:** complete several batches in an open arena. Record the chosen count and launch times from the log: each item chooses 1–5, never overlaps its meteors/remnants, and leaves at least three unpaused seconds between launches. Randomness need not produce every count in a short test. Move between launches and confirm each new warning targets your current position.
2. **Warning, damage and interaction:** dodge a marked point; on another meteor, remain there and record health before/after. Repeat near an ordinary enemy. Face a standing enemy beyond a remnant and strike/kick it, then leave another remnant to expire.
3. **Queue and pause:** receive two AP items close together. Their whole batches should serialize, consuming each item once. A duplicate manual test during a batch should be refused. Pause during flight, with a remnant present, and between launches; resume without an immediate catch-up burst.
4. **Downtime and transitions:** receive an AP item outside combat and check that it waits. A manual test outside a run should be refused. During a batch, leave combat or jump as a remnant ends; the next launch must wait for readiness. Exit to the menu or change runs mid-batch: no remaining meteor should follow you. Check a song transition too.
5. **Cramped arena, death and reconnect:** repeat near a low ceiling or arena edge; a later failed spawn should be skipped without a retry storm. Die mid-batch and restart. Disconnect/reconnect the client after the first launch: that consumed AP item must not start a fresh batch. Check that no batch outlives its game-time cap.

For a failure, note arena/song, approximate timing and the command/item used. Keep `Pagoda/Binaries/Win64/ue4ss/UE4SS.log` and the Archipelago client's `logs/DeadAsDiscoClient_*.txt`.

[Technical evidence and native hook contracts](meteor-research.md)
