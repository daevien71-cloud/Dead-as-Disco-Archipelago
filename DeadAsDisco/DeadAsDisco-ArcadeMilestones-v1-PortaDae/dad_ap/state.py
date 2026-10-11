"""Transactional AP state outside game saves; absolute desired-state unlocks.

Exactly-once side effects across processes cannot be guaranteed by a local receipt.
The bridge therefore SETS the desired entitlement set, and requires an idempotent
adapter acknowledgement. It never issues additive grants or writes a game save.
"""

import hashlib
import json
import os
import sqlite3
from pathlib import Path

from .contract import ITEM, LOCATION, UNLOCK, ProtocolError, network_item


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def fingerprint(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def nonempty_identifier(value):
    return isinstance(value, str) and bool(value.strip()) and len(value) <= 200


class IdentityLock:
    """A crash-released, nonblocking writer lock; the lock file is not a PID claim."""

    def __init__(self, path):
        self.stream = open(path, "a+b")
        try:
            if os.fstat(self.stream.fileno()).st_size == 0:
                self.stream.write(b"\0")
                self.stream.flush()
            self.stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            self.stream.close()
            raise ProtocolError("Another client owns this seed/team/slot state") from exc

    def close(self):
        # Closing the handle releases the OS lock, including after process exit.
        self.stream.close()


class State:
    def __init__(self, directory, seed, team, slot):
        if not isinstance(seed, str) or not seed or type(team) is not int or type(slot) is not int:
            raise ProtocolError("Invalid seed/team/slot identity")
        self.identity = {"seed_name": seed, "team": team, "slot": slot}
        self.key = fingerprint(self.identity)
        self.directory = Path(directory) / self.key
        self.directory.mkdir(parents=True, exist_ok=True)
        self.db = None
        self.writer_lock = IdentityLock(self.directory / "writer.lock")
        try:
            self.db = sqlite3.connect(self.directory / "state.sqlite3")
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=FULL")
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS checks (location INTEGER PRIMARY KEY, origin TEXT NOT NULL,
                                                  event_id TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS events (event_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            """)
            with self.db:
                self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('identity', ?)", (canonical(self.identity),))
                self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('inventory', '[]')")
            if not self.matches_identity(self.get("identity")):
                raise ProtocolError("State identity mismatch")
        except BaseException:
            self.close()
            raise

    def close(self):
        try:
            if self.db is not None:
                self.db.close()
                self.db = None
        finally:
            self.writer_lock.close()

    def matches_identity(self, value):
        return (isinstance(value, dict) and value.keys() == self.identity.keys()
                and all(type(value[key]) is type(expected) and value[key] == expected
                        for key, expected in self.identity.items()))

    def get(self, key):
        row = self.db.execute("SELECT value FROM metadata WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def put(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO metadata VALUES (?, ?)", (key, canonical(value)))

    @property
    def inventory(self):
        return self.get("inventory")

    def receive_items(self, index, values):
        if type(index) is not int or index < 0 or not isinstance(values, list):
            raise ProtocolError("Invalid ReceivedItems index/items")
        items = [network_item(value) for value in values]
        previous = self.inventory
        if index == 0:
            # AP specifies index zero as the complete authoritative inventory.
            updated = items
        elif index > len(previous):
            return "sync_required"
        else:
            overlap = min(len(previous) - index, len(items))
            if previous[index:index + overlap] != items[:overlap]:
                return "sync_required"
            updated = previous[:index] + items
            if len(updated) < len(previous):
                updated = previous  # A duplicate historical range cannot truncate.
        if updated == previous:
            return "unchanged"
        with self.db:
            self.put("inventory", updated)
        return "changed"

    def desired(self):
        inventory = self.inventory
        return {
            "identity": self.identity,
            "inventory_revision": fingerprint(inventory),
            "unlocks": [UNLOCK] if any(item["item"] == ITEM for item in inventory) else [],
            "unknown_item_ids": sorted({item["item"] for item in inventory if item["item"] != ITEM}),
        }

    def observe_check(self, location, origin, event_id, payload):
        if location != LOCATION or type(location) is not int:
            raise ProtocolError("Check outside the v1 location allowlist")
        if origin not in ("game_runtime", "synthetic_transport_test"):
            raise ProtocolError("Unknown event origin")
        if not isinstance(event_id, str) or not 1 <= len(event_id) <= 200:
            raise ProtocolError("Invalid event ID")
        serialized = canonical(payload)
        with self.db:
            old = self.db.execute("SELECT payload FROM events WHERE event_id=?", (event_id,)).fetchone()
            if old and old[0] != serialized:
                raise ProtocolError("Event ID reused with different content")
            self.db.execute("INSERT OR IGNORE INTO events VALUES (?, ?)", (event_id, serialized))
            self.db.execute("INSERT OR IGNORE INTO checks(location,origin,event_id) VALUES (?,?,?)",
                            (location, origin, event_id))

    def observed_checks(self):
        return [row[0] for row in self.db.execute("SELECT location FROM checks ORDER BY location")]

    def acknowledge_checks(self, locations):
        if not isinstance(locations, list) or any(type(x) is not int for x in locations):
            raise ProtocolError("Invalid checked_locations")
        with self.db:
            for location in locations:
                self.db.execute("UPDATE checks SET acknowledged=1 WHERE location=?", (location,))

    def _receipt_matches(self, receipt, nonce):
        desired = self.desired()
        return (isinstance(receipt, dict) and nonempty_identifier(nonce)
                and receipt.get("session_nonce") == nonce
                and self.matches_identity(receipt.get("identity"))
                and receipt.get("inventory_revision") == desired["inventory_revision"]
                and receipt.get("unlocks") == desired["unlocks"]
                and receipt.get("origin") == "game_runtime"
                and receipt.get("kind") == "entitlements_applied"
                and nonempty_identifier(receipt.get("adapter_build")))

    def acknowledge_unlocks(self, receipt, nonce):
        if not self._receipt_matches(receipt, nonce):
            raise ProtocolError("Stale or invalid adapter acknowledgement")
        with self.db:
            self.put("last_runtime_receipt", receipt)

    def current_runtime_receipt(self, session_nonce):
        """Return a matching current-session receipt, never an old inventory receipt."""
        receipt = self.get("last_runtime_receipt")
        return receipt if self._receipt_matches(receipt, session_nonce) else None

    def summary(self, session_nonce=None):
        rows = self.db.execute("SELECT location,origin,acknowledged FROM checks ORDER BY location")
        return {**self.desired(), "checks": [dict(zip(("location", "origin", "acknowledged"), row)) for row in rows],
                "runtime_receipt": self.current_runtime_receipt(session_nonce),
                "historical_runtime_receipt": self.get("last_runtime_receipt")}
