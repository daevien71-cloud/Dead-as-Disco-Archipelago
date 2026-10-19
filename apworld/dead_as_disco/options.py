"""Player options. The docstrings are what the Options Creator shows when you hover an option, so they're
written for players: what it does, an example, and when you'd change it."""

from dataclasses import dataclass

from Options import (
    Accessibility, Choice, DeathLink, ExcludeLocations, ItemLinks, LocalItems, NonLocalItems, OptionGroup, OptionSet,
    PerGameCommonOptions, PriorityLocations, ProgressionBalancing, Range, StartHints, StartInventory,
    StartLocationHints,
)

from .data import DEFAULT_TRAPS, KILL_THRESHOLDS, TRAPS


# ----- Goal -------------------------------------------------------------------------------------------------------

class GoalWave(Choice):
    """How you win. Once you hold enough Gold Records, clear this wave in a single Arcade run.

    Clearing it before you have the records doesn't count, so the final run happens once your friends (and your
    own checks) have turned up enough records. A higher wave means a longer final run.
    """
    display_name = "Goal Wave"
    option_wave_10 = 10
    option_wave_20 = 20
    option_wave_30 = 30
    option_wave_40 = 40
    option_wave_50 = 50
    option_wave_75 = 75
    option_wave_100 = 100
    option_wave_150 = 150
    option_wave_200 = 200
    default = 50


class GoldRecordCount(Range):
    """How many Gold Records are hidden in the multiworld, in your own checks and in your friends' games.

    Put in more than **Gold Records Required** and the extras are spares: you won't need every last one, so a
    record stuck somewhere hard to reach can't hold up your goal. Example: 7 in the pool and 5 required.
    """
    display_name = "Gold Records in Pool"
    range_start = 1
    range_end = 30
    default = 7


class GoldRecordsRequired(Range):
    """How many Gold Records you need before the goal wave counts.

    Keep it at or below **Gold Records in Pool**. If it's higher, it's lowered to match the pool.
    """
    display_name = "Gold Records Required"
    range_start = 1
    range_end = 30
    default = 5


# ----- Checks -----------------------------------------------------------------------------------------------------

class WaveCheckInterval(Range):
    """Adds more wave checks. Waves 1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150 and 200 are always checks;
    set a number here to also make every Nth wave one.

    **0:** just those 15. **5:** adds 35, 45, 55 and so on (43 wave checks). **1:** every wave up to 200.

    Waves count per run: "Clear Wave 100" means reaching wave 100 in one run, and clearing a wave also sends
    every lower wave check you haven't sent yet. More checks means more of your friends' items hidden in your game.
    """
    display_name = "Extra Wave Check Interval"
    range_start = 0
    range_end = 50
    default = 0


class KillChecks(Range):
    """Checks for enemies defeated in total, added up across all your Arcade runs: 25, 50, 100, 150, 200, 300,
    400, 500, 750, 1000, 1500, 2000, 3000 and 5000.

    This picks how many of those are used, from the start of the list. **8:** up to 500 kills. **14:** all the way
    to 5000. **0:** no kill checks. Kills only count while the Dead as Disco Client is running.
    """
    display_name = "Kill Checks"
    range_start = 0
    range_end = len(KILL_THRESHOLDS)
    default = 8


# ----- Traps & effects --------------------------------------------------------------------------------------------

class TrapPercentage(Range):
    """Of your items that aren't Gold Records, how many (in percent) are traps.

    The rest are helpful or harmless: Mirror Ball Shields, Disco Fever and Groovy Vibes. **0:** no traps.
    **100:** everything except Gold Records is a trap.
    """
    display_name = "Trap Percentage"
    range_start = 0
    range_end = 100
    default = 35


class EnabledTraps(OptionSet):
    """Which traps can show up.

    **Slow-Mo Trap:** the whole game runs at 60% speed. **Fast-Forward Trap:** the whole game runs at 140%.
    **Molasses Trap:** only you are slowed to 60%. **Blackout Trap:** the screen goes 98% dark.
    The music keeps its normal speed, so the speed traps throw you off the beat.

    **Meteor Trap (experimental, off by default):** each item rolls 1–5 Aurora meteors. They arrive one at a
    time, each targeting where you stood when it launched, with a warning before impact. The next waits for
    the previous meteor and remnant to disappear. Update both the game mod and APWorld before adding it.
    The whole batch uses one item and its own time limits, separate from Effect Duration; pauses stop its clock.
    Native base damage is 10 to you and 60 to enemies; the game's normal damage modifiers still apply.
    Enemy kills count toward your usual kill checks. Dying to a meteor uses your normal DeathLink send chance,
    with no extra DeathLink roll or message.
    """
    display_name = "Enabled Traps"
    valid_keys = frozenset(TRAPS)
    default = frozenset(DEFAULT_TRAPS)


class EffectDuration(Range):
    """How many seconds the speed/screen traps and each Disco Fever last.

    Traps and buffs wait until you're in an Arcade run, then fire one at a time.
    The experimental Meteor Trap rolls 1–5 meteors and has its own batch time limit; this option does not change it.
    """
    display_name = "Effect Duration"
    range_start = 5
    range_end = 60
    default = 15


# ----- DeathLink --------------------------------------------------------------------------------------------------

