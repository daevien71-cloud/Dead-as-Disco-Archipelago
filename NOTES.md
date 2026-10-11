# Dead as Disco – Archipelago mod: project notes

Notes carried over from a planning chat so a new Claude session can pick up where we left off.

## Status

- Game: **Dead as Disco** (Brain Jar Games), a rhythm beat 'em up in early access since May 5, 2026.
- A quick search found no existing Archipelago integration for it.
- A version already exists, made with ChatGPT. It's in a zip on the laptop's Desktop.
- Next step: read through the ChatGPT version and give an honest assessment: what works, what's broken, what's missing. Then decide whether to fix it or rebuild parts of it.
- Before changing anything, commit the ChatGPT version unchanged to this repo as a baseline.
- Find out which engine the game uses (Unity → BepInEx/C#, Unreal → UE4SS) from the game files and the existing mod.

## How an Archipelago integration is structured

1. **APWorld (Python):** items, locations, logic rules, options and goal. Lives in Archipelago's `worlds/` folder or ships as a `.apworld` file.
2. **Game-side client (the mod):** connects to the AP server over WebSocket, reports checked locations, receives items.

## Game features to build on

- Story mode with boss fights against the Idols
- Challenge mode / Challenge Playlists
- About 30 free-play songs (original and licensed)
- Infinite Disco: endless mode that plays the player's own music, with several arenas
- Unlockable special attacks and health upgrades
- Selectable dance moves
- Fever meter
- Cosmetics (fashion)

## Ideas beyond arcade level clears

### Items (things other players send you)
- **Songs as items:** a track can't be played until it's received (Muse Dash's approach).
- **Moves as items:** start with basic attacks; special attacks, dance moves and health upgrades arrive during the run.
- **Arenas and Idol fights** unlocked by items.
- **Cosmetics as filler.**

### Locations (checks)
- Rank tiers per song (clear / A / S), with an option for how many tiers count.
- Combo milestones (e.g. 50 / 100 / 200 hits on the beat).
- Each Idol defeated in story mode.
- Each challenge playlist completed.
- Infinite Disco: a check every N waves survived.

### Goal options
- Collect X "Gold Records" scattered across the multiworld, then beat a final Idol (Muse Dash's approach; the group decides how long the game runs).
- Or defeat every Idol.

### Traps (harmless sabotage)
- Off-beat: the beat indicator disappears for ~20 seconds.
- Crowd surge: an extra wave of enemies.
- Blackout: the dance floor goes dark.
- Fashion disaster: forced into a ridiculous outfit.

### Multiplayer extras
- DeathLink.
- In-game pop-ups when an item arrives ("Link sent you: Uppercut!").

## Practical points

- The game is in early access, so updates may break the mod. Keep song and location lists in one easy-to-edit data file.
- The mod should turn off leaderboard score submission while running.
- Feasibility depends on what the game's code exposes. Locking songs and moves is usually doable; traps that change the music itself are harder. Rank ideas by difficulty once the code has been read.
- The user playtests; Claude reads logs and fixes what breaks.
