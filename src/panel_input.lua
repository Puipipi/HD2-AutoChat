-- Source fragment: inline in auto_chat.lua; no separate runtime require.
-- Armory Forge's x64 window procedure runs entirely in native code. Its pages
-- deliberately live until process exit: another mod may still chain through one.
local function build_panel_input(ffi, user, kernel, note)
    note = note or function() end
    local EVENT_CAPACITY, EVENT_BASE, CONTROL_MESSAGE = 64, 256, 0x84A2
    local BRIDGE_HEX = [[
4883EC7848894C242048895424284C894424304C894C24384C8954244048C74424480000000081FAA284000075104C39
5424380F8500070000E95502000081FA820000000F843E0200004183BA80000000000F84E106000081FA020100000F84
8500000081FA09010000747D81FA000100000F84F900000081FA010100000F84ED00000081FA040100000F84E1000000
81FA050100000F84D500000081FA0D0100000F845701000081FA0E0100000F844B01000081FA0D0100000F8279060000
81FA0F0100000F869701000081FA810200000F826106000081FA910200000F867F010000E950060000817C2428090100
00750B48817C2430FFFF000074694C8B5424404183BA84000000007553418B82880000008D480183E13F413B8A8C0000
0074324C8D1C4049C1E3034F8D9C1A000100008B542428418913488B54243049895308488B5424384989531041898A88
000000EB0B41C782840000000100000031C0E9E0050000B801000000E9D60500004C8B5424404183BA84000000007553
418B82880000008D480183E13F413B8A8C00000074324C8D1C4049C1E3034F8D9C1A000100008B542428418913488B54
243049895308488B5424384989531041898A88000000EB0B41C78284000000010000008B54242881FA00010000740C81
FA040100000F854E050000488B44243083F80D746E83F81B7469E93A0500004C8B5424404183BA84000000007553418B
82880000008D480183E13F413B8A8C00000074324C8D1C4049C1E3034F8D9C1A000100008B542428418913488B542430
49895308488B5424384989531041898A88000000EB0B41C7828400000001000000EB00488B4C2420488B5424284C8B44
24304C8B4C24384C8B54244041FF92A8000000E9BF04000048C744244801000000EB0A48837C2430007402EB154C8B54
244041C7828000000000000000E93C0300004C8B5424404183BA80000000000F85E90000004183BA94000000000F85DB
00000041C782800000000000000041C782900000000000000041C782940000000000000049C782980000000000000049
C782A000000000000000488B4C242041FF92B00000004C8B542440498982980000004885C0740F488B4C24204889C241
FF92B80000004C8B542440488B4C242031D241B81000000041FF92C000000085C00F84F60000004C8B54244041C78294
00000001000000488B4C242041FF92B00000004885C0743D4C8B542440488B4C24204889C241FF92B80000004C8B5424
4041C782900000000100000041C782800000000100000031C0E99903000031C0E9920300004C8B542440488B4C242049
8B929800000041FF92C800000048894424584C8B542440488B4C242041FF92B00000004C8B542440493B829800000075
264885C0740F488B4C24204889C241FF92B80000004C8B54244041C7829400000000000000EB364885C0740F488B4C24
204889C241FF92B80000004C8B54244041C782800000000000000041C782900000000000000031C0E9FA0200004C8B54
2440488B4C242041FF92D00000004885C00F84650100004C8B542440498982A000000041C7829400000002000000488B
4C24204889C241FF92C80000004C8B542440488B4C242041FF92B00000004C8B542440493B82A00000007531488B4C24
204889C241FF92B80000004C8B54244041C782900000000100000041C782800000000100000031C0E96A0200004885C0
740F488B4C24204889C241FF92B80000004C8B542440488B4C2420498B929800000041FF92C800000048894424584C8B
542440488B4C242041FF92B00000004C8B542440493B829800000074164885C0743A488B4C24204889C241FF92B80000
00EB294885C07411488B4C24204889C241FF92B8000000EB354C8B542440488B442458493B82A000000074224C8B5424
4041C782800000000000000041C782900000000000000031C0E9B90100004C8B542440498B8AA00000004885C9742D41
FF92D80000004C8B54244049C782A00000000000000049C782980000000000000041C78294000000000000004C8B5424
4041C782900000000000000041C782800000000100000031C0E9590100004C8B542440418B829400000085C00F84EF00
0000488B4C2420498B929800000041FF92C80000004C8B54244048894424584183BA9400000002751A4983BA98000000
007522488B442458493B82A0000000757EEB124983BA9800000000750848837C245800746A488B4C242041FF92B00000
004C8B542440493B829800000075164885C07427488B4C24204889C241FF92B8000000EB164885C07435488B4C242048
89C241FF92B8000000EB244C8B5424404183BA94000000027547498B8AA00000004885C9743B41FF92D8000000EB324C
8B54244041C782800000000000000041C782900000000000000048837C244800750431C0EB6148C744244800000000EB
484C8B54244041C782940000000000000041C782900000000000000049C782980000000000000049C782A00000000000
000048837C244800750431C0EB1948C744244800000000EB004C8B5424404883C478E9B9F7FFFF4883C478C3
]]  local BRIDGE_CODE = {}
    local bridge_hex = BRIDGE_HEX:gsub('%s+', '')
    for i = 1, #bridge_hex, 2 do BRIDGE_CODE[#BRIDGE_CODE + 1] = tonumber(bridge_hex:sub(i, i + 1), 16) end
    local FILTER_TABLE = { 0x10, 0x20, 0x10, 0x11, 0x21, 0x11, 0x12, 0x22, 0x12, 0x00, 0x13, 0x23, 0x13 }
    local FILTER_CODE = {
        0x8D, 0x82, 0xFF, 0xFD, 0xFF, 0xFF, 0x83, 0xF8, 0x0C, 0x77, 0x54, 0x45, 0x0F, 0xB6, 0x5C, 0x02,
        0x30, 0x45, 0x85, 0xDB, 0x74, 0x2A, 0x44, 0x89, 0xD8, 0x41, 0x83, 0xE3, 0x0F, 0xC1, 0xE8, 0x04,
        0x83, 0xF8, 0x02, 0x74, 0x0D, 0x41, 0x83, 0x3A, 0x00, 0x75, 0x0E, 0x45, 0x0F, 0xAB, 0x5A, 0x20,
        0xEB, 0x5C, 0x45, 0x0F, 0xB3, 0x5A, 0x20, 0x72, 0x55, 0x41, 0xFF, 0x42, 0x0C, 0x31, 0xC0, 0xC3,
        0x81, 0xFA, 0x0A, 0x02, 0x00, 0x00, 0x75, 0x46, 0x41, 0x83, 0x3A, 0x00, 0x74, 0x40, 0x4C, 0x89,
        0xC0, 0x48, 0xC1, 0xE8, 0x10, 0x0F, 0xBF, 0xC0, 0x41, 0x01, 0x42, 0x04, 0x31, 0xC0, 0xC3, 0x41,
        0x83, 0x3A, 0x00, 0x74, 0x29, 0x81, 0xFA, 0x00, 0x01, 0x00, 0x00, 0x74, 0x1A, 0x81, 0xFA, 0x02,
        0x01, 0x00, 0x00, 0x74, 0x12, 0x81, 0xFA, 0x03, 0x01, 0x00, 0x00, 0x74, 0x0A, 0x81, 0xFA, 0x09,
        0x01, 0x00, 0x00, 0x74, 0x02, 0xEB, 0x07, 0x41, 0xFF, 0x42, 0x08, 0x31, 0xC0, 0xC3, 0x48, 0x83,
        0xEC, 0x38, 0x4C, 0x89, 0x4C, 0x24, 0x20, 0x4D, 0x89, 0xC1, 0x41, 0x89, 0xD0, 0x48, 0x89, 0xCA,
        0x49, 0x8B, 0x4A, 0x10, 0x41, 0xFF, 0x52, 0x18, 0x48, 0x83, 0xC4, 0x38, 0xC3,
    }
    local declarations = {
        'uint32_t GetWindowThreadProcessId(void*,void*);',
        'int16_t GetAsyncKeyState(int key);',
        'uint32_t GetCurrentThreadId(void);',
        'uint32_t GetRegisteredRawInputDevices(void *devices, uint32_t *count, uint32_t size);',
        'int RegisterRawInputDevices(const void *devices, uint32_t count, uint32_t size);',
        'void *GetModuleHandleA(const char *name);',
        'void *GetProcAddress(void *module, const char *name);',
        'void *VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect);',
        'int FlushInstructionCache(void *process, const void *address, size_t size);',
        'int VirtualProtect(void *address, size_t size, uint32_t protect, uint32_t *old_protect);',
        'int VirtualFree(void *address, size_t size, uint32_t type);',
        'void *LoadLibraryA(const char *name);',
        'void *GetCurrentProcess(void);',
        'intptr_t GetWindowLongPtrW(void *window, int index);',
        'intptr_t SetWindowLongPtrW(void *window, int index, intptr_t value);',
        'int PostMessageW(void *window, uint32_t message, uintptr_t wparam, intptr_t lparam);',
    }
    for _, declaration in ipairs(declarations) do
        local name = declaration:match('([A-Za-z_][%w_]*)%s*%(')
        local exists, value = pcall(function() return ffi.C[name] end)
        if not exists or (type(value) ~= 'cdata' and type(value) ~= 'function') then
            pcall(ffi.cdef, declaration)
        end
    end
    if not pcall(ffi.sizeof, 'AUTOCHAT_RAWDEV') then
        pcall(ffi.cdef, 'typedef struct { uint16_t page; uint16_t usage; uint32_t flags; void *target; } AUTOCHAT_RAWDEV;')
    end
    local raw_ok, RAWDEV = pcall(ffi.sizeof, 'AUTOCHAT_RAWDEV')
    local self, input = {}, {}
    local G = { state = 'not yet', saved = nil, next_check = 0 }
    local imm32_module
    if not raw_ok or not user or not kernel then
        G.state, G.broken = 'input APIs unavailable', true
    end
    function input.raw_list()
        local count = ffi.new('uint32_t[1]', 0)
        local queried = user.GetRegisteredRawInputDevices(nil, count, RAWDEV)
        if queried == 0xFFFFFFFF then error('could not enumerate raw input') end
        local out = {}
        if count[0] == 0 then return out end
        count[0] = count[0] + 4
        local list = ffi.new('AUTOCHAT_RAWDEV[?]', count[0])
        -- Match Armory's void* casts when another mod owns the first declaration.
        local got = user.GetRegisteredRawInputDevices(ffi.cast('void *', list), count, RAWDEV)
        if got == 0xFFFFFFFF then error('could not enumerate raw input') end
        for i = 0, got - 1 do
            out[#out + 1] = { page = list[i].page, usage = list[i].usage, flags = list[i].flags, target = list[i].target }
        end
        return out
    end
    function input.raw_register(devices)
        local d = ffi.new('AUTOCHAT_RAWDEV[?]', #devices)
        for i, v in ipairs(devices) do
            d[i - 1].page, d[i - 1].usage, d[i - 1].flags, d[i - 1].target = v.page, v.usage, v.flags, v.target
        end
        return user.RegisterRawInputDevices(ffi.cast('void *', d), #devices, RAWDEV) ~= 0
    end
    function input.raw_ours(dev)
        if dev.target == nil then return true end
        return user.GetWindowThreadProcessId(dev.target, nil) == kernel.GetCurrentThreadId()
    end
    -- the window filter (tools/window_filter.py): one per install, never removed (another
    -- mod may have chained its own procedure after it); all share the flag
    local filters = {}
    local function null_pointer(value)
        if value == nil then return true end
        local ok, address = pcall(function() return ffi.cast('uintptr_t', value) end)
        return not ok or address == 0
    end
    function input.filter_install(window)
        if window == nil then return nil, 'no game window' end
        for _, f in ipairs(filters) do
            if f.window == window then return f end
        end
        local current = user.GetWindowLongPtrW(window, -4)              -- GWLP_WNDPROC
        local user32 = kernel.GetModuleHandleA('user32.dll')
        local call = kernel.GetProcAddress(user32, 'CallWindowProcW')
        local defproc = kernel.GetProcAddress(user32, 'DefWindowProcW')
        -- Keep imm32 loaded while the permanent native thunk can call it.
        local imm32 = imm32_module
        if null_pointer(imm32) then
            imm32 = kernel.LoadLibraryA('imm32.dll')
            if not null_pointer(imm32) then imm32_module = imm32 end
        end
        local imm = {}
        if not null_pointer(imm32) then
            for i, name in ipairs({ 'ImmGetContext', 'ImmReleaseContext', 'ImmAssociateContextEx',
                                    'ImmAssociateContext', 'ImmCreateContext', 'ImmDestroyContext' }) do
                imm[i] = kernel.GetProcAddress(imm32, name)
            end
        end
        if current == 0 or null_pointer(call) or null_pointer(defproc) or null_pointer(imm32) then
            return nil, 'window or IME APIs unavailable'
        end
        for i = 1, 6 do
            if null_pointer(imm[i]) then return nil, 'IME APIs unavailable' end
        end
        local block = kernel.VirtualAlloc(nil, 4096, 0x3000, 0x04)    -- RW state and event ring
        local code = kernel.VirtualAlloc(nil, 4096, 0x3000, 0x04)     -- filled RW, then RX
        local function discard()
            if code ~= nil then kernel.VirtualFree(code, 0, 0x8000) end
            if block ~= nil then kernel.VirtualFree(block, 0, 0x8000) end
        end
        if block == nil or code == nil then discard(); return nil, 'no memory for it' end
        local b, q, u = ffi.cast('uint8_t *', block), ffi.cast('uint64_t *', block), ffi.cast('uint32_t *', block)
        local c = ffi.cast('uint8_t *', code)
        q[2], q[3] = ffi.cast('uint64_t', current), ffi.cast('uint64_t', ffi.cast('uintptr_t', call))
        q[21], q[22], q[23], q[24], q[25], q[26] =
            ffi.cast('uint64_t', ffi.cast('uintptr_t', defproc)),
            ffi.cast('uint64_t', ffi.cast('uintptr_t', imm[1])), ffi.cast('uint64_t', ffi.cast('uintptr_t', imm[2])),
            ffi.cast('uint64_t', ffi.cast('uintptr_t', imm[3])), ffi.cast('uint64_t', ffi.cast('uintptr_t', imm[4])),
            ffi.cast('uint64_t', ffi.cast('uintptr_t', imm[5]))
        q[27] = ffi.cast('uint64_t', ffi.cast('uintptr_t', imm[6]))
        for k, v in ipairs(FILTER_TABLE) do b[47 + k] = v end
        local held = 0                                                  -- buttons down now: the game saw them pressed
        for n, vk in ipairs({ 0x01, 0x02, 0x04, 0x05 }) do
            if user.GetAsyncKeyState(vk) < 0 or (vk == 0x05 and user.GetAsyncKeyState(0x06) < 0) then held = held + 2 ^ (n - 1) end
        end
        u[8] = held
        -- Entry loads the RW state pointer, then enters the IME router.
        c[64], c[65] = 0x49, 0xBA
        ffi.cast('uint64_t *', c + 66)[0] = ffi.cast('uint64_t', ffi.cast('uintptr_t', block))
        c[74] = 0xE9
        ffi.cast('int32_t *', c + 75)[0] = 512 - 79
        for k, v in ipairs(FILTER_CODE) do c[255 + k] = v end
        for k, v in ipairs(BRIDGE_CODE) do c[511 + k] = v end
        if kernel.FlushInstructionCache(kernel.GetCurrentProcess(), c, 4096) == 0 then
            discard(); return nil, 'could not flush the window procedure instruction cache'
        end
        local old_protect = ffi.new('uint32_t[1]', 0)
        if kernel.VirtualProtect(code, 4096, 0x20, old_protect) == 0 then
            discard(); return nil, 'could not make the window procedure executable'
        end
        local entry = ffi.cast('intptr_t', c + 64)
        local previous = user.SetWindowLongPtrW(window, -4, entry)
        if previous == 0 then discard(); return nil, 'Windows refused it' end
        if previous ~= current then q[2] = ffi.cast('uint64_t', previous) end
        local f = { window = window, entry = entry, u = u, data = b, code = c, imm_module = imm32 }
        filters[#filters + 1] = f
        return f
    end
    function input.filter_set(on)
        for _, f in ipairs(filters) do f.u[0] = on and 1 or 0 end
    end
    -- Returning false means Windows has not accepted any restoration attempt.
    local function register(devices)
        local ok, restored = pcall(input.raw_register, devices)
        return ok and restored
    end
    function self.release()
        -- Disable every installed page, including entries below later subclasses.
        if G.window and self.editing then pcall(self.editing, false, G.window) end
        -- The owner-thread control is asynchronous; queued WM_CHAR messages may
        -- still arrive before it is handled. Preserve the SPSC ring for the editor
        -- to flush before ending a field/session, and clear only at explicit reset.
        input.filter_set(false)
        G.filtering, G.filter, G.window, G.next_check = false, nil, nil, 0
        if not G.saved then return end
        local list = {}
        for _, d in pairs(G.saved) do list[#list + 1] = d end
        table.sort(list, function(a, b) return a.usage < b.usage end)
        if register(list) then
            G.saved, G.state = nil, 'given back'
            return
        end
        local plain = {}
        for _, d in ipairs(list) do
            local f = tonumber(d.flags) or 0
            for _, m in ipairs({ 0x100, 0x1000, 0x2000 }) do
                if math.floor(f / m) % 2 == 1 then f = f - m end
            end
            plain[#plain + 1] = { page = 1, usage = d.usage, flags = f, target = nil }
        end
        local restored = register(plain)
        if not restored then
            for _, d in ipairs(plain) do d.flags = 0 end
            restored = register(plain)
        end
        -- Retain pending originals if all attempts failed so teardown can retry.
        if restored then G.saved = nil end
        G.state, G.broken = 'broken', true
        pcall(note, 'panel: could not restore raw input as it was; registered without a window (' .. tostring(restored) .. ')')
    end
    local function hold(now, window, hotkey_down)
        if window == nil then self.release(); return end
        if G.broken then self.release(); return end
        if hotkey_down then return end -- the game sees K let go first
        if G.window and G.window ~= window then
            self.release()
            if G.broken then return end
        end
        if not G.filter or G.window ~= window then
            local f, why = input.filter_install(window)
            if not f then error('no window filter: ' .. tostring(why)) end
            G.filter, G.window = f, window
        end
        if not G.filtering then input.filter_set(true); G.filtering = true end
        if now < G.next_check then return end
        G.next_check = now + 0.5
        local take, other = {}, false
        for _, d in ipairs(input.raw_list()) do
            if d.page == 1 and (d.usage == 2 or d.usage == 6) then
                if input.raw_ours(d) then take[#take + 1] = d else other = true end
            end
        end
        if other then G.other = true end
        if #take == 0 then
            if not G.saved then G.state = other and 'raw input on another thread: left alone' or 'game has no raw input' end
            return
        end
        local remove = {}
        for _, d in ipairs(take) do remove[#remove + 1] = { page = 1, usage = d.usage, flags = 0x1, target = nil } end
        if not input.raw_register(remove) then error('could not take raw input') end
        G.saved = G.saved or {}
        for _, d in ipairs(take) do G.saved[d.usage] = d end
        G.takes = (G.takes or 0) + 1
        G.state = 'held'
    end
    function self.hold(now, window, hotkey_down)
        local ok, why = pcall(hold, now, window, hotkey_down)
        if not ok then
            G.state, G.broken, G.error = 'broken', true, tostring(why)
            self.release()
            pcall(note, 'panel input blocking disabled: ' .. tostring(why))
        end
    end
    local function event_filter()
        for i = #filters, 1, -1 do
            if not G.window or filters[i].window == G.window then return filters[i] end
        end
        return filters[#filters]
    end
    function self.editing(enabled, window)
        local f
        for _, candidate in ipairs(filters) do
            if candidate.window == window then f = candidate; break end
        end
        if not f or not user.PostMessageW then return false, 'window hook unavailable' end
        local requested = enabled and true or false
        local u = ffi.cast('uint32_t *', f.data)
        if f.ime_requested == requested and (requested or (u[32] == 0 and u[37] == 0)) then
            return true
        end
        local ok, posted = pcall(user.PostMessageW, window, CONTROL_MESSAGE, enabled and 1 or 0,
                                 ffi.cast('intptr_t', ffi.cast('uintptr_t', f.data)))
        if not ok or not posted or posted == 0 then
            return false, 'could not queue IME state on the game window thread'
        end
        f.ime_requested = requested
        return true
    end
    function self.clear()
        for _, f in ipairs(filters) do
            local u = ffi.cast('uint32_t *', f.data)
            u[35] = u[34]
            u[33] = 0
            f.overflow = false
        end
    end
    function self.drain()
        local f = event_filter()
        if not f then return {}, false end
        local u = ffi.cast('uint32_t *', f.data)
        if u[33] ~= 0 then
            u[35], u[33] = u[34], 0
            f.overflow = true
            return {}, true
        end
        f.overflow = false
        local out, tail, head = {}, tonumber(u[35]), tonumber(u[34])
        while tail ~= head do
            local index = tail % EVENT_CAPACITY
            local record = ffi.cast('uint8_t *', f.data) + EVENT_BASE + index * 24
            out[#out + 1] = {
                message = tonumber(ffi.cast('uint32_t *', record)[0]),
                wparam = tonumber(ffi.cast('uint64_t *', record + 8)[0]),
                lparam = tonumber(ffi.cast('uint64_t *', record + 16)[0]),
            }
            tail = (tail + 1) % EVENT_CAPACITY
        end
        u[35] = head
        if u[33] ~= 0 then
            u[35], u[33] = u[34], 0
            f.overflow = true
            return {}, true
        end
        return out, false
    end
    function self.status()
        local state = {}
        for key, value in pairs(G) do state[key] = value end
        local f = event_filter()
        if f then
            local u = ffi.cast('uint32_t *', f.data)
            state.editing = u[32] ~= 0
            state.ime_ready = u[36] ~= 0
            state.ime_pending = (f.ime_requested or false) ~= (u[32] ~= 0)
            state.ime_restore_pending = u[37] ~= 0 and u[32] == 0
            state.event_overflow = f.overflow or u[33] ~= 0
        else
            state.editing, state.ime_ready, state.ime_pending, state.ime_restore_pending, state.event_overflow =
                false, false, false, false, false
        end
        return state
    end
    return self
end
