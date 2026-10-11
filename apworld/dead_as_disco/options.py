from dataclasses import dataclass

from Options import Choice, DeathLink, OptionSet, PerGameCommonOptions, Range

from .data import KILL_THRESHOLDS, TRAPS


class GoalWave(Choice):
    """Once you hold enough Gold Records, clear this wave in a single Arcade run to win."""
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
    """How many Gold Records are shuffled into the multiworld."""
    display_name = "Gold Records in Pool"
    range_start = 1
    range_end = 30
    default = 7


class GoldRecordsRequired(Range):
    """How many Gold Records you need before the goal wave counts.
    Capped at the number of Gold Records in the pool."""
    display_name = "Gold Records Required"
    range_start = 1
    range_end = 30
    default = 5


class WaveCheckInterval(Range):
    """Waves 1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150 and 200 are always checks.
    Set this above 0 to also make every Nth wave a check (for example 5 adds 35, 45, 55, ...).
    Waves are counted per run: wave 150 means reaching it in one run."""
    display_name = "Extra Wave Check Interval"
    range_start = 0
    range_end = 50
    default = 0


class KillChecks(Range):
    """Number of lifetime-kill checks (25, 50, 100, 150, 200, 300, 400, 500, 750, 1000, ...).
    Kills add up across every Arcade run, so these are a pure grind. 0 turns them off."""
    display_name = "Kill Checks"
    range_start = 0
    range_end = len(KILL_THRESHOLDS)
    default = 8


class TrapPercentage(Range):
    """Percentage of non-Gold-Record items that are traps."""
    display_name = "Trap Percentage"
    range_start = 0
    range_end = 100
    default = 35


class EnabledTraps(OptionSet):
    """Which traps can appear."""
    display_name = "Enabled Traps"
    valid_keys = frozenset(TRAPS)
    default = frozenset(TRAPS)


class EffectDuration(Range):
    """How many seconds traps and Disco Fever last."""
    display_name = "Effect Duration"
    range_start = 5
    range_end = 60
    default = 15


class DeathLinkSendChance(Range):
    """With DeathLink on: percent chance that your death is sent to everyone else."""
    display_name = "DeathLink Send Chance"
    range_start = 0
    range_end = 100
    default = 25


class DeathLinkReceiveChance(Range):
    """With DeathLink on: percent chance that someone else's death kills you.
    Only applies while you are in an Arcade run."""
    display_name = "DeathLink Receive Chance"
    range_start = 0
    range_end = 100
    default = 40


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
    death_link: DeathLink
    death_link_send_chance: DeathLinkSendChance
    death_link_receive_chance: DeathLinkReceiveChance
