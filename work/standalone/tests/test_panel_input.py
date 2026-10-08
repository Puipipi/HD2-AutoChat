"""Execute the panel input fragment with real LuaJIT FFI and a fake Win32 boundary.

The fake owns real allocated buffers; no Win32 procedure is ever installed here.
"""
import re
import unittest
from pathlib import Path

from lupa.luajit21 import LuaRuntime

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
    from unicorn.x86_const import (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8,
                                  UC_X86_REG_R9, UC_X86_REG_RSP, UC_X86_REG_RAX)
except ImportError:
    Uc = None

ROOT = Path(__file__).resolve().parents[5]
FRAGMENT = ROOT / "mods/auto-chat/src/panel_input.lua"
ARMORY = ROOT / "work/lua-extract2/Super-Earth-Armory-Forge-v6.2.1_AR735914__9ba626afa44a3aa3.patch_0__0.lua"

FAKE_WIN32 = r'''
local real = require('ffi')
local h = { blocks = {}, devices = {}, calls = {}, attempts = {}, notes = {},
            procedures = {[100] = 900, [200] = 901}, threads = {[100] = 7, [200] = 8},
            failures = {}, keys = {}, declared = {}, existing = {}, scans = 0 }
local user, kernel = {}, {}
local ffi = { new = real.new, cast = real.cast, sizeof = real.sizeof }
ffi.C = setmetatable({}, {__index = function(_, key)
    if h.existing[key] then return function() end end
    error('undeclared ' .. key)
end})
ffi.cdef = function(declaration)
    h.declared[#h.declared + 1] = declaration
    return real.cdef(declaration)
end
kernel.GetCurrentThreadId = function() return 7 end
kernel.GetModuleHandleA = function() return real.cast('void *', 10) end
kernel.GetProcAddress = function() return real.cast('void *', 20) end
kernel.VirtualAlloc = function(_, size)
    if h.no_alloc then return nil end
    local b = real.new('uint8_t[?]', size)
    h.blocks[#h.blocks + 1] = b
    return real.cast('void *', b)
end
kernel.GetCurrentProcess = function() return real.cast('void *', -1) end
kernel.FlushInstructionCache = function() return 1 end
user.GetAsyncKeyState = function(vk) return h.keys[vk] and -32768 or 0 end
user.GetWindowThreadProcessId = function(window)
    return h.threads[tonumber(real.cast('uintptr_t', window))] or 0
end
user.GetWindowLongPtrW = function(window) return h.procedures[tonumber(window)] or 0 end
user.SetWindowLongPtrW = function(window, _, entry)
    if h.no_install then return 0 end
    local key = tonumber(window)
    local old = h.procedures[key]
    h.procedures[key] = entry
    return old
end
user.GetRegisteredRawInputDevices = function(devices, count)
    h.scans = h.scans + 1
    if h.scan_throws then error('raw enumeration failed') end
    if h.scan_error then return 0xFFFFFFFF end
    if devices == nil then count[0] = #h.devices; return 0 end
    local list = real.cast('AUTOCHAT_RAWDEV *', devices)
    for i, d in ipairs(h.devices) do
        list[i-1].page, list[i-1].usage = d.page, d.usage
        list[i-1].flags, list[i-1].target = d.flags, d.target
    end
    return #h.devices
end
user.RegisterRawInputDevices = function(devices, count)
    local list, call = real.cast('AUTOCHAT_RAWDEV *', devices), {}
    for i=0,count-1 do
        call[#call+1] = {page=tonumber(list[i].page), usage=tonumber(list[i].usage),
                        flags=tonumber(list[i].flags), target=tonumber(real.cast('uintptr_t',list[i].target))}
    end
    h.attempts[#h.attempts+1] = call
    local fail = table.remove(h.failures, 1)
    if fail == 'throw' then error('registration exception') end
    if fail then return 0 end
    h.calls[#h.calls+1] = call
    for _, d in ipairs(call) do
        for i=#h.devices,1,-1 do
            if h.devices[i].page==d.page and h.devices[i].usage==d.usage then table.remove(h.devices,i) end
        end
        if d.flags~=1 then
            h.devices[#h.devices+1]={page=d.page,usage=d.usage,flags=d.flags,
                                    target=d.target~=0 and real.cast('void *', d.target) or nil}
        end
    end
    return 1
end
function h.device(usage, flags, window, page)
    h.devices[#h.devices+1] = {page=page or 1,usage=usage,flags=flags or 0,
                             target=window and real.cast('void *',window) or nil}
end
function h.flags(index) return tonumber(real.cast('uint32_t *',h.blocks[index or 1])[0]) end
function h.procedure(window) return tonumber(h.procedures[window]) end
function h.block_hex(index)
    local result={}
    for i=0,4095 do result[#result+1]=string.format('%02x',h.blocks[index or 1][i]) end
    return table.concat(result)
end
function h.build(builder)
    return builder(ffi,user,kernel,function(message) h.notes[#h.notes+1]=message end)
end
return h
'''


