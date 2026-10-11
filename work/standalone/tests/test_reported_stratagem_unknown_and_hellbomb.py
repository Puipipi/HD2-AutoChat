"""Offline regressions for safe stratagem-name fallbacks and Hellbomb marks."""
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'work/standalone/tests'))

import test_ping_events as ping_harness
import test_stratagem_catalog as catalog_harness


class ReportedStratagemUnknownTests(unittest.TestCase):
    def test_explicit_unknown_placeholders_use_safe_localized_fallbacks(self):
        case = catalog_harness.StratagemCatalogTests('runTest')
        case.setUp()
        fixture = json.loads((ROOT / 'work/standalone/tests/fixtures/stratagem_catalog_20261009.json')
                             .read_text(encoding='utf-8'))
        for kind, row in enumerate(fixture['rows'], 1):
            case.row(kind, row['id'], row['debug_name'], row['name_key'],
                     row['name_upper_key'], call_type=row['call_type'])

        count, status = case.reader.scan(0)
        rules = case.reader.list_rules()
        by_id = {int(row['id']): row for row in rules.values()}
        self.assertEqual(count, len(fixture['rows']), status)
        # Audited English labels may be borrowed for Chinese only, with ID.
        self.assertEqual(by_id[650447969]['display_name'], 'Seismic Probe #650447969')
        # Do not leak Chinese names into English UI and preserve stable IDs.
        self.assertEqual(by_id[650447969]['display_name_en'], 'Seismic Probe')
        self.assertEqual(by_id[65564476]['display_name'], '战备 #65564476')
        self.assertEqual(by_id[65564476]['display_name_en'], 'Stratagem #65564476')
        # Future IDs remain distinguishable even when both curated maps miss.
        case.row(255, 987654321, 'FUTURE. UNKNOWN ITEM', 987, 988)
        case.reader.scan(6)
        future = case.reader.lookup(987654321)
        self.assertEqual(future['display_name'], '战备 #987654321')
        self.assertEqual(future['display_name_en'], 'Stratagem #987654321')


class ReportedNaturalHellbombPingTests(unittest.TestCase):
    def test_natural_hellbomb_field_ping_emits_a_named_event(self):
        case = ping_harness.PingEventsTests('runTest')
        case.setUp()
        case.target('C6A87C428FD3C7A3')
        case.localized[4010616934] = '地狱火炸弹'
        case.poll(0)  # Establish the ring baseline.
        case.mark(kind=17, localization_key=4010616934)
        case.header(0, 1)
        case.poll(1)

        self.assertEqual(len(case.events), 1, 'natural Hellbomb ping was dropped')
        event = case.events[0][0]
        self.assertEqual(event.get('resource'), 'C6A87C428FD3C7A3')
        self.assertEqual(event.get('target'), '地狱火炸弹')
        self.assertEqual(event.get('category'), 'stratagem')
        self.assertEqual(event.get('stratagem_id'), 3989310204)
        self.assertEqual(event.get('stratagem_rule_id'), 3989310204)
        self.assertEqual(event.get('source'), 'target')
        self.assertEqual(event.get('action'), 'mark')
        case.poll(2)
        self.assertEqual(len(case.events), 1, 'a still-active field mark must not duplicate')

    def test_hellbomb_identity_does_not_promote_generic_objects_or_unknown_kind17(self):
        for resource, kind, target in [
            ('DEADBEEFDEADBEEF', 17, 2001),
            ('C6A87C428FD3C7A3', 18, 2001),
            ('C6A87C428FD3C7A3', 17, 0),
        ]:
            with self.subTest(resource=resource, kind=kind, target=target):
                case=ping_harness.PingEventsTests('runTest');case.setUp()
                case.target(resource);case.poll(0)
                case.mark(kind=kind,target=target,localization_key=4010616934)
                case.header(0,1);case.poll(1)
                self.assertEqual(case.events,[])

    def test_true_hellbomb_callin_keeps_summon_action_and_source(self):
        case=ping_harness.PingEventsTests('runTest');case.setUp()
        case.target('C6A87C428FD3C7A3');case.poll(0)
        case.mark(kind=20,duration=9999,flags=0x2000,localization_key=4010616934)
        case.header(0,1);case.poll(1)
        event=case.events[0][0]
        self.assertEqual(event.get('category'),'stratagem')
        self.assertEqual(event.get('stratagem_id'),3989310204)
        self.assertEqual(event.get('action'),'summon')
        self.assertEqual(event.get('source'),'stratagem_call')

    def test_hellbomb_mark_obeys_master_and_existing_per_item_rule(self):
        chat_source=(ROOT/'src/chat_automation.lua').read_text(encoding='utf-8')
        for master,item,should_send in [(False,True,False),(True,False,False),(True,True,True)]:
            with self.subTest(master=master,item=item):
                case=ping_harness.PingEventsTests('runTest');case.setUp()
                case.target('C6A87C428FD3C7A3');case.localized[4010616934]='地狱火炸弹'
                sent=[]
                automation=case.lua.execute(chat_source+'''
                    local send=...;local peer='76561197960265745'
                    local sr={Network={game_session=function()return 'solo'end,peer_id=function()return peer end},
                        GameSession={peers=function()return {peer}end,game_session_host=function()return peer end}}
                    return build_chat_automation({engine=function()return sr end,context=function()return 123 end,
                        write_file=function()return true end,send=function(text)return send(text)end})
                ''',lambda text:sent.append(text) or True)
                automation.set('ping',master)
                automation.set('message_language','zh');automation.set('ping_sender_prefix',False)
                automation.set('ping_message','{目标}')
                automation.set_rule('stratagem',3989310204,'enabled',item)
                automation.set_rule('stratagem',3989310204,'cooldown',0)
                constructor=case.lua.execute(ping_harness.SOURCE.read_text(encoding='utf-8')
                                              +'\nreturn build_ping_events')
                adapter=constructor(case.lua.table_from({'base':lambda:case.base,'read':case.read,
                    'localize':lambda key:case.localized.get(int(key)),
                    'emit':lambda event,now:automation.push_ping(event,now)}))
                adapter.poll(0)
                case.mark(creator=1001,kind=17,localization_key=4010616934);case.header(0,1)
                observed,_=adapter.poll(1)
                if should_send:
                    self.assertEqual(observed,1)
                    self.assertTrue(automation.poll(1)[0])
                    self.assertEqual(sent,['\n地狱火炸弹'])
                else:
                    self.assertEqual(observed,0)
                    self.assertEqual(sent,[])


if __name__ == '__main__':
    unittest.main()
