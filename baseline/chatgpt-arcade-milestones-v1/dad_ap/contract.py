"""Stable v1 proof contract. No claim that a game adapter is implemented."""

GAME = "Dead as Disco"
LOCATION = 814000001
ITEM = 814001001
UNLOCK = "ap_proof_unlock"
SLOT_DATA = {
    "integration_version": 1,
    "mode": "arcade_proof",
    "proof_wave": 1,
    "proof_location_id": LOCATION,
    "proof_item_id": ITEM,
    "unlock_key": UNLOCK,
    "song_policy": "any",
    "ability_gating": False,
}


class ProtocolError(ValueError):
    pass


def validate_slot_data(data):
    if not isinstance(data, dict):
        raise ProtocolError("Missing proof slot_data")
    for key, expected in SLOT_DATA.items():
        if type(data.get(key)) is not type(expected) or data[key] != expected:
            raise ProtocolError(f"Unsupported slot_data field: {key}")


def network_item(value):
    if not isinstance(value, dict):
        raise ProtocolError("NetworkItem must be an object")
    result = {}
    for key in ("item", "location", "player", "flags"):
        if type(value.get(key)) is not int:
            raise ProtocolError(f"Invalid NetworkItem {key}")
        result[key] = value[key]
    return result
