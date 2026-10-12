import json
import tempfile
import unittest
from pathlib import Path

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
