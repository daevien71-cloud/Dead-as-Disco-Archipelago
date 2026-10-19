# Dead as Disco Archipelago: notes for AI assistants

Shared notes for Claude, Codex/ChatGPT and any other assistant working on this repo. Read this first.
At the end of a session, update **Status** and **Next** here, and add dated findings to `NOTES.md`.

## What this is

An [Archipelago](https://archipelago.gg) multiworld integration for **Dead as Disco** (Brain Jar Games, Unreal
Engine 5.7, early access), focused on **Arcade mode** (the game's `InfiniteDisco` game state). The owner plays it
with friends who play other games and don't own Dead as Disco. Three parts:

1. **APWorld** (`apworld/dead_as_disco/`): items, locations, options, logic, docs. Built into
   `dead_as_disco.apworld` at the repo root.
2. **Client** (`apworld/dead_as_disco/client.py`): a CommonClient launched from the Archipelago Launcher as
   "Dead as Disco Client". It talks to the game through files (`bridge.py`).
3. **Game mod** (`mod/DeadAsDiscoAP/Scripts/main.lua`): a UE4SS Lua mod that reports waves, kills and deaths, and
   applies traps, buffs, DeathLink kills and on-screen pop-ups.

## Layout

| Path | What |
|---|---|
| `apworld/dead_as_disco/data.py` | Every name, ID and threshold in one place. |
| `apworld/dead_as_disco/options.py` | Player options. Docstrings are what the Options Creator shows: keep them plain-language. |
| `apworld/dead_as_disco/tracker.py` | Client rules (checks per event, DeathLink rolls, shields, effect queue). No networking. |
| `apworld/dead_as_disco/bridge.py` | File bridge: `events.jsonl` (game→client), `commands.jsonl` (client→game), `status.json`. |
| `apworld/dead_as_disco/client.py` | Networking, pop-up messages, `/disco`, `/testeffect`, `/testkill`, `/testdeathlink`. |
| `apworld/dead_as_disco/docs/` | Game page (with "Options explained") and setup guide. |
| `apworld/dead_as_disco/test/` | World, tracker and bridge unit tests (run from an Archipelago checkout). |
| `mod/DeadAsDiscoAP/Scripts/main.lua` | UE4SS mod. Tuning constants at the top. |
| `install/` | Installers and updaters: Windows PowerShell, Linux Python; `update_source.json` = repo + branch. |
| `tests/` | Lua harness (fake UE4SS), end-to-end test, Linux installer and updater tests. |
| `baseline/` | The earlier ChatGPT-built version, unchanged. Reference only; don't edit. |
| `NOTES.md` | Dated history, decisions and research facts (hook paths, what works in-game and what doesn't). |

## Build and test

```
python build.py                       # dist/ release zip + dead_as_disco.apworld at the root (commit it)
LOCALAPPDATA=<temp dir> lua tests/lua/test_main.lua <repo>    # Lua 5.4; mod against a fake UE4SS
python tests/test_install_linux.py    # Linux installer + Proton prefix discovery
python tests/test_update.py           # both updaters
```

From an Archipelago 0.6.x source checkout with `apworld/dead_as_disco` copied into its `worlds/`:

```
python -m unittest worlds.dead_as_disco.test.test_world worlds.dead_as_disco.test.test_tracker worlds.dead_as_disco.test.test_bridge
python <repo>/tests/e2e/run_e2e.py <that checkout>   # real server + 2 clients + fake games
```

Run everything before pushing. Things only the real game can show (hooks, effects, kills, pop-ups) need the
owner to playtest; the assistant reads the logs afterwards: `<game>/Pagoda/Binaries/Win64/ue4ss/UE4SS.log` and
Archipelago's `logs/DeadAsDiscoClient_*.txt`.

## Conventions

- **Commit identity:** `daevien71 <313861149+daevien71-cloud@users.noreply.github.com>`. Never the owner's
  personal email: the repo is public.
- **Branches:** `main` is the default and what `Update.bat` / `Update-Linux.sh` pull. Keep
  `claude/trusting-cori-vg0cjc` level with it so copies installed before the rename still update.
- **After any change to `apworld/`, run `python build.py` and commit `dead_as_disco.apworld`.** The build is
  reproducible, so it only changes when the world does.
- **Keep out of the repo:** the owner's personal mods (for example the Pyroette mod in
  `Documents\DaevienPyroetteSpin`), game files, saves, secrets. `dist/` and `playtest/` are gitignored.
- **Committed mod code has `TEST_HOTKEYS = false`.** The status hotkey is Ctrl+Home (F11 toggles the game's
  fullscreen).
- **Never apply `GE_Die`** to kill the player: it only marks them dead and freezes all combat. Use
  `GE_Damage_SetByCaller` with `SetByCaller.Damage` (see NOTES.md).
- **Claude desktop app gotcha:** processes it starts see a redirected `%LOCALAPPDATA%`, which the game can't see.
  Start the Archipelago server and client through `explorer.exe` (e.g. `playtest\Start-*.bat`), and launch the
  game with `steam://rungameid/3404260`.
- Explanations for the owner: plain words, no jargon; they're not a programmer but playtest carefully.

## Owner's setup

- Windows laptop (Archipelago 0.6.7 in `C:\ProgramData\Archipelago`) and the main gaming PC, Kubuntu 26.04 with
  Steam + Proton and a newer Archipelago (AppImage). Both have the owner's pak cosmetic mods in
  `Content/Paks/~mods`; installers never touch `Content/Paks`.
- Linux needs the Steam launch option `WINEDLLOVERRIDES="dwmapi=n,b" %command%` for UE4SS.

## Status (2026-10-19)

v0.1.0 works on Windows and Linux and has been played with friends.

v0.2.0 adds an opt-in **Meteor Trap** (814200105), off in the default trap set. Each item rolls 1–5
sequential meteors. It reuses Aurora's
native falling meteor, warning, damage and kickable remnant. `Scripts/meteor.lua` owns only spawning,
timing and cleanup. Live probes confirmed ~1.98s flight, player damage 10 HP, enemy damage 60 HP, and
kicking into ordinary NPCs. Real AP delivery through the installed single-meteor version passed,
including saved consumption. Batch and transition validation are recorded in `docs/meteor.md` and
`NOTES.md`; do not infer they passed from the native probe alone.

Resolve the controlled player with `GameplayStatics:GetPlayerPawn(state, 0)`: `FindAllOf` can return a
valid old Charlie after restart. Never add substitute damage to compensate for targeting that old actor.
Opaque native struct returns become reflected-only Lua tables in this UE4SS version; do not round-trip
target-data/filter handles through ordinary Lua returns. A discarded filter experiment crashed the game.

Meteor timers use game time (16s cap per launch); native remnant timer is extended to 11s. One meteor
and its remnant at a time, at least 3s between launches, with a whole-batch cap of `20 * count + 10`.
The batch occupies one effect slot. AP consumption is persisted once at its first start; pending command
metadata survives reconnects. Unstarted failures retry twice with 3s gaps before a logged skip; later
failed spawns skip just that meteor. Missing adapters leave the original effects working. Old mods keep
meteor items queued. See `docs/meteor-research.md` for exact hook contracts and evidence.

- **Checks:** 15 per-run wave milestones (optional every-Nth-wave extras) and up to 14 lifetime-kill checks.
- **Goal:** collect N Gold Records, then clear the goal wave in one run.
- **Items:** Gold Records, Disco Fever, Mirror Ball Shield, Groovy Vibes; Slow-Mo, Fast-Forward, Molasses and
  Blackout (98%) traps, plus the optional Meteor Trap.
- **DeathLink:** 25% send / 40% receive (options), only while in a run; shields block one. All confirmed in-game.
- **On-screen pop-ups:** items sent/received, effects, DeathLink, goal.
- **Tooling:** one-click install and update (Windows + Linux), plain-language options in the Options Creator.
- **Last fix:** joining a new multiworld no longer counts kills/waves left over in the event log from earlier
  play.

## Next

- Complete the remaining batch, pause/menu/death/song/arena and Linux/Proton live checks in `docs/meteor.md`.
- Cars remain a later feature; do not expand this into a generic hazard framework.
- Watch long runs: does the wave count survive song changes?
- More traps: enemy surge, hiding the beat indicator, forced outfit.
- Songs, arenas or moves as items (move locking failed in early research; needs another approach).
- Combo-based checks.
