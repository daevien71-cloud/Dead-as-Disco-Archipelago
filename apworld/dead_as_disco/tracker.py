"""Client-side game rules: which checks a game event earns, effect queueing, DeathLink rolls.

No networking here, so it can be tested without a server or the game.
"""

import json
import math
import random
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from .data import (
    GOLD_RECORD, ITEM_EFFECTS, ITEM_ID_TO_NAME, KILL_LOCATIONS, MIRROR_BALL_SHIELD, WAVE_LOCATIONS,
    TRAPS, kill_location_name, wave_location_name,
)

# A death this soon after we told the game to kill the player came from DeathLink.
DEATHLINK_KILL_WINDOW = 15.0
# Ignore deaths that were already old when the client read them (e.g. after a client restart).
STALE_DEATH_SECONDS = 20.0
EFFECT_START_TIMEOUT = 6.0
EFFECT_GAP_SECONDS = 3.0
TRAP_REST_MIN_SECONDS = 20
TRAP_REST_MAX_SECONDS = 30
GOAL_HINT_REPEAT_SECONDS = 30.0
TEMPORARY_EFFECT_FAILURES = {"busy", "paused", "airborne", "downtime", "not_in_run"}
NATIVE_EFFECTS = {"meteor", "cars"}
NATIVE_RETRYABLE_START_FAILURES = {"spawn_blocked", "asset_unavailable", "spawn_failed"}
NATIVE_START_MAX_ATTEMPTS = 3


def supports_effect(status: Optional[dict[str, Any]], effect: str) -> bool:
    effects = (status or {}).get("effects")
    return isinstance(effects, list) and effect in effects


@dataclass
class SavedState:
    kills: int = 0
    best_wave: int = 0
    effects_done: int = 0
    shields_used: int = 0
    goal_sent: bool = False
    last_event_session: Optional[str] = None
    last_event_seq: int = 0
    # Legacy 0.2.0 file keys: these now journal the ONE native-effect slot (meteor or cars).
    # Keep their spelling so existing pending commands and retry deadlines need no migration.
    pending_meteor: Optional[dict[str, Any]] = None
    meteor_start_failures: int = 0
    meteor_retry_at: float = 0.0
    pending_effect: Optional[dict[str, Any]] = None
    trap_rest_remaining: float = 0.0


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
    consumed: bool = False
    command_session: Optional[str] = None


