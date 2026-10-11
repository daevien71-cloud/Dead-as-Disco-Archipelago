# Local Arcade Milestones generation and hosting

Run these commands in the task workspace. They use the existing isolated Python environment and official Archipelago 0.6.9 checkout. They do not install a game adapter or launch the game.

A fresh seed is already generated at `output\arcade-milestones-20261011\AP_96996334102749320486.zip`: player `DiscoMilestones`, team 0, slot 1, goal wave 20. Its SHA-256 is `a1f8b0009c8778cd0614a9e3d709f6d860286be3e939032a08b85957a43de3ca`. It has not been hosted or connected to the game. To host this ready seed:

```powershell
& .\.venv\Scripts\python.exe scripts\run_local_server.py serve output\arcade-milestones-20261011\AP_96996334102749320486.zip --session arcade-milestones-01 --port 38281 --auto-shutdown 600
```

Generate a new solo seed with goal wave 20:

```powershell
& .\.venv\Scripts\python.exe scripts\generate_arcade_milestones.py --seed 2026101104 --slot DiscoMilestones --goal 20 --output output\arcade-milestones-local-01
```

The goal may be any configured milestone: `1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200`. All 15 checks remain available. Goal completion requires the selected clear to be observed locally and acknowledged by the server. Harmless Set Credits do not gate moves or completion. Songs are unrestricted by the AP logic; high-wave game behavior remains unverified.

The output contains `Players\ArcadeMilestones.yaml`, one generated AP archive, and `generation-summary.json` with the actual seed name, slot, hashes, and slot data. Generation refuses to overwrite an existing directory.

Host that generated archive on this laptop:

```powershell
$seedInfo = Get-Content -LiteralPath 'output\arcade-milestones-local-01\generation-summary.json' -Raw | ConvertFrom-Json
& .\.venv\Scripts\python.exe scripts\run_local_server.py serve $seedInfo.archive --session arcade-milestones-local-01 --port 38281 --auto-shutdown 600
```

The server address is `ws://127.0.0.1:38281`. The host command is game-generic and uses the archive's embedded data package. It does not require copying the milestone world into the vendor checkout. Stop it with `/exit` in the server console or Ctrl+C. The 600-second setting is an **inactivity** timeout, not a total session limit.

Using the same session label and archive resumes the adjacent AP save under `runtime\ap-server\sessions\<label>\<archive-hash>\room.apsave`. Choose a new session label for a separate AP room. Game saves are unrelated and are not read or changed by these commands. No public network binding, firewall rule, or persistent password is configured.

For an ordinary Archipelago installation, install the milestone `.apworld` through Archipelago's custom-world installation flow and use this player configuration:

```yaml
name: DiscoMilestones
game: Dead as Disco (Arcade Milestones)
Dead as Disco (Arcade Milestones):
  accessibility: full
  goal_wave: 20
```

The workspace's dependencies are already installed. Provenance is recorded in `evidence/server-source.json` (official source commit, Python identity, wheel URLs and hashes), `evidence/server-requirements-lock.txt` (versions), and `evidence/server-requirements-hashed.txt` (exact Windows Python 3.13 wheel hashes). Official seed generation passed for this milestone build. No new dependency download or server/game runtime test was performed.

The original one-check proof and the synthetic three-check transport evidence remain historical evidence. They do not demonstrate all milestone checks or the new goal in a live game session.
