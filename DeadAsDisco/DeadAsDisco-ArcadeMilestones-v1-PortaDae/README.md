# Dead as Disco — Arcade Milestones v1 (PortaDae)

15 Archipelago checks for clearing Arcade waves **1, 2, 3, 5, 10, 15, 20, 25, 30,
40, 50, 75, 100, 150 and 200**. The included seed finishes at wave **20**. Each
clear is confirmed when the next round starts: wave 20 needs arrival at round 21.
The goal can be any listed milestone when generating a new seed. All checks stay
available, all native moves stay available, and song selection does not affect AP
logic. Received **Set Credits** are harmless filler with no gameplay effect.

This is an experimental private build for the recorded PortaDae game build.
Earlier work proved one real first-wave check reaching a local official AP server
and receiving an item. The first three rounds were calibrated separately. **This
expanded package, its goal and higher waves have not been tested in live gameplay.**
Its offline tests and successful seed generation do not prove that high waves or
mid-run custom-song changes work in the game. Enemy/kill challenges, ability
restrictions, DeathLink and in-game notifications are not included.

## Start the supplied solo room

Extract the archive to an ordinary local folder; keep it there while installed.
Use **PowerShell 7.2+**. Keep the existing workspace
`C:\Users\sip22\Documents\Codex\2026-10-10\task`: the default Python environment
and local AP host live there. Python and Archipelago are not bundled.

Close Dead as Disco. In a PowerShell terminal opened in this extracted folder:

```powershell
.\Install.ps1
```

The installer verifies the recorded game build, takes a current save/config/mod
backup, then installs the temporary UE4SS adapter. It refuses existing UE4SS files
and never overwrites cosmetics or restores old saves. If Windows denies access to
the Steam game folder, reopen PowerShell as administrator and rerun. A partial
installation is journaled for recovery with `Uninstall.ps1`.

Start the local AP host in one terminal:

```powershell
.\Start-Local-Server.ps1
```

Start the client in a second terminal from the extracted folder:

```powershell
.\Start-Client.ps1
```

Wait for the client's connection and ready messages. Start the game normally in
Steam, select **Arcade**, and begin a fresh run. Checks/credits appear in the
client console; there is **no in-game item popup**. The supplied player name is
`DiscoMilestones`, seed name `96996334102749320486`, team 0, slot 1. The host is
loopback-only at `ws://127.0.0.1:38281`; no firewall changes are made.

The observer must see every clear/advance from a fresh run; it never awards checks
just for loading a late round. After a disconnect/reconnect, start a fresh Arcade
run to reestablish observation. Already acknowledged checks and received credits
are retained and deduplicated separately by seed/team/slot. The observer lasts at
most 24 hours per game process; this duration has not been endurance-tested live.

Stop the client with Ctrl+C. Stop the host with `/exit` or Ctrl+C. The same host
session and seed resume the AP save. To remove the game adapter, close the game
and client, then run:

```powershell
.\Uninstall.ps1
```

Uninstall captures the loader and removes only this installation. **It preserves
current game saves and all later play progress; it never restores backups.** It
refuses removal if installed files changed or additional UE4SS mods were added.
Keep the folder until uninstall completes. Do not copy its old backups over saves.

## Different goals or multiworld rooms

The package includes `world/dead_as_disco_arcade_checks.apworld` and
`Players/ArcadeMilestones.yaml`. Install the APWorld through the official AP
launcher; retain its basename. Set `goal_wave` in the YAML to a listed milestone
before generating a new room. Editing YAML does not change the supplied seed.
All moves and checks are reachable without received items in generation logic.

For local generation with the existing workspace, see
`docs/arcade-milestones-local-host.md`. Official AP 0.6.9 generation was verified.
For a newly generated room, uninstall the previous adapter, then install with its
actual seed name and numeric team/slot (the seed name is not the generator number):

```powershell
.\Install.ps1 -SeedName 'ACTUAL_SEED_NAME' -Team 0 -Slot 1 -PlayerName 'YOUR_SLOT_NAME'
.\Start-Client.ps1 -Server 'wss://YOUR_HOST:PORT' -AllowRemote -AskPassword
```

The host must supply the exact seed/team/slot details. Remote and mixed-game live
sessions remain unverified. `-AllowRemote` enables only the requested outbound
connection, and passwords are read in memory, never saved. No remote host is
configured by this package. All wrappers accepting Python support `-PythonExe`
with Python 3.12+ and `requirements-client.txt` installed; the local host also
requires the existing official AP dependencies.

Detailed check IDs, semantics and limits: `docs/arcade-checks-setup.md`.
File hashes: `MANIFEST.json`. Included dependencies are the pinned official UE4SS
release, Lua syntax checker and MIT-licensed json.lua; see `THIRD_PARTY.md`.
No game assets, saves, credentials or gameplay captures are distributed.
