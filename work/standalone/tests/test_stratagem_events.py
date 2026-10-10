"""Non-thrown calls bypass HUD marks; replay the game's per-peer success records."""
from pathlib import Path
import unittest
import json

import test_ping_events as native_fixture

BASE, CTX, OWN, FRIEND = native_fixture.BASE, native_fixture.CTX, native_fixture.OWN, native_fixture.FRIEND

SOURCE = Path(__file__).resolve().parents[3] / 'src/stratagem_events.lua'
RECORDS, CLOCK, ROW = 0xa0000000, 0xa1000000, 0xa2000000
PINS = [(0x135c63c, '4584c90f841e010000'),
        (0x135c69c, '48898cfdd0010000'),
        (0x135c6f9, '48898cfde0010000')]


class StratagemEventsTests(unittest.TestCase):
    def setUp(self):
        self.f = native_fixture.PingEventsTests('runTest'); self.f.setUp()
        self.f.put(BASE + 0x347ce50, '<Q', RECORDS)
        self.f.put(BASE + 0x3326348, '<Q', CLOCK)
        self.f.put(CLOCK + 0x18, '<Q', 1_000_000_000)
        self.f.put(RECORDS + 0x2d200, '<I', 1)
        for offset, value in PINS: self.f.raw(BASE + offset, bytes.fromhex(value))
        self.record(0, OWN)
        self.entry(0, 0, 11, 3722314010, 2281165846)
        self.f.localized[2281165846] = '超级地球旗帜'
        self.f.localized[2087215146] = '上传数据'
        self.reader = None
        if SOURCE.exists():
            constructor = self.f.lua.execute(SOURCE.read_text(encoding='utf-8') + '\nreturn build_stratagem_events')
            self.reader = constructor(self.f.lua.table_from({
                'base': lambda: self.f.base, 'read': self.f.read,
                'session': lambda: self.f.session,
                'localize': lambda key: self.f.localized.get(int(key)), 'emit': self.f.emit}))

    def record(self, slot, peer):
        self.f.raw(RECORDS + slot * 0x1690, peer)
        self.f.put(RECORDS + slot * 0x1690 + 0x7c0, '<I', 1)

    def entry(self, peer, slot, kind, stable_id, name_key, start=0, activation=0, ready=0):
        at = RECORDS + peer * 0x1690 + 0x1c0 + slot * 0x30
        self.f.raw(at, bytes(0x30))
        self.f.put(at, '<II', kind, 0xffffffff)
        self.f.put(at + 0x10, '<QQQ', start, ready, activation)
        self.f.put(BASE + 0x37cb600 + kind * 8, '<Q', ROW + kind * 0x200)
        self.f.raw(ROW + kind * 0x200, bytes(0x80))
        self.f.put(ROW + kind * 0x200, '<II', kind, stable_id)
        self.f.put(ROW + kind * 0x200 + 0x2c, '<I', name_key)
        self.f.put(ROW + kind * 0x200 + 0x74, '<I', 3)

    def poll(self, now):
        self.f.poll(now)
        if self.reader: self.reader.poll(now)

    def success(self, kind=11, stable_id=3722314010, key=2281165846, peer=0):
        self.entry(peer, 0, kind, stable_id, key, 1_000_000_000, 1_009_717_899, 1_038_217_899)

    def test_flag_success_without_any_hud_marker_emits_one_summon(self):
        self.poll(0); self.success(); self.poll(1)
        self.assertEqual(len(self.f.events), 1)
        event = self.f.events[0][0]
        self.assertEqual(event['id'],event['key'])
        self.assertEqual((event['target'], event['action'], event['creator_id']),
                         ('超级地球旗帜', 'summon', '0110000100000011'))
        self.poll(2); self.assertEqual(len(self.f.events), 1)

    def test_transient_emit_rejection_retries_same_task_event_once(self):
        attempts=[]
        localized=[]
        def emit(event, now):
            attempts.append(dict(event))
            return (False, 'retry') if len(attempts)==1 else (True, None)
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
            'session':lambda:self.f.session,
            'localize':lambda key:localized.append(key) or self.f.localized.get(int(key)),
            'emit':emit}))
        self.poll(0);self.success();self.poll(1)
        self.assertEqual(len(attempts),1)
        self.f.poll(2)
        self.assertEqual(self.reader.poll(2)[0],1)
        self.assertEqual(len(attempts),2)
        self.assertEqual(attempts[0]['key'],attempts[1]['key'])
        self.assertEqual(attempts[0]['target'],attempts[1]['target'])
        self.assertEqual(localized,[2281165846], 'a cached retry must not repeat native localization')
        self.poll(3)
        self.assertEqual(len(attempts),2, 'accepted retry must be consumed exactly once')

    def test_pending_retry_is_discarded_when_activation_changes(self):
        attempts=[]
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        def emit(event, now):
            attempts.append(event['key'])
            return (False,'retry') if len(attempts)==1 else (True,None)
        self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
            'session':lambda:self.f.session,'localize':lambda key:self.f.localized.get(int(key)),
            'emit':emit}))
        self.poll(0);self.success();self.poll(1)
        self.f.put(RECORDS+0x1c0+0x20,'<Q',1_009_718_900)
        self.poll(2)
        self.assertEqual(len(attempts),2)
        self.assertNotEqual(attempts[0],attempts[1], 'a renewed activation is a new event, not a stale retry')
        self.poll(3)
        self.assertEqual(len(attempts),2)

    def test_pending_retry_is_cleared_when_session_changes(self):
        attempts=[]
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
            'session':lambda:self.f.session,'localize':lambda key:self.f.localized.get(int(key)),
            'emit':lambda event,now: attempts.append(event['key']) or (False,'retry')}))
        self.poll(0);self.success();self.poll(1)
        self.f.session='session-b';self.poll(2)
        self.assertEqual(len(attempts),1, 'session baseline must not replay pending event')
        self.success();self.poll(3)
        self.assertEqual(len(attempts),1, 'new session baseline should wait for a new activation')

    def test_pending_retry_is_cleared_when_success_record_disappears(self):
        attempts=[]
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
            'session':lambda:self.f.session,'localize':lambda key:self.f.localized.get(int(key)),
            'emit':lambda event,now: attempts.append(event['key']) or (False,'retry')}))
        self.poll(0);self.success();self.poll(1)
        self.f.put(RECORDS+0x7c0,'<I',0);self.poll(2)
        self.assertEqual(len(attempts),1, 'vanished success record must drop pending retry')
        self.f.put(RECORDS+0x7c0,'<I',1);self.poll(3)
        self.assertEqual(len(attempts),1, 'reappearing old activation must not replay')

    def test_pending_retry_requires_explicit_false_and_retry_disposition(self):
        attempts=[]
        results=[(False,'retry'),(None,'retry')]
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        def emit(event, now):
            attempts.append(event['key'])
            return results.pop(0)
        self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
            'session':lambda:self.f.session,'localize':lambda key:self.f.localized.get(int(key)),
            'emit':emit}))
        self.poll(0);self.success();self.poll(1);self.poll(2);self.poll(3)
        self.assertEqual(len(attempts),2,'nil acceptance is permanent even if the disposition says retry')

    def test_permanent_refusal_exception_and_expired_retry_are_consumed(self):
        for result in ('permanent','exception','expired'):
            with self.subTest(result=result):
                self.setUp();attempts=[]
                constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
                def emit(event, now):
                    attempts.append(event['key'])
                    if result=='exception': raise RuntimeError('fixture failure')
                    return (False,'rule-disabled') if result=='permanent' else (False,'retry')
                self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
                    'session':lambda:self.f.session,'localize':lambda key:self.f.localized.get(int(key)),
                    'emit':emit}))
                self.poll(0);self.success();self.poll(1)
                self.poll(17 if result=='expired' else 2)
                self.poll(18 if result=='expired' else 3)
                self.assertEqual(len(attempts),1 if result!='expired' else 1,
                    'permanent errors and expired retries must not be emitted again')

    def test_payloadless_upload_success_emits_execution_not_a_summon(self):
        self.entry(0, 0, 128, 3300666223, 2087215146); self.poll(0)
        self.success(128, 3300666223, 2087215146); self.poll(1)
        self.assertEqual(len(self.f.events), 1)
        self.assertEqual(self.f.events[0][0]['action'], 'use')
        self.assertEqual(self.f.events[0][0]['target'], '上传数据')

    def test_discovered_catalog_preserves_known_flag_summon_action(self):
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        discovered=self.f.lua.table_from({'call_type':3,'payload_count':1,'name':'超级地球旗帜','name_key':2281165846})
        self.reader=constructor(self.f.lua.table_from({
            'base':lambda:self.f.base,'read':self.f.read,'session':lambda:self.f.session,
            'localize':lambda key:self.f.localized.get(int(key)),'emit':self.f.emit,
            'catalog':self.f.lua.table_from({'lookup':lambda identity:discovered})}))
        self.poll(0);self.success();self.poll(1)
        self.assertEqual('summon',self.f.events[0][0]['action'])

    def test_future_nonthrown_rows_inherit_payload_action_and_throws_stay_on_hud_path(self):
        for call_type,payload_count,expected in ((3,0,'use'),(3,1,'summon'),(2,0,'summon'),(0,1,None)):
            with self.subTest(call_type=call_type,payload_count=payload_count):
                self.setUp();self.entry(0,0,200,123456,77)
                self.f.put(ROW+200*0x200+0x74,'<I',call_type)
                discovered=self.f.lua.table_from({'call_type':call_type,'payload_count':payload_count,'name':'未来战备','name_key':77})
                constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
                self.reader=constructor(self.f.lua.table_from({
                    'base':lambda:self.f.base,'read':self.f.read,'session':lambda:self.f.session,
                    'emit':self.f.emit,'catalog':self.f.lua.table_from({'lookup':lambda identity:discovered})}))
                self.poll(0);self.success(200,123456,77);self.f.put(ROW+200*0x200+0x74,'<I',call_type);self.poll(1)
                if expected:self.assertEqual(expected,self.f.events[0][0]['action'])
                else:self.assertEqual([],self.f.events)

    def test_current_game_stratagem_rows_can_be_four_byte_aligned(self):
        row = ROW + 11 * 0x200
        data = self.f.read(row, 0x80)
        self.f.raw(row + 4, data)
        self.f.put(BASE + 0x37cb600 + 11 * 8, '<Q', row + 4)
        self.poll(0)
        # Only the per-peer success changes; the real Info row remains 4-aligned.
        self.f.put(RECORDS + 0x1c0 + 0x10, '<QQQ', 1_000_000_000, 1_038_217_899, 1_009_717_899)
        self.poll(1)
        self.assertEqual(len(self.f.events), 1)

    def test_reviewed_nonthrow_catalog_reaches_the_real_send_queue(self):
        catalog=json.loads((SOURCE.parents[1]/'docs/task-stratagems.json').read_text(encoding='utf-8'))
        for row in catalog['stratagems']:
            with self.subTest(stable_id=row['stable_id'],action=row['action']):
                self.setUp()
                kind=int(row['observed_type'].split()[0]);id=row['stable_id'];key=row['name_key']
                self.entry(0,0,kind,id,key)
                self.f.put(ROW+kind*0x200+0x74,'<I',row['call_in_type'])
                sent=[]
                controller=self.f.lua.execute(SOURCE.with_name('chat_automation.lua').read_text(encoding='utf-8')+"""
                    local send=...;local p='76561197960265745'
                    local sr={Network={game_session=function() return 'solo' end,peer_id=function() return p end},
                        GameSession={peers=function() return {p} end,game_session_host=function() return p end}}
                    return build_chat_automation({engine=function() return sr end,context=function() return 123 end,
                        identity=function(id) return {peer_id=id,name='Alice',short='A1',color_index=0} end,
                        write_file=function() return true end,send=function(text) return send(text) end})
                """,lambda text:sent.append(text) or True)
                controller.set('ping',True);controller.set('ping_sender_prefix',False)
                controller.set('message_language','zh')
                controller.set('summon_message','{玩家名}召唤了{目标}')
                controller.set('task_stratagem_message','{玩家名}正在开始{目标}')
                constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
                self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
                    'session':lambda:self.f.session,'emit':lambda e,t:controller.push_ping(e,t)}))
                self.reader.poll(0)
                self.f.put(RECORDS+0x1c0+0x10,'<QQQ',1_000_000_000,1_038_217_899,1_009_717_899)
                self.assertEqual(self.reader.poll(1)[0],1)
                self.assertTrue(controller.poll(1)[0])
                self.assertEqual(sent,['\nAlice'+('正在开始' if row['action']=='use' else '召唤了')+row['label']])
                self.reader.poll(2);controller.poll(2);self.assertEqual(len(sent),1)

    def test_corrupt_record_count_or_wrong_runtime_call_type_is_ignored(self):
        self.poll(0);self.f.put(RECORDS+0x2d200,'<I',33);self.success();self.poll(1)
        self.assertEqual(self.f.events,[])
        self.f.put(RECORDS+0x2d200,'<I',1);self.poll(2)
        self.f.put(ROW+11*0x200+0x74,'<I',0)
        self.f.put(RECORDS+0x1c0+0x20,'<Q',1_010_000_000);self.poll(3)
        self.assertEqual(self.f.events,[])

    def test_clock_rollback_and_record_slot_replacement_baseline_existing_successes(self):
        self.poll(0);self.success();self.f.put(CLOCK+0x18,'<Q',900_000_000);self.poll(1)
        self.assertEqual(self.f.events,[])
        self.entry(0,0,128,3300666223,2087215146,899_000_000,900_000_000)
        self.poll(2);self.assertEqual(self.f.events,[])

    def test_newly_unlocked_task_used_after_the_previous_snapshot_is_not_missed(self):
        self.poll(0)
        self.f.put(CLOCK+0x18,'<Q',1_010_000_000)
        self.entry(0,0,128,3300666223,2087215146,1_005_000_000,1_006_000_000)
        self.poll(1)
        self.assertEqual(len(self.f.events),1)
        self.assertEqual(self.f.events[0][0]['action'],'use')

    def test_context_change_during_name_lookup_discards_the_event(self):
        def localize(key):
            self.f.session='new-room'
            return '超级地球旗帜'
        constructor=self.f.lua.execute(SOURCE.read_text(encoding='utf-8')+'\nreturn build_stratagem_events')
        self.reader=constructor(self.f.lua.table_from({'base':lambda:BASE,'read':self.f.read,
            'session':lambda:self.f.session,'localize':localize,'emit':self.f.emit}))
        self.poll(0);self.success();self.poll(1);self.assertEqual(self.f.events,[])

    def test_initial_existing_flag_and_cooldown_only_updates_do_not_send(self):
        self.success(); self.poll(0)
        self.f.put(RECORDS + 0x1c0 + 0x18, '<Q', 1_050_000_000); self.poll(1)
        self.assertEqual(self.f.events, [])

    def test_failed_call_start_without_new_success_activation_does_not_send(self):
        self.success(); self.poll(0)
        self.f.put(CLOCK + 0x18, '<Q', 1_100_000_000)
        self.f.put(RECORDS + 0x1c0 + 0x10, '<Q', 1_100_000_000); self.poll(1)
        self.assertEqual(self.f.events, [])

    def test_shared_team_cooldown_is_one_event_without_inventing_the_caller(self):
        self.f.put(RECORDS + 0x2d200, '<I', 2); self.record(1, FRIEND)
        self.entry(1, 0, 11, 3722314010, 2281165846); self.poll(0)
        self.success(peer=0); self.success(peer=1); self.poll(1)
        self.assertEqual(len(self.f.events), 1)
        self.assertTrue(self.f.events[0][0]['anonymous'])
        self.assertIsNone(self.f.events[0][0].get('creator_id'))

    def test_new_session_and_new_peer_records_establish_a_baseline(self):
        self.poll(0); self.f.session = 'session-b'; self.success(); self.poll(1)
        self.assertEqual(self.f.events, [])
        self.f.put(RECORDS + 0x2d200, '<I', 2); self.record(1, FRIEND)
        self.entry(1, 0, 128, 3300666223, 2087215146, 1_000_000_000, 1_002_000_000)
        self.poll(2); self.assertEqual(self.f.events, [])

    def test_changed_success_signature_disables_only_this_reader(self):
        self.poll(0); self.f.raw(BASE + PINS[0][0], bytes(9)); self.success(); self.poll(1)
        self.assertEqual(self.f.events, [])

    def test_stale_activation_and_throw_based_stratagem_records_are_ignored(self):
        self.poll(0)
        self.entry(0, 0, 11, 3722314010, 2281165846, 900_000_000, 910_000_000)
        self.poll(1); self.assertEqual(self.f.events, [])
        self.entry(0, 0, 33, 123, 1263463686, 1_000_000_000, 1_001_000_000)
        self.f.put(ROW + 33 * 0x200 + 0x74, '<I', 0)
        self.poll(2); self.assertEqual(self.f.events, [])
