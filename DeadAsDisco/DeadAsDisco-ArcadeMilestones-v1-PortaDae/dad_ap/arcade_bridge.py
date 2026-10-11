"""Validate the three-clear adapter's anchored callback prefix, without unlocks."""

import re
import time
from .bridge import Bridge as ProofBridge
from .arcade_contract import EVENT_FIELDS, PROFILE, LOCATIONS, MILESTONES
from .contract import ProtocolError


def _sequence(value):
    return type(value) is int and 1 <= value <= 2**31 - 1


class Bridge(ProofBridge):
    def __init__(self, directory, state, *, activation=None):
        super().__init__(directory, state, enabled=activation is not None, lease_seconds=10)
        self.activation = activation

    def accept_event(self, event):
        if not self.enabled or self.activation is None or time.monotonic() >= self._live_until:
            raise ProtocolError("Runtime event received without an enabled live checks lease")
        if not isinstance(event, dict) or event.keys() != EVENT_FIELDS:
            raise ProtocolError("Runtime event fields do not match the three-clear contract")
        a = self.activation
        fixed = {"schema_version": 1, "kind": "wave_cleared", "origin": "game_runtime",
                 "mode": "arcade", "profile": PROFILE, "integration_version": 3,
                 "session_nonce": self.nonce, "adapter_build": a.adapter_build,
                 "hook_path": a.hook_path, "adapter_sha256": a.adapter_sha256,
                 "install_id": a.install_id, "completed": True}
        if any(type(event[k]) is not type(v) or event[k] != v for k, v in fixed.items()):
            raise ProtocolError("Stale, foreign or incompatible three-clear event")
        if not self.state.matches_identity(event["identity"]):
            raise ProtocolError("Foreign runtime identity")
        wave = event["wave"]
        if type(wave) is not int or wave not in MILESTONES or type(event["location"]) is not int or event["location"] != 814000100 + wave:
            raise ProtocolError("Wave/location mismatch")
        if type(event["contiguous_clears"]) is not int or event["contiguous_clears"] != wave:
            raise ProtocolError("Milestone lacks its contiguous runtime clear count")
        run = event["run_id"]
        if not isinstance(run, str) or not re.fullmatch(re.escape(a.install_id) + r"-[1-9][0-9]{0,9}", run):
            raise ProtocolError("Invalid installed run identifier")
        if event["event_id"] != f"{self.nonce}-{run}-wave{wave}":
            raise ProtocolError("Event ID must bind nonce, run and wave")
        for key, maximum in (("observed_context", 1024), ("binding_id", 200)):
            value = event[key]
            if not isinstance(value, str) or not value.strip() or len(value) > maximum or any(ord(c) < 32 for c in value):
                raise ProtocolError("Missing or invalid observed runtime binding")
        reinit, advance = event["anchor_reinit_sequence"], event["anchor_advance_sequence"]
        if not _sequence(reinit) or not _sequence(advance) or reinit >= advance:
            raise ProtocolError("Invalid fresh-run anchor")
        prefix = event["prefix"]
        if not isinstance(prefix, list) or len(prefix) != 1:
            raise ProtocolError("Milestone must carry one bounded terminal clear pair")
        previous = advance
        for pair in prefix:
            if (not isinstance(pair, dict) or pair.keys() != {"wave", "clear_sequence", "advance_sequence"}
                    or type(pair["wave"]) is not int or pair["wave"] != wave
                    or not _sequence(pair["clear_sequence"]) or not _sequence(pair["advance_sequence"])
                    or not previous < pair["clear_sequence"] < pair["advance_sequence"]):
                raise ProtocolError("Noncontiguous or reordered clear prefix")
            previous = pair["advance_sequence"]
        if (type(event["clear_sequence"]) is not int or type(event["advance_sequence"]) is not int
                or event["clear_sequence"] != prefix[-1]["clear_sequence"]
                or event["advance_sequence"] != prefix[-1]["advance_sequence"]):
            raise ProtocolError("Event terminal sequence differs from prefix")
        self.state.observe_check(814000100 + wave, "game_runtime", event["event_id"], event)
        return True
