"""Minimal compressed-WebSocket AP client with reconnection and local-only default."""

import argparse
import asyncio
import contextlib
import getpass
import ipaddress
import json
import logging
import re
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from websockets.asyncio.client import connect as WebSocketConnect

from .bridge import Bridge
from .contract import GAME, ProtocolError, validate_slot_data
from .file_ingress import CheckActivation, FileIngress
from .state import State

LOG = logging.getLogger("dad_ap")
INGRESS_POLL_SECONDS = 0.25
INGRESS_HEARTBEAT_SECONDS = 2.0


class NoRedirectConnect(WebSocketConnect):
    """Connect only to the explicitly validated endpoint; never follow redirects."""

    def process_redirect(self, exc):
        return exc


def server_url(value, *, allow_remote=False):
    """Validate an outbound endpoint without resolving DNS or opening a socket."""
    if type(allow_remote) is not bool:
        raise ValueError("Remote connection opt-in must be a boolean")
    if not isinstance(value, str) or not value or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("Server URL must not contain whitespace or control characters")
    parsed = urlsplit(value)
    if (parsed.scheme not in ("ws", "wss") or "@" in parsed.netloc
            or parsed.query or parsed.fragment or "?" in value or "#" in value):
        raise ValueError("Use ws://HOST:PORT or wss://HOST:PORT without URL credentials, query or fragment")
    # urlsplit accepts '[::1]ignored:PORT' and silently discards 'ignored' from
    # hostname. Require the complete authority rather than validating only its
    # lossy hostname/port projection.
    if "[" in parsed.netloc or "]" in parsed.netloc:
        if not re.fullmatch(r"\[[^\[\]]+\]:[0-9]+", parsed.netloc):
            raise ValueError("Bracketed IP authority must be exactly [IPv6]:PORT")
    host = parsed.hostname or ""
    if not host or parsed.port is None or not 1 <= parsed.port <= 65535 or parsed.path not in ("", "/"):
        raise ValueError("Specify a server hostname or IP, port 1-65535, and no URL path")
    if "%" in host or "\\" in host:
        raise ValueError("Encoded hostnames and scoped addresses are not supported")
    try:
        local = ipaddress.ip_address(host).is_loopback
    except ValueError:
        local = False
        try:
            ascii_host = host.encode("idna").decode("ascii")
        except UnicodeError as exc:
            raise ValueError("Invalid server hostname") from exc
        labels = ascii_host.rstrip(".").split(".")
        if (len(ascii_host) > 253 or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                                             for label in labels)):
            raise ValueError("Invalid server hostname")
    if not allow_remote and (not local or parsed.scheme != "ws"):
        raise ValueError("Default is ws://numeric-loopback:PORT; remote ws/wss requires explicit --allow-remote")
    return value


def loopback_url(value):
    return server_url(value)


