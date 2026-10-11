# Arcade Milestones: setup and completion

Experimental private build: 15 song-independent Arcade checks, all native abilities
available, and harmless AP credits. Game: **Dead as Disco (Arcade Milestones)**.
Profile: `arcade_milestones_v1`, integration version 3. Ability restrictions and
DeathLink are disabled. No enemy/kill telemetry is implemented.

**Live evidence is limited:** an earlier real first-wave check reached AP and
returned an item; separate calibration observed the first three round transitions.
The expanded milestone profile, higher waves and its goal have not been verified
in live gameplay. Offline synthetic wave-200 tests are not gameplay proof.
No further live installation or manual test is planned for this checkpoint.

## PortaDae package

The deliverable is
[DeadAsDisco-ArcadeMilestones-v1-PortaDae.zip](../dist/DeadAsDisco-ArcadeMilestones-v1-PortaDae.zip).
It includes the APWorld, player YAML, a generated seed with goal wave 20, and these
PowerShell entrypoints, requiring **PowerShell 7.2 or newer**:

- `Install.ps1`: takes a fresh snapshot, prepares the workspace adapter, and uses
  the existing installer with source/hash guards.
- `Start-Local-Server.ps1`: hosts the included seed locally using the original
  workspace's official AP dependency; defaults to port 38281 and session
  `arcade-milestones-v1`.
- `Start-Client.ps1`: uses the active prepared plan, with optional server/slot
  overrides.
- `Uninstall.ps1`: captures and removes the installed loader; **never restores
  game saves**. It refuses removal if additional UE4SS mods have been added.

`Install.ps1` defaults to the included seed `96996334102749320486`, team 0, slot 1
and player `DiscoMilestones`. For a regenerated/multiworld seed, pass the correct
`-SeedName`, `-Team`, numeric `-Slot` and `-PlayerName`. `-ValidateOnly` prepares
workspace staging and a backup without installing into the game. Normal install
requires the known game-build hash. From the extracted package, the entrypoints
are `./Install.ps1`, then `./Start-Local-Server.ps1` and `./Start-Client.ps1` in
separate terminals; close the game before `./Uninstall.ps1`.

Keep the original workspace and dependency setup: this is not a standalone Python
or Archipelago distribution. The package supports a `-PythonExe` override for
Python **3.12 or newer**; the local host still needs the workspace's official AP
source/dependencies. Close the game before installing or removing the adapter.
The commands below document the underlying workspace workflow.

The included seed was generated from
`output/arcade-milestones-20261011/AP_96996334102749320486.zip`, with player
`DiscoMilestones`, team 0, slot 1 and goal wave 20. Generation succeeded for all
15 checks and credits; this seed has not established milestone gameplay success.

## Checks and goal

| Clear milestone | Check name | Location ID | Confirming advance |
|---:|---|---:|---:|
| 1 | Arcade - Wave 1 Clear | 814000101 | 2 |
| 2 | Arcade - Wave 2 Clear | 814000102 | 3 |
| 3 | Arcade - Wave 3 Clear | 814000103 | 4 |
| 5 | Arcade - Wave 5 Clear | 814000105 | 6 |
| 10 | Arcade - Wave 10 Clear | 814000110 | 11 |
| 15 | Arcade - Wave 15 Clear | 814000115 | 16 |
| 20 | Arcade - Wave 20 Clear | 814000120 | 21 |
| 25 | Arcade - Wave 25 Clear | 814000125 | 26 |
| 30 | Arcade - Wave 30 Clear | 814000130 | 31 |
| 40 | Arcade - Wave 40 Clear | 814000140 | 41 |
| 50 | Arcade - Wave 50 Clear | 814000150 | 51 |
| 75 | Arcade - Wave 75 Clear | 814000175 | 76 |
| 100 | Arcade - Wave 100 Clear | 814000200 | 101 |
| 150 | Arcade - Wave 150 Clear | 814000250 | 151 |
| 200 | Arcade - Wave 200 Clear | 814000300 | 201 |

`goal_wave` defaults to **20** and may be any milestone in the table. The selected
wave must have a verified local clear and current server acknowledgement before
the client sends `CLIENT_GOAL` (`StatusUpdate` 30). The other milestones and
received credits are not goal requirements. All 15 checks remain available.

The world contains 15 copies of **Set Credit** (item 814001102), filler with no
gameplay effect. In a multiworld, their placement cannot block moves or the goal.
Choose any song; song identity does not affect checks. Only the calibrated Arcade
mode is supported. The observer requires a fresh start and contiguous clear/advance
evidence; loading a late round does not backfill earlier checks. Higher-wave and
mid-run song-switch behavior remain unverified.

## World and local host

