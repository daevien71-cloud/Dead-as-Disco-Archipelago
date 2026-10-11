"""Explicitly pinned checks-only session publication and bounded file ingestion."""

from dataclasses import dataclass
import math
import re
import time
from .arcade_contract import GAME, PROFILE, LOCATIONS, MILESTONES
from .bridge import atomic_json
from .contract import ProtocolError
from .file_ingress import CheckActivation as ProofActivation, FileIngress as ProofIngress, _safe_path


@dataclass(frozen=True)
class CheckActivation(ProofActivation):
    install_id: str

    def __post_init__(self):
        super().__post_init__()
        if not isinstance(self.install_id, str) or not re.fullmatch(r"[a-f0-9]{32}", self.install_id):
            raise ProtocolError("Pin an install ID of exactly 32 lowercase hexadecimal characters")
        if self.adapter_build != "dad-arcade-milestones-v1-" + self.install_id:
            raise ProtocolError("Adapter build must match its checks-only install ID")


class FileIngress(ProofIngress):
    def __init__(self, bridge, *, activation=None):
        if not isinstance(activation, CheckActivation):
            raise ProtocolError("Use an explicit three-clear CheckActivation")
        super().__init__(bridge, activation=activation)
        self.lease_revision = 0

    def heartbeat(self, *, connected, inventory_ready):
        enabled = self._enabled(connected, inventory_ready)
        self._ready = False
        self._deadline = 0.0
        self.bridge._live_until = 0.0
        _safe_path(self.directory)
        started = time.monotonic()
        now = math.floor(time.time())
        expires = now + 10 if enabled else now
        self.bridge.publish(enabled)
        self.bridge._live_until = 0.0
        if enabled:
            for directory in (self.events, self.archive, self.results):
                _safe_path(directory, directory=self.directory)
                directory.mkdir(parents=True, exist_ok=True)
                _safe_path(directory, directory=self.directory)
                if not directory.is_dir():
                    raise ProtocolError("Event transport directory is not a directory")
        self.lease_revision += 1
        a = self.activation
        atomic_json(_safe_path(self.directory / "check-session.json", directory=self.directory), {
            "schema_version": 1, "purpose": "checks_only", "profile": PROFILE,
            "integration_version": 3, "game": GAME, "checks_enabled": enabled,
            "unlock_application_enabled": False, "ability_gating": False,
            "identity": self.bridge.state.identity, "session_nonce": self.bridge.nonce,
            "locations": list(LOCATIONS), "clear_rounds": list(MILESTONES),
            "confirming_advance_rounds": [wave + 1 for wave in MILESTONES], "published_at_utc": now,
            "valid_until_utc": expires, "lease_revision": self.lease_revision,
            "adapter_build": a.adapter_build, "hook_path": a.hook_path,
            "adapter_sha256": a.adapter_sha256, "install_id": a.install_id,
        })
        # Bound elapsed write time and fractional UTC conservatively. Publishing
        # identical bytes late must never manufacture a fresh local lease.
        deadline = min(started + 9.0, time.monotonic() + max(0.0, expires - time.time())) if enabled else 0.0
        self._deadline = self.bridge._live_until = deadline
        self._ready = enabled and time.monotonic() < deadline
        return self._ready
