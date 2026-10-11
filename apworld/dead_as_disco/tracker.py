"""Client-side game rules: which checks a game event earns, effect queueing, DeathLink rolls.

No networking here, so it can be tested without a server or the game.
"""

import json
import random
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from .data import (
    GOLD_RECORD, ITEM_EFFECTS, ITEM_ID_TO_NAME, KILL_LOCATIONS, MIRROR_BALL_SHIELD, WAVE_LOCATIONS,
    kill_location_name, wave_location_name,
)

# A death this soon after we told the game to kill the player came from DeathLink.
DEATHLINK_KILL_WINDOW = 15.0
# Ignore deaths that were already old when the client read them (e.g. after a client restart).
STALE_DEATH_SECONDS = 20.0
EFFECT_START_TIMEOUT = 6.0
EFFECT_GAP_SECONDS = 3.0


@dataclass
class SavedState:
    kills: int = 0
    best_wave: int = 0
    effects_done: int = 0
    shields_used: int = 0
    goal_sent: bool = False
    last_event_session: Optional[str] = None
    last_event_seq: int = 0


@dataclass
class Settings:
    goal_wave: int
    gold_records_required: int
    waves: list[int]
    kill_thresholds: list[int]
    effect_duration: int = 15
    death_link: bool = False
    death_link_send_chance: int = 25
    death_link_receive_chance: int = 40

    @classmethod
    def from_slot_data(cls, slot_data: dict[str, Any]) -> "Settings":
        names = {f.name for f in cls.__dataclass_fields__.values()}
        return cls(**{k: v for k, v in slot_data.items() if k in names})


@dataclass
class PendingEffect:
    command_id: int
    effect: str
    item_name: str
    sent_at: float
    started: bool = False