Use the packaged
[dead_as_disco_arcade_checks.apworld](../dist/arcade_milestones_v1/dead_as_disco_arcade_checks.apworld)
(world version 0.3.0); keep its basename. In official Archipelago 0.6.9, use
**Install APWorld** in the launcher. The destination depends on the installation.
The original one-check `dist/dead_as_disco.apworld` remains separate and intact.

Player YAML:

```yaml
name: DiscoMilestones
game: "Dead as Disco (Arcade Milestones)"
"Dead as Disco (Arcade Milestones)":
  accessibility: full
  goal_wave: 20
```

The following commands use the existing workspace `.venv` and pinned official
Archipelago checkout. Run them from
`C:\Users\sip22\Documents\Codex\2026-10-10\task`. The local generator handles a
solo seed and refuses to overwrite an existing output directory:

```powershell
& .\.venv\Scripts\python.exe scripts\generate_arcade_milestones.py --seed 2026101104 --slot DiscoMilestones --goal 20 --output output\arcade-milestones-local-01
```

Replace the output directory with a fresh name when generating another seed.
`--goal` becomes the seed's `goal_wave`; it is not a client setting. The output
includes `Players\ArcadeMilestones.yaml`, one AP archive and `generation-summary.json`.
To host that archive:

```powershell
$ArcadeSeed = Get-Content -LiteralPath 'output\arcade-milestones-local-01\generation-summary.json' -Raw | ConvertFrom-Json
& .\.venv\Scripts\python.exe scripts\run_local_server.py serve $ArcadeSeed.archive --session arcade-milestones-local-01 --port 38281 --auto-shutdown 600
```

The host binds only to `127.0.0.1:38281`. It opens no public listener and changes
no firewall rules. The 600-second value is an inactivity timeout. The same
session label and archive resume that AP room's save; a new label starts a
separate room. These commands do not install a game adapter or launch the game.
See [local host details](arcade-milestones-local-host.md) for dependency provenance.

## Adapter and client

A reviewed, prepared adapter plan is required. The setup helper remains
`scripts/prepare_arcade_checks_runtime.py`; it writes only workspace staging.
It takes `--session-directory`, `--bridge-directory`, `--seed-name`, numeric
`--team`/`--slot`, and `--accept-owner-calibration`. Use the generated `seed_name`,
not the generator input number or YAML player name. The bridge must match
`<state-root>\arcade_milestones_v1\<seed/team/slot fingerprint>\bridge`.
The returned `install-plan.json` pins that identity and the adapter's source hash.

The session owner handles any future installation with a fresh baseline and
`scripts/install_observer_session.ps1`, then removes only the journaled loader
files with `scripts/remove_observer_session.ps1`. Preparing a plan or starting
the AP server does not install the adapter. No installation is performed by this
guide's host/client commands.

With that prepared plan and its matching state root, run the client in a second
terminal:

```powershell
& .\.venv\Scripts\python.exe -m dad_ap.arcade_client --server ws://127.0.0.1:38281 --slot DiscoMilestones --state-dir '<state-root>' --adapter-plan '<prepared install-plan>'
```

Replace the quoted placeholders with this session's paths. `--slot` must exactly
match the YAML name. The client verifies the plan, authenticates, validates v3
slot data, synchronizes inventory, then enables a fresh renewable observation
lease. Start Arcade after readiness. Watch the terminal's observed/acknowledged
progress and selected-goal status; no in-game item toast is implemented.

The adapter has a **24-hour maximum per loaded process** and renewable short
leases; the client itself continues until Ctrl+C. A new client session nonce
requires a real Arcade reinitialization and discards an incomplete observation
chain. Durable check and receipt state is separated by profile, seed, team and
slot, preventing duplicate logical checks/credits after reconnect.

`--allow-remote` explicitly permits the specified outbound `ws://` or `wss://`
endpoint; it does not expose this laptop as a server. `--ask-password` prompts
for a room password in memory only. Remote/mixed-game runtime behavior is unverified.
Press **Ctrl+C** to stop the client and revoke its lease; the game and all moves
remain available. Stop the local host with `/exit` in its server console.

## Preserve progress

AP state is separate from game saves. Normal setup does not restore saves.
Any experimental same-test cleanup is root-managed against that test's fresh
baseline. **Never reuse old save backups, automatically restore after normal
play, or overwrite later owner progress.** The testing window is not marked
released by this guide. The archive includes original integration code and
documentation, not proprietary game assets or private extracted inspection copies.

Historical three-check acceptance files, including
`output/arcade-checks-v1-acceptance/AP_36110218113552602081.zip`, are not milestone
seeds and are not instructions to start another test. The old three-check harness
is not the normal milestone host/client workflow. Current status and historical
evidence remain in [STATUS.md](../STATUS.md).
