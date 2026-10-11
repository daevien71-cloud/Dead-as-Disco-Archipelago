"""End-to-end test: real AP server + two Dead as Disco clients + two fake games.

The fake games write the same bridge files the UE4SS mod writes, so this exercises the
client, the world, the server protocol and DeathLink without the real game.

Usage: python run_e2e.py <Archipelago source dir with worlds/dead_as_disco installed>
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PORT = 38999


class FakeGame:
    def __init__(self, directory: Path):
        self.dir = directory
        self.dir.mkdir(parents=True, exist_ok=True)
        self.seq = 0
        self.in_run = False
        self.cleared = 0
        self.commands_seen: list[dict] = []
        self.offset = 0
        self.stop = threading.Event()
        (self.dir / "events.jsonl").write_text(json.dumps({"type": "hello", "session": "fake"}) + "\n")
        threading.Thread(target=self.loop, daemon=True).start()

    def emit(self, **event) -> None:
        self.seq += 1
        event.update(seq=self.seq, t=time.time())
        with (self.dir / "events.jsonl").open("a") as stream:
            stream.write(json.dumps(event) + "\n")

    def loop(self) -> None:
        while not self.stop.is_set():
            (self.dir / "status.json").write_text(json.dumps(
                {"t": time.time(), "in_run": self.in_run, "round": self.cleared + 1, "cleared": self.cleared}))
            path = self.dir / "commands.jsonl"
            if path.exists():
                data = path.read_bytes()
                if len(data) < self.offset:
                    self.offset = 0
                for line in data[self.offset:].splitlines():
                    self.handle(json.loads(line))
                self.offset = len(data)
            time.sleep(0.2)

    def handle(self, command: dict) -> None:
        self.commands_seen.append(command)
        if command["type"] == "effect":
            self.emit(type="effect_start", effect=command["effect"], command_id=command["id"])
            self.emit(type="effect_end", effect=command["effect"], command_id=command["id"], reason="expired")
        elif command["type"] == "kill":
            self.in_run = False
            self.emit(type="death")


def wait_for(predicate, what: str, timeout: float = 20) -> None:
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for: {what}")


def main() -> None:
    ap = Path(sys.argv[1]).resolve()
    python = sys.executable
    work = Path(tempfile.mkdtemp(prefix="dad_e2e_"))
    players = work / "players"
    players.mkdir()
    (players / "a.yaml").write_text("""name: DiscoDae
game: Dead as Disco
Dead as Disco:
  goal_wave: 10
  gold_record_count: 1
  gold_records_required: 1
  death_link: true
  death_link_send_chance: 100
  death_link_receive_chance: 100
  start_inventory: {Gold Record: 1, Slow-Mo Trap: 1}
""")
    (players / "b.yaml").write_text("""name: DiscoFriend
game: Dead as Disco
Dead as Disco:
  trap_percentage: 100
  death_link: true
  death_link_send_chance: 100
  death_link_receive_chance: 100
