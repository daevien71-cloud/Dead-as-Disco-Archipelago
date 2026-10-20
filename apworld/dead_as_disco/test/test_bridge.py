import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

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
        self.bridge.status_path.write_text(json.dumps({"effects": ["cars"], "cars_ready": True, "in_run": True,
                                                       "clock_version": 1, "active_play": True,
                                                       "active_play_seconds": 0, "session": "game-a"}))
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
        self.assertEqual(saved["pending_effect"]["command_id"], effects[0]["id"])
        self.assertEqual(saved["pending_effect"]["command_session"], self.bridge.session)
        self.assertEqual(saved["pending_effect"]["effect"], "cars")
        self.assertFalse(saved["pending_effect"]["started"])
        self.assertNotIn("probe", saved["pending_effect"])

    def test_send_callback_sees_assigned_identity_before_command_is_written(self) -> None:
        before = self.bridge.commands_path.read_bytes()
        journal = []

        def before_send(command):
            self.assertEqual(self.bridge.commands_path.read_bytes(), before)
            self.assertEqual(command["session"], self.bridge.session)
            self.assertIsInstance(command["id"], int)
            journal.append(dict(command))

        command_id = self.bridge.send({"type": "effect", "effect": "blackout"}, before_send=before_send)
        written = json.loads(self.bridge.commands_path.read_text().splitlines()[-1])
        self.assertEqual(journal, [written])
        self.assertEqual(command_id, written["id"])

    def test_failed_before_send_journal_never_appends_unrecoverable_command(self) -> None:
        before = self.bridge.commands_path.read_bytes()

        def before_send(command):
            raise OSError("simulated state journal disk failure")

        with self.assertRaisesRegex(OSError, "state journal disk failure"):
            self.bridge.send({"type": "effect", "effect": "blackout"}, before_send=before_send)
        self.assertEqual(self.bridge.commands_path.read_bytes(), before)

    def test_client_journals_regular_effect_before_append_failure_and_restores_it(self) -> None:
        from ..client import game_tick
        from ..data import BLACKOUT_TRAP, ITEM_NAME_TO_ID
        from ..tracker import Settings, Tracker
        tracker = Tracker(Settings(goal_wave=10, gold_records_required=1, waves=[10], kill_thresholds=[]),
                          self.bridge.directory / "ap-state.json")
        tracker.set_received([ITEM_NAME_TO_ID[BLACKOUT_TRAP]])
        self.bridge.status_path.write_text(json.dumps({"in_run": True, "effect": "", "clock_version": 1,
                                                       "active_play": True, "active_play_seconds": 10,
                                                       "session": "game-a"}))
        ctx = SimpleNamespace(bridge=self.bridge, tracker=tracker, slot=1, game_connected=True,
                              last_status_cleared=0, apply=AsyncMock())
        before = self.bridge.commands_path.read_bytes()
        original_open = Path.open
        observed = []

        def fail_command_append(path, mode="r", *args, **kwargs):
            if path == self.bridge.commands_path and mode == "a":
                saved = json.loads(tracker.state_path.read_text())
                pending = saved["pending_effect"]
                self.assertEqual(pending["effect"], "blackout")
                self.assertEqual(pending["command_session"], self.bridge.session)
                self.assertFalse(pending["started"])
                observed.append(pending)
                raise OSError("simulated command append failure")
            return original_open(path, mode, *args, **kwargs)

        with patch.object(Path, "open", fail_command_append):
            with self.assertRaisesRegex(OSError, "command append failure"):
                asyncio.run(game_tick(ctx))
        self.assertEqual(len(observed), 1)
        self.assertEqual(self.bridge.commands_path.read_bytes(), before)
        again = Tracker(tracker.settings, tracker.state_path)
        self.assertEqual(again.pending_effect.command_id, observed[0]["command_id"])
        self.assertEqual(again.pending_effect.command_session, self.bridge.session)
        self.assertEqual(again.state.effects_done, 0)
        self.assertIsNone(again.next_effect_to_send(True, None))

    def test_client_journals_legacy_or_modern_session_before_append(self) -> None:
        from ..client import game_tick
        from ..data import BLACKOUT_TRAP, ITEM_NAME_TO_ID
        from ..tracker import Settings, Tracker
        original_open = Path.open
        for modern in (False, True):
            with self.subTest(modern=modern):
                tracker = Tracker(Settings(goal_wave=10, gold_records_required=1, waves=[10], kill_thresholds=[]),
                                  self.bridge.directory / f"ap-state-{modern}.json")
                tracker.set_received([ITEM_NAME_TO_ID[BLACKOUT_TRAP]])
                status = {"in_run": True, "effect": ""}
                if modern:
                    status.update(clock_version=1, active_play=True, active_play_seconds=10, session="game-a")
                self.bridge.status_path.write_text(json.dumps(status))
                ctx = SimpleNamespace(bridge=self.bridge, tracker=tracker, slot=1, game_connected=True,
                                      last_status_cleared=0, apply=AsyncMock())
                expected_session = self.bridge.session if modern else None
                before = self.bridge.commands_path.read_bytes()
                observed = []

                def observe_append(path, mode="r", *args, **kwargs):
                    if path == self.bridge.commands_path and mode == "a":
                        self.assertEqual(self.bridge.commands_path.read_bytes(), before)
                        pending = json.loads(tracker.state_path.read_text())["pending_effect"]
                        self.assertEqual(pending["command_session"], expected_session)
                        observed.append(pending)
                    return original_open(path, mode, *args, **kwargs)

                with patch.object(Path, "open", observe_append):
                    asyncio.run(game_tick(ctx))
                self.assertEqual(len(observed), 1)
                event = {"type": "effect_end", "command_id": observed[0]["command_id"]}
                if modern:
                    event["command_session"] = self.bridge.session
                tracker.handle_event(event)
                self.assertIsNone(tracker.pending_effect)
                self.assertEqual(tracker.state.effects_done, 1)

    def test_client_observes_current_clock_before_replaying_offline_completion(self) -> None:
        from ..client import game_tick
        from ..data import BLACKOUT_TRAP, ITEM_NAME_TO_ID
        from ..tracker import Settings, Tracker
        settings = Settings(goal_wave=10, gold_records_required=1, waves=[10], kill_thresholds=[])
        tracker = Tracker(settings, self.bridge.directory / "ap-state.json")
        tracker.effect_sent(7, BLACKOUT_TRAP, "blackout", command_session=self.bridge.session)
        again = Tracker(settings, tracker.state_path)
        again.set_received([ITEM_NAME_TO_ID[BLACKOUT_TRAP]] * 2)
        write_events(self.events, "game-a", [{"type": "effect_end", "command_id": 7,
                                             "command_session": self.bridge.session, "active_play_seconds": 100}])
        self.bridge.status_path.write_text(json.dumps({"in_run": True, "effect": "", "clock_version": 1,
                                                       "active_play": True, "active_play_seconds": 200,
                                                       "session": "game-a"}))
        ctx = SimpleNamespace(bridge=self.bridge, tracker=again, slot=1, game_connected=True,
                              last_status_cleared=0, apply=AsyncMock())
        before = self.bridge.commands_path.read_bytes()
        with patch.object(again.rest_rng, "randint", return_value=25) as roll:
            asyncio.run(game_tick(ctx))
            roll.assert_called_once_with(20, 30)
        self.assertEqual(again.state.effects_done, 1)
        self.assertEqual(again.state.trap_rest_remaining, 25)
        self.assertIsNone(again.pending_effect)
        self.assertEqual(self.bridge.commands_path.read_bytes(), before)
