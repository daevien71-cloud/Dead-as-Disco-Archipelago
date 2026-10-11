"""Pure simulated ownership model, NOT a Dead as Disco/Unreal runtime adapter.

No file, network, process, purchase, save, game hook, or real ability API is used.
Python object tokens are simulation-only stand-ins for opaque transient handles.
The caller supplies clocks explicitly so lease and lifecycle cases are testable.
"""

from dataclasses import dataclass, field
import math

from .contract import UNLOCK


@dataclass(frozen=True)
class SimulatedGrant:
    key: str
    owner: object


@dataclass(eq=False)
class SimulatedPawn:
    """An in-memory ledger; field names do not describe any discovered game API."""

    baseline_handles: dict = field(default_factory=dict)
    foreign_handles: dict = field(default_factory=dict)
    transient_handles: dict = field(default_factory=dict)

    @property
    def effective_moves(self):
        return frozenset(self.baseline_handles.values()) | frozenset(self.foreign_handles.values()) | frozenset(
            grant.key for grant in self.transient_handles.values())


@dataclass(frozen=True)
class ModelResult:
    status: str
    reason: str
    model_only: bool = True


def _identity(value):
    if (not isinstance(value, dict) or set(value) != {"seed_name", "team", "slot"}
            or not isinstance(value["seed_name"], str) or not value["seed_name"]
            or type(value["team"]) is not int or value["team"] < 0
            or type(value["slot"]) is not int or value["slot"] < 1):
        raise ValueError("Invalid simulated session identity")
    return value["seed_name"], value["team"], value["slot"]


def _number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


