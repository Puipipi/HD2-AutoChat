-- Source fragment: inline in auto_chat.lua; no separate runtime require.
-- Armory Forge's x64 window procedure runs entirely in native code. Its pages
-- deliberately live until process exit: another mod may still chain through one.
local function build_panel_input(ffi, user, kernel, note)
    note = note or function() end
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
        'void *GetCurrentProcess(void);',
        'intptr_t GetWindowLongPtrW(void *window, int index);',
        'intptr_t SetWindowLongPtrW(void *window, int index, intptr_t value);',
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
    function input.filter_install(window)
        if window == nil then return nil, 'no game window' end
        local current = user.GetWindowLongPtrW(window, -4)              -- GWLP_WNDPROC
        for _, f in ipairs(filters) do
            if f.window == window and current == f.entry then return f end
        end
        local call = kernel.GetProcAddress(kernel.GetModuleHandleA('user32.dll'), 'CallWindowProcW')
        local block = kernel.VirtualAlloc(nil, 4096, 0x3000, 0x40)      -- commit + reserve, read / write / execute
        if call == nil or block == nil or current == 0 then return nil, 'no memory for it' end
        local b, q, u = ffi.cast('uint8_t *', block), ffi.cast('uint64_t *', block), ffi.cast('uint32_t *', block)
        q[2], q[3] = ffi.cast('uint64_t', current), ffi.cast('uint64_t', ffi.cast('uintptr_t', call))
        for k, v in ipairs(FILTER_TABLE) do b[47 + k] = v end
        local held = 0                                                  -- buttons down now: the game saw them pressed
        for n, vk in ipairs({ 0x01, 0x02, 0x04, 0x05 }) do
            if user.GetAsyncKeyState(vk) < 0 or (vk == 0x05 and user.GetAsyncKeyState(0x06) < 0) then held = held + 2 ^ (n - 1) end
        end
        u[8] = held
        b[64], b[65] = 0x49, 0xBA                                       -- mov r10, <block>
        ffi.cast('uint64_t *', b + 66)[0] = ffi.cast('uint64_t', ffi.cast('uintptr_t', block))
        for k, v in ipairs(FILTER_CODE) do b[73 + k] = v end
        kernel.FlushInstructionCache(kernel.GetCurrentProcess(), b + 64, 10 + #FILTER_CODE)
        local entry = ffi.cast('intptr_t', b + 64)
        local previous = user.SetWindowLongPtrW(window, -4, entry)
        if previous == 0 then return nil, 'Windows refused it' end
        if previous ~= current then q[2] = ffi.cast('uint64_t', previous) end
        local f = { window = window, entry = entry, u = u }
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
    function self.status() return G end
    return self
end
