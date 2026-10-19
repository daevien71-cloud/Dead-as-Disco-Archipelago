# Dead as Disco — Archipelago

Play Dead as Disco's Arcade mode in an [Archipelago](https://archipelago.gg) multiworld with friends
who play other games.

- **Checks:** clearing waves 1, 2, 3, 5, 10 … 200 (per run) and lifetime enemy-kill totals.
- **Goal:** collect enough Gold Records, then clear your goal wave in a single run.
- **Items:** Gold Records, Disco Fever (enemies slowed), Mirror Ball Shield (blocks a DeathLink),
  and traps: Slow-Mo, Fast-Forward, Molasses (only you are slowed) and Blackout. An experimental
  **Meteor Trap** rolls 1–5 Aurora meteors per item in Arcade; enable it separately in `enabled_traps`.
  The v0.3.0 candidate also adds **Prophet Car Trap**: two sets of three cars, with the second set waiting
  until the first is gone. Cars remain experimental and need live Arcade verification.
- **DeathLink:** your deaths have a 25% chance to be sent; their deaths have a 40% chance to kill you
  while you're in a run (both adjustable).

## Install and play

See [the setup guide](apworld/dead_as_disco/docs/setup_en.md). Short version: run `Install.bat` (Windows) or
`bash Install-Linux.sh` (Linux/Proton, plus one Steam launch option), give
[`dead_as_disco.apworld`](dead_as_disco.apworld) (top of this repo) to the Archipelago Launcher's
**Install APWorld**, open **Dead as Disco Client**, play Arcade.

Every option, in plain words: [Options explained](apworld/dead_as_disco/docs/en_Dead%20as%20Disco.md#options-explained).

To update later: `Update.bat` (Windows) or `bash Update-Linux.sh` (Linux), with the game closed.

Meteor Trap is **off by default** while its warning, damage and remnant interaction are playtested.
Update both the game mod and APWorld before enabling it. It waits for active Arcade combat and a grounded
player, and chooses 1–5 meteors once per item. They arrive one at a time, waiting for the previous meteor and
remnant to disappear, with at least 3 seconds of game time between launches. The batch has its own time
limits, pauses stop its clock, and leaving Arcade cancels the remaining meteors. Other effects wait for the
whole batch; reconnecting does not replay or consume it again. A client connected to an
older mod keeps meteor items queued and asks you to update. Test it with `/testeffect meteor` in the client;
see [the meteor playtest guide](docs/meteor.md) for checks and current limitations.

Prophet Car Trap is also **off by default**. Add `"Prophet Car Trap"` to `enabled_traps` only after updating
both the mod and APWorld. Both sets occupy one effect slot and spend one item; meteors and other effects
wait until the car trap ends. An older mod keeps the car item queued, and reconnecting does not replay an
accepted trap. Its native collisions are intended to hurt the player and enemies; this remains **unverified
in live Arcade**. Kills and deaths use the existing kill checks and normal DeathLink chance.
For staged testing, `/testeffect car` sends one car and `/testeffect cars` requests both sets of three.
These manual tests do not spend an AP item; they require a running mod with car support.
Follow [the car playtest guide](docs/cars.md), starting with a single car in an open, flat arena.

Only want to play alongside someone else's Dead as Disco? You just need `dead_as_disco.apworld` to generate.

## How it fits together

```
Dead as Disco ── UE4SS ── mod/DeadAsDiscoAP/Scripts/main.lua
                              │  %LOCALAPPDATA%\DeadAsDiscoAP\
                              │    events.jsonl  (game → client: waves, kills, deaths, effect results)
                              │    commands.jsonl (client → game: traps, buffs, DeathLink kills)
                              │    status.json   (game heartbeat: in run? which wave?)
Archipelago server ── apworld/dead_as_disco/client.py (runs inside the Archipelago Launcher)
```

- `apworld/dead_as_disco/data.py`: every name, ID and threshold in one place.
- `apworld/dead_as_disco/tracker.py`: client rules (which checks an event earns, DeathLink rolls,
  shields, effect queue). No networking, so it's unit-tested directly.
- `mod/DeadAsDiscoAP/Scripts/main.lua`: game hooks and effects. Constants at the top.

## Develop

Working on this, alone or with an AI assistant? Start with [AGENTS.md](AGENTS.md): current status, layout,
conventions and what's next. [NOTES.md](NOTES.md) has the history and research.

```
python build.py                      # dist/ release zip + dead_as_disco.apworld (commit the latter)
lua tests/lua/test_main.lua <repo>   # mod tests against a fake UE4SS (set LOCALAPPDATA to a temp dir)
lua tests/lua/test_meteor.lua <repo> # deterministic meteor adapter tests against a fake UE4SS
python -m unittest worlds.dead_as_disco.test.test_world worlds.dead_as_disco.test.test_tracker  # from an AP checkout
python tests/e2e/run_e2e.py <AP checkout with the world installed>   # server + 2 clients + fake games
python tests/test_install_linux.py   # Linux installer + Proton prefix discovery against a fake Steam tree
python tests/test_update.py          # both updaters, from a GitHub-style zip into fake game/Archipelago folders
```

`baseline/` holds the earlier ChatGPT-built version unchanged, for reference.