@dataclass
class Tracker:
    settings: Settings
    state_path: Optional[Path] = None
    rng: random.Random = field(default_factory=random.Random)
    clock: Callable[[], float] = time.time
    log: Callable[[str], None] = print

    state: SavedState = field(init=False)
    received: list[str] = field(init=False, default_factory=list)
    pending_effect: Optional[PendingEffect] = field(init=False, default=None)
    next_effect_at: float = field(init=False, default=0.0)
    deathlink_kill_at: float = field(init=False, default=-1e9)

    def __post_init__(self) -> None:
        self.state = SavedState()
        if self.state_path and self.state_path.exists():
            try:
                saved = json.loads(self.state_path.read_text(encoding="utf-8"))
                self.state = SavedState(**{k: v for k, v in saved.items() if k in SavedState.__dataclass_fields__})
            except (OSError, ValueError, TypeError):
                self.log("Could not read saved progress; starting fresh.")

    def save(self) -> None:
        if self.state_path:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.state_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(asdict(self.state), indent=1), encoding="utf-8")
            tmp.replace(self.state_path)

    # ----- items -------------------------------------------------------------------------

    def set_received(self, item_ids: list[int]) -> None:
        self.received = [ITEM_ID_TO_NAME.get(i, "") for i in item_ids]

    @property
    def gold_records(self) -> int:
        return self.received.count(GOLD_RECORD)

    @property
    def shields_available(self) -> int:
        return max(0, self.received.count(MIRROR_BALL_SHIELD) - self.state.shields_used)

    def effect_queue(self) -> list[str]:
        effects = [name for name in self.received if name in ITEM_EFFECTS]
        return effects[self.state.effects_done:]

    # ----- game events -------------------------------------------------------------------

    def locations_for_wave(self, cleared: int) -> list[int]:
        return [WAVE_LOCATIONS[wave_location_name(w)] for w in self.settings.waves if w <= cleared]

    def locations_for_kills(self) -> list[int]:
        return [KILL_LOCATIONS[kill_location_name(k)] for k in self.settings.kill_thresholds
                if k <= self.state.kills]

    def is_new_event(self, event: dict[str, Any]) -> bool:
        session, seq = event.get("game_session"), event.get("seq")
        if not isinstance(seq, int) or session is None:
            return True
        if session == self.state.last_event_session and seq <= self.state.last_event_seq:
            return False
        self.state.last_event_session, self.state.last_event_seq = session, seq
        return True

    def handle_event(self, event: dict[str, Any]) -> dict[str, Any]:
        """Returns {"locations": [...], "goal": bool, "send_death": bool}."""
        result: dict[str, Any] = {"locations": [], "goal": False, "send_death": False}
        if not self.is_new_event(event):
            return result
        kind = event.get("type")
        if kind == "wave":
            result.update(self.on_wave(int(event.get("wave", 0))))
        elif kind == "kill":
            self.state.kills += int(event.get("count", 1))
            result["locations"] = self.locations_for_kills()
        elif kind == "death":
            result["send_death"] = self.on_death(event)
        elif kind in ("effect_start", "effect_end", "effect_failed"):
            self.on_effect_event(event)
        elif kind == "log":
            self.log(f"[game] {event.get('text', '')}")
        return result

    def on_wave(self, cleared: int) -> dict[str, Any]:
        result: dict[str, Any] = {"locations": self.locations_for_wave(cleared), "goal": False}
        if cleared > self.state.best_wave:
            self.state.best_wave = cleared
        if cleared >= self.settings.goal_wave:
            if self.gold_records >= self.settings.gold_records_required:
                result["goal"] = not self.state.goal_sent
            elif cleared == self.settings.goal_wave:
                missing = self.settings.gold_records_required - self.gold_records
                self.log(f"Wave {cleared} cleared, but you still need {missing} more Gold Record(s) for the goal.")
        return result

    def on_death(self, event: dict[str, Any]) -> bool:
        now = self.clock()
        if now - float(event.get("t", now)) > STALE_DEATH_SECONDS:
            return False
        if now - self.deathlink_kill_at < DEATHLINK_KILL_WINDOW:
            self.deathlink_kill_at = -1e9
            self.log("You died to a DeathLink, so this death is not sent on.")
            return False
        if not self.settings.death_link:
            return False
        roll = self.rng.randrange(100)
        chance = self.settings.death_link_send_chance
        if roll < chance:
            self.log(f"You died. DeathLink roll {roll} < {chance}: sending your death to everyone!")
            return True
        self.log(f"You died. DeathLink roll {roll} >= {chance}: your friends are spared this time.")
        return False

    def on_incoming_deathlink(self, source: str, in_run: bool) -> bool:
        """Returns True when the game should kill the player now."""
        if not in_run:
            self.log(f"DeathLink from {source} ignored: you're not in an Arcade run.")
            return False
        roll = self.rng.randrange(100)
        chance = self.settings.death_link_receive_chance
        if roll >= chance:
            self.log(f"DeathLink from {source}: roll {roll} >= {chance}, you survive!")
            return False
        if self.shields_available > 0:
            self.state.shields_used += 1
            self.save()
            self.log(f"DeathLink from {source}: roll {roll} < {chance}, but your Mirror Ball Shield "
                     f"blocked it! ({self.shields_available} left)")
            return False
        self.log(f"DeathLink from {source}: roll {roll} < {chance}. Down you go!")
        self.deathlink_kill_at = self.clock()
        return True

    # ----- effects -----------------------------------------------------------------------

    def next_effect_to_send(self, in_run: bool) -> Optional[tuple[str, str]]:
        """(item name, effect key) to send now, or None."""
        now = self.clock()
        if self.pending_effect:
            p = self.pending_effect
            if not p.started and now - p.sent_at > EFFECT_START_TIMEOUT:
                self.pending_effect = None  # game didn't answer; try again later
            elif p.started and now - p.sent_at > self.settings.effect_duration + 15:
                self.finish_effect()  # never heard the end; assume it ran
            else:
                return None
        if not in_run or now < self.next_effect_at:
            return None
        queue = self.effect_queue()
        if not queue:
            return None
        return queue[0], ITEM_EFFECTS[queue[0]]

    def effect_sent(self, command_id: int, item_name: str, effect: str) -> None:
        self.pending_effect = PendingEffect(command_id, effect, item_name, self.clock())

    def on_effect_event(self, event: dict[str, Any]) -> None:
        p = self.pending_effect
        if not p or event.get("command_id") != p.command_id:
            return
        kind = event["type"]
        if kind == "effect_start":
            p.started = True
            self.log(f"{p.item_name} is active!")
        elif kind == "effect_end":
            self.log(f"{p.item_name} wore off.")
            self.finish_effect()
        elif kind == "effect_failed":
            reason = event.get("reason", "unknown")
            if reason == "not_in_run":
                self.pending_effect = None  # the run ended first; keep it for the next run
                return
            self.log(f"{p.item_name} could not be applied in-game: {reason}")
            self.finish_effect()

    def finish_effect(self) -> None:
        self.pending_effect = None
        self.state.effects_done += 1
        self.next_effect_at = self.clock() + EFFECT_GAP_SECONDS
        self.save()
