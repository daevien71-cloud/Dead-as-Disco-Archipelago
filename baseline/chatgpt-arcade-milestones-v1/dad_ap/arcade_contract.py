"""Song-independent Arcade milestone contract, separate from the v1 proof."""

from pathlib import Path
from .contract import ProtocolError
from .state import fingerprint

GAME = "Dead as Disco (Arcade Milestones)"
PROFILE = "arcade_milestones_v1"
INTEGRATION_VERSION = 3
MILESTONES = (1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200)
DEFAULT_GOAL_WAVE = 20
LOCATION_NAMES = tuple(f"Arcade - Wave {wave} Clear" for wave in MILESTONES)
LOCATIONS = tuple(814000100 + wave for wave in MILESTONES)
ITEM = 814001102
ITEM_NAME = "Set Credit"
SLOT_DATA = {
    "integration_version": 3, "profile": PROFILE, "mode": "arcade_milestones",
    "location_ids": dict(zip(LOCATION_NAMES, LOCATIONS)), "item_ids": {ITEM_NAME: ITEM},
    "clear_rounds": list(MILESTONES), "confirming_advance_rounds": [wave + 1 for wave in MILESTONES],
    "song_policy": "any", "ability_gating": False, "item_effect": "none",
    "goal": "milestone_verified_clear", "goal_wave": DEFAULT_GOAL_WAVE,
    "runtime_goal_requires": ["goal_wave_verified_clear_server_acknowledged"],
    "endurance_rounds": list(MILESTONES),
}
SESSION_FIELDS = frozenset({
    "schema_version", "purpose", "profile", "integration_version", "game", "checks_enabled",
    "unlock_application_enabled", "ability_gating", "identity", "session_nonce", "locations",
    "clear_rounds", "confirming_advance_rounds", "published_at_utc", "valid_until_utc",
    "lease_revision", "adapter_build", "hook_path", "adapter_sha256", "install_id",
})
EVENT_FIELDS = frozenset({
    "schema_version", "kind", "origin", "mode", "profile", "integration_version", "identity",
    "session_nonce", "adapter_build", "hook_path", "adapter_sha256", "install_id", "wave",
    "location", "completed", "run_id", "event_id", "anchor_reinit_sequence",
    "anchor_advance_sequence", "clear_sequence", "advance_sequence", "prefix",
    "observed_context", "binding_id", "contiguous_clears",
})


def _same(expected, actual):
    if type(expected) is not type(actual):
        return False
    if isinstance(expected, dict):
        return expected.keys() == actual.keys() and all(_same(v, actual[k]) for k, v in expected.items())
    if isinstance(expected, list):
        return len(expected) == len(actual) and all(_same(a, b) for a, b in zip(expected, actual))
    return expected == actual


def validate_slot_data(value):
    if (not isinstance(value, dict)
            or any(not _same(expected, value.get(key)) for key, expected in SLOT_DATA.items() if key != "goal_wave")
            or type(value.get("goal_wave")) is not int or value["goal_wave"] not in MILESTONES):
        raise ProtocolError("Server slot does not match the arcade_milestones_v1 contract")
    return value


def state_directory(root, identity):
    return Path(root) / PROFILE / fingerprint(identity)


def validate_identity(value):
    if (not isinstance(value, dict) or value.keys() != {"seed_name", "team", "slot"}
            or not isinstance(value["seed_name"], str) or not 1 <= len(value["seed_name"]) <= 160
            or not value["seed_name"].isascii() or any(ord(c) < 32 or ord(c) == 127 for c in value["seed_name"])
            or type(value["team"]) is not int or not 0 <= value["team"] <= 2**31 - 1
            or type(value["slot"]) is not int or not 1 <= value["slot"] <= 2**31 - 1):
        raise ProtocolError("Invalid checks-only seed/team/slot identity")
    return value
