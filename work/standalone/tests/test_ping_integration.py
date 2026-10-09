"""Verify the native reader is build-gated and wired to the live scheduler."""
import unittest
from test_auto_chat_probe import fresh_image, SOURCE
from test_marker_localization import SIGNATURE


class PingIntegrationTest(unittest.TestCase):
    def native_lookup(self):
        lua,h=fresh_image();mod=h.load(SOURCE)
        h.exe_base=0x150000000
        h.region(h.exe_base,0x400000,0x1000,0x20)
        h.bytes(h.exe_base,b'MZ'+bytes(58)+b'\x00\x01\x00\x00')
        h.bytes(h.exe_base+0x100,b'PE\x00\x00'+bytes(4)+bytes.fromhex('e482b36a')+bytes(4))
        target=h.exe_base+0x321da0
        h.bytes(target,bytes.fromhex('33d2e999feffffcccccccccccccccccc'))
        h.bytes(h.code_base+0x17802e0,SIGNATURE)
        h.u64(h.code_base+0x3326308,h.ctx_base)
        h.u64(h.ctx_base+0x10,h.ctx_base+0x1000)
        h.u64(h.ctx_base+0x1000+0x3e8,target)
        h.native_address=target;h.native_result=h.ctx_base+0x2000
        lua.execute('''local base=...;local kernel=require('ffi').load('kernel32')
            local query=kernel.VirtualQuery
            kernel.VirtualQuery=function(address,info,size)
                local result=query(address,info,size)
                address=type(address)=='table' and address.value or address
                if type(address)=='number' and address>=base and address<base+0x400000 then
                    local function put(at,n)
                        for i=0,3 do info[at+i]=n%256;n=math.floor(n/256) end
                    end
                    put(8,base%4294967296);put(12,math.floor(base/4294967296));put(0x28,0x1000000)
                end
                return result
            end''',h.exe_base)
        return lua,h,mod,target

    def test_captured_chinese_names_are_read_through_the_actual_guard_and_native_bridge(self):
        for key,name in ((1263463686,'重新补给'),(3947494337,'补给型快速侦察载具'),
                         (1722699279,'关停非法广播'),(1723671216,'武斗虫')):
            with self.subTest(key=key):
                lua,h,mod,target=self.native_lookup()
                h.bytes(h.native_result,name.encode()+bytes(64))
                self.assertEqual(mod.debug_localization().lookup(key),name)
                self.assertEqual(h.call_count(),1)
                self.assertEqual(h.last_call().address,target)

    def test_main_executable_stamp_signature_and_exact_lookup_address_are_required(self):
        for mutation in ('stamp','signature','redirect','missing'):
            with self.subTest(mutation=mutation):
                lua,h,mod,target=self.native_lookup()
                if mutation=='stamp':h.u32(h.exe_base+0x108,0)
                elif mutation=='signature':h.bytes(target,b'\x90')
                elif mutation=='redirect':h.u64(h.ctx_base+0x1000+0x3e8,target+16)
                else:h.exe_base=None
                self.assertIsNone(mod.debug_localization().lookup(1723671216))
                self.assertEqual(h.call_count(),0)

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

    def test_localization_calls_only_the_verified_main_executable_lookup(self):
        for protect, kind, own_image, permitted in ((0x20,0x1000000,True,True),
                (0x04,0x1000000,True,False), (0x120,0x1000000,True,False),
                (0x20,0x20000,True,False), (0x20,0x1000000,False,False)):
            with self.subTest(protect=protect, kind=kind, own_image=own_image):
                lua, h = fresh_image(); mod = h.load(SOURCE)
                h.exe_base = 0x150000000
                h.bytes(h.exe_base, b'MZ' + bytes(58) + b'\x00\x01\x00\x00')
                h.bytes(h.exe_base + 0x100, b'PE\x00\x00' + bytes(4) + bytes.fromhex('e482b36a') + bytes(4))
                h.bytes(h.exe_base + 0x321da0, bytes.fromhex('33d2e999feffffcccccccccccccccccc'))
                h.bytes(h.code_base + 0x17802e0, SIGNATURE)
                h.u64(h.code_base + 0x3326308, h.ctx_base)
                h.u64(h.ctx_base + 0x10, h.ctx_base + 0x1000)
                target = h.exe_base + 0x321da0
                h.u64(h.ctx_base + 0x1000 + 0x3e8, target)
                allocation = h.exe_base if own_image else h.code_base
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
