"""Static identity fixtures for verified special task targets."""
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[3] / 'src' / 'special_targets.lua'


class SpecialTargetsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.exists())
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        builder = self.lua.execute(SOURCE.read_text(encoding='utf-8'))
        self.catalog = builder()

    def test_six_verified_seaf_shells_resolve_to_exact_localized_names(self):
        expected = {
            'DC19126D15692D04': ('大炮 炸弹', 'Explosive (SEAF)'),
            '6B7EE87FB2EC6455': ('大炮 高爆弹', 'High-Yield Explosive (SEAF)'),
            'E09FCB5A280ACB1D': ('大炮 迷你核弹', 'Mini Nuke (SEAF)'),
            'E4BE3FDF0C857B7F': ('大炮 凝固汽油弹', 'Napalm (SEAF)'),
            'F598598C47617605': ('大炮 烟雾弹', 'Smoke (SEAF)'),
            'C02C2623B6359BB3': ('大炮 静电场', 'Static Field (SEAF)'),
        }
        rows = list(self.catalog.list().values())
        self.assertEqual(len(rows), len(expected))
        for resource, (name_zh, name_en) in expected.items():
            with self.subTest(resource=resource):
                row = self.catalog.resolve(resource.lower())
                self.assertEqual(row['resource'], resource)
                self.assertEqual(row['name_zh'], name_zh)
                self.assertEqual(row['name_en'], name_en)

    def test_ambiguous_shell_and_unknown_resources_are_not_guessed(self):
        for resource in ('6C62E2E25E084083', 'C8F9A2233048B836', 'DEADBEEFDEADBEEF'):
            with self.subTest(resource=resource):
                self.assertIsNone(self.catalog.resolve(resource))


if __name__ == '__main__':
    unittest.main()
