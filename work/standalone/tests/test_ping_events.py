"""Native ping reader tests using sparse memory with real observed layouts."""
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[3] / 'src' / 'ping_events.lua'
BASE, CTX, ROOT, PLAYERS, RING = 0x10000000, 0x20000000, 0x30000000, 0x40000000, 0x50000000
ENTITY_SLOTS, NETWORK_SLOTS = 0x60000000, 0x60001000
OWN, FRIEND = bytes.fromhex('1100000001001001'), bytes.fromhex('2200000001001001')


class PingEventsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.exists(), 'native ping adapter is not implemented')
        self.mem, self.events = {}, []
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.base, self.emit_ok = BASE, True
        self.session = 'session-a'
        self.localized = {}
        self.put(BASE + 0x347cef0, '<Q', CTX)
        self.put(CTX + 0xb398, '8s', OWN)
        self.put(BASE + 0x346bf98, '<Q', ROOT)
        self.put(BASE + 0x3326468, '<Q', PLAYERS)
        self.put(BASE + 0x347ce30, '<Q', RING)
        self.put(PLAYERS + 0x84, '<I', 2)
        self.put(PLAYERS + 0x2c8, '8s', OWN)
        self.put(PLAYERS + 0x2c8 + 0x38, '8s', FRIEND)
        for slot, entity, goid in [(0, 3001, 10), (1, 3002, 11)]:
            desc = 0x70000000 + slot * 0x100
            self.put(PLAYERS + 0xe8 + slot * 8, '<Q', desc)
            self.put(desc, '<QIIII', 0, entity, 0, goid, int(slot == 0))
            self.put(PLAYERS + 0x3a8 + slot * 0x20, '<I', goid)
        self.hash(ROOT + 0xf22ec8, NETWORK_SLOTS, {10: 0, 11: 1})
        self.hash(ROOT + 0xf1aeb0, ENTITY_SLOTS, {1001: 0, 1002: 1, 2001: 2})
        self.descriptor(0, 1001, '0000000000000001', 10)
        self.descriptor(1, 1002, '0000000000000001', 11)
        self.target('1A7FCDFF98C664B0')
        self.header(0, 0)
        constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
        self.adapter = constructor(self.lua.table_from({
            'base': lambda: self.base, 'read': self.read, 'emit': self.emit,
            'session': lambda: self.session,
            'localize': lambda key: self.localized.get(int(key)),
        }))

    def raw(self, address, data):
        for n, byte in enumerate(data):
            self.mem[address + n] = byte

    def put(self, address, fmt, *values):
        self.raw(address, struct.pack(fmt, *values))

    def read(self, address, size):
        address, size = int(address), int(size)
        if any(address + n not in self.mem for n in range(size)):
            return None
        return bytes(self.mem[address + n] for n in range(size))

    def emit(self, event, now):
        self.events.append((dict(event), now))
        return self.emit_ok

    def hash(self, address, slots, values):
        self.put(address, '<QIII', slots, 8, 0xffffffff, 1)
        for index in range(8):
            self.put(slots + index * 8, '<II', 0xffffffff, 0xffffffff)
        for key, value in values.items():
            index = key % 8
            while self.mem[slots + index * 8] != 0xff:
                index = (index + 1) % 8
            self.put(slots + index * 8, '<II', key, value)

    def descriptor(self, slot, entity, resource, network):
        self.put(ROOT + 0xf32f18 + slot * 24, '<QIIII', int(resource, 16), entity, 123, network, 0)

    def target(self, resource):
        self.descriptor(2, 2001, resource, 20)

    def header(self, head, tail, active=1):
        self.put(RING, '<IIII', active, 0, head, tail)

    def mark(self, slot=0, creator=1002, target=2001, age=0.1, kind=1, duration=8, position=(0, 0, 0), localization_key=0):
        address = RING + 16 + slot * 0x58
        self.raw(address, bytes(0x58))
        self.put(address, '<I', kind)
        self.put(address + 4, '<fff', *position)
        self.put(address + 0x10, '<ff', duration, age)
        self.put(address + 0x18, '<I', creator)
        self.put(address + 0x20, '<I', target)
        self.put(address + 0x34, '<I', localization_key)

    def poll(self, now):
        return self.adapter.poll(now)

    def actors(self, entities=(3001, 3002)):
        self.actor_base = 0x80000000
        self.put(BASE + 0x3326d20, '<Q', self.actor_base)
        self.put(self.actor_base + 0x6c, '<I', len(entities))
        for slot, entity in enumerate(entities):
            descriptor = 0x81000000 + slot * 0x100
            self.put(self.actor_base + 0x110 + slot * 8, '<Q', descriptor)
            self.put(descriptor + 8, '<I', entity)
            self.raw(self.actor_base + 0x547830 + slot * 0x78, bytes(0x64))

    def map_pin(self, slot=0, active=True, kind=7, network=0x7fff, position=(100, 200, 0)):
        address = self.actor_base + 0x547830 + slot * 0x78
        self.put(address, '<I', 4 if active else 0)
        self.put(address + 0x50, '<fffII', *position, kind, network)

    def objective(self, name='获取发射代码', importance=1, override=None):
        manager, slots, descriptors, runtime = 0x90000000, 0x91000000, 0x92000000, 0x93000000
        resource = 0x9988776655443322
        self.put(BASE + 0x3326da0, '<Q', manager)
        self.put(manager + 0x24, '<I', 1)
        self.hash(manager + 0x38, slots, {4001: 0})
        self.put(manager + 0x50, '<Q', descriptors)
        self.put(descriptors, '<Q', 0x94000000)
        self.put(0x94000000, '<QIIII', resource, 4001, 55, 12, 0)
        self.put(manager + 0x60, '<Q', runtime)
        self.put(runtime + 0x1038, '<I', importance)
        self.put(runtime + 0x1054, '<B', int(override is not None))
        self.put(runtime + 0x1050, '<I', 456 if override else 0)
        definitions = BASE + 0x32ef870
        self.raw(definitions, bytes(153 * 0xa0))
        self.put(definitions + 75 * 0xa0, '<I', 73)
        self.put(definitions + 75 * 0xa0 + 0x18, '<Q', resource)
        self.put(definitions + 75 * 0xa0 + 0x38, '<I', 123)
        self.localized[123] = name
        if override:
            self.localized[456] = override
        self.hash(ROOT + 0xf22ec8, NETWORK_SLOTS, {10: 0, 11: 1, 12: 3})
        self.descriptor(3, 4001, '9988776655443322', 12)

    def test_real_map_state_emits_own_and_remote_pins_without_ring_entries(self):
        self.actors(); self.poll(0)
        self.map_pin(slot=0); self.map_pin(slot=1, position=(300, 400, 0))
        self.poll(1)
        self.assertEqual([e[0]['creator_id'] for e in self.events],
                         ['0110000100000011', '0110000100000022'])
        self.assertTrue(all(e[0]['category'] == 'map' for e in self.events))
        self.poll(2); self.assertEqual(len(self.events), 2)
        self.map_pin(slot=0, active=False); self.poll(3)
        self.map_pin(slot=0); self.poll(4)
        self.assertEqual(len(self.events), 3, 'cancel then re-mark is a new event')

    def test_real_map_state_works_when_hud_ring_is_inactive(self):
        self.actors(); self.header(0, 0, active=0); self.poll(0)
        self.map_pin(); self.poll(1)
        self.assertEqual(len(self.events), 1)

    def test_existing_real_map_state_is_baselined_when_source_becomes_available(self):
        self.poll(0); self.actors(); self.map_pin(); self.poll(1)
        self.assertEqual(self.events, [])
        self.map_pin(position=(555, 666, 0)); self.poll(2)
        self.assertEqual(len(self.events), 1)

    def test_objective_pin_reads_actual_map_name_and_current_mission_importance(self):
        for importance, expected in [(0, 'primary'), (1, 'prerequisite'), (2, 'optional'), (3, 'tactical')]:
            with self.subTest(importance=importance):
                self.setUp(); self.actors(); self.objective('摧毁非法广播', importance)
                self.poll(0); self.map_pin(kind=1, network=12); self.poll(1)
                self.assertEqual(len(self.events), 1)
                event = self.events[0][0]
                self.assertEqual(event['target'], '摧毁非法广播')
                self.assertEqual(event['objective_kind'], expected)
                self.assertEqual(event['target_id'], 4001)
                self.assertEqual(event['category'], 'map')

    def test_objective_pin_honors_game_ui_name_override(self):
        self.actors(); self.objective(override='获取发射代码'); self.poll(0)
        self.map_pin(kind=1, network=12); self.poll(1)
        self.assertEqual(self.events[0][0]['target'], '获取发射代码')
        self.assertEqual(self.events[0][0]['localization_key'], 456)

    def test_objective_name_pending_does_not_consume_pin(self):
        self.actors(); self.objective(); del self.localized[123]; self.poll(0)
        self.map_pin(kind=1, network=12); self.poll(1)
        self.assertEqual(self.events, [])
        self.localized[123] = '获取发射代码'; self.poll(2)
        self.assertEqual(self.events[0][0]['target'], '获取发射代码')

    def test_map_source_replacement_baselines_pins(self):
        self.actors(); self.poll(0)
        old = self.actor_base
        self.actor_base += 0x1000000
        for offset in (0x6c, 0x110, 0x118):
            size = 4 if offset == 0x6c else 8
            self.raw(self.actor_base + offset, self.read(old + offset, size))
        for slot in range(2):
            self.raw(self.actor_base + 0x547830 + slot * 0x78, bytes(0x64))
        self.put(BASE + 0x3326d20, '<Q', self.actor_base)
        self.map_pin(); self.poll(1); self.assertEqual(self.events, [])

    def test_unattributed_and_invalid_real_map_pins_are_ignored(self):
        self.actors((9999, 3002)); self.poll(0)
        self.map_pin(slot=0); self.map_pin(slot=1, position=(float('nan'), 0, 0)); self.poll(1)
        self.assertEqual(self.events, [])

    def test_real_map_source_avoids_duplicate_ring_map_records(self):
        self.actors(); self.poll(0); self.map_pin()
        self.mark(kind=21, creator=3001, target=0xffffffff, duration=9999, position=(100, 200, 0))
        self.header(0, 1); self.poll(1)
        self.assertEqual(len(self.events), 1)

    def test_objective_identity_change_during_localization_discards_old_name(self):
        self.actors(); self.objective(); self.poll(0)
        def localize(key):
            self.put(0x94000000 + 8, '<I', 4999)
            return self.localized.get(int(key))
        constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
        self.adapter = constructor(self.lua.table_from({'base': lambda: self.base,
            'read': self.read, 'emit': self.emit, 'localize': localize}))
        self.poll(0); self.map_pin(kind=1, network=12); self.poll(1)
        self.assertEqual(self.events, [])

    def test_map_pin_change_during_localization_discards_stale_event(self):
        self.actors(); self.objective()
        def localize(key):
            self.map_pin(kind=7, position=(999, 999, 0))
            return self.localized.get(int(key))
        constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
        self.adapter = constructor(self.lua.table_from({'base': lambda: self.base,
            'read': self.read, 'emit': self.emit, 'localize': localize}))
        self.poll(0); self.map_pin(kind=1, network=12); self.poll(1)
        self.assertEqual(self.events, [])

    def test_unknown_importance_is_preserved_without_guessing_main_or_side(self):
        self.actors(); self.objective(importance=99); self.poll(0)
        self.map_pin(kind=1, network=12); self.poll(1)
        self.assertEqual(self.events[0][0]['objective_kind'], 'unknown')

    def test_four_objective_pins_fit_read_budget_and_keep_individual_creators(self):
        self.actors((3001, 3002, 1001, 1002)); self.objective(); self.poll(0)
        for slot in range(4):
            self.map_pin(slot=slot, kind=1, network=12)
        self.poll(1)
        self.assertEqual(len(self.events), 4)

    def test_new_remote_ping_uses_target_resource_and_full_peer_id(self):
        self.poll(0)
        self.mark(); self.header(0, 1); self.poll(1)
        event, now = self.events[0]
        self.assertEqual(event['category'], 'large_enemy')
        self.assertEqual(event['creator_id'], '0110000100000022')
        self.assertEqual(event['target_id'], 2001)
        self.assertEqual(now, 1)
        self.poll(2)
        self.assertEqual(len(self.events), 1)

    def test_ordinary_supplies_stay_excluded_even_with_a_localized_special_marker_kind(self):
        for resource in ('79CCFFD281E3F3A9', '86F3CB87D97942B4', '9D4935FA69B6B41A'):
            with self.subTest(resource=resource):
                self.setUp(); self.target(resource); self.localized[123] = '普通物资'
                self.poll(0); self.mark(kind=20, localization_key=123)
                self.header(0, 1); self.poll(1)
                self.assertEqual(self.events, [])

    def test_native_objective_without_entity_retries_until_game_name_is_loaded(self):
        self.poll(0); self.mark(kind=18, target=0xffffffff, localization_key=123)
        self.header(0, 1); self.poll(1)
        self.assertEqual(self.events, [])
        self.localized[123] = '非法广播'
        self.mark(kind=18, target=0xffffffff, localization_key=123, age=1.5)
        self.poll(2)
        self.assertEqual(self.events[0][0]['target'], '非法广播')

    def test_session_change_inside_first_listener_discards_remaining_old_room_events(self):
        constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
        def changing_emit(event, now):
            accepted = self.emit(event, now)
            self.session = 'session-b'
            return accepted
        self.adapter = constructor(self.lua.table_from({
            'base': lambda: BASE, 'read': self.read, 'emit': changing_emit,
            'session': lambda: self.session,
        }))
        self.poll(0); self.mark(slot=0); self.mark(slot=1)
        self.header(0, 2); self.poll(1)
        self.assertEqual(len(self.events), 1)

    def test_medium_and_massive_resource_categories(self):
        for resource, category in [('10081ACEF6163EF6', 'medium_enemy'),
                                   ('9E2E17F2CCCCAFDD', 'giant_enemy')]:
            with self.subTest(resource=resource):
                self.setUp(); self.target(resource); self.poll(0)
                self.mark(); self.header(0, 1); self.poll(1)
                self.assertEqual(self.events[0][0]['category'], category)

    def test_existing_marks_on_first_poll_are_baseline_only(self):
        self.mark(); self.header(0, 1); self.poll(0); self.poll(1)
        self.assertEqual(self.events, [])

    def test_session_change_with_reused_native_addresses_baselines_existing_marks(self):
        self.poll(0)
        self.session = 'session-b'
        self.mark(age=1.0); self.header(0, 1); self.poll(1)
        self.assertEqual(self.events, [], 'new lobby marks must only establish its baseline')
        self.mark(age=0.05); self.poll(2)
        self.assertEqual(len(self.events), 1, 'new marks in the new lobby still emit')

    def test_unattributed_ground_quickchat_unknown_and_expired_are_ignored(self):
        for kwargs in [dict(creator=9999), dict(kind=0),
                       dict(kind=24), dict(age=8), dict(age=-1), dict(target=0xffffffff)]:
            with self.subTest(kwargs=kwargs):
                self.setUp(); self.poll(0); self.mark(**kwargs); self.header(0, 1); self.poll(1)
                self.assertEqual(self.events, [])
        self.setUp(); self.target('DEADBEEFDEADBEEF'); self.poll(0)
        self.mark(); self.header(0, 1); self.poll(1); self.assertEqual(self.events, [])

    def test_ring_wraparound_and_slot_reping(self):
        self.poll(0); self.mark(slot=127); self.header(127, 0); self.poll(1)
        self.assertEqual(len(self.events), 1)
        self.mark(slot=127, age=1.5); self.poll(2); self.assertEqual(len(self.events), 1)
        self.mark(slot=127, age=0.05); self.poll(3); self.assertEqual(len(self.events), 2)

    def test_context_change_invalid_header_and_unverified_base_reset_baseline(self):
        for mutation in ['invalid_header', 'missing_base', 'context_change']:
            with self.subTest(mutation=mutation):
                self.setUp(); self.poll(0)
                if mutation == 'invalid_header': self.header(128, 0); self.poll(1)
                elif mutation == 'missing_base': self.base = None; self.poll(1); self.base = BASE
                else:
                    self.put(BASE + 0x347cef0, '<Q', CTX + 0x100000)
                    self.put(CTX + 0x100000 + 0xb398, '8s', OWN)
                self.mark(); self.header(0, 1); self.poll(2); self.poll(3)
                self.assertEqual(self.events, [])

    def test_invalid_roster_count_short_read_and_identity_mismatch_refuse(self):
        self.poll(0); self.mark(); self.header(0, 1)
        self.put(PLAYERS + 0x84, '<I', 5); self.poll(1); self.assertEqual(self.events, [])
        self.put(PLAYERS + 0x84, '<I', 2); self.poll(2)
        self.put(ROOT + 0xf32f18 + 2 * 24 + 8, '<I', 9999)
        self.mark(age=0.01); self.poll(3); self.assertEqual(self.events, [])

    def test_failed_emit_is_not_spammed_every_poll(self):
        self.poll(0); self.emit_ok = False; self.mark(); self.header(0, 1)
        self.poll(1); self.poll(2); self.assertEqual(len(self.events), 1)

    def test_roster_change_during_target_read_discards_event(self):
        self.poll(0); self.mark(); self.header(0, 1)
        original = self.read
        target_address = ROOT + 0xf32f18 + 2 * 24
        changed = False

        def raced_read(address, size):
            nonlocal changed
            result = original(address, size)
            if address == target_address and not changed:
                changed = True
                self.put(PLAYERS + 0x2c8 + 0x38, '8s', bytes.fromhex('3300000001001001'))
            return result

        # Replace the same environment callback retained by the reader.
        self.read = raced_read
        # Rebuild so the callback captures raced_read, then establish the empty baseline.
        constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
        self.adapter = constructor(self.lua.table_from({
            'base': lambda: self.base, 'read': raced_read, 'emit': self.emit,
        }))
        self.header(0, 0); self.poll(0); self.header(0, 1); self.poll(1)
        self.assertTrue(changed)
        self.assertEqual(self.events, [])

    def test_non_power_two_hash_capacity_fails_closed(self):
        self.poll(0); self.mark(); self.header(0, 1)
        self.put(ROOT + 0xf1aeb0 + 8, '<I', 7)
        self.poll(1); self.assertEqual(self.events, [])

    def test_tactical_map_kind_21_emits_coordinates_without_target_entity(self):
        self.poll(0)
        self.mark(kind=21, target=0xffffffff, position=(123, 456, 7), duration=9999)
        self.header(0, 1); self.poll(1)
        self.assertEqual(self.events[0][0]['category'], 'map')
        self.assertEqual(dict(self.events[0][0]['position']), {'x': 123, 'y': 456, 'z': 7})
        self.poll(2); self.assertEqual(len(self.events), 1)
        self.mark(kind=21, target=0xffffffff, position=(150, 456, 7), age=1.5)
        self.poll(3); self.assertEqual(len(self.events), 2, 'new position is a new map mark')

    def test_map_invalid_positions_are_ignored(self):
        for kwargs in [dict(position=(float('nan'), 0, 0)), dict(position=(float('inf'), 0, 0)),
                       dict(position=(1000001, 0, 0))]:
            self.setUp(); self.poll(0)
            self.mark(kind=21, target=0xffffffff, **kwargs); self.header(0, 1); self.poll(1)
            self.assertEqual(self.events, [])

    def test_own_laser_cannon_and_map_mark_are_emitted_once_with_local_peer(self):
        for kwargs, category in [(dict(kind=20), 'stratagem'),
                                 (dict(kind=21, target=0xffffffff, duration=9999), 'map')]:
            with self.subTest(category=category):
                self.setUp(); self.target('D54B9505C0F72873'); self.poll(0)
                self.mark(creator=1001, **kwargs); self.header(0, 1)
                self.assertEqual(self.poll(1)[0], 1)
                self.assertEqual(self.events[0][0]['category'], category)
                self.assertEqual(self.events[0][0]['creator_id'], '0110000100000011')
                self.poll(2); self.assertEqual(len(self.events), 1)

    def test_resupply_pod_boxes_and_supply_frv_are_stratagems(self):
        for resource, label in [('5052EC6A928CCF1A', '重新补给'),
                                ('A94913CA014F7579', '重新补给箱'),
                                ('49119612EB284A48', '重新补给箱'),
                                ('9B2140378640432E', 'M-103 补给车')]:
            with self.subTest(resource=resource):
                self.setUp(); self.target(resource); self.poll(0)
                self.mark(creator=1001, kind=13); self.header(0, 1)
                self.assertEqual(self.poll(1)[0], 1)
                self.assertEqual(self.events[0][0]['category'], 'stratagem')
                self.assertEqual(self.events[0][0]['target'], label)

    def test_own_native_marks_reach_real_automation_queue_and_send_in_solo_host_session(self):
        for resource, kind, label in [('D54B9505C0F72873', 20, 'LAS-98 激光大炮'),
                                     ('5052EC6A928CCF1A', 10, '重新补给'),
                                     ('9B2140378640432E', 13, 'M-103 补给车'),
                                     ('D54B9505C0F72873', 21, '地图标记'),
                                     ('D54B9505C0F72873', 21, '获取发射代码')]:
            with self.subTest(label=label):
                self.setUp(); self.target(resource)
                if kind == 21:
                    self.actors()
                    if label != '地图标记': self.objective(label)
                controller_source = SOURCE.with_name('chat_automation.lua').read_text(encoding='utf-8')
                sent = []
                # Use a real policy controller with a captured transport, not a mocked push_ping.
                automation = self.lua.execute(controller_source + '''
                    local send=...;local peer='76561197960265745'
                    local sr={Network={game_session=function() return 'solo' end,peer_id=function() return peer end},
                        GameSession={peers=function() return {peer} end,game_session_host=function() return peer end}}
                    return build_chat_automation({engine=function() return sr end,
                        context=function() return 123 end,write_file=function() return true end,
                        send=function(text) return send(text) end})
                ''', lambda text: (sent.append(text) or True))
                automation.set('ping', True); automation.set('scope', 'host')
                automation.set('ping_sender_prefix', False); automation.set('ping_message', '{目标}')
                constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
                self.adapter = constructor(self.lua.table_from({'base': lambda: BASE, 'read': self.read,
                    'localize': lambda key: self.localized.get(int(key)),
                    'emit': lambda event, now: automation.push_ping(event, now)}))
                self.poll(0)
                if kind == 21:
                    self.map_pin(kind=1 if label != '地图标记' else 7,
                                 network=12 if label != '地图标记' else 0x7fff)
                else:
                    self.mark(creator=1001, kind=kind); self.header(0, 1)
                self.assertEqual(self.poll(1)[0], 1)
                self.assertTrue(automation.poll(1)[0]); self.assertEqual(sent, [label])
                self.poll(2); automation.poll(2); self.assertEqual(sent, [label])

    def test_special_stratagem_resources_are_named_and_ordinary_pickups_are_ignored(self):
        for resource, target in [('D54B9505C0F72873', 'LAS-98 激光大炮'), ('16474112801385B6', '堡垒坦克')]:
            self.setUp(); self.target(resource); self.poll(0)
            self.mark(kind=13, localization_key=686081100); self.header(0, 1); self.poll(1)
            self.assertEqual(self.events[0][0]['category'], 'stratagem')
            self.assertEqual(self.events[0][0]['target'], target)
            self.assertEqual(self.events[0][0]['localization_key'], 686081100)

    def test_native_special_marker_names_do_not_require_a_catalogue_entry(self):
        for kind, name, category in [(18, '非法广播', 'building'), (19, '任务代码', 'building'),
                                     (20, '轨道激光战备', 'stratagem')]:
            self.setUp(); self.target('DEADBEEFDEADBEEF'); self.localized[123456] = name
            self.poll(0); self.mark(kind=kind, localization_key=123456)
            self.header(0, 1); self.poll(1)
            self.assertEqual(self.events[0][0]['category'], category)
            self.assertEqual(self.events[0][0]['target'], name)

    def test_known_target_uses_native_display_name_when_available(self):
        self.localized[686081100] = 'TD-220 堡垒'
        self.target('16474112801385B6'); self.poll(0)
        self.mark(kind=13, localization_key=686081100); self.header(0, 1); self.poll(1)
        self.assertEqual(self.events[0][0]['target'], 'TD-220 堡垒')

    def test_temporarily_unresolved_target_is_retried_while_mark_remains_active(self):
        self.poll(0); self.mark(); self.header(0, 1)
        self.put(ROOT + 0xf32f18 + 2 * 24 + 8, '<I', 9999)
        self.poll(1)
        self.assertEqual(self.events, [])
        self.target('1A7FCDFF98C664B0')
        self.mark(age=1.5); self.poll(2)
        self.assertEqual(len(self.events), 1)
        self.poll(3)
        self.assertEqual(len(self.events), 1)

    def test_same_target_renewal_retries_even_after_age_passes_previous_mark(self):
        self.poll(0); self.mark(age=.2); self.header(0, 1); self.poll(1)
        self.assertEqual(len(self.events), 1)
        self.put(ROOT + 0xf32f18 + 2 * 24 + 8, '<I', 9999)
        self.mark(age=.05); self.poll(2)
        self.assertEqual(len(self.events), 1)
        self.target('1A7FCDFF98C664B0')
        self.mark(age=.3); self.poll(3)
        self.assertEqual(len(self.events), 2)

    def test_ordinary_pickup_resources_are_no_longer_announced(self):
        for resource in ['79CCFFD281E3F3A9', 'B4CA4C5B922F7965', 'BD30758426ED2566', '9D4935FA69B6B41A']:
            with self.subTest(resource=resource):
                self.setUp(); self.target(resource); self.poll(0)
                self.mark(); self.header(0, 1); self.poll(1)
                self.assertEqual(self.events, [])
        self.assertIsNone(self.adapter.supported.small_items)

    def test_known_spottable_objective_entities_use_mission_category(self):
        for resource in ['A3D5F183F8A2B768', 'B1D938C07E30C5DB', 'EAE962D85C0C2D4A']:
            with self.subTest(resource=resource):
                self.setUp(); self.target(resource); self.poll(0)
                self.mark(); self.header(0, 1); self.poll(1)
                self.assertEqual(self.events[0][0]['category'], 'building')
        self.assertTrue(self.adapter.supported.building)

    def test_ring_slot_reuse_during_target_read_discards_stale_remote_attribution(self):
        original = self.read
        target_address = ROOT + 0xf32f18 + 2 * 24
        changed = False

        def raced_read(address, size):
            nonlocal changed
            result = original(address, size)
            if address == target_address and not changed:
                changed = True
                self.mark(creator=1001, age=0.05)
            return result

        constructor = self.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_ping_events')
        self.adapter = constructor(self.lua.table_from({
            'base': lambda: self.base, 'read': raced_read, 'emit': self.emit,
            'session': lambda: self.session,
        }))
        self.poll(0); self.mark(); self.header(0, 1); self.poll(1)
        self.assertTrue(changed)
        self.assertEqual(self.events, [], 'slot reuse cannot retain the previous remote creator')


if __name__ == '__main__':
    unittest.main()
