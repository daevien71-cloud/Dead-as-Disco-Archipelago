"""Disabled-by-default DeathLink policy; no game hooks or network implementation.

Callbacks are explicit, synchronous adapter boundaries, NOT runtime verification.
A receipt is committed before calling one. Uncertain actions are never retried:
at-most-once attempts trade a possible dropped action for no delayed/duplicate kill.
"""

from dataclasses import dataclass
import math
from pathlib import Path
import random
import sqlite3
import unicodedata

from .contract import ProtocolError
from .state import IdentityLock, canonical, fingerprint


def _number(value, *, positive=False):
    try:
        return (type(value) in (int, float) and math.isfinite(value)
                and (value > 0 if positive else value >= 0))
    except OverflowError:
        return False


def _identifier(value):
    return isinstance(value, str) and 0 < len(value) <= 200 and bool(value.strip())


def _text(value, limit):
    # Plain text only. No control, bidi, ANSI, markup interpretation or formatting.
    value = "".join(" " if unicodedata.category(c).startswith("C") else c for c in value)
    return " ".join(value.split())[:limit]


@dataclass(frozen=True)
class Identity:
    seed_name: str
    team: int
    slot: int

    def __post_init__(self):
        if not (_identifier(self.seed_name) and type(self.team) is int and self.team >= 0
                and type(self.slot) is int and self.slot > 0):
            raise ProtocolError("Invalid DeathLink seed/team/slot")

    def as_dict(self):
        return {"seed_name": self.seed_name, "team": self.team, "slot": self.slot}


@dataclass(frozen=True)
class Config:
    enabled: bool = False
    incoming_chance: float = 0.40
    outgoing_chance: float = 0.25
    max_event_age: float = 30.0
    max_future_skew: float = 5.0
    snapshot_ttl: float = 2.0

    def __post_init__(self):
        if type(self.enabled) is not bool:
            raise ProtocolError("DeathLink enabled must be boolean")
        for value in (self.incoming_chance, self.outgoing_chance):
            if not _number(value) or value > 1:
                raise ProtocolError("DeathLink probability must be between zero and one")
        for value in (self.max_event_age, self.max_future_skew, self.snapshot_ttl):
            if not _number(value) or value > 300:
                raise ProtocolError("Invalid DeathLink timing bound")


@dataclass(frozen=True)
class RuntimeSnapshot:
    """Trusted adapter observations, never fields copied from a network packet.

    life_id must remain stable through a death and across reconnects, then change
    on respawn. session_nonce changes only for a new game/adapter runtime, not
    for an AP socket reconnect. observed_at and now use the same UTC clock.
    """

    identity: Identity
    session_nonce: str
    connection_nonce: str
    life_id: str
    observed_at: float
    state: str  # playing, dead, menu, loading, unknown
    kill_verified: bool = False
    death_verified: bool = False


@dataclass(frozen=True)
class KillRequest:
    event_key: str
    identity: Identity
    session_nonce: str
    connection_nonce: str
    life_id: str
    source: str
    cause: str


@dataclass(frozen=True)
class Decision:
    status: str
    event_key: str | None = None
    roll: float | None = None
    previous_status: str | None = None


