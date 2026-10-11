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
- **Groovy Vibes**: nothing, just vibes.

Traps and buffs wait until you're in an Arcade run, then fire one at a time.

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
| Enabled Traps (`enabled_traps`) | Which traps can appear: Slow-Mo (game at 60%), Fast-Forward (140%), Molasses (only you at 60%), Blackout (screen 98% dark). | all four |
| Effect Duration (`effect_duration`) | Seconds each trap and Disco Fever lasts. | 15 |

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
