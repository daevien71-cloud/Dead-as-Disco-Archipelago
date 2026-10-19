import random
import tempfile
import unittest
from pathlib import Path

from ..data import (
    BLACKOUT_TRAP, DISCO_FEVER, GOLD_RECORD, ITEM_NAME_TO_ID, KILL_LOCATIONS, METEOR_TRAP, MIRROR_BALL_SHIELD,
    SLOW_MO_TRAP, WAVE_LOCATIONS, kill_location_name, wave_location_name,
)
from ..tracker import Settings, Tracker


def meteor_status(ready: bool = True, active: bool = False) -> dict:
    return {"effects": ["slowmo", "fastforward", "molasses", "blackout", "fever", "meteor"],
            "meteor_ready": ready, "effect": "meteor" if active else "", "in_run": True}


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

    def test_is_new_only_without_saved_progress(self) -> None:
        t = self.make()
        self.assertTrue(t.is_new)
        t.save()
        self.assertFalse(Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append).is_new)

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
        # The same clear arrives again from the game's status: no second reminder.
        t.on_wave(20)
        self.assertEqual(sum("more Gold Record" in line for line in self.logs), 1)
        self.clock.now += 60  # a later run reaches the goal wave again: remind again
        t.on_wave(20)
        self.assertEqual(sum("more Gold Record" in line for line in self.logs), 2)
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

    def test_meteor_waits_for_capability_without_losing_item_or_spamming(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        for status in ({"in_run": True}, {"in_run": True, "effects": ["blackout"]},
                       {"in_run": True, "effects": None}, {"in_run": True, "effects": "meteor"}):
            self.assertIsNone(t.next_effect_to_send(True, status))
        self.assertEqual(t.state.effects_done, 0)
        self.assertEqual(t.effect_queue(), [METEOR_TRAP, BLACKOUT_TRAP])
        self.assertEqual(sum("update the game mod" in line for line in self.logs), 1)
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (METEOR_TRAP, "meteor"))

    def test_meteor_waits_for_live_ready_status(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP))
        self.assertIsNone(t.next_effect_to_send(True))
        self.assertIsNone(t.next_effect_to_send(False, meteor_status()))
        self.assertIsNone(t.next_effect_to_send(True, meteor_status(ready=False)))
        missing_ready = meteor_status()
        del missing_ready["meteor_ready"]
        self.assertIsNone(t.next_effect_to_send(True, missing_ready))
        self.assertEqual(t.effect_queue(), [METEOR_TRAP])
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (METEOR_TRAP, "meteor"))

    def test_temporary_meteor_failures_keep_item_and_back_off(self) -> None:
        for reason in ("busy", "paused", "airborne", "downtime", "not_in_run"):
            with self.subTest(reason=reason):
                t = self.make()
                t.set_received(ids(METEOR_TRAP))
                t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
                self.event(t, 1, type="effect_failed", command_id=1, reason=reason)
                self.assertEqual(t.effect_queue(), [METEOR_TRAP])
                self.assertEqual(t.state.effects_done, 0)
                self.assertIsNone(t.next_effect_to_send(True, meteor_status()))
                self.clock.now += 2.9
                self.assertIsNone(t.next_effect_to_send(True, meteor_status()))
                self.clock.now += 0.1
                self.assertEqual(t.next_effect_to_send(True, meteor_status()), (METEOR_TRAP, "meteor"))

    def test_meteor_consumption_persists_at_start_and_is_not_doubled(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_start", command_id=1)
        self.assertTrue(t.pending_effect.consumed)
        self.assertEqual(t.state.effects_done, 1)
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        self.assertEqual(again.effect_queue(), [BLACKOUT_TRAP])
        self.assertTrue(again.pending_effect.started)
        self.assertTrue(again.pending_effect.consumed)
        self.assertIsNone(again.next_effect_to_send(True, meteor_status(active=True)))
        self.event(again, 2, type="effect_end", command_id=1)
        self.assertEqual(again.state.effects_done, 1)
        # A duplicate start under a new event sequence must not consume the next queued item.
        self.event(t, 2, type="effect_start", command_id=1)
        self.event(t, 3, type="effect_end", command_id=1)
        self.assertEqual(t.state.effects_done, 1)
        self.clock.now += 3
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (BLACKOUT_TRAP, "blackout"))

    def test_meteor_command_survives_restart_before_start_acknowledgement(self) -> None:
        t = self.make()
        received = ids(METEOR_TRAP, BLACKOUT_TRAP)
        t.set_received(received)
        t.effect_sent(7, *t.next_effect_to_send(True, meteor_status()))
        # Disconnect or restart between dispatch and the next bridge poll.
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(received)
        self.assertEqual(again.pending_effect.command_id, 7)
        self.assertFalse(again.pending_effect.started)
        self.assertEqual(again.state.effects_done, 0)
        self.event(again, 1, type="effect_start", command_id=7)
        self.assertEqual(again.state.effects_done, 1)
        self.assertIsNone(again.next_effect_to_send(True, meteor_status(active=True)))
        self.event(again, 2, type="effect_end", command_id=7)
        self.assertEqual(again.state.effects_done, 1)
        after_end = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        after_end.set_received(received)
        self.assertIsNone(after_end.pending_effect)
        self.assertEqual(after_end.effect_queue(), [BLACKOUT_TRAP])

    def test_temporary_failure_clears_persisted_meteor_command(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_failed", command_id=1, reason="downtime")
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(ids(METEOR_TRAP))
        self.assertIsNone(again.pending_effect)
        self.assertEqual(again.state.effects_done, 0)
        self.assertEqual(again.effect_queue(), [METEOR_TRAP])

    def test_unacknowledged_meteor_retries_after_restart_if_command_was_never_read(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(ids(METEOR_TRAP))
        self.assertIsNone(again.next_effect_to_send(True, meteor_status()))
        self.clock.now += 10
        self.assertEqual(again.next_effect_to_send(True, meteor_status()), (METEOR_TRAP, "meteor"))
        self.assertEqual(again.state.effects_done, 0)

    def test_meteor_active_status_suspends_watchdog_through_pause(self) -> None:
        t = self.make(effect_duration=5)
        t.set_received(ids(METEOR_TRAP, DISCO_FEVER))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_start", command_id=1)
        self.clock.now += 3600  # paused real-time; the mod still owns its warning/meteor/remnant
        self.assertIsNone(t.next_effect_to_send(True, meteor_status(ready=False, active=True)))
        self.assertIsNotNone(t.pending_effect)
        self.assertEqual(t.state.effects_done, 1)
        # Missing heartbeat also cannot prove that a paused native meteor finished.
        self.assertIsNone(t.next_effect_to_send(False))
        self.assertIsNotNone(t.pending_effect)
        self.event(t, 2, type="effect_end", command_id=1)
        self.clock.now += 3
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (DISCO_FEVER, "fever"))

    def test_five_meteor_batch_consumes_once_and_blocks_queue_across_restart(self) -> None:
        t = self.make(effect_duration=5)
        received = ids(METEOR_TRAP, BLACKOUT_TRAP)
        t.set_received(received)
        t.effect_sent(7, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_start", command_id=7, meteor_count=5)
        self.assertEqual(t.state.effects_done, 1)
        self.assertEqual(t.effect_queue(), [BLACKOUT_TRAP])
        # A long batch and a pause must outlive both the 6-second start timeout and the normal watchdog.
        self.clock.now += 120
        self.assertIsNone(t.next_effect_to_send(True, meteor_status(active=True, ready=False)))
        self.assertIsNotNone(t.pending_effect)
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(received)
        self.assertTrue(again.pending_effect.consumed)
        self.assertEqual(again.state.effects_done, 1)
        self.clock.now += 120
        self.assertIsNone(again.next_effect_to_send(True, meteor_status(active=True, ready=False)))
        self.event(again, 2, type="effect_start", command_id=7, meteor_count=5)
        self.assertEqual(again.state.effects_done, 1)
        self.event(again, 3, type="effect_end", command_id=7, meteor_count=5, reason="native_finished")
        self.assertEqual(again.state.effects_done, 1)
        self.assertIsNone(again.pending_effect)
        self.clock.now += 3
        self.assertEqual(again.next_effect_to_send(True, meteor_status()), (BLACKOUT_TRAP, "blackout"))

    def test_active_meteor_without_start_ack_never_gets_reissued(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.clock.now += 3600
        self.assertIsNone(t.next_effect_to_send(True, meteor_status(active=True)))
        self.assertIsNotNone(t.pending_effect)
        self.assertFalse(t.pending_effect.started)
        self.event(t, 1, type="effect_end", command_id=1)
        self.assertEqual(t.state.effects_done, 1)  # end acknowledgement still spends exactly one item

    def test_stale_meteor_watchdog_recovers_only_when_mod_is_no_longer_active(self) -> None:
        t = self.make(effect_duration=5)
        t.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_start", command_id=1)
        self.clock.now += 3600
        self.assertIsNone(t.next_effect_to_send(True, meteor_status(active=True)))
        # The bridge returns None for a missing or stale heartbeat. Neither permits recovery.
        for unavailable in (None, {}):
            self.assertIsNone(t.next_effect_to_send(False, unavailable))
            self.assertIsNotNone(t.pending_effect)
            self.assertTrue(t.pending_effect.consumed)
            self.assertEqual(t.state.effects_done, 1)
        fresh = meteor_status()
        fresh["effect"] = None
        self.assertIsNone(t.next_effect_to_send(True, fresh))
        self.assertIsNone(t.pending_effect)
        self.assertEqual(t.state.effects_done, 1)
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        self.assertIsNone(again.pending_effect)
        self.assertEqual(again.effect_queue(), [BLACKOUT_TRAP])
        self.clock.now += 3
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (BLACKOUT_TRAP, "blackout"))

    def test_failed_meteor_is_consumed_once_and_queue_continues(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_failed", command_id=1, reason="native class unavailable")
        self.assertEqual(t.state.effects_done, 1)
        self.assertTrue(any("native class unavailable" in line for line in self.logs))
        self.clock.now += 3
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (BLACKOUT_TRAP, "blackout"))

    def test_blocked_meteor_retries_twice_then_skips_once(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        for attempt in range(1, 4):
            t.effect_sent(attempt, *t.next_effect_to_send(True, meteor_status()))
            self.event(t, attempt, type="effect_failed", command_id=attempt, reason="spawn_blocked")
            self.assertIsNone(t.next_effect_to_send(True, meteor_status()))
            if attempt < 3:
                self.assertEqual(t.state.effects_done, 0)
                self.assertEqual(t.state.meteor_start_failures, attempt)
                self.assertEqual(t.effect_queue(), [METEOR_TRAP, BLACKOUT_TRAP])
                self.clock.now += 2.9
                self.assertIsNone(t.next_effect_to_send(True, meteor_status()))
                self.clock.now += 0.1
        self.assertEqual(t.state.effects_done, 1)
        self.assertEqual(t.state.meteor_start_failures, 0)
        self.assertEqual(t.state.meteor_retry_at, 0)
        self.assertEqual(sum("skipped after 3 failed start attempts" in line for line in self.logs), 1)
        self.event(t, 4, type="effect_failed", command_id=3, reason="spawn_blocked")
        self.assertEqual(t.state.effects_done, 1)
        self.assertEqual(sum("skipped after 3 failed start attempts" in line for line in self.logs), 1)
        self.clock.now += 3
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (BLACKOUT_TRAP, "blackout"))

    def test_meteor_asset_failure_counter_and_backoff_survive_restart(self) -> None:
        t = self.make()
        received = ids(METEOR_TRAP, BLACKOUT_TRAP)
        t.set_received(received)
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_failed", command_id=1, reason="asset_unavailable")
        again = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        again.set_received(received)
        self.assertEqual(again.state.meteor_start_failures, 1)
        self.assertIsNone(again.pending_effect)
        self.assertIsNone(again.next_effect_to_send(True, meteor_status()))
        self.clock.now += 3
        again.effect_sent(2, *again.next_effect_to_send(True, meteor_status()))
        self.event(again, 2, type="effect_failed", command_id=2, reason="spawn_failed")
        self.assertEqual(again.state.meteor_start_failures, 2)
        self.clock.now += 3
        again.effect_sent(3, *again.next_effect_to_send(True, meteor_status()))
        self.event(again, 3, type="effect_start", command_id=3)
        self.event(again, 4, type="effect_end", command_id=3)
        self.assertEqual(again.state.effects_done, 1)
        self.assertEqual(again.state.meteor_start_failures, 0)
        self.assertEqual(again.state.meteor_retry_at, 0)
        self.assertFalse(any("skipped after" in line for line in self.logs))
        restored = Tracker(t.settings, t.state_path, clock=self.clock, log=self.logs.append)
        self.assertEqual(restored.state.meteor_start_failures, 0)

    def test_started_meteor_failure_does_not_retry_or_double_consume(self) -> None:
        t = self.make()
        t.set_received(ids(METEOR_TRAP, BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True, meteor_status()))
        self.event(t, 1, type="effect_start", command_id=1)
        self.event(t, 2, type="effect_failed", command_id=1, reason="spawn_failed")
        self.assertIsNone(t.pending_effect)
        self.assertEqual(t.state.effects_done, 1)
        self.assertEqual(t.state.meteor_start_failures, 0)
        self.assertFalse(any("retrying" in line for line in self.logs))
        self.clock.now += 3
        self.assertEqual(t.next_effect_to_send(True, meteor_status()), (BLACKOUT_TRAP, "blackout"))

    def test_normal_effect_hard_failure_still_consumes_without_meteor_retry(self) -> None:
        t = self.make()
        t.set_received(ids(BLACKOUT_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True))
        self.event(t, 1, type="effect_failed", command_id=1, reason="asset_unavailable")
        self.assertEqual(t.state.effects_done, 1)
        self.assertEqual(t.state.meteor_start_failures, 0)
        self.assertFalse(any("retrying" in line for line in self.logs))

    def test_legacy_effect_still_consumes_on_end(self) -> None:
        t = self.make()
        t.set_received(ids(BLACKOUT_TRAP, METEOR_TRAP))
        t.effect_sent(1, *t.next_effect_to_send(True))
        self.event(t, 1, type="effect_start", command_id=1)
        self.assertEqual(t.state.effects_done, 0)
        self.event(t, 2, type="effect_end", command_id=1)
        self.assertEqual(t.state.effects_done, 1)
