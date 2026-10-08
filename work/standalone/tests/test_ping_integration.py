"""Verify the native reader is build-gated and wired to the live scheduler."""
import unittest
from test_auto_chat_probe import fresh_image, SOURCE
from test_marker_localization import SIGNATURE


class PingIntegrationTest(unittest.TestCase):
    def test_native_reader_has_the_tested_category_support(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        adapter = mod.debug_ping_events()
        self.assertTrue(adapter.supported.medium_enemy)
        self.assertTrue(adapter.supported.large_enemy)
        self.assertTrue(adapter.supported.giant_enemy)
        self.assertIsNone(adapter.supported.small_items)
        self.assertTrue(adapter.supported.stratagem)
        self.assertTrue(adapter.supported.map)
        self.assertTrue(adapter.supported.building)

    def test_unsupported_pe_stamp_prevents_native_reader_memory_walk(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        h.u32(h.code_base + 0x100 + 8, 0)
        before = mod.reads
        count, status = mod.debug_ping_events().poll(10)
        self.assertEqual(count, 0)
        self.assertEqual(status, '标记数据暂不可用')
        self.assertLessEqual(mod.reads - before, 2)

    def test_scheduler_polls_reader_only_when_auto_ping_is_enabled(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        reader = mod.debug_ping_events()
        calls = []
        reader.poll = lambda now: (calls.append(now) or 0, 'test native observation')
        lua.execute('for i=1,60 do update() end')
        self.assertEqual(calls, [])
        self.assertTrue(mod.debug_automation().set('ping', True)[0])
        lua.execute('for i=1,60 do update() end')
        self.assertGreater(len(calls), 0)
        self.assertEqual(mod.ping_status, 'test native observation')
        before = len(calls)
        self.assertTrue(mod.debug_automation().set('enabled', False)[0])
        lua.execute('for i=1,60 do update() end')
        self.assertEqual(len(calls), before)
        self.assertEqual(mod.ping_status, '自动发送已关闭')

    def test_registered_event_listener_is_polled_with_core_automatic_messages_disabled(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        calls = []
        mod.debug_ping_events().poll = lambda now: (calls.append(now) or 0, 'listener observation')
        self.assertTrue(mod.debug_automation().set('enabled', False)[0])
        lua.execute("HD2AutoChatAPI.register({id='observer',name='观察者',draw=function() end,on_event=function() end})")
        lua.execute('for i=1,60 do update() end')
        self.assertGreater(len(calls), 0)
        self.assertEqual(h.call_count(), 0)
        lua.execute("HD2AutoChatAPI.unregister('observer')")
        before = len(calls)
        lua.execute('for i=1,60 do update() end')
        self.assertEqual(len(calls), before)

    def test_unsupported_build_never_reaches_native_localization_call(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        h.u32(h.code_base + 0x100 + 8, 0)
        before = h.call_count()
        self.assertIsNone(mod.debug_localization().lookup(123))
        self.assertEqual(h.call_count(), before)

    def test_localization_calls_only_a_verified_executable_page_in_the_game_image(self):
        for protect, kind, own_image, permitted in ((0x20,0x1000000,True,True),
                (0x04,0x1000000,True,False), (0x120,0x1000000,True,False),
                (0x20,0x20000,True,False), (0x20,0x1000000,False,False)):
            with self.subTest(protect=protect, kind=kind, own_image=own_image):
                lua, h = fresh_image(); mod = h.load(SOURCE)
                h.bytes(h.code_base + 0x17802e0, SIGNATURE)
                h.u64(h.code_base + 0x3326308, h.ctx_base)
                h.u64(h.ctx_base + 0x10, h.ctx_base + 0x1000)
                target = h.code_base + 0x100000
                h.u64(h.ctx_base + 0x1000 + 0x3e8, target)
                allocation = h.code_base if own_image else h.ctx_base
                lua.execute('''local protect,kind,allocation=...
                    require('ffi').load('kernel32').VirtualQuery=function(address,info,size)
                        local function put(at,n)
                            for i=0,3 do info[at+i]=n%256; n=math.floor(n/256) end
                        end
                        put(8,allocation%4294967296);put(12,math.floor(allocation/4294967296))
                        put(0x20,0x1000);put(0x24,protect);put(0x28,kind)
                        return 48
                    end''',protect,kind,allocation)
                before = h.call_count()
                self.assertIsNone(mod.debug_localization().lookup(123))
                self.assertEqual(h.call_count()-before, int(permitted))
                if permitted:
                    self.assertEqual(h.last_call().address, target)
                    self.assertEqual(h.last_call().arg1_address, 123)


if __name__ == '__main__':
    unittest.main()
