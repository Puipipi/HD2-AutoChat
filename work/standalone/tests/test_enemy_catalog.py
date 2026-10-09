"""Enemy catalog rendering must preserve reviewed identity and hostility facts."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('enemy_catalog_generator', ROOT / 'tools/generate_enemy_catalog.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class EnemyCatalogTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((ROOT / 'docs/enemy-catalog.json').read_text(encoding='utf-8'))

    def rendered_rows(self, catalog=None):
        render = getattr(generator, 'render', None)
        self.assertTrue(callable(render), 'offline enemy catalog renderer is missing')
        block = render(catalog) if catalog is not None else render()
        rows = LuaRuntime(unpack_returned_tuples=True).execute(block + '\nreturn ENEMY_TARGETS')
        return {key: dict(row) for key, row in rows.items()}

    def test_rendered_runtime_catalog_contains_only_markable_hostile_resources(self):
        rows = self.rendered_rows()
        self.assertEqual(len(rows), 142)
        self.assertEqual(rows['64090088502435DD'][1], 'flying_enemy')
        self.assertEqual(rows['282EB766C1FFA6A1'][1], 'flying_enemy')
        self.assertEqual(rows['98152772A72F7838'][1], 'flying_enemy')
        self.assertEqual(rows['AC60E78435098C9D'][1], 'flying_enemy')
        self.assertEqual(rows['8FF0A839830A7692'][1], 'small_enemy')
        self.assertEqual(rows['64090088502435DD'][3], 793026793)
        for resource in ('304C3124208291E9', '5D142C3A73EBC634', '14453B8FCB040099',
                         '79CCFFD281E3F3A9', '86F3CB87D97942B4'):
            self.assertNotIn(resource, rows)

    def test_rendering_is_stable_when_input_order_changes(self):
        render = getattr(generator, 'render', None)
        self.assertTrue(callable(render), 'offline enemy catalog renderer is missing')
        reversed_catalog = copy.deepcopy(self.catalog)
        reversed_catalog['entries'].reverse()
        self.assertEqual(render(self.catalog), render(reversed_catalog))

    def test_renderer_rejects_unreviewed_friendly_or_unknown_size_rows(self):
        render = getattr(generator, 'render', None)
        self.assertTrue(callable(render), 'offline enemy catalog renderer is missing')
        for change in ({'factions': ['FactionType_SuperEarth']}, {'unit_size': 4},
                       {'flying': True, 'flight_evidence': []}):
            with self.subTest(change=change):
                catalog = copy.deepcopy(self.catalog)
                catalog['entries'][0].update(change)
                with self.assertRaises((ValueError, AssertionError)):
                    render(catalog)

    def test_label_escaping_cannot_break_generated_lua(self):
        catalog = copy.deepcopy(self.catalog)
        catalog['entries'][0]['name_zh'] = "quote' and backslash\\ plus newline\n"
        rows = self.rendered_rows(catalog)
        self.assertEqual(rows['0002BA767DF856F3'][2], "quote' and backslash\\ plus newline\n")

    def test_embedded_runtime_catalog_matches_offline_render(self):
        render = getattr(generator, 'render', None)
        self.assertTrue(callable(render), 'offline enemy catalog renderer is missing')
        self.assertIn(render(), (ROOT / 'src/ping_events.lua').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