def fresh():
    assert FRAGMENT.exists(), "panel input fragment has not been implemented"
    lua = LuaRuntime(unpack_returned_tuples=True)
    h = lua.execute(FAKE_WIN32)
    builder = lua.execute(FRAGMENT.read_text(encoding="utf-8") + "\nreturn build_panel_input")
    return lua, h, h.build(builder)


class PanelInputTest(unittest.TestCase):
    def test_waits_for_panel_key_release_then_blocks_own_thread_devices(self):
        _, h, panel = fresh()
        h.device(2, 0x130, 100)
        h.device(6, 0, 200)  # another thread must keep its keyboard
        h.device(5, 0, 100)  # unrelated device
        panel.hold(1, 100, True)
        self.assertEqual(0, len(h.blocks))
        self.assertEqual(0, len(h.attempts))
        panel.hold(1.1, 100, False)
        self.assertEqual(1, h.flags())
        self.assertEqual(1, len(h.calls[1]))
        self.assertEqual((1, 2, 1, 0), tuple(h.calls[1][1][k] for k in ('page','usage','flags','target')))
        self.assertEqual(2, len(h.devices))
        panel.release()
        self.assertEqual(0, h.flags())
        self.assertEqual((2, 0x130, 100), tuple(h.calls[2][1][k] for k in ('usage','flags','target')))
        self.assertEqual(3, len(h.devices))
        before = len(h.calls)
        panel.release()
        self.assertEqual(before, len(h.calls))

    def test_half_second_check_retakes_and_restores_latest_registration(self):
        _, h, panel = fresh()
        h.device(2, 0, 100)
        panel.hold(10, 100, False)
        h.device(2, 0x30, 100)
        panel.hold(10.49, 100, False)
        self.assertEqual(1, len(h.attempts))
        panel.hold(10.5, 100, False)
        self.assertEqual(2, len(h.attempts))
        panel.release()
        self.assertEqual(0x30, h.calls[3][1]['flags'])

    def test_focus_loss_disables_every_filter_and_restores_raw_input(self):
        _, h, panel = fresh()
        h.device(6, 0, 100)
        panel.hold(0, 100, False)
        entry = h.procedure(100)
        panel.hold(0.1, None, False)
        self.assertEqual(0, h.flags())
        self.assertEqual(1, len(h.devices))
        self.assertEqual(entry, h.procedure(100))  # never unchain a procedure
        panel.hold(1, 100, False)
        self.assertEqual(1, len(h.blocks))
        panel.release()

    def test_later_subclass_is_preserved_and_all_allocations_stay_inactive_after_close(self):
        _, h, panel = fresh()
        panel.hold(0, 100, False)
        panel.release()
        h.procedures[100] = 777  # a later mod chained on top of our entry
        panel.hold(1, 100, False)
        self.assertEqual(2, len(h.blocks))
        panel.release()
        self.assertEqual((0, 0), (h.flags(1), h.flags(2)))
        self.assertNotEqual(777, h.procedures[100])
        self.assertEqual(2, len(h.blocks))

    def test_failed_remove_restores_previously_taken_devices_and_deactivates_filter(self):
        _, h, panel = fresh()
        h.device(2, 0, 100)
        panel.hold(0, 100, False)
        h.device(6, 0, 100)
        h.failures[1] = True
        panel.hold(0.5, 100, False)
        self.assertTrue(panel.status()['broken'])
        self.assertEqual(0, h.flags())
        self.assertEqual(2, len(h.devices))

    def test_restore_fallback_clears_window_flags_then_tries_plain_registration(self):
        _, h, panel = fresh()
        h.device(2, 0x3130, 100)
        panel.hold(0, 100, False)
        h.failures[1], h.failures[2] = True, True
        panel.release()
        self.assertEqual((0x3130, 0x30, 0), tuple(h.attempts[i][1]['flags'] for i in (2,3,4)))
        self.assertEqual(0, h.attempts[3][1]['target'])
        self.assertTrue(panel.status()['broken'])
        self.assertEqual(1, len(h.devices))
        self.assertEqual(0, h.flags())

    def test_exception_during_enumeration_restores_raw_input_and_filter(self):
        _, h, panel = fresh()
        h.device(2, 0, 100)
        panel.hold(0, 100, False)
        h.scan_throws = True
        panel.hold(0.5, 100, False)
        self.assertEqual(0, h.flags())
        self.assertEqual(1, len(h.devices))
        self.assertTrue(panel.status()['broken'])

    def test_filter_install_failure_leaves_raw_devices_alone(self):
        _, h, panel = fresh()
        h.device(2, 0, 100)
        h.no_install = True
        panel.hold(0, 100, False)
        self.assertEqual(0, len(h.attempts))
        self.assertEqual(0, h.flags())
        self.assertEqual(1, len(h.devices))

    def test_total_restore_failure_keeps_pending_originals_for_a_later_release(self):
        _, h, panel = fresh()
        h.device(2, 0x30, 100)
        panel.hold(0, 100, False)
        for i in (1,2,3):
            h.failures[i] = True
        panel.release()
        self.assertEqual(0, len(h.devices))
        self.assertIsNotNone(panel.status()['saved'])
        self.assertEqual(0, h.flags())
        panel.release()
        self.assertEqual(1, len(h.devices))
        self.assertEqual(0x30, h.calls[2][1]['flags'])
        self.assertIsNone(panel.status()['saved'])

    def test_raw_enumeration_error_code_deactivates_filter(self):
        _, h, panel = fresh()
        h.scan_error = True
        panel.hold(0, 100, False)
        self.assertEqual(0, h.flags())
        self.assertTrue(panel.status()['broken'])

    def test_changing_windows_installs_and_activates_the_new_filter(self):
        _, h, panel = fresh()
        panel.hold(0, 100, False)
        panel.hold(1, 200, False)
        self.assertEqual(1, h.flags(2))
        panel.release()
        self.assertEqual((0,0), (h.flags(1),h.flags(2)))

    def test_declarations_reuse_existing_symbols_and_match_armory_prototypes(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        h = lua.execute(FAKE_WIN32)
        h.existing['GetWindowThreadProcessId'] = True
        self.assertTrue(FRAGMENT.exists(), 'panel input fragment has not been implemented')
        builder = lua.execute(FRAGMENT.read_text(encoding='utf-8') + '\nreturn build_panel_input')
        h.build(builder)
        reference = ARMORY.read_text(encoding='utf-8')
        for i in range(1, len(h.declared)+1):
            declaration = h.declared[i]
            if 'typedef struct' in declaration:
                declaration = declaration.replace('AUTOCHAT_RAWDEV', 'AF_RAWDEV')
            self.assertIn("'" + declaration + "'", reference)
            self.assertNotIn('GetWindowThreadProcessId', h.declared[i])

    def test_native_table_and_code_are_identical_to_armory(self):
        self.assertTrue(FRAGMENT.exists(), 'panel input fragment has not been implemented')
        def extract(path, name):
            text = path.read_text(encoding='utf-8')
            body = re.search(r'local ' + name + r' = \{(.*?)\}', text, re.S)[1]
            return bytes(int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]+)', body))
        for name in ('FILTER_TABLE', 'FILTER_CODE'):
            self.assertEqual(extract(ARMORY, name), extract(FRAGMENT, name))