class TransientUnlockModel:
    """Only this model's recorded handles can be removed by this model.

    bind_session is an explicit trusted selection. Incoming snapshot identity
    never selects a session. Calling shutdown models graceful adapter teardown.
    """

    def __init__(self, allowed_unlocks=frozenset({UNLOCK})):
        self.allowed_unlocks = frozenset(allowed_unlocks)
        self._owner = object()
        self._identity = None
        self._nonce = None
        self._pawn = None
        self._owned = {}
        self._target = frozenset()
        self._active = False
        self._deadline = 0.0
        self._last_published = -math.inf
        self._last_signature = None
        self.created_count = 0
        self.revoked_count = 0

    @property
    def owned_handles(self):
        return dict(self._owned)

    @property
    def desired_unlocks(self):
        return self._target

    def _remove(self, key):
        token = self._owned.pop(key)
        grant = self._pawn.transient_handles.get(token) if self._pawn is not None else None
        # A recycled token or changed owner is not ours, even if the key matches.
        if grant is not None and grant.owner is self._owner and grant.key == key:
            del self._pawn.transient_handles[token]
            self.revoked_count += 1

    def _remove_all(self):
        for key in list(self._owned):
            self._remove(key)

    def _deactivate(self):
        self._remove_all()
        self._target = frozenset()
        self._active = False
        self._deadline = 0.0

    def bind_session(self, identity, nonce):
        identity_key = _identity(identity)
        if not isinstance(nonce, str) or not nonce.strip() or len(nonce) > 200:
            raise ValueError("Invalid simulated session nonce")
        if (identity_key, nonce) == (self._identity, self._nonce):
            return
        self._deactivate()
        self._identity, self._nonce = identity_key, nonce
        self._last_published = -math.inf
        self._last_signature = None

    def attach_pawn(self, pawn, monotonic_now):
        if pawn is not None and not isinstance(pawn, SimulatedPawn):
            raise TypeError("This model accepts only SimulatedPawn instances")
        self.poll(monotonic_now)
        if pawn is not self._pawn:
            self._remove_all()
            self._pawn = pawn
        self._apply()

    def _apply(self):
        if not self._active or self._pawn is None:
            return
        for key, token in list(self._owned.items()):
            grant = self._pawn.transient_handles.get(token)
            if grant is None or grant.owner is not self._owner or grant.key != key:
                del self._owned[key]  # Never delete a token now owned elsewhere.
        for key in list(self._owned):
            if key not in self._target:
                self._remove(key)
        for key in sorted(self._target):
            externally_available = (key in self._pawn.baseline_handles.values()
                                    or key in self._pawn.foreign_handles.values()
                                    or any(grant.key == key and grant.owner is not self._owner
                                           for grant in self._pawn.transient_handles.values()))
            if externally_available:
                if key in self._owned:
                    self._remove(key)
            elif key not in self._owned:
                token = object()
                self._pawn.transient_handles[token] = SimulatedGrant(key, self._owner)
                self._owned[key] = token
                self.created_count += 1

    def poll(self, monotonic_now):
        if not _number(monotonic_now):
            raise ValueError("Supply a finite monotonic clock value")
        if self._active and monotonic_now >= self._deadline:
            self._deactivate()
        self._apply()

    def receive(self, snapshot, *, utc_now, monotonic_now):
        """Validate a bridge-shaped simulated input and reconcile the desired set.

        Rejection revokes owned grants. A newer valid publication is then needed
        to resume. Duplicate publications never extend the monotonic deadline.
        """
        if not _number(utc_now):
            raise ValueError("Supply a finite UTC epoch clock value")
        self.poll(monotonic_now)
        try:
            if not isinstance(snapshot, dict):
                raise ValueError("Snapshot must be an object")
            if self._identity is None or _identity(snapshot.get("identity")) != self._identity:
                raise ValueError("Snapshot belongs to an unbound or different identity")
            if snapshot.get("session_nonce") != self._nonce:
                raise ValueError("Snapshot belongs to a different session")
            if type(snapshot.get("schema_version")) is not int or snapshot["schema_version"] != 1:
                raise ValueError("Unsupported simulated snapshot schema")
            if any(type(snapshot.get(key)) is not bool for key in ("connected", "adapter_enabled", "ability_gating")):
                raise ValueError("Snapshot status fields must be Boolean")
            if snapshot["ability_gating"]:
                raise ValueError("This additive proof model cannot gate baseline moves")
            unlocks = snapshot.get("unlocks")
            if (not isinstance(unlocks, list) or any(not isinstance(key, str) for key in unlocks)
                    or not set(unlocks) <= self.allowed_unlocks):
                raise ValueError("Unsupported simulated unlock key")
            revision = snapshot.get("inventory_revision")
            if not isinstance(revision, str) or len(revision) != 64 or any(c not in "0123456789abcdef" for c in revision):
                raise ValueError("Invalid inventory revision")
            published, expires = snapshot.get("published_at_utc"), snapshot.get("valid_until_utc")
            if (not _number(published) or not _number(expires) or published > utc_now
                    or not 0 <= expires - published <= 60):
                raise ValueError("Invalid, future-dated, or excessive bridge lease")
            target = frozenset(unlocks)
            signature = (revision, target, published, expires, snapshot["connected"], snapshot["adapter_enabled"])
            if published < self._last_published:
                raise ValueError("Out-of-order publication")
            if published == self._last_published:
                if signature != self._last_signature or not self._active:
                    raise ValueError("Conflicting or retired publication; require a newer heartbeat")
                self._apply()
                return ModelResult("active", "Duplicate desired set; original lease retained")
            self._last_published, self._last_signature = published, signature
            if not snapshot["connected"] or not snapshot["adapter_enabled"] or expires <= utc_now:
                self._deactivate()
                return ModelResult("inactive", "Disconnected, disabled, or expired snapshot")
            self._target = target
            self._deadline = monotonic_now + (expires - utc_now)
            self._active = True
            self._apply()
            return ModelResult("active", "Simulated desired set reconciled")
        except ValueError as exc:
            self._deactivate()
            return ModelResult("rejected", str(exc))

    def shutdown(self):
        self._deactivate()
        self._identity = None
        self._nonce = None
        self._pawn = None
        self._last_published = -math.inf
        self._last_signature = None