@dataclass
class Tracker:
    settings: Settings
    state_path: Optional[Path] = None
    rng: random.Random = field(default_factory=random.Random)
    clock: Callable[[], float] = time.time
    log: Callable[[str], None] = print
    notify: Callable[[str], None] = lambda text: None  # on-screen pop-up in the game
    rest_rng: random.Random = field(default_factory=random.Random)

    state: SavedState = field(init=False)
    received: list[str] = field(init=False, default_factory=list)
    pending_effect: Optional[PendingEffect] = field(init=False, default=None)
    next_effect_at: float = field(init=False, default=0.0)
    deathlink_kill_at: float = field(init=False, default=-1e9)
    goal_hint_at: float = field(init=False, default=-1e9)
    native_update_notified: set[str] = field(init=False, default_factory=set)
    rest_update_notified: bool = field(init=False, default=False)
    _rest_cursor: Optional[tuple[str, float]] = field(init=False, default=None)
    _clock_floor: Optional[tuple[str, float]] = field(init=False, default=None)

    def __post_init__(self) -> None:
        self.state = SavedState()
        # No saved progress means this is the first time this slot of this multiworld is played here.
        self.is_new = not (self.state_path and self.state_path.exists())
        if self.state_path and self.state_path.exists():
            try:
                saved = json.loads(self.state_path.read_text(encoding="utf-8"))
                self.state = SavedState(**{k: v for k, v in saved.items() if k in SavedState.__dataclass_fields__})
            except (OSError, ValueError, TypeError):
                self.log("Could not read saved progress; starting fresh.")
        journal = self.state.pending_effect or self.state.pending_meteor
        if journal:
            try:
                pending = PendingEffect(**journal)
                supported = ITEM_EFFECTS.values() if self.state.pending_effect else NATIVE_EFFECTS
                if pending.effect in supported:
                    self.pending_effect = pending
            except (TypeError, ValueError):
                self.log("Could not restore the pending effect command.")
        rest = self.state.trap_rest_remaining
        if isinstance(rest, bool) or not isinstance(rest, (int, float)) or not math.isfinite(rest) or rest < 0:
            self.state.trap_rest_remaining = 0.0
        self.next_effect_at = self.state.meteor_retry_at

    def save(self) -> None:
        pending = self.pending_effect
        self.state.pending_effect = asdict(pending) if pending else None
        # Retain the old native journal without new fields so older clients can still read it.
        self.state.pending_meteor = ({k: v for k, v in asdict(pending).items() if k != "command_session"}
                                     if pending and pending.effect in NATIVE_EFFECTS else None)
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
            elif cleared == self.settings.goal_wave and self.clock() - self.goal_hint_at > GOAL_HINT_REPEAT_SECONDS:
                # The game reports a clear both as an event and in its status, so only remind once per run.
                self.goal_hint_at = self.clock()
                missing = self.settings.gold_records_required - self.gold_records
                self.log(f"Wave {cleared} cleared, but you still need {missing} more Gold Record(s) for the goal.")
                self.notify(f"Goal wave cleared, but you need {missing} more Gold Record(s)")
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
            self.notify("Your death was sent to everyone!")
            return True
        self.log(f"You died. DeathLink roll {roll} >= {chance}: your friends are spared this time.")
        self.notify("You died, but your friends are spared")
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
            self.notify(f"{source} died. You survive!")
            return False
        if self.shields_available > 0:
            self.state.shields_used += 1
            self.save()
            self.log(f"DeathLink from {source}: roll {roll} < {chance}, but your Mirror Ball Shield "
                     f"blocked it! ({self.shields_available} left)")
            self.notify(f"Mirror Ball Shield blocked {source}'s DeathLink!")
            return False
        self.log(f"DeathLink from {source}: roll {roll} < {chance}. Down you go!")
        self.notify(f"{source} died and takes you down with them!")
        self.deathlink_kill_at = self.clock()
        return True

    # ----- effects -----------------------------------------------------------------------

    @staticmethod
    def _clock_sample(status: Optional[dict[str, Any]]) -> Optional[tuple[str, float]]:
        if not status or status.get("clock_version") != 1:
            return None
        session, seconds = status.get("session"), status.get("active_play_seconds")
        if (not isinstance(session, str) or not session or isinstance(seconds, bool)
                or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0
                or not isinstance(status.get("active_play"), bool)):
            return None
        return session, float(seconds)

    def _advance_trap_rest(self, status: Optional[dict[str, Any]]) -> None:
        sample = self._clock_sample(status)
        if sample is None:
            return
        previous = self._rest_cursor
        if previous is None or previous[0] != sample[0]:
            # Reconnects and game restarts resume the saved rest without credit for time away.
            self._rest_cursor = sample
            return
        if sample[1] < previous[1]:
            return  # a heartbeat can predate the end event; never move that anchor backwards
        self._rest_cursor = sample
        remaining = self.state.trap_rest_remaining
        self.state.trap_rest_remaining = max(0.0, remaining - (sample[1] - previous[1]))
        if math.ceil(remaining) != math.ceil(self.state.trap_rest_remaining):
            self.save()  # at most once per elapsed second, with the final zero saved too

    def observe_status(self, status: Optional[dict[str, Any]]) -> None:
        """Sample before replaying events, so an offline completion cannot spend a new rest."""
        sample = self._clock_sample(status)
        if sample is not None and (self._clock_floor is None or self._clock_floor[0] != sample[0]):
            self._clock_floor = sample
        self._advance_trap_rest(status)

    def next_effect_to_send(self, in_run: bool, status: Optional[dict[str, Any]] = None) -> Optional[tuple[str, str]]:
        """(item name, effect key) to send now, or None."""
        now = self.clock()
        self.observe_status(status)
        # A live effect heartbeat outranks the timeout, including after a client restart.
        if status and status.get("effect") in ITEM_EFFECTS.values():
            return None
        if self.pending_effect:
            p = self.pending_effect
            if not status:
                return None  # no heartbeat is not evidence that a command failed or finished
            if not p.started and now - p.sent_at > EFFECT_START_TIMEOUT:
                self.pending_effect = None  # game didn't answer; try again later
                self.save()
            elif p.started and now - p.sent_at > self.settings.effect_duration + 15:
                self.finish_effect()  # never heard the end; assume it ran
            else:
                return None
        if not in_run or now < self.next_effect_at:
            return None
        queue = self.effect_queue()
        if not queue:
            return None
        effect = ITEM_EFFECTS[queue[0]]
        if queue[0] in TRAPS:
            sample = self._clock_sample(status)
            if self.state.trap_rest_remaining > 0:
                if status and sample is None and not self.rest_update_notified:
                    self.log("Queued traps are resting: update both the game mod and APWorld for "
                             "20–30 seconds of active play between traps. Your queued items have been kept.")
                    self.rest_update_notified = True
                return None
            if status and status.get("clock_version") == 1 and (sample is None or status.get("active_play") is not True):
                return None
        if effect in NATIVE_EFFECTS:
            if not supports_effect(status, effect):
                if status and effect not in self.native_update_notified:
                    self.log(f"{queue[0]} is waiting: update the game mod to a version with {effect} support. "
                             "Your queued item has been kept.")
                    self.native_update_notified.add(effect)
                return None
            if status.get(f"{effect}_ready") is not True:
                return None
        return queue[0], effect

    def effect_sent(self, command_id: int, item_name: str, effect: str,
                    command_session: Optional[str] = None) -> None:
        self.pending_effect = PendingEffect(command_id, effect, item_name, self.clock(),
                                            command_session=command_session)
        # The bridge calls this before appending the command. Reconnects can then match its
        # acknowledgements even if the client exits immediately after the game accepts it.
        self.save()

    def on_effect_event(self, event: dict[str, Any]) -> None:
        p = self.pending_effect
        if not p or event.get("command_id") != p.command_id:
            return
        if p.command_session is not None and event.get("command_session") != p.command_session:
            return
        if event.get("effect", p.effect) != p.effect:
            return
        kind = event["type"]
        if kind == "effect_start":
            if p.started:
                return
            p.started = True
            if p.effect in NATIVE_EFFECTS:
                # Spend the whole native batch once at acceptance. Persist before a restart can
                # launch the same trap again while its actors or remaining sets still exist.
                p.consumed = True
                self.state.effects_done += 1
            self.save()
            self.log(f"{p.item_name} is active!")
        elif kind == "effect_end":
            self.log(f"{p.item_name} wore off.")
            self.finish_effect(completed=True, event=event)
        elif kind == "effect_failed":
            reason = event.get("reason", "unknown")
            if p.effect in NATIVE_EFFECTS and not p.started and not p.consumed and reason in NATIVE_RETRYABLE_START_FAILURES:
                self.state.meteor_start_failures += 1
                attempts = self.state.meteor_start_failures
                if attempts < NATIVE_START_MAX_ATTEMPTS:
                    self.pending_effect = None
                    self.next_effect_at = self.clock() + EFFECT_GAP_SECONDS
                    self.state.meteor_retry_at = self.next_effect_at
                    self.log(f"{p.item_name} could not start ({reason}, attempt {attempts}/{NATIVE_START_MAX_ATTEMPTS}); "
                             "keeping the item and retrying in 3 seconds.")
                    self.save()
                    return
                self.log(f"{p.item_name} skipped after {NATIVE_START_MAX_ATTEMPTS} failed start attempts ({reason}). "
                         "This item is consumed so the remaining effects can continue.")
                self.finish_effect()
                return
            if reason in TEMPORARY_EFFECT_FAILURES and not p.started:
                self.pending_effect = None  # not started; keep it for the next safe opportunity
                self.next_effect_at = self.clock() + EFFECT_GAP_SECONDS
                self.save()
                return
            self.log(f"{p.item_name} could not be applied in-game: {reason}")
            self.finish_effect(event=event)

    def finish_effect(self, completed: bool = False, event: Optional[dict[str, Any]] = None) -> None:
        pending = self.pending_effect
        if pending is None:
            return
        self.pending_effect = None
        if not pending.consumed:
            self.state.effects_done += 1
        self.state.meteor_start_failures = 0
        self.state.meteor_retry_at = 0.0
        self.next_effect_at = self.clock() + EFFECT_GAP_SECONDS
        if pending.item_name in TRAPS and (completed or pending.started):
            self.state.trap_rest_remaining = float(self.rest_rng.randint(TRAP_REST_MIN_SECONDS, TRAP_REST_MAX_SECONDS))
            # Completion stamps exclude time spent inside the preceding trap. The ordinary
            # heartbeat may be older; without a stamp the next heartbeat establishes a baseline.
            self._rest_cursor = self._clock_sample({
                "clock_version": 1, "session": (event or {}).get("game_session"),
                "active_play": True, "active_play_seconds": (event or {}).get("active_play_seconds"),
            })
            if (self._rest_cursor is not None and self._clock_floor is not None
                    and self._rest_cursor[0] == self._clock_floor[0]
                    and self._rest_cursor[1] < self._clock_floor[1]):
                self._rest_cursor = self._clock_floor
            self.log(f"Next queued trap rests for {int(self.state.trap_rest_remaining)} seconds of active Arcade play.")
        self.save()