""")
    env = dict(os.environ, SKIP_REQUIREMENTS_UPDATE="1", PYTHONUNBUFFERED="1")
    subprocess.run([python, "Generate.py", "--player_files_path", str(players), "--outputpath", str(work / "out"),
                    "--seed", "7"], cwd=ap, env=env, check=True, capture_output=True)
    archive = next((work / "out").glob("AP_*.zip"))

    procs = []
    logs: dict[str, list[str]] = {}

    def start(name: str, args: list[str]) -> subprocess.Popen:
        proc = subprocess.Popen([python, *args], cwd=ap, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        logs[name] = []

        def pump() -> None:
            for line in proc.stdout:
                logs[name].append(line.rstrip())
        threading.Thread(target=pump, daemon=True).start()
        procs.append(proc)
        return proc

    def seen(name: str, text: str) -> bool:
        return any(text in line for line in logs[name])

    try:
        start("server", ["MultiServer.py", "--port", str(PORT), "--host", "127.0.0.1", str(archive)])
        wait_for(lambda: seen("server", "Hosting game"), "server start")
        game_a, game_b = FakeGame(work / "bridge_a"), FakeGame(work / "bridge_b")
        launch = "from worlds.dead_as_disco.client import launch; import sys; launch(*sys.argv[1:])"
        start("a", ["-c", launch, "--nogui", "--connect", f"127.0.0.1:{PORT}", "--name", "DiscoDae",
                    "--bridge-dir", str(game_a.dir)])
        start("b", ["-c", launch, "--nogui", "--connect", f"127.0.0.1:{PORT}", "--name", "DiscoFriend",
                    "--bridge-dir", str(game_b.dir)])
        wait_for(lambda: seen("a", "Goal: collect 1 Gold Records") and seen("b", "Goal:"), "both clients connected")
        wait_for(lambda: any((game_a.dir / "state").glob("*_0_1.json")), "client saves progress")
        assert not any((game_a.dir / "state").glob("None_*")), "progress saved without a seed name"
        print("PASS clients connect and read slot data")

        # Traps wait for a run, then fire.
        time.sleep(1.5)
        assert not any(c["type"] == "effect" for c in game_a.commands_seen), "effect sent outside a run"
        game_a.in_run = True
        game_a.emit(type="run_start")
        wait_for(lambda: any(c.get("effect") == "slowmo" for c in game_a.commands_seen), "slow-mo trap sent in run")
        wait_for(lambda: seen("a", "Slow-Mo Trap wore off"), "trap lifecycle logged")
        print("PASS trap waits for a run, then fires and ends")

        # Waves and kills send checks; clearing the goal wave with a Gold Record finishes.
        game_a.emit(type="wave", wave=10)
        game_a.emit(type="kill", count=30)
        wait_for(lambda: seen("a", "GOAL COMPLETE"), "goal")
        wait_for(lambda: seen("server", "has completed their goal"), "server saw goal")
        print("PASS wave + kill events send checks and the goal")
        messages = lambda game: [c.get("text", "") for c in game.commands_seen if c["type"] == "message"]
        wait_for(lambda: any("GOAL COMPLETE" in m for m in messages(game_a)), "goal pop-up")
        wait_for(lambda: any(m.startswith(("You found your", "You sent")) for m in messages(game_a)), "item pop-up")
        wait_for(lambda: any(" sent you " in m for m in messages(game_b)), "friend's item pop-up")
        print("PASS pop-up messages for items and the goal")

        # DeathLink: A dies -> (100%) sent -> B in run -> B killed -> B doesn't echo it back.
        game_b.in_run = True
        time.sleep(1.5)
        game_a.emit(type="death")
        wait_for(lambda: any(c["type"] == "kill" for c in game_b.commands_seen), "B told to die")
        wait_for(lambda: seen("b", "this death is not sent on"), "B doesn't echo")
        wait_for(lambda: any("takes you down" in c.get("text", "") for c in game_b.commands_seen), "DeathLink pop-up")
        time.sleep(2)
        assert not any(c["type"] == "kill" for c in game_a.commands_seen), "DeathLink echoed back to A"
        print("PASS DeathLink sends, kills the receiver in a run, and doesn't echo")

        # Out of run: incoming DeathLink is ignored.
        game_a.in_run = False
        time.sleep(1.5)
        game_b.in_run = True
        time.sleep(1.5)
        game_b.emit(type="death")
        wait_for(lambda: seen("a", "not in an Arcade run"), "A ignores DeathLink outside a run")
        print("PASS DeathLink ignored outside a run")

        procs[1].stdin.write("/disco\n")
        procs[1].stdin.flush()
        wait_for(lambda: seen("a", "Gold Records: 2/1"), "/disco command")
        print("PASS /disco status command")
        print("ALL E2E CHECKS PASSED")
    except Exception:
        for name, lines in logs.items():
            print(f"----- {name} -----")
            print("\n".join(lines[-40:]))
        raise
    finally:
        for proc in procs:
            proc.kill()


if __name__ == "__main__":
    main()
