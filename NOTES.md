# Dead as Disco – Archipelago mod: history and research log

Dated decisions, findings and research facts. For the current state, conventions and next steps, start with
[AGENTS.md](AGENTS.md).

## Decisions (2026-10-11)

- Friends play **other games** and don't own Dead as Disco. Only the owner runs the mod.
- **Rebuilt the plumbing** instead of patching the ChatGPT version. That version is kept unchanged in
  `baseline/chatgpt-arcade-milestones-v1/` (commit 2d859eb).
- Focus is **Arcade mode** (the game's `InfiniteDisco` game state).
- **Waves count per run.** Reaching wave 200 in one run is fine: waves aren't hard, it's a grind.
  Anything that blocks friends should be reachable eventually by grinding; no extra logic gating.
- **DeathLink:** 25% chance to send on death; 40% chance an incoming DeathLink kills the player,
  only while in a run. Both are YAML options.
- Traps that mess with time are welcome; the owner is patient and fine with downsides.

## Initial build (2026-10-11)

Built v0.1.0 (APWorld + client + UE4SS Lua mod + installer). First tested offline:
- Lua mod against a fake UE4SS API: `tests/lua/test_main.lua` (31 checks).
- World + tracker unit tests (37), AP 0.6.9 general world tests, generation from the packaged .apworld.
- End-to-end: real AP server, two clients, fake games (`tests/e2e/run_e2e.py`).
- Installer/uninstaller against a fake game folder; auto-detection finds the real Steam install.

Live-tested in the real game: waves, kill checks, all five effects, outgoing DeathLink and the DeathLink
kill. Still untested live: an incoming DeathLink from another player, long runs and song changes.

## Linux (owner's main gaming PC: Kubuntu 26.04, Steam + Proton)

- Same Windows mod and UE4SS under Proton; needs Steam launch option `WINEDLLOVERRIDES="dwmapi=n,b" %command%`.
- `install/install_linux.py` (via `Install-Linux.sh`) finds native/Flatpak/Snap Steam libraries, writes
  `bridge_dir.txt` = `C:\users\steamuser\AppData\Local\DeadAsDiscoAP` and creates that folder in the prefix
  (`steamapps/compatdata/3404260/pfx/drive_c/users/steamuser/AppData/Local`).
- The native Linux AP client finds the same folder through the prefix (`bridge.proton_local_appdata`).
- **Works on the real Kubuntu PC** (2026-10-11): installer, UE4SS under Proton, client found the prefix, checks,
  traps, Disco Fever and goal reminders all worked with the owner's newer Archipelago.
- Owner has pak cosmetic mods in `Content/Paks/~mods` on both PCs; installers never touch Content/Paks.

## What the mod relies on (from the earlier Codex research)

Confirmed live in October 2026 with UE4SS 3.0.1-1164 on game build sha256 8115716…:
- `BP_PagodaGameState_InfiniteDisco_C` hooks: ReinitDiscoState, AdvanceRound (round = new wave),
  OnIncursionCleared_Event, HandleLevelEnded/Restarted. Order seen for rounds 1–3:
  Reinit(0) → Advance(1) → kills → WaveEnded → IncursionCleared(1) → Advance(2) → ...
- `/Script/Pagoda.PagodaInfiniteDiscoSubsystem:NotifyEnemyKilled` fires once per kill (native, post).
- `BP_PagodaPlayerCharacter_Charlie_C:OnDeathStartedDelegate_Event` fires on player death, then
  native `PagodaCharacter:FinishDeath` ~2s later.
- Audio is FMOD, so time dilation should not change the music.

## Live findings (2026-10-11, first playtest)

- UE4SS loads, all 8 hooks register, and the hotkey effects apply in-game (slow-mo 0.6, fast-forward 1.4,
  molasses, blackout, fever).
- `LoopAsync` only fired once in this UE4SS build. The main loop now reschedules itself with
  `ExecuteInGameThreadWithDelay` (confirmed ticking in-game).
- `PagodaCombatFunctionLibrary:ApplySetByCallerEffect` on the player is used for attack range
  (`SetByCaller.AttackRange`, 450) and the music-sync meter, **not** for enemy damage. Damage-learning now
  only accepts effects with "damage" in the class or tag; none seen yet.
- Second playtest: waves 1–3 and the 25-kill check sent, Fast-Forward and Slow-Mo traps fired and wore off,
  natural death went out over DeathLink. Engine `ApplyDamage` and `PagodaCharacter:FinishDeath` do **not** kill.
- The game's asset index (Pagoda-Windows.utoc directory index, readable) has
  `/Game/Pagoda/Characters/Common/Effects/GE_Die` and `GE_Damage_SetByCaller`, plus
  `/Game/Pagoda/Environment/Common/Volumes/BP_Volume_Death`.
- Third playtest: **never apply GE_Die.** It only marks a character dead (`Status.Death.Dead`) without
  killing it; afterwards nobody could deal or take damage until the game restarted (runtime only, saves fine).
- Native gameplay tags are UTF-16 strings in the exe: `SetByCaller.Damage` (plus Heal, MaxHealth,
  MaxDamageInHearts, IncomingDamageMultiplier, ...), `Status.Death.Dead/Dying`. Reading the tag from
  GE_Damage_SetByCaller's CDO returned None (likely an execution calc, not a modifier).
- Kill now: GE_Damage_SetByCaller x9999 with SetByCaller.Damage; from the 2nd hit on, Health is set to 0.01
  first; one hit per 0.5s, up to 12. Logs health before/after each hit.
- Fourth playtest: **the kill works.** The first GE_Damage_SetByCaller hit killed instantly (the death hook
  fired during the call) and the death went out over DeathLink. `PagodaCharacter:GetHealth()` read 0.0 even
  before the hit, so don't trust it for diagnostics.
- Processes started by Claude (the Claude desktop app is MSIX-packaged) see a redirected
  `%LOCALAPPDATA%`. The game can't see that copy. For playtests, start the AP server/client through
  `playtest\Start-Server.bat` / `Start-Client.bat` via explorer.exe, or have the user start them.
  The installer now writes the bridge path to `bridge_dir.txt` in the mod folder.

- Fifth playtest: **on-screen pop-ups work.** The overlay is hosted on `WBP_LevelSelectLabelText` (its
  widget tree is replaced by a canvas + TextBlock) and is rebuilt after level changes. Item messages from the
  client ("You found your Molasses Trap") and the mod's own effect announcements both show.
- Client bug found and fixed: `CommonContext.seed_name` stays None for clients in AP 0.6.7 and 0.6.9, so
  progress went to `state/None_<team>_<slot>.json`. The client now takes the seed name from RoomInfo.
  (A one-time migration of the old file was removed on 2026-10-12: it could carry old kills into any new
  multiworld.)
- When reading bridge files from Claude's tools, delete the stale redirected copy under
  `AppData\Local\Packages\Claude_*\LocalCache\Local\DeadAsDiscoAP` first, or you read old data.

- Incoming DeathLink confirmed in the real game via `/testdeathlink` (2026-10-11). The Pyroette spin fix works
  (she now stands still). Ctrl+F11 also toggles the game's fullscreen, so the status hotkey is Ctrl+Home.
- First real session with friends (2026-10-12): joining a new multiworld before starting the game sent kill/wave
  checks from the previous session's events.jsonl. Fixed: a slot's first connect on a machine skips the existing
  log, and a restarted game is detected by its hello session. Progress is keyed by seed/team/slot, so a room
  moving to a new port keeps its progress.
- `/testdeathlink [name]` in the client bounces a fake DeathLink to your own slot only (no DeathLink tag,
  `slots=[own]`), so it can't reach friends; the client then rolls/shields/kills like a real one.
- `Update.bat` / `Update-Linux.sh`: git pull in a clone, otherwise download the branch zip from GitHub. The
  repo went public on 2026-10-11 (commit emails moved to the GitHub no-reply address first) and was renamed from
  `test` to `Dead-as-Disco-Archipelago`, default branch `ClaudeGPT-coded` → `main`. Update works on both PCs.
- Owner's Pyroette (Vermillion Dance boss ability, `BP_BossAbility_VermillionDance_Pyroette`, anim
  `A_AI_Pyroette_Spin`) spins too fast with their model mod. A separate UE4SS mod `DaevienPyroetteSpin`
  (kept OUT of this repo at `Documents\DaevienPyroetteSpin`, zip on the Desktop) slows that actor's mesh
  animation, rotating movement and spin variables to 1%; confirmed working. v2 also holds her `BeatsSeen`
  counter for 5 s to keep her on the field longer and logs her config/functions; not yet tried in-game.

## Playtest checklist (current build)

1. With the game closed, run Update (or Install). Start the game: `ue4ss/UE4SS.log` should show
   `[DeadAsDiscoAP] hooked ...` for 7 functions, `main loop running` and `bridge open`.
2. The Dead as Disco Client says "Dead as Disco detected." Ctrl+Home in the game shows the status pop-up.
3. In an Arcade run: clear a few waves (checks + pop-ups), `/testeffect slowmo`, `/testdeathlink`.
4. Read both logs afterwards: `UE4SS.log` and Archipelago's `logs/DeadAsDiscoClient_*.txt`.

Ideas for later live in AGENTS.md under "Next".
