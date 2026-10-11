from dataclasses import dataclass
from Options import Choice, PerGameCommonOptions

class GoalWave(Choice):
    """Clear this Arcade milestone to finish. All milestone checks remain available."""
    display_name = "Goal Wave"
    default = 20
    option_wave_1 = 1
    option_wave_2 = 2
    option_wave_3 = 3
    option_wave_5 = 5
    option_wave_10 = 10
    option_wave_15 = 15
    option_wave_20 = 20
    option_wave_25 = 25
    option_wave_30 = 30
    option_wave_40 = 40
    option_wave_50 = 50
    option_wave_75 = 75
    option_wave_100 = 100
    option_wave_150 = 150
    option_wave_200 = 200

@dataclass
class ArcadeChecksOptions(PerGameCommonOptions):
    goal_wave: GoalWave