class DeadAsDiscoDeathLink(DeathLink):
    """Links your deaths with everyone else who turned DeathLink on.

    In Dead as Disco it's softened by the two chances below, so not every death is passed on, and a Mirror Ball
    Shield blocks one incoming death.
    """
    display_name = "DeathLink"


class DeathLinkSendChance(Range):
    """When you die, the chance (in percent) that your death is sent to everyone with DeathLink on.

    **25:** about one in four of your deaths. **100:** every death. Only matters with DeathLink on.
    """
    display_name = "DeathLink Send Chance"
    range_start = 0
    range_end = 100
    default = 25


class DeathLinkReceiveChance(Range):
    """When someone else's death reaches you, the chance (in percent) that it kills you.

    Only while you're in an Arcade run: at the menus you're safe. A Mirror Ball Shield blocks one that would have
    killed you. **40:** you survive more often than not. Only matters with DeathLink on.
    """
    display_name = "DeathLink Receive Chance"
    range_start = 0
    range_end = 100
    default = 40


# ----- Archipelago-wide options, explained for this game ----------------------------------------------------------

class DeadAsDiscoAccessibility(Accessibility):
    """How strict the generator is about everything being reachable.

    **Full:** every check can be done and every item found. **Minimal:** only guarantees you can reach your goal,
    so some of your extra items (spare Gold Records, traps, buffs) might be put somewhere nobody can reach.

    Every Dead as Disco check is always reachable (it's all just playing Arcade), so leave this on Full.
    """


class DeadAsDiscoProgressionBalancing(ProgressionBalancing):
    """Tries to move a player's important items earlier, so they don't get stuck waiting.

    For Dead as Disco this does next to nothing: your only important items are Gold Records, and they're left
    spread out on purpose. Leave it at the default (50). **0** turns it off, **99** is the strongest.
    """


class DeadAsDiscoLocalItems(LocalItems):
    """Items that must turn up in your own checks, never in your friends' games.

    Example: **Gold Record** here means you find every record yourself by playing.
    """


class DeadAsDiscoNonLocalItems(NonLocalItems):
    """Items that must turn up in someone else's game, never in your own checks.

    Example: **Gold Record** here means your friends have to find all of your records for you.
    """


class DeadAsDiscoStartInventory(StartInventory):
    """Items you start the game with, on top of the normal pool. Example: {Mirror Ball Shield: 1, Gold Record: 2}"""


class DeadAsDiscoStartHints(StartHints):
    """Items whose hiding places you know from the start, like a free !hint.

    Example: **Gold Record** shows where every one of your records is.
    """


class DeadAsDiscoStartLocationHints(StartLocationHints):
    """Checks whose contents you know from the start. Example: **Arcade - Clear Wave 200** shows what's waiting there."""


class DeadAsDiscoExcludeLocations(ExcludeLocations):
    """Checks that will never hold anything important for anyone, only filler or traps.

    Use it for checks you might never reach, like **Arcade - Clear Wave 200** or **Arcade - Defeat 5000 Enemies**,
    so nobody's game ends up waiting on them.
    """


class DeadAsDiscoPriorityLocations(PriorityLocations):
    """Checks that will always hold something important for someone. Good for making a hard check worth doing."""


class DeadAsDiscoItemLinks(ItemLinks):
    """Advanced: lets several players of the same game share part of their item pools. Rarely useful here."""


@dataclass
class DeadAsDiscoOptions(PerGameCommonOptions):
    goal_wave: GoalWave
    gold_record_count: GoldRecordCount
    gold_records_required: GoldRecordsRequired
    wave_check_interval: WaveCheckInterval
    kill_checks: KillChecks
    trap_percentage: TrapPercentage
    enabled_traps: EnabledTraps
    effect_duration: EffectDuration
    death_link: DeadAsDiscoDeathLink
    death_link_send_chance: DeathLinkSendChance
    death_link_receive_chance: DeathLinkReceiveChance
    accessibility: DeadAsDiscoAccessibility
    progression_balancing: DeadAsDiscoProgressionBalancing
    local_items: DeadAsDiscoLocalItems
    non_local_items: DeadAsDiscoNonLocalItems
    start_inventory: DeadAsDiscoStartInventory
    start_hints: DeadAsDiscoStartHints
    start_location_hints: DeadAsDiscoStartLocationHints
    exclude_locations: DeadAsDiscoExcludeLocations
    priority_locations: DeadAsDiscoPriorityLocations
    item_links: DeadAsDiscoItemLinks


OPTION_GROUPS = [
    OptionGroup("Goal", [GoalWave, GoldRecordCount, GoldRecordsRequired]),
    OptionGroup("Checks", [WaveCheckInterval, KillChecks]),
    OptionGroup("Traps & Effects", [TrapPercentage, EnabledTraps, EffectDuration]),
    OptionGroup("DeathLink", [DeadAsDiscoDeathLink, DeathLinkSendChance, DeathLinkReceiveChance]),
    OptionGroup("Generation", [DeadAsDiscoAccessibility, DeadAsDiscoProgressionBalancing]),
    OptionGroup("Item & Location Options", [
        DeadAsDiscoLocalItems, DeadAsDiscoNonLocalItems, DeadAsDiscoStartInventory, DeadAsDiscoStartHints,
        DeadAsDiscoStartLocationHints, DeadAsDiscoExcludeLocations, DeadAsDiscoPriorityLocations,
        DeadAsDiscoItemLinks,
    ], start_collapsed=True),
]
