"""Reviewable task resource facts must hash to the identities the reader consumes."""
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'work/standalone/vendor/bingus'))
from archive import resource_hash
from generate_mission_targets import render


class MissionCatalogTests(unittest.TestCase):
    def test_reviewed_paths_hash_to_real_unique_spottable_resource_identities(self):
        data=json.loads((ROOT/'docs/mission-targets.json').read_text(encoding='utf-8'))
        seen=set()
        for row in data['targets']:
            with self.subTest(resource=row['resource']):
                self.assertNotIn(row['resource'],seen);seen.add(row['resource'])
                if row['path']:
                    self.assertEqual(f"{resource_hash(row['path']):016X}",row['resource'])
                self.assertIn('SpottableComponentData',row['components'])
                self.assertNotIn('AiEnemyComponentData',row['components'])
        self.assertNotIn('B0F1B354BA1D38D8',seen,'CQC-1 flag weapon is not the mission flagpole')
        self.assertNotIn('14368DC8784220B0',seen,'a weapon terminal component alone is not a task site')
        self.assertNotIn('C6A87C428FD3C7A3',seen,'a Hellbomb terminal is still stratagem equipment')

    def test_generated_catalog_matches_the_tested_fragment_and_packaged_entry(self):
        block=render()
        self.assertIn(block,(ROOT/'src/ping_events.lua').read_text(encoding='utf-8'))
        self.assertIn(block,(ROOT/'src/auto_chat.lua').read_text(encoding='utf-8'))
