"""Opt-in, checks-only file transport. No game hook or unlock implementation.

The producer must atomically rename complete UTF-8 JSON into events/<id>.json.
Only root-reviewed activation can enable ingestion; no activation is inferred
from a payload or diagnostic log. A file receipt is not a game-unlock receipt.
"""

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import time
import uuid

from .bridge import atomic_json
from .contract import LOCATION, SLOT_DATA, ProtocolError
from .state import nonempty_identifier

MAX_EVENT_BYTES = 16_384
MAX_DIRECTORY_ENTRIES = 64
MAX_EVENTS_PER_POLL = 16
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,119}\.json\Z")


@dataclass(frozen=True)
class CheckActivation:
    """Explicitly reviewed provenance; this does not itself prove a game hook."""

    adapter_build: str
    hook_path: str
    adapter_sha256: str

    def __post_init__(self):
        if not nonempty_identifier(self.adapter_build):
            raise ProtocolError("Pin a nonempty reviewed adapter build")
        if not isinstance(self.hook_path, str) or not self.hook_path.startswith("/") or len(self.hook_path) > 1024:
            raise ProtocolError("Pin the exact calibrated hook path")
        if not isinstance(self.adapter_sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", self.adapter_sha256):
            raise ProtocolError("Pin the reviewed adapter artifact SHA256")


@dataclass(frozen=True)
class PollResult:
    accepted: int = 0
    rejected: int = 0
    new_locations: int = 0


def _safe_path(path, *, directory=None, must_exist=False):
    """Reject links/junctions in every existing ancestor, not only the leaf."""
    path = Path(os.path.abspath(path))
    if directory is not None and not path.is_relative_to(Path(os.path.abspath(directory))):
        raise ProtocolError("Event transport path escaped its bridge directory")
    for part in (path, *path.parents):
        try:
            metadata = part.lstat()
        except FileNotFoundError:
            if part == path and must_exist:
                raise
            continue
        if (stat.S_ISLNK(metadata.st_mode)
                or getattr(metadata, "st_file_attributes", 0) & 0x400):
            raise ProtocolError("Event transport refuses links and reparse points")
    if must_exist:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ProtocolError("Event transport requires an ordinary, unshared file")
    return path


def _metadata_key(value):
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


def _opened_file_key(value):
    # Windows Python lstat/fstat disagree on ctime after atomic rename. Compare
    # identity, bytes/mtime and birthtime across APIs; compare full metadata
    # before/after using the SAME API to detect changes during the read.
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns,
            getattr(value, "st_birthtime_ns", None))


def _object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("Duplicate JSON object key")
        result[key] = value
    return result


def _invalid_number(value):
    raise ProtocolError("Nonfinite JSON number")


def _finite_float(value):
    result = float(value)
    if not math.isfinite(result):
        raise ProtocolError("Nonfinite JSON number")
    return result


