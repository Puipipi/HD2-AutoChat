"""Discovery, identity and consistency checks over sparse native-layout fixtures."""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[3] / 'src/stratagem_catalog.lua'
BASE, ROWS, STRINGS = 0x10000000, 0x20000000, 0x30000000
PINS = [(0x66d54c, '4b8b84fd00b67c03'), (0x179d962, '8b752c'),
        (0x183a1e5, '498b96b0000000')]


class StratagemCatalogTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.mem, self.localized, self.reads = {}, {2994328991: '500千克炸弹'}, []
        self.base = BASE
        self.raw(BASE + 0x37cb600, bytes(256 * 8))
        for offset, data in PINS:
            self.raw(BASE + offset, bytes.fromhex(data))
        self.row(3, 4119049995, 'EAGLE. 500KG BOMB', 2994328991, 1057738842,
                 icon=0xF96A659EBFFDFBE4)
        factory = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_stratagem_catalog')
        self.reader = factory(self.lua.table_from({
            'base': lambda: self.base, 'read': self.read,
            'localize': lambda key: self.localized.get(int(key)),
            'resource_aliases': self.lua.table_from({'00000000abcdef01': 4119049995}),
        }))

    def raw(self, at, data):
        self.mem.update({at + n: b for n, b in enumerate(data)})

    def put(self, at, fmt, *values):
        self.raw(at, struct.pack(fmt, *values))

    def read(self, at, size):
        at, size = int(at), int(size)
        self.reads.append((at, size))
        if any(at + n not in self.mem for n in range(size)):
            return None
        return bytes(self.mem[at + n] for n in range(size))

    def row(self, kind, identity, name, cased=10, upper=20, icon=0, call_type=0, payload_count=0):
        # Real Info objects may be four-byte aligned.
        at, text = ROWS + kind * 0x200 + 4, STRINGS + kind * 0x200
        self.put(BASE + 0x37cb600 + kind * 8, '<Q', at)
        self.raw(at, bytes(0xb8))
        self.put(at, '<II', kind, identity)
        self.put(at + 0x10, '<Q', text)
        self.put(at + 0x28, '<II', upper, cased)
        self.put(at + 0x68, '<f', 15)
        self.put(at + 0x74, '<I', call_type)
        self.put(at + 0xa0, '<I', payload_count)
        self.put(at + 0xb0, '<Q', icon)
        self.raw(text, name.encode().ljust(160, b'\0'))
        return at

    def test_native_names_icon_and_stable_id_are_discovered_without_writes(self):
        original = self.mem.copy()
        count, _ = self.reader.scan(0)
        self.assertEqual(count, 1)
        row = self.reader.lookup('4119049995')
        self.assertEqual((row['type'], row['id'], row['name'], row['group'], row['call_type']),
                         (3, 4119049995, '500千克炸弹', 'red', 0))
        self.assertEqual(row['icon'], 'F96A659EBFFDFBE4')
        self.assertEqual(self.reader.resolve_name_key(1057738842)['id'], row['id'])
        self.assertEqual(self.reader.resolve_name_key(2994328991)['id'], row['id'])
        self.assertEqual(self.mem, original)

    def test_new_rows_discover_and_type_reordering_keeps_stable_identity(self):
        self.reader.scan(0)
        self.put(BASE + 0x37cb600 + 3 * 8, '<Q', 0)
        self.row(141, 4119049995, 'EAGLE. 500KG BOMB', 2994328991, 1057738842)
        self.row(200, 123456, 'VEHICLES. FUTURE VEHICLE', 11, 21)
        count, _ = self.reader.scan(6)
        self.assertEqual(count, 2)
        self.assertEqual(self.reader.lookup(4119049995)['type'], 141)
        self.assertEqual(self.reader.lookup(123456)['group'], 'blue')

    def test_duplicate_localization_keys_remain_ambiguous(self):
        self.row(5, 55, 'MISSIONS. ONE', 77, 88, call_type=3)
        self.row(6, 66, 'MISSIONS. TWO', 77, 99, call_type=3)
        self.reader.scan(0)
        self.assertIsNone(self.reader.resolve_name_key(77))
        self.assertEqual(self.reader.resolve_name_key(88)['id'], 55)
        self.assertEqual(self.reader.lookup(55)['family'], 'mission')

    def test_unknown_family_remains_visible_and_does_not_join_color_bulk_group(self):
        self.row(5, 55, 'FUTURE. UNKNOWN', 77, 88)
        self.reader.scan(0)
        self.assertEqual(self.reader.lookup(55)['group'], 'other')

    def test_only_explicit_verified_resource_aliases_resolve(self):
        self.reader.scan(0)
        self.assertEqual(self.reader.resolve_resource('00000000ABCDEF01')['id'], 4119049995)
        self.assertIsNone(self.reader.resolve_resource('E44B691DC039A505'))

    def test_verified_default_equipment_aliases_match_current_payload_graph(self):
        self.row(15, 2822568285, 'TEAM WEAPONS. LASER CANNON', 100, 101)
        self.row(16, 2636699686, 'VEHICLES. FAST RECON VEHICLE (Resupply Auto Turret)', 102, 103)
        self.row(17, 3843705076, 'BACKPACK. ENERGY SHIELD', 104, 105)
        self.reader.scan(0)
        for resource, identity in [('D54B9505C0F72873', 2822568285),
                                   ('FDE262593307CA2F', 2822568285),
                                   ('9B2140378640432E', 2636699686),
                                   ('12C8D71AC3897A5C', 3843705076)]:
            self.assertEqual(self.reader.resolve_resource(resource)['id'], identity)
        # Both campaign and presidential reward own the same rack and boxes.
        self.assertIsNone(self.reader.resolve_resource('A94913CA014F7579'))

    def test_default_aliases_exactly_match_reviewed_fact_manifest(self):
        import json
        import re
        facts = json.loads((SOURCE.parents[1] / 'docs/stratagem-resource-aliases.json').read_text(encoding='utf-8'))
        text = SOURCE.read_text(encoding='utf-8')
        actual = dict((resource, int(identity)) for resource, identity in
                      re.findall(r"\['([0-9A-F]{16})'\]=(\d+)", text))
        self.assertEqual(actual, {r['resource']: r['id'] for r in facts['unique']})

    def test_exact_current_resupply_and_jump_variants_share_rules_without_claiming_native_id(self):
        self.row(4, 1295431756, 'PRESIDENT REWARDS. AMMO CACHE', 1673875834, 1263463686)
        self.row(5, 867876502, 'CONSUMABLES. RESUPPLY', 1673875834, 1263463686,
                 icon=9942671013075500632)
        self.row(6, 3316399568, 'PRESIDENT REWARDS. JUMPPACK BACKPACK', 2872120750, 2204198870)
        self.row(7, 1753436707, 'BACKPACK. JUMPPACK BACKPACK', 2872120750, 2204198870,
                 icon=16448666815309286875)
        self.assertEqual(self.reader.scan(0)[0], 5)
        self.assertEqual(len(self.reader.list_rules()), 3)
        for key in (1263463686, 1673875834):
            self.assertIsNone(self.reader.resolve_name_key(key))
            rule = self.reader.resolve_rule_name_key(key)
            self.assertEqual(rule['id'], 867876502)
            self.assertEqual(list(rule['variant_ids'].values()), [867876502, 1295431756])
        for resource in ('5052EC6A928CCF1A', 'A94913CA014F7579'):
            self.assertIsNone(self.reader.resolve_resource(resource))
            self.assertEqual(self.reader.resolve_rule_resource(resource)['id'], 867876502)
        self.assertEqual(self.reader.resolve_rule_name_key(2872120750)['id'], 1753436707)
        self.assertIsNone(self.reader.resolve_name_key(2872120750))
        for identity in (867876502, 1295431756, 1753436707, 3316399568):
            row = self.reader.lookup(identity)
            self.assertEqual(row['group'], 'blue')
        self.assertEqual(self.reader.lookup(1295431756)['rule_id'], 867876502)
        self.assertEqual(self.reader.lookup(3316399568)['rule_id'], 1753436707)

    def test_single_key_collision_or_different_call_types_do_not_collapse_rules(self):
        self.row(4, 44, 'CONSUMABLES. A', 77, 88)
        self.row(5, 55, 'PRESIDENT REWARDS. A', 77, 99)
        self.row(6, 66, 'MISSIONS. A', 77, 88, call_type=3)
        self.reader.scan(0)
        self.assertEqual(len(self.reader.list_rules()), 4)
        self.assertIsNone(self.reader.resolve_rule_name_key(77))
        self.assertIsNone(self.reader.resolve_rule_name_key(88))
        self.assertEqual(self.reader.resolve_rule_name_key(99)['id'], 55)

    def test_zero_name_keys_do_not_collapse_unknown_rows(self):
        self.row(4, 44, 'MISSIONS. A', 0, 0)
        self.row(5, 55, 'MISSIONS. B', 0, 0)
        self.reader.scan(0)
        self.assertEqual(len(self.reader.list_rules()), 3)
        self.assertIsNone(self.reader.resolve_rule_name_key(0))
        self.assertEqual(self.reader.lookup(44)['rule_id'], 44)
        self.assertEqual(self.reader.lookup(55)['rule_id'], 55)

    def test_resource_rule_requires_all_candidates_and_exact_visible_identity(self):
        self.row(4, 867876502, 'CONSUMABLES. RESUPPLY', 1673875834, 1263463686)
        self.reader.scan(0)
        self.assertIsNone(self.reader.resolve_rule_resource('A94913CA014F7579'))
        self.row(5, 1295431756, 'PRESIDENT REWARDS. AMMO CACHE', 1673875834, 55)
        self.reader.scan(6)
        self.assertIsNone(self.reader.resolve_rule_resource('A94913CA014F7579'))
        self.row(5, 1295431756, 'PRESIDENT REWARDS. AMMO CACHE', 1673875834, 1263463686, call_type=3)
        self.reader.scan(12)
        self.assertIsNone(self.reader.resolve_rule_resource('A94913CA014F7579'))

    def test_mixed_equipment_cache_does_not_acquire_single_weapon_policy(self):
        self.row(4, 458198946, 'TEAM WEAPONS. MACHINEGUN', 3663193426, 1936822397)
        self.row(5, 1567517764, 'PRESIDENT REWARDS. MACHINEGUN', 3663193426, 1936822397)
        self.row(6, 3868299561, 'PRESIDENT REWARDS. MIXED CACHE', 11, 12)
        self.reader.scan(0)
        self.assertIsNone(self.reader.resolve_resource('11C27D3BABB38956'))
        self.assertIsNone(self.reader.resolve_rule_resource('11C27D3BABB38956'))

    def test_representative_prefers_normal_then_icon_then_lowest_stable_id(self):
        self.row(4, 44, 'PRESIDENT REWARDS. FOO', 77, 88, icon=123)
        self.row(5, 55, 'BACKPACK. FOO', 77, 88)
        self.row(6, 66, 'TUTORIAL FOO', 77, 88, icon=456)
        self.reader.scan(0)
        self.assertEqual(self.reader.resolve_rule_name_key(77)['id'], 55)
        self.row(7, 77, 'BACKPACK. FOO NORMAL', 77, 88, icon=456)
        self.reader.scan(6)
        self.assertEqual(self.reader.resolve_rule_name_key(77)['id'], 77)
        self.row(5, 55, 'BACKPACK. FOO', 77, 88, icon=123)
        self.reader.scan(12)
        self.assertEqual(self.reader.resolve_rule_name_key(77)['id'], 55)

    def test_nonthrow_physical_payload_metadata_is_available_and_bounded(self):
        row = self.row(4, 3722314010, 'MISSIONS. RAISE FLAG', 2281165846, 2378431612,
                       call_type=3, payload_count=2)
        self.reader.scan(0)
        self.assertEqual(self.reader.lookup(3722314010)['payload_count'], 2)
        self.assertEqual(self.reader.lookup(3722314010)['call_type'], 3)
        self.put(row + 0xa0, '<I', 65)
        self.assertEqual(self.reader.scan(6)[0], 0)

    def test_ambiguous_resource_candidates_exactly_match_fact_manifest(self):
        import json
        import re
        facts = json.loads((SOURCE.parents[1] / 'docs/stratagem-resource-aliases.json').read_text(encoding='utf-8'))
        # Parse the complete bounded literal, not runtime-generated policy keys.
        text = SOURCE.read_text(encoding='utf-8').split('local verified_candidates={', 1)[1].split('local state=', 1)[0]
        actual = {resource: [int(x) for x in ids.split(',')] for resource, ids in
                  re.findall(r"\['([0-9A-F]{16})'\]=\{([0-9,]+)\}", text)}
        self.assertEqual(actual, {r['resource']: r['ids'] for r in facts['ambiguous']})

    def test_zero_icon_remains_absent_and_bad_localization_uses_native_debug_name(self):
        self.localized[2994328991] = '<bad>'
        self.row(5, 55, 'SENTRYS. NEW DEFENSE', 77, 88)
        self.reader.scan(0)
        self.assertEqual(self.reader.lookup(4119049995)['name'], 'EAGLE. 500KG BOMB')
        self.assertIsNone(self.reader.lookup(55)['icon'])
        self.assertEqual(self.reader.lookup(55)['group'], 'green')

    def test_shield_generator_backpack_is_blue_and_deployed_relay_is_green(self):
        self.row(5, 3843705076, 'BACKPACK. SHIELD GENERATOR', 77, 88)
        self.row(6, 2281932031, 'EMPLACEMENTS. SHIELD GENERATOR RELAY', 78, 89)
        self.reader.scan(0)
        self.assertEqual(self.reader.lookup(3843705076)['group'], 'blue')
        self.assertEqual(self.reader.lookup(2281932031)['group'], 'green')

    def test_build_and_consumer_guard_failures_retire_cached_catalog(self):
        self.reader.scan(0)
        self.raw(BASE + 0x183a1e5, b'\x90')
        self.assertEqual(self.reader.scan(6)[0], 0)
        self.assertFalse(self.reader.state['ready'])
        self.assertIsNone(self.reader.lookup(4119049995))
        self.assertEqual(len(self.reader.list_rules()), 0)
        self.assertIsNone(self.reader.resolve_rule_name_key(2994328991))
        self.base = None
        self.assertEqual(self.reader.scan(7)[0], 0)

    def test_mid_scan_row_change_is_rejected(self):
        original_read = self.read
        row = ROWS + 3 * 0x200 + 4
        times = 0

        def mutating_read(at, size):
            nonlocal times
            if int(at) == row:
                times += 1
                if times == 2:
                    self.put(row + 4, '<I', 123)
            return original_read(at, size)

        self.reader = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_stratagem_catalog')(
            self.lua.table_from({'base': lambda: BASE, 'read': mutating_read}))
        self.assertEqual(self.reader.scan(0)[0], 0)

    def test_duplicate_stable_ids_reject_the_whole_snapshot(self):
        self.row(5, 4119049995, 'EAGLE. DUPLICATE', 77, 88)
        self.assertEqual(self.reader.scan(0)[0], 0)

    def test_repeated_scan_is_throttled(self):
        self.reader.scan(0)
        reads = len(self.reads)
        self.assertEqual(self.reader.scan(1)[0], 1)
        self.assertEqual(len(self.reads), reads)


if __name__ == '__main__':
    unittest.main()
