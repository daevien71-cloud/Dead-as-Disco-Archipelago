"""Names, IDs and tuning tables shared by the world and the client.

Keep everything that might change with a game update in this one file.
"""

GAME_NAME = "Dead as Disco"
SLOT_DATA_VERSION = 1

LOCATION_BASE = 814_100_000
ITEM_BASE = 814_200_000

MAX_WAVE = 200
# Milestones are always checks. The wave_check_interval option adds more.
MILESTONE_WAVES = (1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200)
# Lifetime enemy kills, counted across every Arcade run.
KILL_THRESHOLDS = (25, 50, 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000)


def wave_location_name(wave: int) -> str:
    return f"Arcade - Clear Wave {wave}"


def kill_location_name(kills: int) -> str:
    return f"Arcade - Defeat {kills} Enemies"


WAVE_LOCATIONS = {wave_location_name(w): LOCATION_BASE + w for w in range(1, MAX_WAVE + 1)}
KILL_LOCATIONS = {kill_location_name(k): LOCATION_BASE + 1000 + i for i, k in enumerate(KILL_THRESHOLDS)}
LOCATION_NAME_TO_ID = {**WAVE_LOCATIONS, **KILL_LOCATIONS}

# Item names. "effect" is what the game mod applies when the item arrives.
GOLD_RECORD = "Gold Record"
DISCO_FEVER = "Disco Fever"
MIRROR_BALL_SHIELD = "Mirror Ball Shield"
GROOVY_VIBES = "Groovy Vibes"
SLOW_MO_TRAP = "Slow-Mo Trap"
FAST_FORWARD_TRAP = "Fast-Forward Trap"
MOLASSES_TRAP = "Molasses Trap"
BLACKOUT_TRAP = "Blackout Trap"
METEOR_TRAP = "Meteor Trap"
PROPHET_CAR_TRAP = "Prophet Car Trap"

ITEM_NAME_TO_ID = {
    GOLD_RECORD: ITEM_BASE + 1,
    DISCO_FEVER: ITEM_BASE + 2,
    MIRROR_BALL_SHIELD: ITEM_BASE + 3,
    GROOVY_VIBES: ITEM_BASE + 4,
    SLOW_MO_TRAP: ITEM_BASE + 101,
    FAST_FORWARD_TRAP: ITEM_BASE + 102,
    MOLASSES_TRAP: ITEM_BASE + 103,
    BLACKOUT_TRAP: ITEM_BASE + 104,
    METEOR_TRAP: ITEM_BASE + 105,
    PROPHET_CAR_TRAP: ITEM_BASE + 106,
}
ITEM_ID_TO_NAME = {v: k for k, v in ITEM_NAME_TO_ID.items()}

DEFAULT_TRAPS = (SLOW_MO_TRAP, FAST_FORWARD_TRAP, MOLASSES_TRAP, BLACKOUT_TRAP)
TRAPS = (*DEFAULT_TRAPS, METEOR_TRAP, PROPHET_CAR_TRAP)

# Item name -> effect key understood by the UE4SS mod (Scripts/main.lua).
ITEM_EFFECTS = {
    DISCO_FEVER: "fever",
    SLOW_MO_TRAP: "slowmo",
    FAST_FORWARD_TRAP: "fastforward",
    MOLASSES_TRAP: "molasses",
    BLACKOUT_TRAP: "blackout",
    METEOR_TRAP: "meteor",
    PROPHET_CAR_TRAP: "cars",
}

ITEM_DESCRIPTIONS = {
    GOLD_RECORD: "Collect enough of these, then clear your goal wave in a single Arcade run to win.",
    DISCO_FEVER: "Enemies move at reduced speed for a while; you keep full speed. Fires at the next opportunity during a run.",
    MIRROR_BALL_SHIELD: "Blocks the next DeathLink that would have killed you.",
    GROOVY_VIBES: "Good vibes. No gameplay effect.",
    SLOW_MO_TRAP: "The whole game runs in slow motion for a while. The music does not.",
    FAST_FORWARD_TRAP: "The whole game runs faster for a while. The music does not.",
    MOLASSES_TRAP: "Only you are slowed down for a while.",
    BLACKOUT_TRAP: "The screen goes almost completely dark (98%) for a while.",
    METEOR_TRAP: "Experimental: one trap rolls 1–5 Aurora meteors, arriving one at a time with warnings and native remnants. "
                 "Each targets where you stood when it launched. Off by default; update the game mod and APWorld together.",
    PROPHET_CAR_TRAP: "Experimental: two sets of three Prophet cars form an X around your starting position, "
                      "one diagonal at a time. Each has a two-second warning; the second waits until the first is gone. "
                      "Native cars damage you and enemies. "
                      "Off by default; update the game mod and APWorld together.",
}
