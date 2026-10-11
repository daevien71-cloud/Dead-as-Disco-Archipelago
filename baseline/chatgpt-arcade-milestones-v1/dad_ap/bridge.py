"""File bridge contract for a future verified adapter; no game hooks here."""

import json
import os
import time
import uuid
from pathlib import Path

from .contract import LOCATION, ProtocolError
from .state import canonical, nonempty_identifier

WINDOWS_REPLACE_RETRY_SECONDS = 0.2
WINDOWS_REPLACE_RETRY_INTERVAL = 0.01


def _replace_published_file(temporary, path):
    # Lua/Windows readers can briefly omit FILE_SHARE_DELETE. Retry only that
    # platform's access/sharing errors, never regenerate bytes or a lease clock.
    deadline = time.monotonic() + WINDOWS_REPLACE_RETRY_SECONDS
    last_error = None
    while True:
        if last_error is not None and time.monotonic() >= deadline:
            raise last_error
        try:
            os.replace(temporary, path)
            return
        except OSError as error:
            remaining = deadline - time.monotonic()
            if os.name != 'nt' or getattr(error, 'winerror', None) not in (5, 32, 33) or remaining <= 0:
                raise
            last_error = error
            time.sleep(min(WINDOWS_REPLACE_RETRY_INTERVAL, remaining))


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(canonical(data) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        _replace_published_file(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class Bridge:
    def __init__(self, directory, state, *, enabled=False, lease_seconds=10.0):
        if type(lease_seconds) not in (int, float) or not 0 < lease_seconds <= 60:
            raise ProtocolError("Bridge lease must be positive and at most 60 seconds")
        self.directory = Path(directory)
        self.state = state
        self.enabled = enabled
        self.nonce = uuid.uuid4().hex
        self.lease_seconds = lease_seconds
        self._live_until = 0.0

    def publish(self, connected):
        now = time.time()
        duration = self.lease_seconds if connected else 0
        atomic_json(self.directory / "desired.json", {
            "schema_version": 1, "session_nonce": self.nonce,
            "connected": bool(connected), "adapter_enabled": self.enabled,
            "ability_gating": False,
            "unlock_application_enabled": False,
            "published_at_utc": now, "valid_until_utc": now + duration,
            **self.state.desired(),
        })
        # A future client heartbeat must renew the published lease. A runtime
        # consumer must independently reject an expired valid_until_utc value.
        self._live_until = time.monotonic() + duration if connected else 0.0

    def accept_event(self, event):
        if not self.enabled:
            raise ProtocolError("Runtime adapter disabled: no verified game hook is installed")
        if not isinstance(event, dict):
            raise ProtocolError("Runtime event must be an object")
        if time.monotonic() >= self._live_until:
            raise ProtocolError("Runtime event received without a live bridge lease")
        if (event.get("session_nonce") != self.nonce
                or not self.state.matches_identity(event.get("identity"))
                or event.get("origin") != "game_runtime"):
            raise ProtocolError("Stale or foreign runtime event")
        if event.get("kind") == "entitlements_applied":
            self.state.acknowledge_unlocks(event, self.nonce)
            return False
        if (event.get("kind") != "wave_cleared"
                or event.get("mode") != "arcade"
                or type(event.get("wave")) is not int
                or event["wave"] != 1
                or event.get("completed") is not True
                or not nonempty_identifier(event.get("adapter_build"))
                or not nonempty_identifier(event.get("run_id"))):
            raise ProtocolError("Event is not a verified proof-wave completion")
        self.state.observe_check(LOCATION, "game_runtime", event.get("event_id"), event)
        return True
