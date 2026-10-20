"""End-to-end test: real AP server + two Dead as Disco clients + two fake games.

The fake games write the same bridge files the UE4SS mod writes, so this exercises the
client, the world, the server protocol and DeathLink without the real game.

Usage: python run_e2e.py <Archipelago source dir with worlds/dead_as_disco installed>
"""

import json
import os
import re
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
        self.session = "fake"
        self.in_run = False
        self.paused = False
        self.active_play_seconds = 0.0
        self.clock_at = time.monotonic()
        self.lock = threading.RLock()
        self.cleared = 0
        self.commands_seen: list[dict] = []
        self.events_seen: list[dict] = []
        self.meteor_command: dict | None = None
        self.car_command: dict | None = None
        self.offset = 0
        self.stop = threading.Event()
        (self.dir / "events.jsonl").write_text(json.dumps({"type": "hello", "session": self.session}) + "\n")
        threading.Thread(target=self.loop, daemon=True).start()

    def clock_fields(self) -> dict:
        with self.lock:
            now = time.monotonic()
            active = self.in_run and not self.paused
            if active:
                self.active_play_seconds += now - self.clock_at
            self.clock_at = now
            return {"clock_version": 1, "active_play": active, "active_play_seconds": self.active_play_seconds}

    def set_paused(self, paused: bool) -> None:
        with self.lock:
            self.clock_fields()  # account for the old pause state before changing it
            self.paused = paused

    def advance_active_play(self, seconds: float) -> None:
        """Controlled fake-game time for later rests; never used against a real game bridge."""
        with self.lock:
            assert self.in_run and not self.paused and seconds >= 0
            self.clock_fields()
            self.active_play_seconds += seconds

    def emit(self, **event) -> None:
        with self.lock:
            self.seq += 1
            event.update(seq=self.seq, t=time.time(), **self.clock_fields())
            self.events_seen.append(dict(event))
            with (self.dir / "events.jsonl").open("a") as stream:
                stream.write(json.dumps(event) + "\n")

    def loop(self) -> None:
        while not self.stop.is_set():
            (self.dir / "status.json").write_text(json.dumps(
                {"t": time.time(), "session": self.session, "in_run": self.in_run,
                 "round": self.cleared + 1, "cleared": self.cleared, **self.clock_fields(),
                 "effects": ["slowmo", "fastforward", "molasses", "blackout", "fever", "meteor", "cars"],
                 "meteor_ready": self.in_run and not self.paused and self.meteor_command is None and self.car_command is None,
                 "cars_ready": self.in_run and not self.paused and self.meteor_command is None and self.car_command is None,
                 "effect": "meteor" if self.meteor_command else ("cars" if self.car_command else "")}))
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
            if command["effect"] == "meteor":
                self.meteor_command = command
                self.emit(type="effect_start", effect="meteor", command_id=command["id"],
                          command_session=command["session"], meteor_count=5)
            elif command["effect"] == "cars":
                self.car_command = command
                self.emit(type="effect_start", effect="cars", command_id=command["id"],
                          command_session=command["session"], car_sets=2, car_count=6)
            else:
                self.emit(type="effect_start", effect=command["effect"], command_id=command["id"],
                          command_session=command["session"])
                self.emit(type="effect_end", effect=command["effect"], command_id=command["id"],
                          command_session=command["session"], reason="expired")
        elif command["type"] == "kill":
            self.in_run = False
            self.emit(type="death")

    def finish_meteor(self) -> None:
        command, self.meteor_command = self.meteor_command, None
        assert command is not None
        self.emit(type="effect_end", effect="meteor", command_id=command["id"],
                  command_session=command["session"], meteor_count=5, reason="native_finished")

    def finish_cars(self) -> None:
        command, self.car_command = self.car_command, None
        assert command is not None
        self.emit(type="effect_end", effect="cars", command_id=command["id"],
                  command_session=command["session"], car_sets=2, car_count=6, reason="native_finished")


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
  effect_duration: 5
  start_inventory: {Gold Record: 1, Slow-Mo Trap: 1, Meteor Trap: 1, Prophet Car Trap: 1, Blackout Trap: 1}
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
        logs.setdefault(name, [])

        def pump() -> None:
            for line in proc.stdout:
                logs[name].append(line.rstrip())
        threading.Thread(target=pump, daemon=True).start()
        procs.append(proc)
        return proc

    def seen(name: str, text: str) -> bool:
        # Client output is coloured; match against the plain text.
        return any(text in re.sub(r"\x1b\[[0-9;]*m", "", line) for line in logs[name])

    try:
        start("server", ["MultiServer.py", "--port", str(PORT), "--host", "127.0.0.1", str(archive)])
        wait_for(lambda: seen("server", "Hosting game"), "server start")
        # A's game isn't running yet, and its event log still holds yesterday's session: 600 kills, wave 40.
        bridge_a = work / "bridge_a"
        bridge_a.mkdir()
        (bridge_a / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in [
            {"type": "hello", "session": "yesterday"}, {"type": "kill", "count": 600, "seq": 1},
            {"type": "wave", "wave": 40, "seq": 2}]))
        game_b = FakeGame(work / "bridge_b")
        launch = "from worlds.dead_as_disco.client import launch; import sys; launch(*sys.argv[1:])"
        args_a = ["-c", launch, "--nogui", "--connect", f"127.0.0.1:{PORT}", "--name", "DiscoDae",
                  "--bridge-dir", str(bridge_a)]
        client_a = start("a", args_a)
        start("b", ["-c", launch, "--nogui", "--connect", f"127.0.0.1:{PORT}", "--name", "DiscoFriend",
                    "--bridge-dir", str(game_b.dir)])
        wait_for(lambda: seen("a", "Goal: collect 1 Gold Records") and seen("b", "Goal:"), "both clients connected")
        wait_for(lambda: any((bridge_a / "state").glob("*_0_1.json")), "client saves progress")
        assert not any((bridge_a / "state").glob("None_*")), "progress saved without a seed name"
        print("PASS clients connect and read slot data")

        wait_for(lambda: seen("a", "New multiworld: kills and waves count from zero"), "fresh-start notice")
        time.sleep(2)
        assert not seen("a", "(Arcade - "), "events from before joining this multiworld were counted"
        game_a = FakeGame(bridge_a)  # now the game starts; real play must count
        print("PASS a new multiworld ignores waves and kills from before you joined")

        # Traps wait for a run, then fire.
        time.sleep(1.5)
        assert not any(c["type"] == "effect" for c in game_a.commands_seen), "effect sent outside a run"
        game_a.in_run = True
        game_a.emit(type="run_start")
        wait_for(lambda: any(c.get("effect") == "slowmo" for c in game_a.commands_seen), "slow-mo trap sent in run")
        wait_for(lambda: seen("a", "Slow-Mo Trap wore off"), "trap lifecycle logged")
        print("PASS trap waits for a run, then fires and ends")

        state_path = next((bridge_a / "state").glob("*_0_1.json"))
        state_now = lambda: json.loads(state_path.read_text())
        sent = lambda effect: any(c.get("effect") == effect for c in game_a.commands_seen)
        event_time = lambda effect, kind: next(e["active_play_seconds"] for e in game_a.events_seen
                                              if e.get("effect") == effect and e["type"] == kind)

        # One real 20-30s rest: freeze the game clock, then reconnect after the fake game advanced
        # 45 active seconds with the client offline. Neither pause nor offline time may spend the rest.
        wait_for(lambda: state_now().get("trap_rest_remaining", 0) > 0, "rest saved after Slow-Mo")
        game_a.set_paused(True)
        time.sleep(1)
        resting = state_now()["trap_rest_remaining"]
        assert 19 <= resting <= 30, f"expected a freshly rolled 20-30s rest, got {resting}"
        assert not sent("meteor"), "meteor skipped the post-trap rest"
        time.sleep(1)
        assert abs(state_now()["trap_rest_remaining"] - resting) < 0.05, "paused game spent trap rest"
        connections = sum("Goal: collect" in line for line in logs["a"])
        client_a.stdin.write("/exit\n")
        client_a.stdin.flush()
        client_a.wait(timeout=10)
        game_a.set_paused(False)
        game_a.advance_active_play(45)
        game_a.set_paused(True)
        time.sleep(0.5)  # publish the advanced clock while the client is still offline
        client_a = start("a", args_a)
        wait_for(lambda: sum("Goal: collect" in line for line in logs["a"]) > connections, "A reconnected during rest")
        time.sleep(1)
        assert abs(state_now()["trap_rest_remaining"] - resting) < 0.05, "restart rerolled or spent offline rest"
        assert not sent("meteor"), "restart bypassed trap rest"
        resumed_at = game_a.clock_fields()["active_play_seconds"]
        game_a.set_paused(False)
        wait_for(lambda: sent("meteor"), "meteor after remaining active-play rest", timeout=40)
        wait_for(lambda: seen("a", "Meteor Trap is active"), "five-meteor batch started")
        elapsed = event_time("meteor", "effect_start") - resumed_at
        assert resting - 0.25 <= elapsed <= resting + 3, (resting, elapsed)
        print("PASS random trap rest pauses, survives client restart, and gives no offline time credit")

        def advance_rest(next_effect: str, previous_effect: str, rest_started_at: float | None = None) -> None:
            """Check the next rest boundary without adding another 20-30 wall seconds per native batch."""
            wait_for(lambda: state_now().get("trap_rest_remaining", 0) > 0, f"rest saved after {previous_effect}")
            remaining = state_now()["trap_rest_remaining"]
            assert 19 <= remaining <= 30, remaining
            assert not sent(next_effect), f"{next_effect} skipped rest after {previous_effect}"
            game_a.advance_active_play(max(0, remaining - 5))
            wait_for(lambda: state_now()["trap_rest_remaining"] < 6, "controlled active time applied to rest")
            assert state_now()["trap_rest_remaining"] > 0 and not sent(next_effect), "next trap fired before rest ended"
            game_a.advance_active_play(state_now()["trap_rest_remaining"] + 0.5)
            wait_for(lambda: sent(next_effect), f"{next_effect} after {previous_effect} rest", timeout=40)
            wait_for(lambda: any(e.get("effect") == next_effect and e["type"] == "effect_start"
                                 for e in game_a.events_seen), f"{next_effect} start event")
            if rest_started_at is None:
                rest_started_at = event_time(previous_effect, "effect_end")
            gap = event_time(next_effect, "effect_start") - rest_started_at
            assert 20 <= gap <= 35, (previous_effect, next_effect, gap)

        # The fake game holds one five-meteor batch past the old (5 + 15)-second watchdog and its
        # 3-second dispatch gap. A queued Blackout must wait through the whole batch, even after restart.
        time.sleep(24)
        assert not any(c.get("effect") == "cars" for c in game_a.commands_seen), "cars interrupted meteor batch"
        assert not any(c.get("effect") == "blackout" for c in game_a.commands_seen), "Blackout interrupted batch"
        state = json.loads(state_path.read_text())
        assert state["effects_done"] == 2 and state["pending_meteor"]["consumed"], state
        connections = sum("Goal: collect" in line for line in logs["a"])
        client_a.stdin.write("/exit\n")
        client_a.stdin.flush()
        client_a.wait(timeout=10)
        client_a = start("a", args_a)
        wait_for(lambda: sum("Goal: collect" in line for line in logs["a"]) > connections, "A reconnected mid-batch")
        time.sleep(1)
        assert sum(c.get("effect") == "meteor" for c in game_a.commands_seen) == 1, "restart replayed batch"
        assert not any(c.get("effect") == "cars" for c in game_a.commands_seen), "restart overlapped native batches"
        assert not any(c.get("effect") == "blackout" for c in game_a.commands_seen), "restart interrupted batch"
        game_a.finish_meteor()
        wait_for(lambda: seen("a", "Meteor Trap wore off"), "meteor item completed")
        assert sum(c.get("effect") == "meteor" for c in game_a.commands_seen) == 1, "meteor repeated"
        state = json.loads(state_path.read_text())
        assert state["effects_done"] == 2, state
        advance_rest("cars", "meteor")
        print("PASS five-meteor batch survives watchdog and client restart, consumes one item, then releases queue")

        wait_for(lambda: seen("a", "Prophet Car Trap is active"), "two-set car trap started")
        # Both sets and the wait between them stay one active effect. Hold it beyond the ordinary
        # watchdog, then restart the client to verify the same journal protects cars and meteors.
        time.sleep(24)
        assert not any(c.get("effect") == "blackout" for c in game_a.commands_seen), "Blackout interrupted cars"
        state = json.loads(state_path.read_text())
        assert state["effects_done"] == 3 and state["pending_meteor"]["effect"] == "cars", state
        assert state["pending_meteor"]["consumed"], state
        connections = sum("Goal: collect" in line for line in logs["a"])
        client_a.stdin.write("/exit\n")
        client_a.stdin.flush()
        client_a.wait(timeout=10)
        client_a = start("a", args_a)
        wait_for(lambda: sum("Goal: collect" in line for line in logs["a"]) > connections, "A reconnected during cars")
        time.sleep(1)
        assert sum(c.get("effect") == "cars" for c in game_a.commands_seen) == 1, "restart replayed car trap"
        assert not any(c.get("effect") == "blackout" for c in game_a.commands_seen), "restart interrupted cars"

        # A pending trap can finish while the client is offline. Historical end events must start
        # a fresh rest on reconnect, not spend it using game time the client never observed.
        connections = sum("Goal: collect" in line for line in logs["a"])
        client_a.stdin.write("/exit\n")
        client_a.stdin.flush()
        client_a.wait(timeout=10)
        game_a.finish_cars()
        game_a.advance_active_play(45)
        game_a.set_paused(True)
        time.sleep(0.5)
        client_a = start("a", args_a)
        wait_for(lambda: sum("Goal: collect" in line for line in logs["a"]) > connections,
                 "A reconnected after cars ended offline")
        wait_for(lambda: seen("a", "Prophet Car Trap wore off"), "car trap completed")
        state = json.loads(state_path.read_text())
        assert state["effects_done"] == 3 and state["pending_meteor"] is None, state
        assert sum(c.get("effect") == "cars" for c in game_a.commands_seen) == 1, "car trap repeated"
        assert sum(c.get("effect") == "meteor" for c in game_a.commands_seen) == 1, "earlier meteor repeated"
        assert 20 <= state["trap_rest_remaining"] <= 30, state
        assert not sent("blackout"), "offline car completion bypassed the rest"
        time.sleep(1)
        assert state_now()["trap_rest_remaining"] == state["trap_rest_remaining"], "paused reconnect spent rest"
        # The 45 offline seconds intentionally separate the historical event and the live rest.
        # Use the reconnect clock for the boundary assertion below.
        rest_started_at = game_a.clock_fields()["active_play_seconds"]
        game_a.set_paused(False)
        advance_rest("blackout", "cars", rest_started_at)
        print("PASS native trap ending offline starts a full rest on reconnect without replay")
        print("PASS two-set car trap survives watchdog and client restart, consumes one item, then releases queue")

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

        # /testdeathlink reaches only the sender's slot, then rolls (100% in this seed) and kills.
        game_a.in_run = True
        time.sleep(1.5)
        b_kills = sum(c["type"] == "kill" for c in game_b.commands_seen)
        client_a.stdin.write("/testdeathlink Robo\n")
        client_a.stdin.flush()
        # A may own Mirror Ball Shields from its own checks, so a block counts as well as a kill.
        wait_for(lambda: any(c["type"] == "kill" and c.get("source") == "Robo" for c in game_a.commands_seen)
                 or seen("a", "Shield blocked it"), "test DeathLink kills the sender or hits a shield")
        wait_for(lambda: any(("Robo died and takes you down" in c.get("text", "")
                              or "blocked Robo's DeathLink" in c.get("text", "")) for c in game_a.commands_seen),
                 "test DeathLink pop-up")
        time.sleep(2)
        assert sum(c["type"] == "kill" for c in game_b.commands_seen) == b_kills, "test DeathLink reached another slot"
        assert not seen("b", "Robo"), "test DeathLink showed up in another player's client"
        print("PASS /testdeathlink goes only to your own slot")

        client_a.stdin.write("/disco\n")
        client_a.stdin.flush()
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
            if proc.poll() is None:
                proc.kill()


if __name__ == "__main__":
    main()