class Client:
    def __init__(self, url, slot, state_root, *, password=None, version=(0, 6, 9), check_activation=None, allow_remote=False):
        self.url = server_url(url, allow_remote=allow_remote)
        if check_activation is not None and not isinstance(check_activation, CheckActivation):
            raise ProtocolError("Experimental checks require an explicit reviewed CheckActivation")
        self.check_activation = check_activation
        self.slot_name = slot
        self.password = password  # Memory only; never placed in evidence or state.
        self.version = version
        self.state_root = Path(state_root)
        self.uuid = str(uuid.uuid4())
        self.state = None
        self.bridge = None
        self.ingress = None
        self._ingress_task = None
        self._ingress_error = None
        self._ingress_transport_failure = False
        self.seed = None
        self.websocket = None
        self.connected = asyncio.Event()
        self.inventory_ready = asyncio.Event()
        self.stop = asyncio.Event()
        self.trace = []
        self.sync_pending = False
        self.sync_token = None

    def _game_name(self):
        return GAME

    def _validate_slot_data(self, value):
        return validate_slot_data(value)

    def _create_state(self, seed, team, slot):
        return State(self.state_root, seed, team, slot)

    def _create_bridge(self):
        return Bridge(self.state.directory / "bridge", self.state, enabled=self.check_activation is not None)

    def _create_ingress(self):
        return FileIngress(self.bridge, activation=self.check_activation)

    def _log_connected(self, packet):
        LOG.info("Connected seed=%s team=%s slot=%s; %s; runtime unlock unproven", self.seed,
                 packet.get("team"), packet.get("slot"),
                 "experimental checks only" if self.ingress else "game adapter disabled")

    def _log_inventory(self, result):
        LOG.info("Inventory %s; count=%d; runtime application unproven", result, len(self.state.inventory))

    async def _pause_ingress(self):
        """Invalidate before yielding, then wait for the old session's pump to end."""
        task, self._ingress_task = self._ingress_task, None
        try:
            if self.state is not None:
                if self.ingress:
                    self.ingress.disconnect()
                elif self.bridge:
                    self.bridge.publish(False)
        finally:
            if task is not None:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task

    async def _publish_ready(self):
        if not (self.connected.is_set() and self.inventory_ready.is_set() and self.state and self.bridge):
            return
        self._raise_ingress_error()
        if self.ingress is None:
            self.bridge.publish(True)  # Existing disabled-adapter diagnostic snapshot.
            return
        self.ingress.heartbeat(connected=True, inventory_ready=True)
        if self._ingress_task is None or self._ingress_task.done():
            self._ingress_task = asyncio.create_task(
                self._pump_ingress(self.ingress, self.state, self.websocket), name="dad-ap-check-ingress")

    async def _pump_ingress(self, ingress, state, websocket):
        """Renew a checks-only lease and submit only checks already committed by ingress."""
        from websockets.exceptions import ConnectionClosed
        error = None
        transport_failure = False
        next_heartbeat = time.monotonic() + INGRESS_HEARTBEAT_SECONDS
        try:
            while (not self.stop.is_set() and self.connected.is_set() and self.inventory_ready.is_set()
                   and self.ingress is ingress and self.state is state and self.websocket is websocket):
                if time.monotonic() >= next_heartbeat:
                    ingress.heartbeat(connected=True, inventory_ready=True)
                    next_heartbeat = time.monotonic() + INGRESS_HEARTBEAT_SECONDS
                result = ingress.poll_once(connected=True, inventory_ready=True)
                if result.accepted:
                    # poll_once has durably persisted the event/check before returning.
                    # Never copy a location ID directly from an input file to the socket.
                    try:
                        await self.submit_observed_checks()
                    except (OSError, ConnectionClosed, TimeoutError):
                        transport_failure = True
                        raise
                await asyncio.sleep(INGRESS_POLL_SECONDS)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            error = exc
        finally:
            try:
                ingress.disconnect()
            except Exception as exc:
                error = error or exc
                transport_failure = False  # A failed lease revocation must fail closed.
            if error is not None:
                self._ingress_error = error
                self._ingress_transport_failure = transport_failure
                self.connected.clear()
                self.inventory_ready.clear()
                LOG.error("Experimental check ingress failed (%s); runtime unlock unproven", type(error).__name__)
                if websocket is not None:
                    try:
                        await websocket.close()
                    except Exception as exc:
                        LOG.warning("Connection close failed (%s); check lease revoked", type(exc).__name__)

    def _raise_ingress_error(self):
        if self._ingress_error is not None:
            if self._ingress_transport_failure:
                raise self._ingress_error
            raise ProtocolError("Experimental check ingress failed; runtime unlock remains unproven") from self._ingress_error

    async def send(self, packets):
        if self.websocket is None:
            raise ConnectionError("No WebSocket connection")
        await self.websocket.send(json.dumps(packets, separators=(",", ":")))
        self.trace.extend({"direction": "out", **{k: v for k, v in packet.items() if k not in ("password", "uuid")}}
                          for packet in packets)

    async def sync(self):
        self.inventory_ready.clear()
        await self._pause_ingress()
        if not self.sync_pending:
            self.sync_pending = True
            self.sync_token = uuid.uuid4().hex
            # Upstream sends no ReceivedItems packet for an EMPTY inventory.
            # Get is read-only and echoes extra fields. Its ordered reply acts
            # as a barrier after Sync, not a timeout-based guess at emptiness.
            await self.send([
                {"cmd": "Sync"},
                {"cmd": "LocationChecks", "locations": self.state.observed_checks()},
                {"cmd": "Get", "keys": ["dad_ap_sync_barrier"], "dad_ap_sync_token": self.sync_token},
            ])

    async def handle(self, packet):
        if not isinstance(packet, dict) or not isinstance(packet.get("cmd"), str):
            raise ProtocolError("Malformed AP command")
        cmd = packet["cmd"]
        # Bounded, diagnostic trace: no chat messages, credentials or server text.
        if cmd in ("Connected", "ReceivedItems", "RoomUpdate", "ConnectionRefused", "InvalidPacket"):
            self.trace.append({"direction": "in", **{k: v for k, v in packet.items()
                if k in ("cmd", "team", "slot", "index", "items", "checked_locations", "missing_locations", "errors", "type")}})
        if len(self.trace) > 1000:
            self.trace = self.trace[-1000:]
        if cmd == "RoomInfo":
            self.seed = packet.get("seed_name")
            if not isinstance(self.seed, str) or not self.seed or self._game_name() not in packet.get("games", []):
                raise ProtocolError("Room has no Dead as Disco seed")
            await self.send([{
                "cmd": "Connect", "password": self.password, "game": self._game_name(),
                "name": self.slot_name, "uuid": self.uuid,
                "version": dict(zip(("major", "minor", "build"), self.version), **{"class": "Version"}),
                "items_handling": 7, "tags": ["AP"], "slot_data": True,
            }])
        elif cmd == "ConnectionRefused":
            raise ProtocolError("Archipelago connection refused: " + str(packet.get("errors", [])))
        elif cmd == "InvalidPacket":
            raise ProtocolError("Archipelago rejected a protocol packet")
        elif cmd == "Connected":
            self._validate_slot_data(packet.get("slot_data"))
            if self.seed is None:
                raise ProtocolError("Connected before RoomInfo")
            self.connected.clear()
            self.inventory_ready.clear()
            await self._pause_ingress()
            self.bridge = None
            self.ingress = None
            if self.state:
                self.state.close()
            self.state = None
            self.state = self._create_state(self.seed, packet.get("team"), packet.get("slot"))
            self.state.acknowledge_checks(packet.get("checked_locations", []))
            self.bridge = self._create_bridge()
            if self.check_activation is not None:
                self.ingress = self._create_ingress()
            self.bridge.publish(False)  # Inventory must be synchronized before usable state.
            self.connected.set()
            self.sync_pending = False
            await self.sync()
            self._log_connected(packet)
        elif cmd == "ReceivedItems":
            if not self.connected.is_set():
                raise ProtocolError("ReceivedItems before Connected")
            result = self.state.receive_items(packet.get("index"), packet.get("items"))
            if result == "sync_required":
                await self.sync()
                return
            if packet["index"] == 0:
                self.sync_pending = False
                self.inventory_ready.set()
            if self.inventory_ready.is_set():
                await self._publish_ready()
            self._log_inventory(result)
        elif cmd == "RoomUpdate" and self.state:
            self.state.acknowledge_checks(packet.get("checked_locations", []))
        elif cmd == "Retrieved" and self.connected.is_set():
            if packet.get("dad_ap_sync_token") == self.sync_token and self.sync_token is not None:
                if self.sync_pending:
                    self.state.receive_items(0, [])
                    self.sync_pending = False
                    self.inventory_ready.set()
                    await self._publish_ready()
                self.sync_token = None

    async def submit_observed_checks(self):
        if not self.connected.is_set():
            raise ConnectionError("Wait for AP authentication")
        await self.send([{"cmd": "LocationChecks", "locations": self.state.observed_checks()}])

    async def run(self, *, reconnect=True):
        from websockets.exceptions import ConnectionClosed
        delay = 1
        try:
            while not self.stop.is_set():
                self.connected.clear()
                self.inventory_ready.clear()
                self.sync_pending = False
                self.sync_token = None
                self.seed = None
                self._ingress_error = None
                self._ingress_transport_failure = False
                try:
                    async with NoRedirectConnect(self.url, compression="deflate", open_timeout=10,
                                       max_size=2**20, ping_interval=20, ping_timeout=20) as websocket:
                        self.websocket = websocket
                        delay = 1
                        async for message in websocket:
                            try:
                                packets = json.loads(message)
                            except (ValueError, TypeError) as exc:
                                raise ProtocolError("Non-JSON AP message") from exc
                            if not isinstance(packets, list) or len(packets) > 1000:
                                raise ProtocolError("Invalid AP command batch")
                            for packet in packets:
                                self._raise_ingress_error()
                                await self.handle(packet)
                            if self.stop.is_set():
                                break
                        self._raise_ingress_error()
                except ProtocolError:
                    raise  # Fail closed: incompatibility is not a retry loop.
                except (OSError, ConnectionClosed, TimeoutError) as exc:
                    if self._ingress_error is not None and not self._ingress_transport_failure:
                        raise ProtocolError("Experimental check ingress failed; runtime unlock remains unproven") from self._ingress_error
                    LOG.warning("Connection lost (%s); state retained", type(exc).__name__)
                    if not reconnect:
                        raise
                finally:
                    self.websocket = None
                    self.connected.clear()
                    self.inventory_ready.clear()
                    await self._pause_ingress()
                if not reconnect:
                    return
                with contextlib.suppress(TimeoutError):
                    await asyncio.wait_for(self.stop.wait(), timeout=delay)
                delay = min(delay * 2, 30)
        finally:
            self.connected.clear()
            self.inventory_ready.clear()
            try:
                await self._pause_ingress()
            finally:
                if self.state:
                    self.state.close()
                    self.state = None

    async def shutdown(self):
        self.stop.set()
        self.connected.clear()
        self.inventory_ready.clear()
        try:
            await self._pause_ingress()
        finally:
            if self.websocket:
                await self.websocket.close()