class DeathLinkPolicy:
    """One writer per identity; persistent receipts are outside all game saves.

    Only ``receive_bounced`` and ``local_death`` can call external adapters, and
    only when enabled, connected and supplied with a fresh verified snapshot.
    The current POC supplies neither adapter, and does not advertise DeathLink.
    """

    def __init__(self, directory, identity, session_nonce, source, *, config=None, rng=None):
        if not isinstance(identity, Identity) or not _identifier(session_nonce) or not _identifier(source):
            raise ProtocolError("Invalid DeathLink policy identity/session/source")
        self.identity = identity
        self.session_nonce = session_nonce
        self.source = _text(source, 200)
        if not self.source:
            raise ProtocolError("DeathLink source must have printable text")
        self.config = config if config is not None else Config()
        if not isinstance(self.config, Config):
            raise ProtocolError("Invalid DeathLink configuration")
        self.rng = rng if rng is not None else random.SystemRandom().random
        self.connection_nonce = None
        self.connected_at = None
        self.directory = Path(directory) / fingerprint(identity.as_dict())
        self.directory.mkdir(parents=True, exist_ok=True)
        self.db = None
        self.lock = IdentityLock(self.directory / "deathlink.lock")
        try:
            self.db = sqlite3.connect(self.directory / "deathlink.sqlite3")
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=FULL")
            self.db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS receipts (
                    kind TEXT NOT NULL, event_key TEXT NOT NULL, session_nonce TEXT NOT NULL,
                    connection_nonce TEXT, life_id TEXT, status TEXT NOT NULL, roll REAL,
                    observed_at REAL NOT NULL, payload TEXT NOT NULL,
                    PRIMARY KEY (kind, event_key));
                CREATE TABLE IF NOT EXISTS linked_lives (
                    session_nonce TEXT NOT NULL, life_id TEXT NOT NULL, event_key TEXT NOT NULL,
                    PRIMARY KEY (session_nonce, life_id));
                CREATE TABLE IF NOT EXISTS sent_times (time REAL PRIMARY KEY);
            """)
            with self.db:
                encoded = canonical(identity.as_dict())
                self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('identity', ?)", (encoded,))
                if self.db.execute("SELECT value FROM metadata WHERE key='identity'").fetchone()[0] != encoded:
                    raise ProtocolError("DeathLink receipt identity mismatch")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None
        self.lock.close()

    def connect(self, connection_nonce, *, now):
        """Bind after authenticated Connected; rotate nonce for every socket."""
        if not _identifier(connection_nonce) or not _number(now, positive=True):
            raise ProtocolError("Invalid DeathLink connection")
        self.connection_nonce = connection_nonce
        self.connected_at = float(now)

    def disconnect(self):
        self.connection_nonce = None
        self.connected_at = None

    def _context_reason(self, snapshot, now, *, incoming):
        if not self.config.enabled:
            return "disabled"
        if self.connection_nonce is None:
            return "disconnected"
        if not isinstance(snapshot, RuntimeSnapshot):
            return "unavailable"
        if (snapshot.identity != self.identity or snapshot.session_nonce != self.session_nonce
                or snapshot.connection_nonce != self.connection_nonce):
            return "wrong_context"
        if (not _identifier(snapshot.life_id) or not _number(snapshot.observed_at, positive=True)
                or not 0 <= now - snapshot.observed_at <= self.config.snapshot_ttl):
            return "stale_snapshot"
        if incoming:
            if snapshot.state != "playing":
                return "unavailable"
            if snapshot.kill_verified is not True:
                return "unverified_adapter"
        elif snapshot.state != "dead" or snapshot.death_verified is not True:
            return "unverified_death"
        return None

    def _old(self, kind, key):
        row = self.db.execute("SELECT status, roll FROM receipts WHERE kind=? AND event_key=?",
                              (kind, key)).fetchone()
        return Decision("duplicate", key, row[1], row[0]) if row else None

    def _save(self, kind, key, status, roll, now, payload, snapshot):
        self.db.execute("INSERT INTO receipts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (kind, key, self.session_nonce, self.connection_nonce,
                         snapshot.life_id if isinstance(snapshot, RuntimeSnapshot) else None,
                         status, roll, now, canonical(payload)))
        return Decision(status, key, roll)

    def _update(self, kind, key, status, roll):
        with self.db:
            self.db.execute("UPDATE receipts SET status=?, roll=? WHERE kind=? AND event_key=?", (status, roll, kind, key))
        return Decision(status, key, roll)

    def _roll(self):
        roll = self.rng()
        if not _number(roll) or roll >= 1:
            raise ProtocolError("DeathLink RNG must return a finite value in [0, 1)")
        return float(roll)

    def receive_bounced(self, packet, snapshot=None, *, now, kill=None):
        """Consume one authenticated socket Bounced message; never queue a kill.

        kill(request) must synchronously revalidate and act on the exact life.
        True means request accepted, NOT death proven. False guarantees no action.
        An exception/other return is uncertain and suppresses broadcasts for that
        life. A crash after receipt commit does not retry this request on restart.
        """
        if not _number(now, positive=True):
            raise ProtocolError("Invalid DeathLink time")
        if not isinstance(packet, dict) or packet.get("cmd") != "Bounced":
            return Decision("invalid_packet")
        tags = packet.get("tags")
        data = packet.get("data")
        if not (isinstance(tags, list) and len(tags) <= 128 and "DeathLink" in tags
                and all(isinstance(t, str) and len(t) <= 200 for t in tags) and isinstance(data, dict)):
            return Decision("invalid_packet")
        timestamp, source, cause = data.get("time"), data.get("source"), data.get("cause", "")
        if (not _number(timestamp, positive=True) or not _identifier(source)
                or not isinstance(cause, str) or len(cause) > 4096):
            return Decision("invalid_packet")
        timestamp = float(timestamp)
        # Raw source + normalized IEEE timestamp identify a death. Cause changes,
        # field ordering, and 1000 vs 1000.0 must not provide another RNG attempt.
        key = fingerprint({"source": source, "time": timestamp.hex()})
        payload = {"time": timestamp, "source": _text(source, 200), "cause": _text(cause, 500)}
        old = self._old("incoming", key)
        if old:
            return old
        reason = self._context_reason(snapshot, now, incoming=True)
        teams = packet.get("teams")
        if teams is not None and (not isinstance(teams, list)
                                  or any(type(t) is not int for t in teams)
                                  or self.identity.team not in teams):
            reason = "wrong_team"
        if source == self.source or self.db.execute("SELECT 1 FROM sent_times WHERE time=?", (timestamp,)).fetchone():
            reason = "self_echo"
        elif timestamp > now + self.config.max_future_skew or now - timestamp > self.config.max_event_age:
            reason = "stale_event"
        elif self.connected_at is not None and timestamp < self.connected_at:
            reason = "before_connection"
        if reason is None and kill is None:
            reason = "unavailable_adapter"
        if reason is None and self.db.execute(
                "SELECT 1 FROM linked_lives WHERE session_nonce=? AND life_id=?",
                (self.session_nonce, snapshot.life_id)).fetchone():
            reason = "linked_life_pending"
        if reason is not None:
            with self.db:
                return self._save("incoming", key, "ignored_" + reason, None, now, payload, snapshot)
        # Reserve before even drawing RNG. A crash during the RNG/commit gap is
        # consumed as decision_pending, never a fresh roll after restart.
        with self.db:
            self._save("incoming", key, "decision_pending", None, now, payload, snapshot)
        roll = None
        try:
            roll = self._roll()
        except Exception:
            reason = "rng_error"
        status = "ignored_" + reason if reason else ("kill_requested" if roll < self.config.incoming_chance else "spared")
        with self.db:
            self.db.execute("UPDATE receipts SET status=?, roll=? WHERE kind='incoming' AND event_key=?",
                            (status, roll, key))
            if status == "kill_requested":
                # Commit attribution before callback: even reentrant death
                # notification sees the marker and cannot echo a linked death.
                self.db.execute("INSERT INTO linked_lives VALUES (?, ?, ?)",
                                (self.session_nonce, snapshot.life_id, key))
        if status != "kill_requested":
            return Decision(status, key, roll)
        request = KillRequest(key, self.identity, self.session_nonce, self.connection_nonce,
                              snapshot.life_id, payload["source"], payload["cause"])
        try:
            accepted = kill(request)
        except Exception:
            accepted = None
        if accepted is False:
            with self.db:
                self.db.execute("DELETE FROM linked_lives WHERE session_nonce=? AND life_id=? AND event_key=?",
                                (self.session_nonce, snapshot.life_id, key))
            return self._update("incoming", key, "kill_declined", roll)
        return self._update("incoming", key, "kill_requested" if accepted is True else "kill_unconfirmed", roll)

    def local_death(self, death_id, snapshot, *, now, attribution="unknown", cause="", send=None):
        """Consume a fresh real death observation, with one roll per runtime life.

        attribution is natural/deathlink/unknown. Only verified natural deaths
        can broadcast. send(packet) is a synchronous one-shot transport boundary;
        True reports a send attempt, NOT recipient death/delivery. No replay queue.
        """
        if (not _identifier(death_id) or not isinstance(snapshot, RuntimeSnapshot)
                or not _identifier(snapshot.life_id) or not _number(now, positive=True)
                or attribution not in ("natural", "deathlink", "unknown")
                or not isinstance(cause, str) or len(cause) > 4096):
            raise ProtocolError("Invalid local DeathLink observation")
        # Reject foreign runtime events rather than contaminating this life's
        # natural-death receipt with another session's matching life identifier.
        if snapshot.identity != self.identity or snapshot.session_nonce != self.session_nonce:
            return Decision("ignored_wrong_context")
        key = fingerprint({"session_nonce": self.session_nonce, "life_id": snapshot.life_id})
        old = self._old("outgoing", key)
        if old:
            return old
        reason = self._context_reason(snapshot, now, incoming=False)
        linked = self.db.execute("SELECT 1 FROM linked_lives WHERE session_nonce=? AND life_id=?",
                                 (self.session_nonce, snapshot.life_id)).fetchone()
        if linked or attribution == "deathlink":
            reason = "linked_death"
        elif attribution != "natural":
            reason = "unknown_attribution"
        if reason is None and send is None:
            reason = "unavailable_transport"
        last = self.db.execute("SELECT MAX(time) FROM sent_times").fetchone()[0]
        if reason is None and last is not None and last > now + self.config.max_future_skew:
            reason = "clock_regression"
        payload = {"death_id": death_id, "attribution": attribution}
        if reason is not None:
            with self.db:
                return self._save("outgoing", key, "ignored_" + reason, None, now, payload, snapshot)
        with self.db:
            self._save("outgoing", key, "decision_pending", None, now, payload, snapshot)
        roll = None
        try:
            roll = self._roll()
        except Exception:
            reason = "rng_error"
        status = "ignored_" + reason if reason else ("broadcast_attempted" if roll < self.config.outgoing_chance else "withheld")
        with self.db:
            self.db.execute("UPDATE receipts SET status=?, roll=? WHERE kind='outgoing' AND event_key=?",
                            (status, roll, key))
            if status == "broadcast_attempted":
                timestamp = float(now) if last is None or now > last else math.nextafter(last, math.inf)
                self.db.execute("INSERT INTO sent_times VALUES (?)", (timestamp,))
        if status != "broadcast_attempted":
            return Decision(status, key, roll)
        # Cause always includes source. Arbitrary player-provided text is data.
        detail = _text(cause, 290)
        packet = {"cmd": "Bounce", "tags": ["DeathLink"], "data": {
            "time": timestamp, "source": self.source,
            "cause": f"{self.source}: {detail}" if detail else f"{self.source} died in Dead as Disco."}}
        try:
            sent = send(packet)
        except Exception:
            sent = None
        return self._update("outgoing", key,
                            "broadcast_attempted" if sent is True else "broadcast_declined" if sent is False else "broadcast_unconfirmed",
                            roll)
