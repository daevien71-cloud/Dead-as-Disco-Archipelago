"""Arcade milestone AP client. No ability restrictions or game save mutation."""

import argparse
import asyncio
import getpass
import hashlib
import json
import logging
from pathlib import Path

from .arcade_contract import GAME, PROFILE, LOCATIONS, MILESTONES, DEFAULT_GOAL_WAVE, SLOT_DATA, state_directory, validate_slot_data, validate_identity, _same
from .arcade_state import State
from .arcade_bridge import Bridge
from .arcade_ingress import CheckActivation, FileIngress
from .client import Client as ProofClient, server_url
from .contract import ProtocolError
from .file_ingress import _safe_path, _object_without_duplicates, _invalid_number

LOG = logging.getLogger("dad_ap.arcade")


class Client(ProofClient):
    def __init__(self, *args, expected_identity=None, expected_bridge=None, **kwargs):
        activation = kwargs.get("check_activation")
        if activation is not None and not isinstance(activation, CheckActivation):
            raise ProtocolError("Checks-only client requires the three-clear activation type")
        super().__init__(*args, **kwargs)
        self.expected_identity = dict(expected_identity) if expected_identity is not None else None
        self.expected_bridge = Path(expected_bridge).absolute() if expected_bridge is not None else None
        self._goal_lock = asyncio.Lock()
        self._goal_sent_nonce = None
        self.goal_wave = DEFAULT_GOAL_WAVE

    def _game_name(self):
        return GAME

    def _validate_slot_data(self, value):
        validated = validate_slot_data(value)
        self.goal_wave = validated["goal_wave"]
        for packet in reversed(self.trace):
            if packet.get("direction") == "in" and packet.get("cmd") == "Connected":
                packet["slot_data"] = json.loads(json.dumps(validated))
                break
        return validated

    def _create_state(self, seed, team, slot):
        identity = {"seed_name": seed, "team": team, "slot": slot}
        if self.expected_identity is not None and not _same(self.expected_identity, identity):
            raise ProtocolError("Authenticated identity differs from the reviewed adapter plan")
        directory = state_directory(self.state_root, identity)
        if self.expected_bridge is not None and (directory / "bridge").absolute() != self.expected_bridge:
            raise ProtocolError("State bridge differs from the reviewed adapter plan")
        _safe_path(directory)
        state = State(self.state_root, seed, team, slot, goal_wave=self.goal_wave)
        # Connected.checked_locations is the current server's authoritative set;
        # historical ACKs alone must not finish a fresh authenticated session.
        with state.db:
            state.db.execute("UPDATE checks SET acknowledged=0")
        return state

    def _create_bridge(self):
        return Bridge(self.state.directory / "bridge", self.state, activation=self.check_activation)

    def _create_ingress(self):
        return FileIngress(self.bridge, activation=self.check_activation)

    def _log_connected(self, packet):
        LOG.info("Connected Arcade checks: seed=%s team=%s slot=%s; all moves remain available.",
                 self.seed, packet.get("team"), packet.get("slot"))

    def _log_inventory(self, result):
        LOG.info("Credit inventory %s: %d Set Credits; these receipts have no gameplay effect.",
                 result, self.state.summary()["credit_count"])

    async def _maybe_goal(self):
        async with self._goal_lock:
            if (not self.connected.is_set() or not self.state or not self.bridge
                    or not self.state.goal_ready or self._goal_sent_nonce == self.bridge.nonce):
                return
            nonce = self.bridge.nonce
            await self.send([{"cmd": "StatusUpdate", "status": 30}])
            self.state.record_goal_sent(nonce)
            self._goal_sent_nonce = nonce
            LOG.info("Goal complete: verified wave %d clear acknowledged by Archipelago.", self.state.goal_wave)

    async def handle(self, packet):
        if isinstance(packet, dict) and packet.get("cmd") == "RoomInfo":
            self.trace.append({"direction": "in", "cmd": "RoomInfo",
                               "seed_name": packet.get("seed_name"), "games": packet.get("games")})
        await super().handle(packet)
        if packet.get("cmd") in ("Connected", "RoomUpdate", "ReceivedItems") and self.state:
            summary = self.state.summary()
            acknowledged = sum(row["acknowledged"] == 1 for row in summary["checks"])
            LOG.info("Arcade milestones: %d/%d observed, %d acknowledged; goal wave %d; Set Credits: %d (no gameplay effect).",
                     len(summary["checks"]), len(LOCATIONS), acknowledged, self.state.goal_wave, summary["credit_count"])
            await self._maybe_goal()