def argument_parser():
    parser = argparse.ArgumentParser(description="AP client; loopback default, remote outbound connections require opt-in. No game unlock implementation.")
    parser.add_argument("--server", default="ws://127.0.0.1:38281")
    parser.add_argument("--allow-remote", action="store_true", help="Allow an outbound connection to the specified ws/wss server; opens no listening port")
    parser.add_argument("--slot", default="DiscoProof")
    parser.add_argument("--state-dir", type=Path, default=Path("state"))
    parser.add_argument("--ask-password", action="store_true", help="Read password without storing it")
    parser.add_argument("--experimental-checks", action="store_true", help="Opt into a reviewed checks-only file adapter; does not enable game unlocks")
    parser.add_argument("--adapter-build", help="Exact reviewed adapter build identifier")
    parser.add_argument("--adapter-hook-path", help="Exact calibrated wave-clear hook path")
    parser.add_argument("--adapter-sha256", help="SHA256 of the reviewed adapter artifact")
    return parser


def activation_from_args(args):
    pins = (args.adapter_build, args.adapter_hook_path, args.adapter_sha256)
    if not args.experimental_checks:
        if any(value is not None for value in pins):
            raise ProtocolError("Adapter pins require explicit --experimental-checks")
        return None
    if any(value is None for value in pins):
        raise ProtocolError("Experimental checks require --adapter-build, --adapter-hook-path and --adapter-sha256")
    return CheckActivation(*pins)


def main():
    parser = argument_parser()
    args = parser.parse_args()
    try:
        activation = activation_from_args(args)
        server_url(args.server, allow_remote=args.allow_remote)
    except (ProtocolError, ValueError) as exc:
        parser.error(str(exc))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    client = Client(args.server, args.slot, args.state_dir,
                    password=getpass.getpass("Room password: ") if args.ask_password else None,
                    check_activation=activation, allow_remote=args.allow_remote)
    try:
        asyncio.run(client.run())
    except KeyboardInterrupt:
        pass
    except (ProtocolError, ValueError) as exc:
        parser.exit(2, f"Stopped: {exc}\n")


if __name__ == "__main__":
    main()
