"""Prepare an isolated Arcade milestones adapter; never modify the live game."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.prepare_check_runtime import HOOK, safe_workspace
from dad_ap.arcade_contract import GAME, PROFILE, MILESTONES, LOCATIONS, state_directory

SOURCE = ROOT / "staging/arcade-checks-adapter"
DEPENDENCY = ROOT / "staging/runtime-adapter/deps/json.lua"
JSON_SHA256 = "0eaccda57fabc0330736de25f45cf589821a42b5e0fe02e4e3125f7dc0bf2b7e"
BUILD_PREFIX = "dad-arcade-milestones-v1-"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def config_literal(bridge, identity, install_id):
    return ("{bridge_dir=" + json.dumps(bridge.as_posix())
            + ",identity={seed_name=" + json.dumps(identity["seed_name"])
            + ",team=" + str(identity["team"]) + ",slot=" + str(identity["slot"])
            + "},install_id=" + json.dumps(install_id) + "}")


def prepare(session, bridge, identity):
    session, bridge = safe_workspace(Path(session)), safe_workspace(Path(bridge))
    if session.exists() or not session.is_relative_to(ROOT / "runtime"):
        raise ValueError("Choose a fresh preparation directory under workspace runtime")
    if (type(identity) is not dict or set(identity) != {"seed_name", "team", "slot"}
            or type(identity["seed_name"]) is not str or not identity["seed_name"]
            or len(identity["seed_name"]) > 160 or not identity["seed_name"].isascii()
            or any(ord(c) < 32 for c in identity["seed_name"])
            or type(identity["team"]) is not int or not 0 <= identity["team"] <= 2147483647
            or type(identity["slot"]) is not int or not 1 <= identity["slot"] <= 2147483647):
        raise ValueError("Invalid exact seed/team/slot identity")
    key = digest(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode())
    if (bridge.name != "bridge" or bridge.parent.name != key
            or bridge.parent.parent.name != PROFILE):
            raise ValueError("Bridge must use state-root/arcade_milestones_v1/<identity fingerprint>/bridge")
    # Preserve the exact bytes used for both assembly and provenance.
    components = [DEPENDENCY, SOURCE / "three_wave.lua", SOURCE / "bridge-wrapper.lua"]
    snapshots = [safe_workspace(path).read_bytes() for path in components]
    if digest(snapshots[0]) != JSON_SHA256:
        raise ValueError("Pinned JSON dependency changed")
    texts = [data.decode("utf-8") for data in snapshots]
    install_id = uuid.uuid4().hex
    wrapper = texts[2]
    for old, new in [("local ENABLE_CHECKS = false", "local ENABLE_CHECKS = true"),
                     ("local CONFIG = nil", "local CONFIG = " + config_literal(bridge, identity, install_id))]:
        if wrapper.count(old) != 1:
            raise ValueError("Disabled wrapper marker changed: " + old)
        wrapper = wrapper.replace(old, new, 1)
    bundle = ("local json = (function()\n" + texts[0] + "\nend)()\n"
              + "local ThreeWave = (function()\n" + texts[1] + "\nend)()\n" + wrapper)
    subprocess.run([sys.executable, str(ROOT / "scripts/prepare_metadata_runtime.py"),
                    "--session-directory", str(session), "--wave-observer"],
                   check=True, capture_output=True)
    destination = session / "staging/ue4ss/Mods/DADAPProbe/Scripts/main.lua"
    destination.write_text(bundle, encoding="utf-8", newline="\n")
    luac = ROOT / "staging/metadata-probe/syntax-check/build/luac.exe"
    syntax = subprocess.run([str(luac), "-p", str(destination)], capture_output=True, text=True)
    if syntax.returncode:
        raise ValueError("Derived Arcade adapter failed Lua syntax: " + syntax.stderr)
    plan_path = session / "install-plan.json"
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    plan.update(
        purpose="Arcade checks-only milestones through wave 200; all moves available",
        game=GAME, profile=PROFILE, integration_version=3, locations=list(LOCATIONS),
        clear_rounds=list(MILESTONES), confirming_advance_rounds=[w + 1 for w in MILESTONES], song_policy="any",
        wave_observer=False, session_nonce=None, checks_only=True, ability_gating=False,
        deathlink_enabled=False, unlock_application_enabled=False,
        owner_calibration_profile="owner_requested_arcade_20261011",
        install_id=install_id, identity=identity, bridge_directory=str(bridge),
        adapter_build=BUILD_PREFIX + install_id, adapter_sha256=digest(destination.read_bytes()),
        hook_path=HOOK,
        source_components=[{"path": str(path), "sha256": digest(data)}
                           for path, data in zip(components, snapshots)],
        syntax={"command": [str(luac), "-p", str(destination)], "exit_code": 0,
                "script_executed": False},
    )
    for entry in plan["entries"]:
        data = (Path(plan["staging_root"]) / entry["relative_path"]).read_bytes()
        entry.update(bytes=len(data), sha256=digest(data))
    plan_path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    return {"plan": str(plan_path), "adapter_build": plan["adapter_build"],
            "adapter_sha256": plan["adapter_sha256"], "install_id": install_id,
            "bridge_directory": str(bridge), "live_writes": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-directory", type=Path, required=True)
    bridge_group = parser.add_mutually_exclusive_group(required=True)
    bridge_group.add_argument("--bridge-directory", type=Path)
    bridge_group.add_argument("--state-dir", type=Path)
    parser.add_argument("--seed-name", required=True)
    parser.add_argument("--team", type=int, default=0)
    parser.add_argument("--slot", type=int, default=1)
    parser.add_argument("--accept-owner-calibration", action="store_true", required=True)
    args = parser.parse_args()
    identity = {"seed_name": args.seed_name, "team": args.team, "slot": args.slot}
    bridge = args.bridge_directory or state_directory(args.state_dir, identity) / "bridge"
    print(json.dumps(prepare(args.session_directory, bridge, identity), indent=2))


if __name__ == "__main__":
    main()
