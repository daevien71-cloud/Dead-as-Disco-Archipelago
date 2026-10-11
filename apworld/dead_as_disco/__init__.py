"""Dead as Disco (Arcade) for Archipelago."""

from typing import Any

from BaseClasses import Item, ItemClassification, Location, Region, Tutorial
from worlds.AutoWorld import WebWorld, World
from worlds.LauncherComponents import Component, Type, components, launch as launch_component

from .data import (
    DISCO_FEVER, GAME_NAME, GOLD_RECORD, GROOVY_VIBES, ITEM_DESCRIPTIONS, ITEM_NAME_TO_ID,
    KILL_LOCATIONS, KILL_THRESHOLDS, LOCATION_NAME_TO_ID, MAX_WAVE, MILESTONE_WAVES,
    MIRROR_BALL_SHIELD, SLOT_DATA_VERSION, TRAPS, WAVE_LOCATIONS, kill_location_name,
    wave_location_name,
)
from .options import OPTION_GROUPS, DeadAsDiscoOptions


def launch_client(*args: str) -> None:
    from .client import launch
    launch_component(launch, name="DeadAsDiscoClient", args=args)


components.append(Component("Dead as Disco Client", func=launch_client,
                            component_type=Type.CLIENT, description="Connects Dead as Disco to Archipelago."))


class DeadAsDiscoItem(Item):
    game = GAME_NAME


class DeadAsDiscoLocation(Location):
    game = GAME_NAME


class DeadAsDiscoWeb(WebWorld):
    theme = "partyTime"
    item_descriptions = ITEM_DESCRIPTIONS
    option_groups = OPTION_GROUPS
    rich_text_options_doc = True
    tutorials = [Tutorial(
        "Multiworld Setup Guide",
        "Install the mod and connect Dead as Disco to a multiworld.",
        "English",
        "setup_en.md",
        "setup/en",
        ["daevien71"],
    )]


CLASSIFICATIONS = {
    GOLD_RECORD: ItemClassification.progression_skip_balancing,
    DISCO_FEVER: ItemClassification.useful,
    MIRROR_BALL_SHIELD: ItemClassification.useful,
    GROOVY_VIBES: ItemClassification.filler,
    **{trap: ItemClassification.trap for trap in TRAPS},
}


def selected_waves(interval: int) -> list[int]:
    waves = set(MILESTONE_WAVES)
    if interval > 0:
        waves.update(range(interval, MAX_WAVE + 1, interval))
    return sorted(waves)


class DeadAsDiscoWorld(World):
    """Dead as Disco is a rhythm beat 'em up. Survive Arcade waves and rack up kills to find
    everyone's items; collect Gold Records, then clear your goal wave to win."""

    game = GAME_NAME
    web = DeadAsDiscoWeb()
    options_dataclass = DeadAsDiscoOptions
    options: DeadAsDiscoOptions
    topology_present = False
    item_name_to_id = ITEM_NAME_TO_ID
    location_name_to_id = LOCATION_NAME_TO_ID
    item_name_groups = {"Traps": set(TRAPS)}
    location_name_groups = {"Waves": set(WAVE_LOCATIONS), "Kills": set(KILL_LOCATIONS)}

    waves: list[int]
    kill_thresholds: list[int]
    gold_records: int
    gold_required: int

    def generate_early(self) -> None:
        self.waves = selected_waves(self.options.wave_check_interval.value)
        self.kill_thresholds = list(KILL_THRESHOLDS[:self.options.kill_checks.value])
        total = len(self.waves) + len(self.kill_thresholds)
        self.gold_records = min(self.options.gold_record_count.value, total)
        self.gold_required = min(self.options.gold_records_required.value, self.gold_records)

    def create_regions(self) -> None:
        menu = Region("Menu", self.player, self.multiworld)
        arcade = Region("Arcade", self.player, self.multiworld)
        names = [wave_location_name(w) for w in self.waves]
        names += [kill_location_name(k) for k in self.kill_thresholds]
        for name in names:
            arcade.locations.append(DeadAsDiscoLocation(self.player, name, LOCATION_NAME_TO_ID[name], arcade))
        menu.connect(arcade)
        self.multiworld.regions += [menu, arcade]

    def create_item(self, name: str) -> DeadAsDiscoItem:
        return DeadAsDiscoItem(name, CLASSIFICATIONS[name], ITEM_NAME_TO_ID[name], self.player)

    def create_items(self) -> None:
        total = len(self.waves) + len(self.kill_thresholds)
        pool = [GOLD_RECORD] * self.gold_records
        remaining = total - len(pool)
        traps = sorted(self.options.enabled_traps.value)
        trap_count = round(remaining * self.options.trap_percentage.value / 100) if traps else 0
        pool += [self.random.choice(traps) for _ in range(trap_count)]
        rest = remaining - trap_count
        pool += [MIRROR_BALL_SHIELD] * (rest // 4) + [DISCO_FEVER] * (rest // 4)
        pool += [GROOVY_VIBES] * (total - len(pool))
        self.multiworld.itempool += [self.create_item(name) for name in pool]

    def set_rules(self) -> None:
        required = self.gold_required
        self.multiworld.completion_condition[self.player] = lambda state: state.has(GOLD_RECORD, self.player, required)

    def get_filler_item_name(self) -> str:
        return GROOVY_VIBES

    def fill_slot_data(self) -> dict[str, Any]:
        return {
            "version": SLOT_DATA_VERSION,
            "goal_wave": self.options.goal_wave.value,
            "gold_records_required": self.gold_required,
            "waves": self.waves,
            "kill_thresholds": self.kill_thresholds,
            "effect_duration": self.options.effect_duration.value,
            "death_link": bool(self.options.death_link.value),
            "death_link_send_chance": self.options.death_link_send_chance.value,
            "death_link_receive_chance": self.options.death_link_receive_chance.value,
        }
