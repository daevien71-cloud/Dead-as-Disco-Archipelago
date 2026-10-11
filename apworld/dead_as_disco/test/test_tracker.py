import random
import tempfile
import unittest
from pathlib import Path

from ..data import (
    BLACKOUT_TRAP, DISCO_FEVER, GOLD_RECORD, ITEM_NAME_TO_ID, KILL_LOCATIONS, MIRROR_BALL_SHIELD,
    SLOW_MO_TRAP, WAVE_LOCATIONS, kill_location_name, wave_location_name,
)
from ..tracker import Settings, Tracker


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def ids(*names: str) -> list[int]:
    return [ITEM_NAME_TO_ID[n] for n in names]


class TrackerTest(unittest.TestCase):
    def make(self, rolls: list[int] = (), **settings) -> Tracker:
        base = dict(goal_wave=20, gold_records_required=2, waves=[1, 2, 3, 5, 10, 15, 20],
                    kill_thresholds=[25, 50], death_link=True)
        base.update(settings)
        self.clock = FakeClock()
        self.logs: list[str] = []
        rng = random.Random()
        queue = list(rolls)
        rng.randrange = lambda n: queue.pop(0)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        return Tracker(Settings(**base), Path(self.tmp.name) / "state.json", rng=rng, clock=self.clock,
                       log=self.logs.append)

    def event(self, tracker: Tracker, seq: int, **event):
        return tracker.handle_event(dict(event, seq=seq, game_session="g1", t=self.clock.now))

    def test_wave_sends_all_lower_milestones(self) -> None:
        t = self.make()
        result = self.event(t, 1, type="wave", wave=7)
        self.assertEqual(sorted(result["locations"]),
                         sorted(WAVE_LOCATIONS[wave_location_name(w)] for w in (1, 2, 3, 5)))

    def test_duplicate_events_ignored(self) -> None:
        t = self.make()
        self.event(t, 1, type="kill", count=20)
        self.event(t, 1, type="kill", count=20)
        self.assertEqual(t.state.kills, 20)
        result = self.event(t, 2, type="kill", count=5)
        self.assertEqual(result["locations"], [KILL_LOCATIONS[kill_location_name(25)]])

    def test_kills_persist_across_restarts(self) -> None:
        t = self.make()
        self.event(t, 1, type="kill", count=30)
        t.save()
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        self.assertEqual(again.state.kills, 30)
        # Re-reading the same game session's events after a client restart doesn't double count.
        again.handle_event({"type": "kill", "count": 30, "seq": 1, "game_session": "g1"})
        self.assertEqual(again.state.kills, 30)

    def test_goal_needs_records(self) -> None:
        t = self.make()
        t.set_received(ids(GOLD_RECORD))
        self.assertFalse(self.event(t, 1, type="wave", wave=20)["goal"])
        self.assertTrue(any("1 more Gold Record" in line for line in self.logs))
        t.set_received(ids(GOLD_RECORD, GOLD_RECORD))
        self.assertFalse(self.event(t, 2, type="wave", wave=19)["goal"])
        self.assertTrue(self.event(t, 3, type="wave", wave=21)["goal"])

    def test_death_send_chance(self) -> None:
        t = self.make(rolls=[24, 25])
        self.assertTrue(self.event(t, 1, type="death")["send_death"])
        self.clock.now += 100
        self.assertFalse(self.event(t, 2, type="death")["send_death"])

    def test_death_link_off_never_sends(self) -> None:
        t = self.make(death_link=False)
        self.assertFalse(self.event(t, 1, type="death")["send_death"])

    def test_stale_death_not_sent(self) -> None:
        t = self.make(rolls=[0])
        result = t.handle_event({"type": "death", "seq": 1, "game_session": "g1", "t": self.clock.now - 60})
        self.assertFalse(result["send_death"])

    def test_deathlink_death_not_echoed(self) -> None:
        t = self.make(rolls=[10, 0])
        self.assertTrue(t.on_incoming_deathlink("Friend", in_run=True))
        self.clock.now += 3
        self.assertFalse(self.event(t, 1, type="death")["send_death"])

    def test_receive_chance_and_shield(self) -> None:
        t = self.make(rolls=[40, 39, 5, 5])
        self.assertFalse(t.on_incoming_deathlink("A", in_run=False))  # no roll used
        self.assertFalse(t.on_incoming_deathlink("A", in_run=True))   # 40 >= 40 survives
        t.set_received(ids(MIRROR_BALL_SHIELD))
        self.assertFalse(t.on_incoming_deathlink("A", in_run=True))   # 39 hits, shield blocks
        self.assertEqual(t.shields_available, 0)
        self.assertTrue(t.on_incoming_deathlink("A", in_run=True))    # 5 hits, no shield

    def test_effects_run_one_at_a_time_in_order(self) -> None:
        t = self.make()
        t.set_received(ids(SLOW_MO_TRAP, GOLD_RECORD, DISCO_FEVER, BLACKOUT_TRAP))
        self.assertIsNone(t.next_effect_to_send(in_run=False))
        first = t.next_effect_to_send(in_run=True)
        self.assertEqual(first, (SLOW_MO_TRAP, "slowmo"))
        t.effect_sent(1, *first)
        self.assertIsNone(t.next_effect_to_send(in_run=True))
        self.event(t, 1, type="effect_start", command_id=1)
        self.event(t, 2, type="effect_end", command_id=1)
        self.assertIsNone(t.next_effect_to_send(in_run=True))  # short gap between effects
        self.clock.now += 5
        self.assertEqual(t.next_effect_to_send(in_run=True), (DISCO_FEVER, "fever"))

    def test_effect_refused_outside_run_is_kept(self) -> None:
        t = self.make()
        t.set_received(ids(BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(in_run=True))
        self.event(t, 1, type="effect_failed", command_id=1, reason="not_in_run")
        self.assertEqual(t.effect_queue(), [BLACKOUT_TRAP])

    def test_unanswered_effect_is_retried(self) -> None:
        t = self.make()
        t.set_received(ids(BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(in_run=True))
        self.clock.now += 10
        self.assertEqual(t.next_effect_to_send(in_run=True), (BLACKOUT_TRAP, "blackout"))
