# Dead as Disco — Archipelago

Play Dead as Disco's Arcade mode in an [Archipelago](https://archipelago.gg) multiworld with friends
who play other games.

- **Checks:** clearing waves 1, 2, 3, 5, 10 … 200 (per run) and lifetime enemy-kill totals.
- **Goal:** collect enough Gold Records, then clear your goal wave in a single run.
- **Items:** Gold Records, Disco Fever (enemies slowed), Mirror Ball Shield (blocks a DeathLink),
  and traps: Slow-Mo, Fast-Forward, Molasses (only you are slowed) and Blackout.
- **DeathLink:** your deaths have a 25% chance to be sent; their deaths have a 40% chance to kill you
  while you're in a run (both adjustable).

## Install and play

See [the setup guide](apworld/dead_as_disco/docs/setup_en.md). Short version: run `Install.bat` (Windows) or
`bash Install-Linux.sh` (Linux/Proton, plus one Steam launch option), install `dead_as_disco.apworld`, open
**Dead as Disco Client** from the Archipelago Launcher, play Arcade.

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

```
python build.py                      # dist/dead_as_disco.apworld and the release zip
lua tests/lua/test_main.lua <repo>   # mod tests against a fake UE4SS (set LOCALAPPDATA to a temp dir)
python -m unittest worlds.dead_as_disco.test.test_world worlds.dead_as_disco.test.test_tracker  # from an AP checkout
python tests/e2e/run_e2e.py <AP checkout with the world installed>   # server + 2 clients + fake games
python tests/test_install_linux.py   # Linux installer + Proton prefix discovery against a fake Steam tree
```

`baseline/` holds the earlier ChatGPT-built version unchanged, for reference.
