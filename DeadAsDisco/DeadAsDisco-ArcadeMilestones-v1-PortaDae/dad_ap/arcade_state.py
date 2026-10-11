"""Durable checks and receipt-indexed harmless credits; never game entitlements."""

from pathlib import Path
from .arcade_contract import PROFILE, LOCATIONS, ITEM, MILESTONES, DEFAULT_GOAL_WAVE, validate_identity
from .contract import ProtocolError
from .state import State as ProofState, canonical, fingerprint


class State(ProofState):
    def __init__(self, directory, seed, team, slot, *, goal_wave=DEFAULT_GOAL_WAVE):
        validate_identity({"seed_name": seed, "team": team, "slot": slot})
        if type(goal_wave) is not int or goal_wave not in MILESTONES:
            raise ProtocolError("Goal wave must be an allowed milestone")
        self.goal_wave = goal_wave
        super().__init__(Path(directory) / PROFILE, seed, team, slot)
        try:
            with self.db:
                old = self.get("profile")
                if old not in (None, PROFILE):
                    raise ProtocolError("State profile mismatch")
                self.put("profile", PROFILE)
                old_goal = self.get("goal_wave")
                if old_goal is not None and old_goal != goal_wave:
                    raise ProtocolError("Authenticated goal changed for this seed/team/slot")
                self.put("goal_wave", goal_wave)
        except BaseException:
            self.close()
            raise

    def desired(self):
        inventory = self.inventory
        return {"identity": self.identity, "profile": PROFILE,
                "inventory_revision": fingerprint(inventory), "unlocks": [],
                "unknown_item_ids": sorted({item["item"] for item in inventory if item["item"] != ITEM})}

    def observe_check(self, location, origin, event_id, payload):
        if type(location) is not int or location not in LOCATIONS or origin != "game_runtime":
            raise ProtocolError("State accepts only its allowlisted runtime milestone locations")
        if not isinstance(event_id, str) or not 1 <= len(event_id) <= 200:
            raise ProtocolError("Invalid event ID")
        if not isinstance(payload, dict) or payload.get("location") != location or payload.get("event_id") != event_id:
            raise ProtocolError("Check and event payload disagree")
        serialized = canonical(payload)
        with self.db:
            old = self.db.execute("SELECT payload FROM events WHERE event_id=?", (event_id,)).fetchone()
            if old and old[0] != serialized:
                raise ProtocolError("Event ID reused with different content")
            self.db.execute("INSERT OR IGNORE INTO events VALUES (?, ?)", (event_id, serialized))
            self.db.execute("INSERT OR IGNORE INTO checks(location,origin,event_id) VALUES (?,?,?)",
                            (location, origin, event_id))

    def acknowledge_unlocks(self, receipt, nonce):
        raise ProtocolError("Checks-only profile has no game entitlement application")

    def current_runtime_receipt(self, session_nonce):
        return None

    @property
    def goal_ready(self):
        rows = self.db.execute("SELECT location FROM checks WHERE origin='game_runtime' AND acknowledged=1")
        return 814000100 + self.goal_wave in {row[0] for row in rows}

    def record_goal_sent(self, session_nonce):
        if not self.goal_ready:
            raise ProtocolError("Goal requires the chosen local milestone acknowledged by AP")
        with self.db:
            self.put("goal_status_sent", {"status": 30, "session_nonce": session_nonce,
                                         "identity": self.identity, "locations": [814000100 + self.goal_wave]})

    def summary(self, session_nonce=None):
        result = super().summary(session_nonce)
        receipts = [{"receipt_index": index, **item} for index, item in enumerate(self.inventory) if item["item"] == ITEM]
        return {**result, "historical_runtime_receipt": None,
                "credit_count": len(receipts), "credit_receipts": receipts,
                "goal_wave": self.goal_wave,
                "goal_ready": self.goal_ready, "goal_status_sent": self.get("goal_status_sent") is not None,
                "goal_status_receipt": self.get("goal_status_sent")}
