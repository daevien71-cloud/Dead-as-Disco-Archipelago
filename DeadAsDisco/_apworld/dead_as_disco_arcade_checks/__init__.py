"""Song-independent Arcade milestone checks with harmless network rewards."""

from BaseClasses import Item, ItemClassification, Location, Region
from worlds.AutoWorld import WebWorld, World

from .contract import CREDIT_NAME, GAME_NAME, ITEM_IDS, LOCATION_IDS, LOGIC_EVENTS, MILESTONES, make_slot_data
from .options import ArcadeChecksOptions


class ArcadeChecksItem(Item):
    game = GAME_NAME


class ArcadeChecksLocation(Location):
    game = GAME_NAME


class ArcadeChecksWebWorld(WebWorld):
    theme = "partyTime"
    tutorials = []
    item_descriptions = {CREDIT_NAME: "Harmless AP credit. Does not change abilities, health, equipment, or saves."}
    location_descriptions = {
        name: f"Clear Arcade wave {round_number}, confirmed by the next round advance. Any song."
        for round_number, name in zip(MILESTONES, LOCATION_IDS)
    }


class DeadAsDiscoArcadeChecksWorld(World):
    game = GAME_NAME
    options_dataclass = ArcadeChecksOptions
    options: ArcadeChecksOptions
    web = ArcadeChecksWebWorld()
    topology_present = False
    item_name_to_id = ITEM_IDS
    location_name_to_id = LOCATION_IDS

    def generate_early(self) -> None:
        # Preserve the profile's fifteen harmless reward copies. Standard
        # locality/accessibility options do not introduce game-side restrictions.
        for name in ("start_inventory", "item_links", "plando_items"):
            if getattr(self.options, name).value:
                raise ValueError(f"Arcade Milestones v1 requires empty {name}")

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        arcade = Region("Arcade", self.player, self.multiworld)
        for name, code in LOCATION_IDS.items():
            arcade.locations.append(ArcadeChecksLocation(self.player, name, code, arcade))
            event_location, _ = LOGIC_EVENTS[name]
            arcade.locations.append(ArcadeChecksLocation(self.player, event_location, None, arcade))
        self.multiworld.regions.extend([menu, arcade])
        menu.connect(arcade, "Enter Arcade")

    def create_items(self) -> None:
        self.multiworld.itempool.extend(self.create_item(CREDIT_NAME) for _ in LOCATION_IDS)
        for event_location, event_item in LOGIC_EVENTS.values():
            self.get_location(event_location).place_locked_item(self.create_item(event_item))

    def set_rules(self) -> None:
        # AP generation simulates reachability, not observed runtime clears.
        # Each event is an internal reachability marker, never a network check.
        for name, (event_location, _) in LOGIC_EVENTS.items():
            self.get_location(event_location).access_rule = (
                lambda state, location=name: state.can_reach(location, "Location", self.player)
            )
        self.multiworld.completion_condition[self.player] = (
            lambda state: state.has(
                LOGIC_EVENTS[f"Arcade - Wave {self.options.goal_wave.value} Clear"][1], self.player
            )
        )

    def create_item(self, name: str) -> ArcadeChecksItem:
        if name in {event_item for _, event_item in LOGIC_EVENTS.values()}:
            return ArcadeChecksItem(name, ItemClassification.progression, None, self.player)
        return ArcadeChecksItem(name, ItemClassification.filler, self.item_name_to_id[name], self.player)

    def get_filler_item_name(self) -> str:
        return CREDIT_NAME

    def fill_slot_data(self) -> dict:
        return make_slot_data(self.options.goal_wave.value)