@unittest.skipIf(Uc is None, 'optional unicorn x64 emulator is unavailable')
class NativeWindowProcedureTest(unittest.TestCase):
    def setUp(self):
        _, h, panel = fresh()
        panel.hold(0,100,False)
        block = bytearray.fromhex(h.block_hex())
        self.base, self.call, self.stop = 0x100000, 0x200000, 0x300000
        # Relocate only the per-install block and forwarding function pointers.
        block[24:32] = self.call.to_bytes(8,'little')
        block[66:74] = self.base.to_bytes(8,'little')
        self.uc = Uc(UC_ARCH_X86,UC_MODE_64)
        for address, size in ((self.base,4096),(self.call,4096),(self.stop,4096),(0x400000,0x10000)):
            self.uc.mem_map(address,size)
        self.uc.mem_write(self.base,bytes(block))
        self.uc.mem_write(self.call,bytes.fromhex('b878563412c3'))  # unique forwarded return
        self.forwarded = []
        def hook(uc,address,_size,_data):
            if address==self.call:
                rsp=uc.reg_read(UC_X86_REG_RSP)
                args=[uc.reg_read(reg) for reg in (UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9)]
                args.append(int.from_bytes(uc.mem_read(rsp+40,8),'little'))
                self.forwarded.append(tuple(args))
        self.uc.hook_add(UC_HOOK_CODE,hook)

    def message(self,msg,wparam=0,lparam=0):
        rsp=0x408008
        self.uc.mem_write(rsp,self.stop.to_bytes(8,'little'))
        for reg,value in ((UC_X86_REG_RSP,rsp),(UC_X86_REG_RCX,100),(UC_X86_REG_RDX,msg),
                          (UC_X86_REG_R8,wparam),(UC_X86_REG_R9,lparam)):
            self.uc.reg_write(reg,value)
        before=len(self.forwarded)
        self.uc.emu_start(self.base+64,self.stop,count=1000)
        return self.uc.reg_read(UC_X86_REG_RAX),len(self.forwarded)>before

    def test_esc_and_social_key_presses_are_consumed_but_releases_and_raw_messages_forward(self):
        for key in (0x1b,0x4f):
            self.assertEqual((0,False),self.message(0x100,key,123))
            self.assertEqual((0x12345678,True),self.message(0x101,key,456))
        for msg in (0x102,0x103,0x109):
            self.assertEqual((0,False),self.message(msg,65))
        self.assertEqual((0x12345678,True),self.message(0xff,7,8))
        self.assertEqual((900,100,0xff,7,8),self.forwarded[-1])

    def test_closing_filter_forwards_new_keys_clicks_and_signed_wheel(self):
        self.assertEqual((0,False),self.message(0x201))
        self.assertEqual((0,False),self.message(0x202))
        self.assertEqual((0,False),self.message(0x20a,(0xff88<<16)))
        self.assertEqual(-120,int.from_bytes(self.uc.mem_read(self.base+4,4),'little',signed=True))
        self.uc.mem_write(self.base,(0).to_bytes(4,'little'))
        for msg,wp in ((0x100,0x1b),(0x201,0),(0x20a,120<<16)):
            self.assertEqual((0x12345678,True),self.message(msg,wp))

    def test_release_of_mouse_button_seen_before_open_reaches_game_once(self):
        self.uc.mem_write(self.base+32,(1).to_bytes(4,'little'))
        self.assertEqual((0x12345678,True),self.message(0x202))
        self.assertEqual((0,False),self.message(0x202))


if __name__ == '__main__':
    unittest.main()
