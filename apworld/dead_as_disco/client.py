"""Dead as Disco client: relays between the Archipelago server and the UE4SS mod's file bridge.

Start it from the Archipelago Launcher ("Dead as Disco Client"), connect, then play Arcade.
"""

import asyncio
import time
from pathlib import Path
from typing import Any, Optional

import Utils
from CommonClient import (
    ClientCommandProcessor, CommonContext, get_base_parser, gui_enabled, handle_url_arg, logger, server_loop,
)
from NetUtils import ClientStatus

from .bridge import GameBridge
from .data import GAME_NAME
from .tracker import Settings, Tracker

POLL_SECONDS = 0.25
# Marks a /testdeathlink packet. It's bounced to your slot only and carries no DeathLink tag, so it can
# never reach anyone else, even mid-session.
TEST_DEATHLINK = "dead_as_disco_test_deathlink"


class DeadAsDiscoCommandProcessor(ClientCommandProcessor):
    ctx: "DeadAsDiscoContext"

    def _cmd_disco(self) -> bool:
        """Show game connection, Gold Records, kills and queued effects."""
        ctx = self.ctx
        status = ctx.bridge.status()
        self.output(f"Game: {'connected' if status else 'not detected (is the mod installed and the game running?)'}"
                    + (f", in run: {bool(status.get('in_run'))}, wave {status.get('round', 0)}" if status else ""))
        t = ctx.tracker
        if not t:
            self.output("Not connected to a multiworld yet.")
            return True
        s = t.settings
        self.output(f"Gold Records: {t.gold_records}/{s.gold_records_required}, goal: clear wave {s.goal_wave}")
        self.output(f"Best wave: {t.state.best_wave}, lifetime kills: {t.state.kills}, "
                    f"Mirror Ball Shields: {t.shields_available}")
        queue = t.effect_queue()
        self.output(f"Queued effects: {', '.join(queue) if queue else 'none'}")
        if s.death_link:
            self.output(f"DeathLink: send {s.death_link_send_chance}%, receive {s.death_link_receive_chance}%")
        return True

    def _cmd_testeffect(self, effect: str = "slowmo") -> bool:
        """Send an effect to the game without using an item: slowmo, fastforward, molasses, blackout, fever."""
        self.ctx.bridge.send({"type": "effect", "effect": effect, "duration": 10, "item": f"Test {effect}"})
        self.output(f"Sent test effect '{effect}' (only applies during a run).")
        return True

    def _cmd_testdeathlink(self, name: str = "Test Buddy") -> bool:
        """Pretend a friend died: goes through the server to your slot only, then rolls your receive chance
        and uses up a Mirror Ball Shield exactly like a real DeathLink. Only bites during a run."""
        ctx = self.ctx
        if not ctx.slot or not ctx.tracker:
            self.output("Connect to a multiworld first.")
            return False
        Utils.async_start(ctx.send_msgs([{"cmd": "Bounce", "slots": [ctx.slot], "data": {
            "time": time.time(), "source": name, "cause": f"{name} slipped on the dance floor.", TEST_DEATHLINK: True}}]))
        self.output(f"Sent a test DeathLink from {name} to yourself.")
        return True

    def _cmd_testkill(self) -> bool:
        """Ask the game to kill your character, to test DeathLink. Only works during a run."""
        self.ctx.bridge.send({"type": "kill", "source": "test"})
        self.output("Sent a test kill.")
        return True


