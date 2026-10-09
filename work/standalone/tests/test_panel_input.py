"""Execute the panel input fragment with real LuaJIT FFI and a fake Win32 boundary.

The fake owns real allocated buffers; no Win32 procedure is ever installed here.
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from lupa.luajit21 import LuaRuntime

try:
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
    from unicorn.x86_const import (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8,
                                  UC_X86_REG_R9, UC_X86_REG_R10, UC_X86_REG_R11,
                                  UC_X86_REG_RSP, UC_X86_REG_RAX, UC_X86_REG_RIP,
                                  UC_X86_REG_RBX, UC_X86_REG_RBP, UC_X86_REG_RSI, UC_X86_REG_RDI,
                                  UC_X86_REG_R12, UC_X86_REG_R13, UC_X86_REG_R14, UC_X86_REG_R15)
except ImportError:
    Uc = None

ROOT = Path(__file__).resolve().parents[5]
FRAGMENT = ROOT / "mods/auto-chat/src/panel_input.lua"
BRIDGE_ASM = Path(__file__).with_name("panel_input_bridge.asm")
ARMORY = ROOT / "work/lua-extract2/Super-Earth-Armory-Forge-v6.2.1_AR735914__9ba626afa44a3aa3.patch_0__0.lua"

FAKE_WIN32 = r'''
local real = require('ffi')
local h = { blocks = {}, allocations = {}, devices = {}, calls = {}, attempts = {}, notes = {}, posted = {},
            protections = {}, freed = {}, load_count = 0, api = {CallWindowProcW=20, DefWindowProcW=21,
              ImmGetContext=30, ImmReleaseContext=31, ImmAssociateContextEx=32,
              ImmAssociateContext=33, ImmCreateContext=34, ImmDestroyContext=35},
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
kernel.LoadLibraryA = function()
    h.load_count = h.load_count + 1
    if h.null_library then return real.cast('void *', 0) end
    return real.cast('void *', 11)
end
kernel.GetProcAddress = function(_, name)
    if h.missing_export == name then return real.cast('void *', 0) end
    return real.cast('void *', h.api[name] or 20)
end
kernel.VirtualAlloc = function(_, size, _, protect)
    if h.no_alloc then return nil end
    local b = real.new('uint8_t[?]', size)
    h.blocks[#h.blocks + 1] = b
    h.allocations[#h.allocations+1] = {size=size, protect=protect}
    return real.cast('void *', b)
end
kernel.VirtualProtect = function(address, size, protect, old)
    if h.no_protect then return 0 end
    h.protections[#h.protections+1] = {address=tonumber(real.cast('uintptr_t',address)), size=size, protect=protect}
    old[0] = 4
    return 1
end
kernel.VirtualFree = function(address)
    h.freed[#h.freed+1] = tonumber(real.cast('uintptr_t',address))
    return 1
end
kernel.GetCurrentProcess = function() return real.cast('void *', -1) end
kernel.FlushInstructionCache = function() return h.flush_failure and 0 or 1 end
user.GetAsyncKeyState = function(vk) return h.keys[vk] and -32768 or 0 end
user.GetWindowThreadProcessId = function(window)
    return h.threads[tonumber(real.cast('uintptr_t', window))] or 0
end
user.GetWindowLongPtrW = function(window) return h.procedures[tonumber(window)] or 0 end
user.PostMessageW = function(window, message, wp, lp)
    if h.post_fail then return 0 end
    h.posted[#h.posted+1] = {tonumber(window), tonumber(message), tonumber(wp), tonumber(lp)}
    return 1
end
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
function h.block_set(index, hex)
    local block=h.blocks[index or 1]
    for i=0,4095 do block[i]=tonumber(hex:sub(i*2+1,i*2+2),16) end
end
function h.data_hex(index) return h.block_hex(index or 1) end
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
    @unittest.skipUnless(shutil.which('nasm'), 'NASM is needed to reproduce the checked-in x64 thunk')
    def test_static_bridge_bytes_match_x64_assembly_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'panel_input_bridge.bin'
            subprocess.run([shutil.which('nasm'), '-f', 'bin', '-o', str(output), str(BRIDGE_ASM)], check=True)
            machine_code = output.read_bytes()
        source = FRAGMENT.read_text(encoding='utf-8')
        bridge = re.search(r'local BRIDGE_HEX = \[\[(.*?)\]\]', source, re.S).group(1)
        self.assertEqual(machine_code, bytes.fromhex(bridge))

    def test_editing_queues_owner_thread_ime_transition_and_can_drain_events(self):
        _, h, panel = fresh()
        panel.hold(0, 100, False)
        self.assertTrue(panel.editing(True, 100))
        self.assertEqual((100, 0x84A2, 1), tuple(h.posted[1][i] for i in range(1, 4)))
        panel.clear()
        events, overflow = panel.drain()
        self.assertEqual([], list(events.values()))
        self.assertFalse(overflow)
        self.assertTrue(panel.editing(False, 100))
        self.assertEqual((100, 0x84A2, 0), tuple(h.posted[2][i] for i in range(1, 4)))

    def test_release_preserves_native_ring_for_editor_to_flush_after_async_disable(self):
        _, h, panel = fresh()
        panel.hold(0, 100, False)
        data = bytearray.fromhex(h.block_hex(1))
        data[136:140] = (1).to_bytes(4, 'little')  # native producer head
        data[140:144] = (0).to_bytes(4, 'little')  # consumer tail
        data[256:260] = (0x102).to_bytes(4, 'little')
        data[264:272] = (0x4E2D).to_bytes(8, 'little')
        data[272:280] = (0).to_bytes(8, 'little')
        h.block_set(1, data.hex())

        panel.release()
        events, overflow = panel.drain()
        self.assertFalse(overflow)
        rows = list(events.values())
        self.assertEqual([(0x102, 0x4E2D, 0)],
                         [(row['message'], row['wparam'], row['lparam']) for row in rows])

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
        self.assertEqual(2, len(h.blocks))
        panel.release()

    def test_later_subclass_is_preserved_and_all_allocations_stay_inactive_after_close(self):
        _, h, panel = fresh()
        panel.hold(0, 100, False)
        panel.release()
        h.procedures[100] = 777  # a later mod chained on top of our entry
        panel.hold(1, 100, False)
        self.assertEqual(2, len(h.blocks))
        panel.release()
        self.assertEqual(0, h.flags(1))
        self.assertEqual(777, h.procedures[100])
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

    def test_null_imm32_and_missing_middle_or_last_export_fail_before_allocating(self):
        _, h, panel = fresh()
        h.null_library = True
        panel.hold(0, 100, False)
        self.assertEqual(1, h.load_count)
        self.assertEqual(0, len(h.blocks))
        self.assertEqual(900, h.procedure(100))

        for name in ('ImmAssociateContextEx', 'ImmDestroyContext'):
            _, h, panel = fresh()
            h.missing_export = name
            panel.hold(0, 100, False)
            self.assertEqual(0, len(h.blocks), name)
            self.assertEqual(900, h.procedure(100), name)

    def test_instruction_cache_flush_failure_frees_pages_before_install(self):
        _, h, panel = fresh()
        h.flush_failure = True
        panel.hold(0, 100, False)
        self.assertEqual(2, len(h.blocks))
        self.assertEqual(2, len(h.freed))
        self.assertEqual(0, len(h.protections))
        self.assertEqual(900, h.procedure(100))

    def test_native_state_stays_rw_code_becomes_rx_and_failed_protection_frees_both_pages(self):
        _, h, panel = fresh()
        panel.hold(0, 100, False)
        self.assertEqual([0x04, 0x04], [h.allocations[i]['protect'] for i in range(1, len(h.allocations)+1)])
        self.assertEqual([0x20], [h.protections[i]['protect'] for i in range(1, len(h.protections)+1)])
        self.assertEqual(1, h.load_count)

        _, h, panel = fresh()
        h.no_protect = True
        panel.hold(0, 100, False)
        self.assertEqual(0, len(h.protections))
        self.assertEqual(2, len(h.freed))
        self.assertEqual(900, h.procedure(100))

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
        self.assertEqual(1, h.flags(3))
        panel.release()
        self.assertEqual((0,0), (h.flags(1),h.flags(3)))

    def test_declarations_reuse_existing_symbols_and_match_armory_prototypes(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        h = lua.execute(FAKE_WIN32)
        h.existing['GetWindowThreadProcessId'] = True
        self.assertTrue(FRAGMENT.exists(), 'panel input fragment has not been implemented')
        builder = lua.execute(FRAGMENT.read_text(encoding='utf-8') + '\nreturn build_panel_input')
        h.build(builder)
        reference = ARMORY.read_text(encoding='utf-8')
        reference_declarations = []
        armory_names = {'GetCurrentThreadId', 'GetRegisteredRawInputDevices', 'RegisterRawInputDevices',
                        'GetModuleHandleA', 'GetProcAddress', 'VirtualAlloc', 'FlushInstructionCache',
                        'GetCurrentProcess', 'GetWindowLongPtrW', 'SetWindowLongPtrW'}
        for i in range(1, len(h.declared)+1):
            declaration = h.declared[i]
            if 'typedef struct' in declaration:
                declaration = declaration.replace('AUTOCHAT_RAWDEV', 'AF_RAWDEV')
                self.assertIn("'" + declaration + "'", reference)
                continue
            name = re.search(r'([A-Za-z_]\w*)\s*\(', declaration).group(1)
            self.assertNotIn('GetWindowThreadProcessId', declaration)
            if name in armory_names:
                reference_declarations.append(declaration)
                self.assertIn("'" + declaration + "'", reference)
        self.assertEqual(len(armory_names),len(reference_declarations))

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
        self.panel, self.h = panel, h
        self.code_base, self.state = 0x100000, 0x500000
        self.call, self.defproc, self.stop = 0x200000, 0x210000, 0x300000
        self.imm_base = 0x220000
        data = bytearray.fromhex(h.block_hex(1))
        code = bytearray.fromhex(h.block_hex(2))
        code[66:74] = self.state.to_bytes(8,'little')
        data[24:32] = self.call.to_bytes(8,'little')
        for offset, address in ((168,self.defproc),(176,self.imm_base),(184,self.imm_base+16),
                                (192,self.imm_base+32),(200,self.imm_base+48),
                                (208,self.imm_base+64),(216,self.imm_base+80)):
            data[offset:offset+8] = address.to_bytes(8,'little')
        self.uc = Uc(UC_ARCH_X86,UC_MODE_64)
        for address, size in ((self.code_base,4096),(self.state,4096),(self.call,4096),
                              (self.defproc,4096),(self.imm_base,4096),(self.stop,4096),(0x400000,0x10000)):
            self.uc.mem_map(address,size)
        self.uc.mem_write(self.code_base,bytes(code))
        self.uc.mem_write(self.state,bytes(data))
        self.forwarded, self.defaulted, self.imm_calls, self.call_rsp_mods = [], [], [], []
        self.imm_current, self.default_context = 0x555, 0x666
        self.assoc_ex_result, self.create_result, self.imm_get_override = 1, 0x777, None
        self.fail_restore = False
        self.imm_get_count, self.override_after_associate = 0, None
        def hook(uc,address,_size,_data):
            if address in (self.call,self.defproc) or self.imm_base <= address <= self.imm_base+80:
                self.call_rsp_mods.append(uc.reg_read(UC_X86_REG_RSP) % 16)
            if address == self.call:
                args = self.args(uc, five=True)
                self.forwarded.append(args)
                self.api_return(uc, 0x12345678)
            elif address == self.defproc:
                self.defaulted.append(self.args(uc))
                self.api_return(uc, 0x76543210)
            elif address >= self.imm_base and address <= self.imm_base + 80:
                self.imm_api(uc, address - self.imm_base)
        self.uc.hook_add(UC_HOOK_CODE,hook)

    def args(self, uc, five=False):
        args=[uc.reg_read(reg) for reg in (UC_X86_REG_RCX,UC_X86_REG_RDX,UC_X86_REG_R8,UC_X86_REG_R9)]
        if five:
            rsp=uc.reg_read(UC_X86_REG_RSP)
            args.append(int.from_bytes(uc.mem_read(rsp+40,8),'little'))
        return tuple(args)

    def api_return(self, uc, value):
        rsp=uc.reg_read(UC_X86_REG_RSP)
        target=int.from_bytes(uc.mem_read(rsp,8),'little')
        uc.reg_write(UC_X86_REG_RSP,rsp+8)
        uc.reg_write(UC_X86_REG_RAX,value)
        # Windows x64 may clobber every volatile GPR except that RAX carries
        # the return value. Deliberately poison them to catch hidden live state.
        for reg, poison in ((UC_X86_REG_RCX,0xC1C1C1C1C1C1C1C1),
                            (UC_X86_REG_RDX,0xD2D2D2D2D2D2D2D2),
                            (UC_X86_REG_R8,0x8181818181818181),
                            (UC_X86_REG_R9,0x9191919191919191),
                            (UC_X86_REG_R10,0xA0A0A0A0A0A0A0A0),
                            (UC_X86_REG_R11,0xB1B1B1B1B1B1B1B1)):
            uc.reg_write(reg,poison)
        uc.reg_write(UC_X86_REG_RIP,target)

    def imm_api(self, uc, offset):
        args=self.args(uc)
        self.imm_calls.append((offset,args))
        if offset == 0:
            self.imm_get_count += 1
            value = self.imm_current
            if self.imm_get_override is not None:
                value = self.imm_get_override
            elif self.override_after_associate is not None and self.imm_get_count >= self.override_after_associate[0]:
                value = self.override_after_associate[1]
                self.override_after_associate = None
            self.api_return(uc,value)
        elif offset == 16:
            self.api_return(uc,1)
        elif offset == 32:
            if self.assoc_ex_result:
                self.imm_current = self.default_context
            self.api_return(uc,self.assoc_ex_result)
        elif offset == 48:
            previous=self.imm_current
            if not (self.fail_restore and self.imm_current==0x777 and args[1]==0x555):
                self.imm_current=args[1]
            self.api_return(uc,previous)
        elif offset == 64:
            self.api_return(uc,self.create_result)
        elif offset == 80:
            self.api_return(uc,1)

    def message(self,msg,wparam=0,lparam=0):
        rsp=0x408008
        self.uc.mem_write(rsp,self.stop.to_bytes(8,'little'))
        self.uc.mem_write(rsp+40,(0xAABBCCDD).to_bytes(8,'little'))
        nonvolatile = ((UC_X86_REG_RBX,0xB0B0B0B0B0B0B0B0),
                       (UC_X86_REG_RBP,0xB5B5B5B5B5B5B5B5),
                       (UC_X86_REG_RSI,0x5151515151515151),
                       (UC_X86_REG_RDI,0xD1D1D1D1D1D1D1D1),
                       (UC_X86_REG_R12,0x1212121212121212),
                       (UC_X86_REG_R13,0x1313131313131313),
                       (UC_X86_REG_R14,0x1414141414141414),
                       (UC_X86_REG_R15,0x1515151515151515))
        for reg,value in nonvolatile:
            self.uc.reg_write(reg,value)
        for reg,value in ((UC_X86_REG_RSP,rsp),(UC_X86_REG_RCX,100),(UC_X86_REG_RDX,msg),
                          (UC_X86_REG_R8,wparam),(UC_X86_REG_R9,lparam)):
            self.uc.reg_write(reg,value)
        before=len(self.forwarded)
        self.uc.emu_start(self.code_base+64,self.stop,count=10000)
        self.assertEqual([value for _,value in nonvolatile],
                         [self.uc.reg_read(reg) for reg,_ in nonvolatile],
                         'WNDPROC must preserve all Windows x64 nonvolatile GPRs')
        return self.uc.reg_read(UC_X86_REG_RAX),len(self.forwarded)>before

    def set_active(self, active=True):
        self.uc.mem_write(self.state+128,int(active).to_bytes(4,'little'))

    def events(self):
        self.h.block_set(1,bytes(self.uc.mem_read(self.state,4096)).hex())
        result=self.panel.drain()
        self.uc.mem_write(self.state,bytes.fromhex(self.h.block_hex(1)))
        return result

    def control(self, enabled):
        return self.message(0x84A2, int(enabled), self.state)

    def test_inactive_messages_use_original_filter_and_forward_all_five_arguments(self):
        self.uc.mem_write(self.state,(0).to_bytes(4,'little'))
        self.assertEqual((0x12345678,True),self.message(0x102,ord('x'),0))
        self.assertEqual((0x12345678,True),self.message(0xff,7,8))
        self.assertEqual((900,100,0xff,7,8),self.forwarded[-1])
        self.assertEqual(0, int.from_bytes(self.uc.mem_read(self.state+132,4),'little'))

    def test_editing_captures_utf16_keys_and_composition_without_game_forwarding(self):
        self.set_active()
        self.assertEqual((0,False),self.message(0x102,0x4E2D,0))
        self.assertEqual((0x76543210,False),self.message(0x10D,0,0))
        self.assertEqual((0x76543210,False),self.message(0x10E,0,0))
        self.assertEqual((0x76543210,False),self.message(0x100,0x0D,0))
        events, overflow = self.events()
        self.assertFalse(overflow)
        rows=list(events.values())
        self.assertEqual([(0x102,0x4E2D),(0x10D,0),(0x10E,0),(0x100,0x0D)],
                         [(row['message'],row['wparam']) for row in rows])
        self.assertEqual([(100,0x10D,0,0),(100,0x10E,0,0),(100,0x100,0x0D,0)],
                         [(x[0],x[1],x[2],x[3]) for x in self.defaulted])
        self.assertTrue(self.call_rsp_mods)
        self.assertTrue(all(mod == 8 for mod in self.call_rsp_mods))

    def test_unichar_probe_returns_true_without_adding_a_ring_record(self):
        self.set_active()
        self.assertEqual((1,False),self.message(0x109,0xFFFF,0))
        events, overflow = self.events()
        self.assertEqual(([],False),(list(events.values()),overflow))

    def test_ring_wraps_and_overflow_discards_batch_then_recovers(self):
        self.set_active()
        for _ in range(3):
            for i in range(50): self.message(0x102,65+i,0)
            events, overflow = self.events()
            self.assertFalse(overflow)
            self.assertEqual(50,len(events))
        for i in range(64): self.message(0x102,65+i,0)
        events, overflow = self.events()
        self.assertEqual(([],True),(list(events.values()),overflow))
        self.message(0x102,ord('z'),0)
        events, overflow = self.events()
        self.assertFalse(overflow)
        self.assertEqual([ord('z')],[event['wparam'] for event in events.values()])

    def test_candidate_enter_is_queued_and_routed_to_defwindowproc_not_game(self):
        self.set_active()
        self.assertEqual((0x76543210,False),self.message(0x100,0x0D,0))
        self.assertEqual((0,False),self.message(0x102,0x0D,0))
        self.assertEqual(1,len(self.defaulted))
        events, overflow=self.events()
        self.assertEqual([0x100,0x102],[e['message'] for e in events.values()])

    def test_unrelated_wm_app_message_with_same_id_is_forwarded(self):
        self.assertEqual((0x12345678,True),self.message(0x84A2,1,0xDEADBEEF))

    def test_default_context_is_associated_and_exact_previous_himc_restored(self):
        self.imm_current, self.default_context = 0x555, 0x666
        self.assertEqual((0,False),self.control(True))
        self.assertEqual(1,int.from_bytes(self.uc.mem_read(self.state+128,4),'little'))
        self.assertEqual(1,int.from_bytes(self.uc.mem_read(self.state+144,4),'little'))
        self.assertEqual(0x666,self.imm_current)
        self.assertEqual((0,False),self.control(False))
        self.assertEqual(0x555,self.imm_current)
        self.assertEqual(0,int.from_bytes(self.uc.mem_read(self.state+128,4),'little'))
        self.assertEqual(1,len([call for call in self.imm_calls if call[0]==32]))

    def test_missing_default_uses_owned_context_and_destroys_only_after_restore(self):
        self.imm_current, self.default_context = 0x555, 0
        self.assertEqual((0,False),self.control(True))
        self.assertEqual(0x777,self.imm_current)
        self.assertEqual(2,int.from_bytes(self.uc.mem_read(self.state+148,4),'little'))
        self.assertEqual((0,False),self.control(False))
        self.assertEqual(0x555,self.imm_current)
        self.assertEqual([0x777],[call[1][0] for call in self.imm_calls if call[0]==80])

    def test_failed_default_and_create_paths_do_not_claim_ime_ready(self):
        self.assoc_ex_result, self.create_result = 0, 0
        self.assertEqual((0,False),self.control(True))
        self.assertEqual(1,int.from_bytes(self.uc.mem_read(self.state+128,4),'little'))
        self.assertEqual(0,int.from_bytes(self.uc.mem_read(self.state+144,4),'little'))
        self.assertEqual(0x555,self.imm_current)
        self.assertEqual([], [call for call in self.imm_calls if call[0]==80])

    def test_bad_owned_context_is_released_restored_and_destroyed(self):
        self.imm_current, self.assoc_ex_result = 0x555, 0
        self.override_after_associate = (2,0x888)
        self.assertEqual((0,False),self.control(True))
        self.assertEqual(0x555,self.imm_current)
        self.assertTrue(any(offset == 16 and args[:2] == (100,0x888)
                            for offset,args in self.imm_calls))
        self.assertTrue(any(offset == 48 and args[:2] == (100,0x555)
                            for offset,args in self.imm_calls))
        self.assertIn(0x777,[args[0] for offset,args in self.imm_calls if offset == 80])
        self.assertEqual(0,int.from_bytes(self.uc.mem_read(self.state+148,4),'little'))

    def test_failed_restore_keeps_owned_himc_tracked_until_a_later_retry(self):
        self.assoc_ex_result = 0
        self.control(True)
        self.assertEqual(0x777,self.imm_current)
        self.fail_restore = True
        self.control(False)
        self.assertEqual(0,int.from_bytes(self.uc.mem_read(self.state+128,4),'little'))
        self.assertEqual(2,int.from_bytes(self.uc.mem_read(self.state+148,4),'little'))
        self.assertEqual(0x555,int.from_bytes(self.uc.mem_read(self.state+152,8),'little'))
        self.assertEqual(0x777,int.from_bytes(self.uc.mem_read(self.state+160,8),'little'))
        self.assertEqual([], [call for call in self.imm_calls if call[0]==80])
        self.h.block_set(1,bytes(self.uc.mem_read(self.state,4096)).hex())
        self.assertTrue(self.panel.status()['ime_restore_pending'])
        self.control(True)
        self.assertEqual(0x555,int.from_bytes(self.uc.mem_read(self.state+152,8),'little'))
        self.assertEqual(0x777,int.from_bytes(self.uc.mem_read(self.state+160,8),'little'))
        self.fail_restore = False
        self.control(False)
        self.assertEqual(0x555,self.imm_current)
        self.assertEqual(0,int.from_bytes(self.uc.mem_read(self.state+148,4),'little'))
        self.assertEqual([0x777],[call[1][0] for call in self.imm_calls if call[0]==80])
        self.assertTrue(all(mod == 8 for mod in self.call_rsp_mods))

    def test_duplicate_enable_does_not_replace_saved_himc_or_create_a_second_context(self):
        self.imm_current, self.default_context = 0x555, 0x666
        self.control(True)
        self.control(True)
        self.assertEqual(1,len([call for call in self.imm_calls if call[0]==32]))
        self.assertEqual(0x555,int.from_bytes(self.uc.mem_read(self.state+152,8),'little'))

    def test_closing_filter_forwards_new_keys_clicks_and_signed_wheel(self):
        self.assertEqual((0,False),self.message(0x201))
        self.assertEqual((0,False),self.message(0x202))
        self.assertEqual((0,False),self.message(0x20a,(0xff88<<16)))
        self.assertEqual(-120,int.from_bytes(self.uc.mem_read(self.state+4,4),'little',signed=True))
        self.uc.mem_write(self.state,(0).to_bytes(4,'little'))
        for msg,wp in ((0x100,0x1b),(0x201,0),(0x20a,120<<16)):
            self.assertEqual((0x12345678,True),self.message(msg,wp))

    def test_release_of_mouse_button_seen_before_open_reaches_game_once(self):
        self.uc.mem_write(self.state+32,(1).to_bytes(4,'little'))
        self.assertEqual((0x12345678,True),self.message(0x202))
        self.assertEqual((0,False),self.message(0x202))


if __name__ == '__main__':
    unittest.main()
