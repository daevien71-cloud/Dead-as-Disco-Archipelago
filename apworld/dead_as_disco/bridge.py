"""File bridge between the AP client and the UE4SS mod.

All files live in %LOCALAPPDATA%/DeadAsDiscoAP:
  events.jsonl    game -> client, one JSON object per line. The mod truncates it on game start.
  commands.jsonl  client -> game, one JSON object per line. The client truncates it on client start.
  status.json     game -> client heartbeat, rewritten about once a second.
"""

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any, Iterator, Optional

HEARTBEAT_TIMEOUT = 5.0


def default_bridge_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA") or str(Path.home())
    return Path(base) / "DeadAsDiscoAP"


class GameBridge:
    def __init__(self, directory: Optional[Path] = None):
        self.directory = Path(directory) if directory else default_bridge_dir()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.events_path = self.directory / "events.jsonl"
        self.commands_path = self.directory / "commands.jsonl"
        self.status_path = self.directory / "status.json"
        self.session = uuid.uuid4().hex[:12]
        self._next_id = 1
        self._events_offset = 0
        self._partial = b""
        self._game_session: Optional[str] = None
        self._last_status: Optional[dict[str, Any]] = None
        self._last_status_at = 0.0
        # Start a fresh command stream; the mod notices the shrink and rewinds.
        self.commands_path.write_text(json.dumps({"type": "hello", "session": self.session}) + "\n",
                                      encoding="utf-8")

    def send(self, command: dict[str, Any]) -> int:
        command = dict(command, session=self.session, id=self._next_id)
        self._next_id += 1
        with self.commands_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(command, separators=(",", ":")) + "\n")
            stream.flush()
        return command["id"]

    def read_events(self) -> Iterator[dict[str, Any]]:
        """New events since the last call. Each carries the game session it came from as
        "game_session", so callers can skip events they already handled before a restart."""
        try:
            size = self.events_path.stat().st_size
        except FileNotFoundError:
            return
        if size < self._events_offset:
            # The game restarted and truncated the file.
            self._events_offset, self._partial = 0, b""
        if size == self._events_offset:
            return
        with self.events_path.open("rb") as stream:
            stream.seek(self._events_offset)
            data = stream.read(size - self._events_offset)
        self._events_offset += len(data)
        data = self._partial + data
        lines = data.split(b"\n")
        self._partial = lines.pop()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(event, dict):
                if event.get("type") == "hello":
                    self._game_session = event.get("session")
                event["game_session"] = self._game_session
                yield event

    def status(self) -> Optional[dict[str, Any]]:
        """The game's latest heartbeat, or None when the game isn't running the mod."""
        try:
            status = json.loads(self.status_path.read_text(encoding="utf-8"))
            if isinstance(status, dict):
                self._last_status, self._last_status_at = status, os.path.getmtime(self.status_path)
        except (OSError, ValueError):
            pass  # caught the game mid-rewrite; fall back to the previous heartbeat
        if self._last_status is None or time.time() - self._last_status_at > HEARTBEAT_TIMEOUT:
            return None
        return self._last_status

    def in_run(self) -> bool:
        status = self.status()
        return bool(status and status.get("in_run"))
