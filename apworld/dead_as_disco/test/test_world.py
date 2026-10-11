from ..data import GOLD_RECORD, MILESTONE_WAVES, TRAPS, wave_location_name
from . import DeadAsDiscoTestBase


class TestDefaults(DeadAsDiscoTestBase):
    def test_location_count(self) -> None:
        locations = self.multiworld.get_locations(self.player)
        self.assertEqual(len(locations), len(MILESTONE_WAVES) + 8)

    def test_goal_needs_gold_records(self) -> None:
        self.assertFalse(self.multiworld.has_beaten_game(self.multiworld.state))
        self.collect_by_name([GOLD_RECORD] * 5)
        self.assertTrue(self.multiworld.has_beaten_game(self.multiworld.state))

    def test_slot_data(self) -> None:
        slot_data = self.world.fill_slot_data()
        self.assertEqual(slot_data["goal_wave"], 50)
        self.assertEqual(slot_data["waves"], list(MILESTONE_WAVES))
        self.assertEqual(slot_data["death_link_send_chance"], 25)
        self.assertEqual(slot_data["death_link_receive_chance"], 40)


class TestEveryFifthWave(DeadAsDiscoTestBase):
    options = {"wave_check_interval": 5, "kill_checks": 0}

    def test_waves(self) -> None:
        names = {loc.name for loc in self.multiworld.get_locations(self.player)}
        self.assertIn(wave_location_name(35), names)
        self.assertIn(wave_location_name(3), names)
        self.assertNotIn(wave_location_name(36), names)
        self.assertEqual(len(names), 43)


class TestMoreRecordsThanLocations(DeadAsDiscoTestBase):
    options = {"kill_checks": 0, "gold_record_count": 30, "gold_records_required": 30}

    def test_records_capped(self) -> None:
        pool = [item.name for item in self.multiworld.itempool if item.player == self.player]
        self.assertEqual(pool.count(GOLD_RECORD), len(MILESTONE_WAVES))
        self.assertEqual(self.world.gold_required, len(MILESTONE_WAVES))


class TestNoTraps(DeadAsDiscoTestBase):
    options = {"enabled_traps": [], "trap_percentage": 100}

    def test_no_traps(self) -> None:
        pool = [item.name for item in self.multiworld.itempool if item.player == self.player]
        self.assertFalse(set(pool) & set(TRAPS))


class TestAllTraps(DeadAsDiscoTestBase):
    options = {"trap_percentage": 100, "gold_record_count": 1, "gold_records_required": 1}

    def test_all_non_records_are_traps(self) -> None:
        pool = [item.name for item in self.multiworld.itempool if item.player == self.player]
        self.assertEqual(sum(name in TRAPS for name in pool), len(pool) - 1)