class DeadAsDiscoContext(CommonContext):
    game = GAME_NAME
    items_handling = 0b111
    want_slot_data = True
    command_processor = DeadAsDiscoCommandProcessor

    def __init__(self, server_address: Optional[str], password: Optional[str], bridge_dir: Optional[Path] = None):
        super().__init__(server_address, password)
        self.bridge = GameBridge(bridge_dir)
        self.tracker: Optional[Tracker] = None
        self.game_connected = False
        self.last_status_cleared = 0
        self.room_seed_name: Optional[str] = None

    async def server_auth(self, password_requested: bool = False) -> None:
        if password_requested and not self.password:
            await super().server_auth(password_requested)
        await self.get_username()
        await self.send_connect()

    def make_gui(self):
        ui = super().make_gui()
        ui.base_title = "Dead as Disco Client"
        return ui

    async def disconnect(self, allow_autoreconnect: bool = False) -> None:
        self.tracker = None
        await super().disconnect(allow_autoreconnect)

    def on_package(self, cmd: str, args: dict[str, Any]) -> None:
        if cmd == "RoomInfo":
            # CommonContext leaves seed_name unset for clients that don't set it themselves.
            self.room_seed_name = args.get("seed_name")
        elif cmd == "Connected":
            settings = Settings.from_slot_data(args.get("slot_data") or {})
            state_dir = self.bridge.directory / "state"
            state_path = state_dir / f"{self.room_seed_name}_{self.team}_{self.slot}.json"
            unnamed = state_dir / f"None_{self.team}_{self.slot}.json"  # written by v0.1.0 before this fix
            if not state_path.exists() and unnamed.exists():
                unnamed.replace(state_path)
            self.tracker = Tracker(settings, state_path, log=logger.info, notify=self.popup)
            self.tracker.set_received([item.item for item in self.items_received])
            self.last_status_cleared = 0
            Utils.async_start(self.update_death_link(settings.death_link))
            # Re-send anything earned while disconnected.
            Utils.async_start(self.apply({"locations": self.tracker.locations_for_wave(self.tracker.state.best_wave)
                                          + self.tracker.locations_for_kills()}))
            logger.info(f"Goal: collect {settings.gold_records_required} Gold Records, then clear wave "
                        f"{settings.goal_wave} in one Arcade run. Type /disco for status.")
        elif cmd == "Bounced" and (args.get("data") or {}).get(TEST_DEATHLINK):
            self.on_deathlink(args["data"])
        elif cmd == "ReceivedItems" and self.tracker:
            self.tracker.set_received([item.item for item in self.items_received])

    def popup(self, text: str) -> None:
        self.bridge.send({"type": "message", "text": text})

    def on_print_json(self, args: dict[str, Any]) -> None:
        super().on_print_json(args)
        if args.get("type") == "ItemSend" and self.slot is not None:
            message = self.item_message(args)
            if message:
                self.popup(message)

    def item_message(self, args: dict[str, Any]) -> Optional[str]:
        item, receiving = args.get("item"), args.get("receiving")
        if item is None or receiving is None:
            return None
        if isinstance(item, dict):
            item_id, finder, flags = item.get("item"), item.get("player"), item.get("flags", 0)
        else:
            item_id, finder, flags = item.item, item.player, item.flags
        if self.slot not in (receiving, finder):
            return None
        name = self.item_names.lookup_in_slot(item_id, receiving)
        if receiving == self.slot and finder == self.slot:
            return f"You found your {name}"
        if receiving == self.slot:
            return f"{self.player_names.get(finder, 'Someone')} sent you {name}"
        important = "!" if flags & 0b001 else ""  # progression items matter most to your friends
        return f"You sent {name} to {self.player_names.get(receiving, 'someone')}{important}"

    def on_deathlink(self, data: dict[str, Any]) -> None:
        super().on_deathlink(data)
        if self.tracker and self.tracker.on_incoming_deathlink(data.get("source", "someone"), self.bridge.in_run()):
            self.bridge.send({"type": "kill", "source": data.get("source", "")})

    async def apply(self, result: dict[str, Any]) -> None:
        tracker = self.tracker
        if not tracker:
            return
        new = set(result.get("locations", ())) & self.missing_locations
        if new:
            await self.send_msgs([{"cmd": "LocationChecks", "locations": sorted(new)}])
        if result.get("goal") and not tracker.state.goal_sent:
            await self.send_msgs([{"cmd": "StatusUpdate", "status": ClientStatus.CLIENT_GOAL}])
            tracker.state.goal_sent = True
            self.finished_game = True
            logger.info("GOAL COMPLETE! You're the Disco champion.")
            self.popup("GOAL COMPLETE! You're the Disco champion!")
        if result.get("send_death"):
            name = self.player_names.get(self.slot, "Someone")
            await self.send_death(f"{name} got knocked off the dance floor.")
        tracker.save()


async def game_loop(ctx: DeadAsDiscoContext) -> None:
    while not ctx.exit_event.is_set():
        await asyncio.sleep(POLL_SECONDS)
        try:
            await game_tick(ctx)
        except Exception as exc:  # keep the loop alive; report and continue
            logger.exception(f"Game bridge error: {exc}")


async def game_tick(ctx: DeadAsDiscoContext) -> None:
    status = ctx.bridge.status()
    if bool(status) != ctx.game_connected:
        ctx.game_connected = bool(status)
        logger.info("Dead as Disco detected." if status else "Lost contact with Dead as Disco.")
    tracker = ctx.tracker
    if not tracker or not ctx.slot:
        return  # leave events unread until we know which slot they belong to
    for event in ctx.bridge.read_events():
        await ctx.apply(tracker.handle_event(event))
    in_run = bool(status and status.get("in_run"))
    cleared = int(status.get("cleared", 0)) if status else 0
    if cleared != ctx.last_status_cleared:
        ctx.last_status_cleared = cleared
        if cleared > 0:
            await ctx.apply(tracker.on_wave(cleared))
    effect = tracker.next_effect_to_send(in_run)
    if effect:
        item_name, key = effect
        command_id = ctx.bridge.send({"type": "effect", "effect": key, "item": item_name,
                                      "duration": tracker.settings.effect_duration})
        tracker.effect_sent(command_id, item_name, key)


def launch(*launch_args: str) -> None:
    async def main(args) -> None:
        ctx = DeadAsDiscoContext(args.connect, args.password, Path(args.bridge_dir) if args.bridge_dir else None)
        ctx.auth = args.name
        logger.info(f"Talking to the game through {ctx.bridge.directory}")
        ctx.server_task = asyncio.create_task(server_loop(ctx), name="server loop")
        game_task = asyncio.create_task(game_loop(ctx), name="game loop")
        if gui_enabled:
            ctx.run_gui()
        ctx.run_cli()
        await ctx.exit_event.wait()
        game_task.cancel()
        await ctx.shutdown()

    parser = get_base_parser(description="Dead as Disco Archipelago client")
    parser.add_argument("--name", default=None, help="Slot name to connect as.")
    parser.add_argument("--bridge-dir", default=None, help="Override the game bridge folder (for testing).")
    parser.add_argument("url", nargs="?", help="Archipelago connection url")
    args = handle_url_arg(parser.parse_args(launch_args), parser=parser)

    Utils.init_logging("DeadAsDiscoClient", exception_logger="Client")
    import colorama
    colorama.just_fix_windows_console()
    asyncio.run(main(args))
    colorama.deinit()
