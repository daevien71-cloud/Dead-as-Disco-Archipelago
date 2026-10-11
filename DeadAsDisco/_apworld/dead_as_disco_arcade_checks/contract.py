"""Versioned song-independent Arcade milestone checks; no item effects."""
GAME_NAME = "Dead as Disco (Arcade Milestones)"
PROFILE = "arcade_milestones_v1"
INTEGRATION_VERSION = 3
WORLD_VERSION = "0.3.0"
MILESTONES = (1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200)
DEFAULT_GOAL_WAVE = 20
CREDIT_NAME = "Set Credit"
CREDIT_ID = 814_001_102
LOCATION_IDS = {f"Arcade - Wave {wave} Clear": 814_000_100 + wave for wave in MILESTONES}
ITEM_IDS = {CREDIT_NAME: CREDIT_ID}
LOGIC_EVENTS = {name: (f"Logic - {name} Reachable", f"Logic - {name} Reachability") for name in LOCATION_IDS}
PROTECTED_PROOF_IDS = {814_000_001, 814_001_001}
RETIRED_CANDIDATE_PERMIT_ID = 814_001_101


def make_slot_data(goal_wave=DEFAULT_GOAL_WAVE):
    if type(goal_wave) is not int or goal_wave not in MILESTONES:
        raise ValueError("Goal wave must be one of the configured milestones")
    return {
        "integration_version": 3, "profile": PROFILE, "mode": "arcade_milestones",
        "location_ids": dict(LOCATION_IDS), "item_ids": dict(ITEM_IDS),
        "clear_rounds": list(MILESTONES), "confirming_advance_rounds": [wave + 1 for wave in MILESTONES],
        "song_policy": "any", "ability_gating": False, "item_effect": "none",
        "goal": "milestone_verified_clear", "goal_wave": goal_wave,
        "runtime_goal_requires": ["goal_wave_verified_clear_server_acknowledged"],
        "endurance_rounds": list(MILESTONES),
    }
