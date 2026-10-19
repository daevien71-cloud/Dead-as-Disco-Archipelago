# Dead as Disco

## What does randomization do to this game?

Nothing in the game itself is shuffled. Playing Arcade mode sends checks to the multiworld, and the
items you get back change your runs: traps that mess with game speed or the screen, buffs, and shields
against DeathLink.

## What are the checks?

- **Wave clears**: waves 1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150 and 200, plus every Nth wave
  if `wave_check_interval` is set. Waves count per run, so "Clear Wave 100" means reaching it in one run.
- **Lifetime kills**: 25, 50, 100 and more enemies defeated, added up across all your Arcade runs.

## What items are there?

- **Gold Record**: collect enough, then clear your goal wave in one run to win.
- **Disco Fever**: enemies slow down for a while; you don't.
- **Mirror Ball Shield**: blocks the next DeathLink that would have killed you.
- **Slow-Mo, Fast-Forward, Molasses and Blackout traps**: change the game's speed, your speed or
  darken the screen for a while. The music keeps playing at normal speed, so expect to fight off-beat.
- **Meteor Trap (experimental, off by default)**: one item rolls **1–5 Aurora meteors**, arriving one at a time
  with warnings and native remnants. Each targets where you stood when it launched. Update both the game mod
  and APWorld before enabling it.
- **Prophet Car Trap (experimental, off by default)**: two sets of three native Prophet cars; the second
  waits until the first set is gone. This v0.3.0 candidate still needs live Arcade verification.
- **Groovy Vibes**: nothing, just vibes.

Traps and buffs wait until you're in an Arcade run, then fire one at a time.
Meteors also wait for active combat and for you to be on the ground. Each trap chooses its count once and
uses **one item for the entire batch**. The next meteor waits until the previous meteor and remnant are gone,
with at least 3 seconds of game time between launches. Each target locks when that meteor launches; moving
does not move its warning. Pausing stops the batch clock, and leaving the run cancels its remaining meteors.

The remnant lasts at most 11 seconds, each meteor has a 16-second limit, and the whole batch has a limit of
`20 × count + 10` seconds (up to 110), all in game time. These limits are independent of `effect_duration`.
Other queued effects wait for the entire batch to finish. A client restart does not repeat an accepted batch.
If the mod lacks meteor support, the item stays queued until you update.
The native attack's base damage is **10 to the player and 60 to enemies**, subject to the game's damage
modifiers. Meteor kills count toward the usual enemy-kill checks. If a meteor kills you, the normal DeathLink
send chance applies once; the trap does not send an extra DeathLink.

If the game cannot load or spawn the first meteor, the client keeps the item and retries after 3 seconds, for
up to 3 attempts. After the third failed start it reports that the item was skipped and lets the queue continue.
Pauses, downtime and airborne movement simply wait for a safe opportunity and do not spend those attempts.
Once a batch has started it is spent; a later failed launch can skip that meteor without replaying the item.

Prophet Car Trap uses **one item for both sets of three**, and has its own time limits instead of
`effect_duration`. Both sets, including the wait between them, occupy the same effect slot: another car trap,
meteor batch, speed trap or Blackout waits until it ends. Accepted car traps persist across client reconnects
without replaying or consuming another item. An old mod without car support keeps the item queued and shows
one update notice. Update both the game mod and APWorld before enabling `"Prophet Car Trap"`.

The cars are intended to damage the player and enemies through native game behavior; damage and collision
behavior are **not yet verified in live Arcade**. Native kills use the usual kill checks, and a death uses the
normal DeathLink send chance once. Failed startup uses the same three-attempt, three-second retry policy as
meteors. Once the first set is accepted, a failure in the second set cannot replay the whole item.

## DeathLink

When DeathLink is on, each of your deaths has a chance (default 25%) to kill everyone else, and each of
their deaths has a chance (default 40%) to kill you, but only while you're in an Arcade run.

## Options explained

The Options Creator in the Archipelago Launcher shows these same explanations when you hover an option.
The name in brackets is what the option is called in the YAML file.

### Goal

| Option | What it does | Default |
|---|---|---|
| Goal Wave (`goal_wave`) | How you win: once you hold enough Gold Records, clear this wave in one Arcade run. Clearing it before you have the records doesn't count. | wave 50 |
| Gold Records in Pool (`gold_record_count`) | How many Gold Records are hidden, in your checks and your friends' games. More than you need = spares, so one stuck somewhere can't block you. | 7 |
| Gold Records Required (`gold_records_required`) | How many you need before the goal wave counts. Lowered to the pool size if set higher. | 5 |

### Checks

| Option | What it does | Default |
|---|---|---|
| Extra Wave Check Interval (`wave_check_interval`) | Waves 1, 2, 3, 5, 10 … 200 (15 in all) are always checks. A number here also makes every Nth wave one: 5 adds 35, 45, 55 … (43 in all). | 0 |
| Kill Checks (`kill_checks`) | How many of the total-kill checks (25, 50, 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000) are used, from the start of the list. 8 = up to 500 kills. Only counts while the client is running. | 8 |

### Traps & effects

| Option | What it does | Default |
|---|---|---|
| Trap Percentage (`trap_percentage`) | Of your non-Gold-Record items, the percent that are traps. The rest are Mirror Ball Shields, Disco Fever and Groovy Vibes. | 35 |
| Enabled Traps (`enabled_traps`) | Which traps can appear: Slow-Mo (game at 60%), Fast-Forward (140%), Molasses (only you at 60%), Blackout (screen 98% dark), experimental Meteor Trap (1–5 meteors, one at a time), or experimental Prophet Car Trap (two sets of three). Add either experimental trap yourself after updating the mod and APWorld. | original four; meteors and cars off |
| Effect Duration (`effect_duration`) | Seconds the speed/screen traps and Disco Fever last. Meteor and car traps have their own time limits. | 15 |

### DeathLink

| Option | What it does | Default |
|---|---|---|
| DeathLink (`death_link`) | Links your deaths with everyone else who has it on, softened by the two chances below. | off |
| DeathLink Send Chance (`death_link_send_chance`) | Percent chance your death is sent to everyone. | 25 |
| DeathLink Receive Chance (`death_link_receive_chance`) | Percent chance someone else's death kills you. Only during an Arcade run; a Mirror Ball Shield blocks one. | 40 |

### Generation (every Archipelago game has these)

| Option | What it does | For Dead as Disco |
|---|---|---|
| Accessibility (`accessibility`) | **Full**: every check can be done and every item found. **Minimal**: only your goal is guaranteed; some of your extra items might be unreachable. | Leave on Full. |
| Progression Balancing (`progression_balancing`) | Moves a player's important items earlier so they don't get stuck. 0 = off, 50 = normal, 99 = strongest. | Next to no effect (Gold Records are spread out on purpose). Leave at 50. |

### Item & location options (every Archipelago game has these)

| Option | What it does | Example |
|---|---|---|
| Local Items | Items that must be in your own checks. | Gold Record: you find all your records yourself. |
| Non-local Items | Items that must be in someone else's game. | Gold Record: your friends find all of them for you. |
| Start Inventory | Items you start with, on top of the normal pool. | `{Mirror Ball Shield: 1}` |
| Start Hints | Items whose locations you know from the start. | Gold Record |
| Start Location Hints | Checks whose contents you know from the start. | Arcade - Clear Wave 200 |
| Excluded Locations | Checks that never hold anything important. Use for checks you may never reach, so no one waits on them. | Arcade - Clear Wave 200 |
| Priority Locations | Checks that always hold something important. | Arcade - Clear Wave 100 |