def _read_json(path, maximum=262144):
    path = _safe_path(path, must_exist=True)
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ProtocolError("Reviewed adapter plan exceeds its size bound")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_object_without_duplicates,
                          parse_constant=_invalid_number)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError("Malformed reviewed adapter plan") from exc


def activation_from_plan(path, state_root):
    """Validate a prepared workspace plan; performs no game writes or installation."""
    plan = _read_json(path)
    required = {"game": GAME, "profile": PROFILE, "integration_version": 3,
                "locations": list(LOCATIONS), "clear_rounds": list(MILESTONES),
                "confirming_advance_rounds": [wave + 1 for wave in MILESTONES], "song_policy": "any",
                "checks_only": True, "ability_gating": False,
                "unlock_application_enabled": False, "deathlink_enabled": False}
    if not isinstance(plan, dict) or any(not _same(v, plan.get(k)) for k, v in required.items()):
        raise ProtocolError("Reviewed plan is not the song-independent milestones profile")
    identity = plan.get("identity")
    validate_identity(identity)
    bridge = _safe_path(plan.get("bridge_directory", ""))
    if bridge != (state_directory(state_root, identity) / "bridge").absolute():
        raise ProtocolError("Reviewed plan bridge must match --state-dir and exact seed/team/slot")
    activation = CheckActivation(plan.get("adapter_build"), plan.get("hook_path"),
                                 plan.get("adapter_sha256"), plan.get("install_id"))
    entries = plan.get("entries")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 16:
        raise ProtocolError("Reviewed plan entries are missing or unbounded")
    relative = "ue4ss/Mods/DADAPProbe/Scripts/main.lua"
    matches = [entry for entry in entries if isinstance(entry, dict)
               and str(entry.get("relative_path", "")).replace("\\", "/") == relative]
    if len(matches) != 1:
        raise ProtocolError("Reviewed plan must identify exactly one checks adapter source")
    staging = _safe_path(plan.get("staging_root", ""))
    source = _safe_path(staging / relative, directory=staging, must_exist=True)
    with source.open("rb") as stream:
        data = stream.read(1048577)
    entry = matches[0]
    if (len(data) > 1048576 or type(entry.get("bytes")) is not int or entry["bytes"] != len(data)
            or hashlib.sha256(data).hexdigest() != activation.adapter_sha256
            or entry.get("sha256") != activation.adapter_sha256):
        raise ProtocolError("Reviewed checks adapter bytes/hash do not match the plan")
    return activation, identity, bridge


def argument_parser():
    parser = argparse.ArgumentParser(description="Dead as Disco Arcade milestones: waves 1–200, default goal wave20, all moves available.")
    parser.add_argument("--server", default="ws://127.0.0.1:38281")
    parser.add_argument("--slot", required=True, help="Exact player name in the generated Archipelago seed")
    parser.add_argument("--state-dir", type=Path, default=Path("state"))
    parser.add_argument("--adapter-plan", type=Path, required=True, help="Explicit reviewed checks-only install-plan.json")
    parser.add_argument("--allow-remote", action="store_true", help="Opt into this outbound ws/wss endpoint; no listener or firewall changes")
    parser.add_argument("--ask-password", action="store_true", help="Read room password in memory only")
    return parser


def main():
    parser = argument_parser()
    args = parser.parse_args()
    try:
        server_url(args.server, allow_remote=args.allow_remote)
        activation, identity, bridge = activation_from_plan(args.adapter_plan, args.state_dir)
    except (ProtocolError, ValueError, TypeError, OSError) as exc:
        parser.error(str(exc))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    client = Client(args.server, args.slot, args.state_dir, check_activation=activation,
                    expected_identity=identity, expected_bridge=bridge, allow_remote=args.allow_remote,
                    password=getpass.getpass("Room password: ") if args.ask_password else None)
    try:
        asyncio.run(client.run())
    except KeyboardInterrupt:
        pass
    except (ProtocolError, ValueError, OSError) as exc:
        parser.exit(2, f"Stopped: {exc}\n")


if __name__ == "__main__":
    main()
