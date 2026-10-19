import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

from ..bridge import GameBridge


def write_events(path: Path, session: str, events: list[dict]) -> None:
    lines = [{"type": "hello", "session": session}] + [dict(e, seq=i + 1) for i, e in enumerate(events)]
    path.write_text("".join(json.dumps(line) + "\n" for line in lines))


class BridgeTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.bridge = GameBridge(Path(tmp.name))
        self.events = self.bridge.events_path

    def kinds(self) -> list[str]:
        return [e["type"] for e in self.bridge.read_events()]

    def test_skip_existing_events(self) -> None:
        write_events(self.events, "yesterday", [{"type": "kill", "count": 600}, {"type": "wave", "wave": 40}])
        self.bridge.skip_existing_events()
        self.assertEqual(self.kinds(), [])
        # The game starts: new session, new file.
        write_events(self.events, "today", [{"type": "kill", "count": 1}])
        self.assertEqual(self.kinds(), ["hello", "kill"])

    def test_restart_detected_even_if_the_new_file_is_already_bigger(self) -> None:
        write_events(self.events, "first", [{"type": "kill", "count": 1}])
        self.assertEqual(self.kinds(), ["hello", "kill"])
        write_events(self.events, "second", [{"type": "kill", "count": 1}] * 20)
        events = list(self.bridge.read_events())
        self.assertEqual(len(events), 21)
        self.assertTrue(all(e["game_session"] == "second" for e in events))

    def test_appended_events_are_read_once(self) -> None:
        write_events(self.events, "s", [{"type": "kill", "count": 1}])
        self.assertEqual(self.kinds(), ["hello", "kill"])
        with self.events.open("a") as stream:
            stream.write(json.dumps({"type": "wave", "wave": 3, "seq": 2}) + "\n")
        self.assertEqual(self.kinds(), ["wave"])
        self.assertEqual(self.kinds(), [])

    def test_car_probe_and_batch_share_one_effect_key_and_require_capability(self) -> None:
        from ..client import DeadAsDiscoCommandProcessor
        processor = DeadAsDiscoCommandProcessor(SimpleNamespace(bridge=self.bridge))
        messages = []
        processor.output = messages.append
        before = self.bridge.commands_path.read_bytes()
        self.bridge.status_path.write_text(json.dumps({"effects": ["meteor"], "in_run": True}))
        self.assertFalse(processor._cmd_testeffect("car"))
        self.assertFalse(processor._cmd_testeffect("cars"))
        self.assertEqual(self.bridge.commands_path.read_bytes(), before)
        self.bridge.status_path.write_text(json.dumps({"effects": ["meteor", "cars"], "in_run": True}))
        self.assertTrue(processor._cmd_testeffect("car"))
        self.assertTrue(processor._cmd_testeffect("cars"))
        effects = [json.loads(line) for line in self.bridge.commands_path.read_text().splitlines()
                   if json.loads(line).get("type") == "effect"]
        self.assertEqual(len(effects), 2)
        self.assertTrue(all(command["effect"] == "cars" for command in effects))
        self.assertIs(effects[0]["probe"], True)
        self.assertNotIn("probe", effects[1])
        self.assertTrue(any("single-car probe" in line for line in messages))
        self.assertTrue(any("two sets of three" in line for line in messages))

    def test_ap_car_dispatch_and_saved_journal_omit_manual_probe_flag(self) -> None:
        from ..client import game_tick
        from ..data import ITEM_NAME_TO_ID, PROPHET_CAR_TRAP
        from ..tracker import Settings, Tracker
        tracker = Tracker(Settings(goal_wave=10, gold_records_required=1, waves=[10], kill_thresholds=[]),
                          self.bridge.directory / "ap-state.json")
        tracker.set_received([ITEM_NAME_TO_ID[PROPHET_CAR_TRAP]])
        self.bridge.status_path.write_text(json.dumps({"effects": ["cars"], "cars_ready": True, "in_run": True}))
        ctx = SimpleNamespace(bridge=self.bridge, tracker=tracker, slot=1, game_connected=True,
                              last_status_cleared=0, apply=AsyncMock())
        asyncio.run(game_tick(ctx))
        commands = [json.loads(line) for line in self.bridge.commands_path.read_text().splitlines()]
        effects = [command for command in commands if command.get("type") == "effect"]
        self.assertEqual(len(effects), 1)
        self.assertEqual(effects[0]["effect"], "cars")
        self.assertEqual(effects[0]["item"], PROPHET_CAR_TRAP)
        self.assertNotIn("probe", effects[0])
        saved = json.loads(tracker.state_path.read_text())
        self.assertEqual(saved["effects_done"], 0)
        self.assertEqual(saved["pending_meteor"]["command_id"], effects[0]["id"])
        self.assertEqual(saved["pending_meteor"]["effect"], "cars")
        self.assertFalse(saved["pending_meteor"]["started"])
        self.assertNotIn("probe", saved["pending_meteor"])
