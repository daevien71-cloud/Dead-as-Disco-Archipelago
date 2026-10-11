# Dead as Disco – Archipelago mod: project notes

Notes so a new Claude session can pick up where we left off.

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

## Status

Built v0.1.0 (APWorld + client + UE4SS Lua mod + installer). Tested offline only:
- Lua mod against a fake UE4SS API: `tests/lua/test_main.lua` (31 checks).
- World + tracker unit tests (37), AP 0.6.9 general world tests, generation from the packaged .apworld.
- End-to-end: real AP server, two clients, fake games (`tests/e2e/run_e2e.py`).
- Installer/uninstaller against a fake game folder; auto-detection finds the real Steam install.

**Not yet tested in the real game.** The first live test needs to confirm the items below.

## What the mod relies on (from the earlier Codex research)

Confirmed live in October 2026 with UE4SS 3.0.1-1164 on game build sha256 8115716…:
- `BP_PagodaGameState_InfiniteDisco_C` hooks: ReinitDiscoState, AdvanceRound (round = new wave),
  OnIncursionCleared_Event, HandleLevelEnded/Restarted. Order seen for rounds 1–3:
  Reinit(0) → Advance(1) → kills → WaveEnded → IncursionCleared(1) → Advance(2) → ...
- `/Script/Pagoda.PagodaInfiniteDiscoSubsystem:NotifyEnemyKilled` fires once per kill (native, post).
- `BP_PagodaPlayerCharacter_Charlie_C:OnDeathStartedDelegate_Event` fires on player death, then
  native `PagodaCharacter:FinishDeath` ~2s later.
- Audio is FMOD, so time dilation should not change the music.

## First live test checklist

1. Run `Install.bat` (game closed). Start the game; check `...\Win64\ue4ss\UE4SS.log` for
   `[DeadAsDiscoAP] hooked ...` lines (8 expected over time) and no crash.
2. Start an Arcade run. Press Ctrl+F11: status line should say in_run=true and the wave number.
3. Try Ctrl+F5..F9 one at a time: slow-mo, fast-forward, molasses, blackout, fever. Note which visibly work.
4. Get hit by an enemy once: log should say `learned how enemies damage you`. (If not, the damage hook
   isn't seeing hits and DeathLink falls back to other kill methods.)
5. Ctrl+F10 (test kill): log says which kill method worked, or `every method was tried`.
6. Solo seed: generate with the YAML template, host locally, connect the client, clear a few waves,
   confirm checks appear. Then a death with DeathLink at 100% send to see it go out.

Unknowns to watch: whether wave numbers keep counting past song changes; whether time dilation
breaks beat timing badly (fun) or entirely (needs tuning); which kill method works.

## Ideas not built yet

- Item-arrival pop-ups in the game (no in-game text yet; the client window shows everything).
- Songs/arenas/moves as items (move locking failed in the earlier research; needs a different approach).
- More traps: enemy surge, fashion disaster, hiding the beat indicator.
- Combo-based checks.