class FileIngress:
    """Synchronous bounded work for the client's existing asyncio loop.

    Root must wire heartbeat every 2-3 seconds and poll only while both connected
    and inventory-ready. Neither construction nor heartbeat turns Bridge on.
    """

    def __init__(self, bridge, *, activation=None):
        if activation is not None and not isinstance(activation, CheckActivation):
            raise ProtocolError("Use an explicit reviewed CheckActivation")
        expected = Path(bridge.state.directory).absolute() / "bridge"
        if Path(bridge.directory).absolute() != expected:
            raise ProtocolError("Ingress must use this state's exact bridge directory")
        self.bridge = bridge
        self.directory = _safe_path(expected)
        self.events = self.directory / "events"
        self.archive = self.directory / "event-archive"
        self.results = self.directory / "event-results"
        self.activation = activation
        self._ready = False
        self._deadline = 0.0

    def _enabled(self, connected, inventory_ready):
        return (connected is True and inventory_ready is True
                and self.activation is not None and self.bridge.enabled is True)

    def heartbeat(self, *, connected, inventory_ready):
        enabled = self._enabled(connected, inventory_ready)
        # Revocation is in-memory first: an I/O failure must never retain a live
        # acceptance lease. Root closes the transport on any heartbeat failure.
        self._ready = False
        self._deadline = 0.0
        self.bridge._live_until = 0.0
        _safe_path(self.directory)
        now = time.time()
        self.bridge.publish(enabled)
        bridge_deadline = self.bridge._live_until
        self.bridge._live_until = 0.0
        if enabled:
            for directory in (self.events, self.archive, self.results):
                _safe_path(directory, directory=self.directory)
                directory.mkdir(parents=True, exist_ok=True)
                if not directory.is_dir():
                    raise ProtocolError("Event transport directory is not a directory")
                _safe_path(directory, directory=self.directory)
        activation = self.activation
        # Dedicated check handshake omits inventory unlocks entirely.
        atomic_json(self.directory / "check-session.json", {
            "schema_version": 1, "purpose": "checks_only", "checks_enabled": enabled,
            "unlock_application_enabled": False, "ability_gating": False,
            "identity": self.bridge.state.identity, "session_nonce": self.bridge.nonce,
            "proof_wave": SLOT_DATA["proof_wave"], "proof_location_id": LOCATION,
            "published_at_utc": now,
            "valid_until_utc": now + self.bridge.lease_seconds if enabled else now,
            "adapter_build": activation.adapter_build if activation else None,
            "hook_path": activation.hook_path if activation else None,
            "adapter_sha256": activation.adapter_sha256 if activation else None,
        })
        self.bridge._live_until = bridge_deadline
        self._ready = enabled
        self._deadline = time.monotonic() + self.bridge.lease_seconds if enabled else 0.0
        return enabled

    def _read_event(self, path, *, directory=None):
        directory = self.events if directory is None else directory
        path = _safe_path(path, directory=directory, must_exist=True)
        before = path.lstat()
        if before.st_size > MAX_EVENT_BYTES:
            return None, None, before, "Event exceeds 16384 bytes"
        with path.open("rb") as stream:
            opened = os.fstat(stream.fileno())
            if (_opened_file_key(before) != _opened_file_key(opened)
                    or not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1):
                raise ProtocolError("Opened event identity differs from the inspected ordinary file")
            data = stream.read(MAX_EVENT_BYTES + 1)
            if _metadata_key(opened) != _metadata_key(os.fstat(stream.fileno())):
                raise ProtocolError("Event changed through the opened handle during read")
        if len(data) > MAX_EVENT_BYTES:
            raise ProtocolError("Event grew beyond its allowed size during read")
        _safe_path(path, directory=directory, must_exist=True)
        if _metadata_key(before) != _metadata_key(path.lstat()):
            raise ProtocolError("Event changed during read; producer must publish atomically")
        digest = hashlib.sha256(data).hexdigest()
        try:
            event = json.loads(data.decode("utf-8"), object_pairs_hook=_object_without_duplicates,
                               parse_constant=_invalid_number, parse_float=_finite_float)
        except (UnicodeDecodeError, ValueError, RecursionError) as exc:
            return None, digest, before, f"Malformed event JSON: {type(exc).__name__}"
        return event, digest, before, None

    def poll_once(self, *, connected, inventory_ready):
        if (not self._enabled(connected, inventory_ready) or not self._ready
                or time.monotonic() >= self._deadline):
            return PollResult()
        _safe_path(self.events, directory=self.directory)
        # Count entries with a bounded iterator before parsing any event.
        entries = []
        with os.scandir(self.events) as iterator:
            for entry in iterator:
                entries.append(Path(entry.path))
                if len(entries) > MAX_DIRECTORY_ENTRIES:
                    raise ProtocolError("Event inbox exceeds its 64-entry bound")
        eligible = []
        for path in entries:
            _safe_path(path, directory=self.events, must_exist=True)
            if path.suffix == ".tmp":
                continue
            if not _NAME.fullmatch(path.name):
                raise ProtocolError("Unexpected event inbox filename")
            eligible.append(path)
        accepted = rejected = new_locations = 0
        for path in sorted(eligible)[:MAX_EVENTS_PER_POLL]:
            event, digest, metadata, rejection = self._read_event(path)
            new_location = False
            if rejection is None:
                try:
                    if not isinstance(event, dict) or event.get("kind") != "wave_cleared":
                        raise ProtocolError("Only wave_cleared is supported; unlock receipts are disabled")
                    if type(event.get("schema_version")) is not int or event["schema_version"] != 1:
                        raise ProtocolError("Unsupported event schema")
                    if (event.get("adapter_build") != self.activation.adapter_build
                            or event.get("hook_path") != self.activation.hook_path
                            or event.get("adapter_sha256") != self.activation.adapter_sha256):
                        raise ProtocolError("Event does not match the explicitly calibrated adapter build/hook")
                    previous = self.bridge.state.observed_checks()
                    self.bridge.accept_event(event)  # Durable SQLite event/check validation.
                    new_location = len(self.bridge.state.observed_checks()) > len(previous)
                except ProtocolError as exc:
                    rejection = str(exc)
            # Keep the nonce in JSON, not the basename: atomic_json appends a
            # temporary UUID, and Windows workspaces can approach MAX_PATH.
            report_id = uuid.uuid4().hex
            report = {
                "schema_version": 1, "kind": "check_event_ingestion", "source": "file_transport",
                "status": "rejected" if rejection else "accepted", "reason": rejection,
                "identity": self.bridge.state.identity, "session_nonce": self.bridge.nonce,
                "event_id": event.get("event_id") if isinstance(event, dict) else None,
                "input_filename": path.name, "input_sha256": digest,
                "new_location_recorded": new_location, "server_acknowledged": False,
                "runtime_unlock_proven": False, "adapter_sha256": self.activation.adapter_sha256,
            }
            _safe_path(path, directory=self.events, must_exist=True)
            if _metadata_key(metadata) != _metadata_key(path.lstat()):
                raise ProtocolError("Event changed before archival; durable state retained for inspection")
            _safe_path(self.archive, directory=self.directory)
            destination = self.archive / (report_id + ".json")
            if destination.exists():
                raise ProtocolError("Refusing to overwrite archived event evidence")
            path.rename(destination)
            _, archived_digest, archived_metadata, _ = self._read_event(destination, directory=self.archive)
            if (_opened_file_key(metadata) != _opened_file_key(archived_metadata)
                    or digest != archived_digest):
                raise ProtocolError("Archived event identity or hash changed; evidence retained for inspection")
            report["archive_filename"] = destination.name
            report["archive_verified"] = True
            _safe_path(self.results, directory=self.directory)
            report_path = _safe_path(self.results / (report_id + ".json"), directory=self.results)
            if report_path.exists():
                raise ProtocolError("Refusing to overwrite an event ingestion report")
            atomic_json(report_path, report)
            if rejection:
                rejected += 1
            else:
                accepted += 1
                new_locations += int(new_location)
        return PollResult(accepted, rejected, new_locations)

    def disconnect(self):
        self.heartbeat(connected=False, inventory_ready=False)
