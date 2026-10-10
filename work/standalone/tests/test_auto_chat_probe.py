# -*- coding: utf-8 -*-
"""Offline engine-boundary tests for the AutoChat read-only probe.

The point of these tests is NOT "it runs without an error". It is to pin the
things that actually cost time in this mod family:

  * a signature mismatch must cost ZERO further memory reads, and must never
    let a recorded offset reach the FFI layer;
  * an address that is not a plausible x64 user-mode pointer must be refused
    before ffi.cast, not after (ffi.cast raises on a bad double);
  * an uncommitted / guard page must be refused;
  * a static frame must NOT produce a log line every frame, and must produce
    the frame count it actually saw;
  * `update` must always call the previous `update` and pass its returns
    through, or every mod later in the chain loses its frame.

Run:  python -B tests/test_auto_chat_probe.py
"""
import io
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest

try:
    import lupa.luajit21 as luajit
except ImportError:  # pragma: no cover
    sys.exit("lupa is required: python -m pip install lupa")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import gates  # noqa: E402  (needs the path setup above)

HERE = os.path.dirname(os.path.abspath(__file__))
def _walk_up(relative):
    current = HERE
    while True:
        candidate = os.path.join(current, relative)
        if os.path.exists(candidate):
            return candidate
        parent = os.path.dirname(current)
        if parent == current:
            raise AssertionError("cannot locate %s above %s" % (relative, HERE))
        current = parent


SOURCE = _walk_up(os.path.join("src", "auto_chat.lua"))

# Where Super Earth Armory Forge's source might be on this machine. This repo does
# NOT redistribute it, so the reference-comparison test skips when it is absent --
# a skip with a reason, never a silent pass.
# tests -> standalone -> work -> auto-chat -> mods -> workspace root
_WORKSPACE = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(HERE)))))
REFERENCE_SOURCE_CANDIDATES = [
    os.path.join(_WORKSPACE, "outputs", "validated-2026-10-04", "hud-compatibility",
                 "sources", "installed-Super-Earth-Armory-Forge-v6.2.1-0-0.lua"),
    os.path.join(_WORKSPACE, "outputs", "validated-2026-10-05", "crash-165213-no-smooth",
                 "source-audit", "sources",
                 "mods__patpatpatrick__mod_lag_finder.lua"),
]

# ---------------------------------------------------------------- fake engine
# A tiny flat memory model. Every read the mod performs goes through it, so the
# read counter is a real measurement of what the mod touched.
HARNESS = r'''
local harness = {}
harness.reads = 0
harness.log = {}
-- Declared at chunk scope: `harness.log_text()` below reads it, and a `local`
-- declared inside install() would not be in that function's scope at all.
local written = {}
local virtual_files = {}

-- mem[address] = byte. Dense enough for the few hundred bytes under test.
local mem = {}
harness.mem = mem
local pages = {}          -- address -> {state=, protect=, region=}
local cache = {}          -- address:size -> captured byte string

-- Captured once, at chunk scope. Capturing it inside install() would capture the
-- PREVIOUS test's stub on the second call and recurse forever.
local REAL_OPEN = io.open

-- A pointer stand-in that behaves like a cdata pointer, not like a Lua table.
-- This matters: `tonumber(ffi.cast('uintptr_t', handle))` returns nil when handle
-- is a plain Lua table in real LuaJIT, so a permissive mock would hide the very
-- bug this harness exists to catch.
local cptr = {}
cptr.__index = cptr
cptr.__tostring = function(self) return 'cdata<void *>: ' .. tostring(self.value) end
local function ptr(value)
    -- Marked with a plain field as well as a metatable. Metatable identity checks
    -- turned out to be a poor discriminator here (a value that failed the check
    -- reached Python as a table and was coerced to a boolean), so unwrap keys off
    -- this field, which cannot fail silently.
    return setmetatable({value = value, __cptr = true}, cptr)
end
harness.ptr = ptr

-- uint8_t[?] and size_t[1] stand-ins for ffi.new. Indexed reads must yield
-- NUMBERS, exactly as real cdata does: a mock that handed back one-character
-- strings would let arithmetic bugs through and then fail far from the cause.
local Bytes = {}
Bytes.__index = function(self, key)
    if type(key) == 'number' then
        local ch = self.chars[key]
        if type(ch) == 'string' then return ch:byte() end
        if type(ch) == 'number' then return ch end
        return 0
    end
    return rawget(Bytes, key)
end
function Bytes:__newindex(key, value)
    if type(key) == 'number' and type(value) == 'number' then
        value = string.char(value % 256)
    end
    self.chars[key] = value
end
function Bytes:__tostring() return self.text end

local function new_buffer(ctype, arg)
    if ctype == 'uint64_t[1]' then
        return setmetatable({text=''}, {__index=function(self,key)
            if key == 0 then
                local out={};for i=8,1,-1 do out[#out+1]=string.format('%02X',self.text:byte(i) or 0) end
                return table.concat(out)
            end
        end})
    end
    if ctype == 'uint8_t[?]' then
        return setmetatable({n = arg, chars = {}, text = ''}, Bytes)
    end
    if ctype == 'size_t[1]' then
        return setmetatable({0, n = 1}, {__index = function() return 0 end})
    end
    if ctype == 'int64_t[1]' then return {[0] = 0, n = 1} end
    -- Small integer arrays the input path needs: GetClipCursor writes 4 ints into
    -- one and ClipCursor reads 4 back; GetCursorPos/GetClientRect fill int32 pairs,
    -- and GetWindowThreadProcessId writes a uint32 pid. A PLAIN table, on purpose:
    -- real cdata stores writes where a later read finds them, and a metatable-backed
    -- buffer does not (the metatable intercepts __newindex), which would make every
    -- external inspection of the buffer report zeros.
    --
    -- Missing an element type here does not fail loudly: the mod's own pcall around
    -- the frame turns it into a silent early return, and the panel simply never
    -- appears. That is exactly how the mouse path went untested.
    local count = ctype:match('^u?int32_t%[(%d+)%]$')
    if count then
        count = tonumber(count)
        local buf = {n = count}
        for i = 0, count - 1 do buf[i] = 0 end
        return buf
    end
    error('unexpected alloc: ' .. tostring(ctype))
end

function harness.write_buffer(buf, address, size)
    local chars = {}
    for i = 0, size - 1 do
        chars[i + 1] = mem[address + i] or 0
    end
    buf.chars = chars
    buf.text = string.char(unpack(chars))
    return buf.text
end

function harness.region(base, size, state, protect)
    pages[base] = {state = state or 0x1000, protect = protect or 0x04, region = size}
end

function harness.bytes(address, str)
    cache = {} -- a later ReadProcessMemory must see changes made by the game
    for i = 1, #str do mem[address + i - 1] = str:sub(i, i) end
end
function harness.mem_hex(address, size)
    local out = {}
    for i=0,size-1 do out[#out+1] = string.format('%02X', (mem[address+i] or '\0'):byte()) end
    return table.concat(out)
end

-- Little-endian writers used to lay out the synthetic game state.
local function le_bytes(value, size)
    local out = {}
    for i = 1, size do
        out[i] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return out
end

function harness.u32(address, value)
    cache = {}
    local bytes = le_bytes(value, 4)
    for i = 1, 4 do mem[address + i - 1] = bytes[i] end
end

function harness.u8(address, value)
    cache = {}
    mem[address] = string.char(value % 256)
end

function harness.u64(address, value)
    cache = {}
    -- Byte-by-byte division, NOT (value - lo) / 2^32. The subtraction form loses
    -- precision and, worse, writing a 4-byte value into an 8-byte slot silently
    -- leaves the upper half zero while the lower half holds a small number -- which
    -- made a synthetic "context pointer" read as a peer count.
    local bytes = le_bytes(value, 8)
    for i = 1, 8 do mem[address + i - 1] = bytes[i] end
end

local function n(address)
    local function byte(at) return (mem[at] or '\0'):byte() end
    return byte(address) + byte(address + 1) * 256
         + byte(address + 2) * 65536 + byte(address + 3) * 16777216
end

function harness.install()
    -- Declared first: cptr unwrapping is needed by ffi.cast, ReadProcessMemory and
    -- VirtualQuery alike, and a `local` declared below its reader is not in scope
    -- there (the name becomes a nil global read).
    local function unwrap(value)
        if type(value) == 'table' and value.__cptr then return value.value end
        return value
    end

    -- ---- fake ffi: only the surface the probe actually uses ----------------
    local ffi = {os = 'Windows', C = {}}
    ffi.abi = function(what) return what == '64bit' end
    ffi.NULL = 'NULL'
    ffi.cdef = function() end
    ffi.string = function(buf, size) return buf.text:sub(1, size) end
    -- Function pointers are how the mod actually calls the game's send: the
    -- verified absolute address is cast to a typed pointer and called. This mock
    -- records the address and the arguments so a test can assert BOTH, which is
    -- the only way to show the send was aimed at the verified RVA.
    harness.casts = {}
    harness.invocations = {}
    ffi.cast = function(ctype, value)        if type(ctype) == 'string' and ctype:find('%(') then
            local address = unwrap(value)
            -- Two distinct events, deliberately tracked separately:
            --   * acquiring a function pointer (a cast) -- happens once, at boot
            --   * actually calling it -- what a send does
            -- Keeping them apart is what lets a test say "the send made one call
            -- to the verified address" without counting the resolver.
            harness.casts[#harness.casts + 1] = {address = address}
            return function(a1, a2, a3)
                -- The mock's functype takes the pointer as a NUMBER. The real call
                -- site casts it to `void *` (LuaJIT refuses to pass a bare number
                -- where a pointer is expected -- that refusal is what the in-game
                -- run reported). Modelled as a number so the value survives into
                -- Python intact instead of degrading into a coerced boolean.
                local record = {
                    address = address,
                    arg1_address = a1,
                    arg2 = a2,
                    arg3_text = type(a3) == 'table' and a3.text or tostring(a3),
                }
                harness.invocations[#harness.invocations + 1] = record
                if address == harness.native_address then return harness.native_result end
                return 0
            end
        end
        if ctype == 'uintptr_t' then
            -- Real ffi.cast yields a cdata integer. Returning the bare number
            -- here would make `tonumber(...)` succeed where the game would fail.
            return unwrap(value)
        end
        if ctype == 'void *' or ctype == 'const void *' then
            local raw = unwrap(value)
            if type(raw) == 'number' then
                -- Real ffi.cast raises on a double that cannot be a pointer.
                if raw ~= math.floor(raw) or raw < 0 or raw >= 2 ^ 64 then
                    error('cannot convert to pointer: ' .. tostring(raw))
                end
            end
            return ptr(raw)
        end
        error('unexpected cast: ' .. tostring(ctype))
    end
    ffi.copy = function(destination, source)
        if type(source) == 'string' then
            destination.text = source
            destination.chars = {}
            for i = 1, #source do destination.chars[i] = source:sub(i, i) end
        end
    end
    ffi.new = new_buffer

    -- ---- fake kernel32 ----------------------------------------------------
    local kernel = {}
    function kernel.GetCurrentProcess() return 'PROCESS' end
    function kernel.GetModuleHandleA(name)
        harness.ghm_calls = (harness.ghm_calls or 0) + 1
        if name == 'game.dll' then return harness.code_base end
        if name == 'helldivers2.exe' then return harness.exe_base end
        return nil
    end
    -- A per-address byte cache. The naive version rebuilt a Lua table on every
    -- read, which made a 600-frame test take tens of seconds; this keeps the
    -- suite fast enough that nobody is tempted to skip it.
    function kernel.ReadProcessMemory(process, address, buf, size, got)
        harness.reads = harness.reads + 1
        address = unwrap(address)
        if (harness.ui_registry and address >= harness.ui_registry and address < harness.ui_registry + 0x10000)
           or (harness.chat_view and address >= harness.chat_view and address < harness.chat_view + 0x20000)
           or address == harness.code_base + 0x1437dd9
           or address == harness.code_base + 0x185f566
           or address == harness.code_base + 0x3326e68 then
            harness.ui_reads = (harness.ui_reads or 0) + 1
        end
        if harness.deny_reads_from and address >= harness.deny_reads_from then
            return 0
        end
        local key = address .. ':' .. size
        local hit = cache[key]
        if hit == nil then
            local chars = {}
            for i = 0, size - 1 do
                local byte = mem[address + i]
                if byte == nil then return 0 end
                chars[i + 1] = byte:byte()
            end
            hit = string.char(unpack(chars, 1, size))
            cache[key] = hit
        end
        buf.text = hit
        buf.chars = {}
        for i = 1, size do buf.chars[i] = hit:sub(i, i) end
        got[0] = size
        return 1
    end

    -- Real VirtualQuery returns the number of bytes written (48 on x64), and 0
    -- when the address is not in any region. The probe compares against 48, so
    -- the mock must use the same convention or it would hide a wrong comparison.
    function kernel.VirtualQuery(address, info, size)
        address = unwrap(address)
        -- Real VirtualQuery resolves the containing region for any address
        -- inside it, so the mock must do the same: the mod queries an arbitrary
        -- field address, not a region base.
        local page = nil
        for base, candidate in pairs(pages) do
            if address >= base and address < base + candidate.region then
                page = candidate
                break
            end
        end
        if not page then return 0 end
        local function put(offset, value)
            info[offset] = string.char(value % 256)
            info[offset + 1] = string.char(math.floor(value / 256) % 256)
            info[offset + 2] = string.char(math.floor(value / 65536) % 256)
            info[offset + 3] = string.char(math.floor(value / 16777216) % 256)
        end
        put(0x18, page.region)
        put(0x20, page.state)
        put(0x24, page.protect)
        return 48
    end
    function kernel.CreateDirectoryA() return 1 end
    function kernel.QueryPerformanceFrequency(out) out[0] = 1000000; return 1 end
    function kernel.QueryPerformanceCounter(out)
        out[0] = harness.qpc or 0
        return 1
    end
    function kernel.MoveFileExA(from, to)
        if type(from)=='string' and type(to)=='string' and from:find('AutoChat',1,true) then
            virtual_files[to]=virtual_files[from]
            virtual_files[from]=nil
        end
        return 1
    end
    -- The mod requires this at boot (it compares the foreground window's pid to its
    -- own before honouring the hotkey), so the mock must provide it or the mod
    -- stops at "missing kernel32 symbol".
    harness.own_pid = harness.own_pid or 4242
    harness.foreground_pid = harness.own_pid
    function kernel.GetCurrentProcessId() return harness.own_pid end
    harness.disable_qpc_frequency = function()
        kernel.QueryPerformanceFrequency = nil
        setmetatable(kernel, {__index=function(_, name)
            if name == 'QueryPerformanceFrequency' then error('undefined symbol: QueryPerformanceFrequency') end
        end})
    end
    harness.fail_qpc_counter = function() kernel.QueryPerformanceCounter = function() return 0 end end

    -- ---- fake user32 ---------------------------------------------------------
    -- Without this the mock's ffi.load ERRORS on user32, `user` ends up nil, and
    -- every panel input path silently no-ops. The tests still passed, which is
    -- exactly the danger: the riskiest new code had zero coverage while the suite
    -- reported green. This mock makes the input path reachable and observable.
    --
    -- ShowCursor is a per-thread COUNTER, so the fake must model that: it returns
    -- the counter value, and the test asserts the take/release calls cancel out.
    user32_calls = {show = 0, clip = 0, key = {}}
    harness.user32_calls = user32_calls
    local cursor_visible = false
    local cursor_show_count = 0
    local clip_rect = nil
    local held_keys = {}
    harness.user32 = {
        set_key = function(vk, down) held_keys[vk] = down and true or false end,
        set_foreground_pid = function(pid) harness.foreground_pid = pid end,
        cursor_visible = function() return cursor_visible end,
        show_count = function() return cursor_show_count end,
        clip = function() return clip_rect end,
        calls = user32_calls,
    }
    -- Set the clip rectangle the game would already have in place, so the save and
    -- restore can be tested as a round trip rather than a one-way clear.
    --
    -- The indices must be written EXPLICITLY. `clip_rect = {a, b, c, d}` from a
    -- Python tuple lands at Lua's 1-based slots, so the C-style 0..3 reads below
    -- would see nil/0 -- the same class of mistake that made the first version of
    -- this mock disagree with the real API.
    harness.user32_set_clip = function(a, b, c, d)
        if a == nil then clip_rect = nil return end
        clip_rect = {[0] = a, [1] = b, [2] = c, [3] = d, n = 4}
    end
    -- Drive the display counter directly, so a test can reproduce the state a crashed
    -- session leaves behind (cursor visible, nobody left to hide it).
    harness.user32_show = function(show)
        local n = show and 1 or 0
        cursor_show_count = cursor_show_count + (n ~= 0 and 1 or -1)
        cursor_visible = cursor_show_count >= 0
        return cursor_show_count
    end
    -- Returned as a STRING on purpose. A Lua table read from Python must be indexed
    -- 1..n, and getting that wrong is precisely what made the first version of this
    -- mock silently read zeros -- so the value is flattened to text and compared as
    -- text, where there is no indexing convention left to get wrong.
    harness.user32_clip_text = function()
        if not clip_rect then return 'none' end
        return string.format('%d,%d,%d,%d',
            clip_rect[0], clip_rect[1], clip_rect[2], clip_rect[3])
    end
    -- Cached, deliberately. Each pcall(ffi.load, 'user32') in this family produces
    -- ONE library handle whose state persists for the process; building a fresh
    -- instance per call gives every caller its own clip_rect/held_keys closure, so a
    -- test that sets state through one handle and reads it through another sees a
    -- different library. That mismatch is what made the first version of this mock
    -- report zeros while the state was set correctly.
    local user32_lib = nil
    local function new_user32()
        local lib = {}
        -- Returns the NEW display counter: negative means hidden. The mod loops
        -- until this stops being negative, then gives back exactly that many.
        --
        -- The argument arrives as a Lua boolean (the mod writes ShowCursor(true) /
        -- ShowCursor(false)), but the C prototype takes an int. Normalising has to
        -- handle BOTH: `tonumber(true)` is nil in Lua, and `false ~= 0` is true
        -- because only nil/false are falsy. Getting either wrong makes the mock
        -- model the opposite of the real API and the mod looks broken.
        local function to_int(flag)
            if flag == true then return 1 end
            if flag == false or flag == nil then return 0 end
            return tonumber(flag) or 0
        end
        function lib.ShowCursor(show)
            local n = to_int(show)
            user32_calls.show = user32_calls.show + 1
            cursor_show_count = cursor_show_count + (n ~= 0 and 1 or -1)
            cursor_visible = cursor_show_count >= 0
            return cursor_show_count
        end
        function lib.GetAsyncKeyState(vk)
            user32_calls.key[vk] = (user32_calls.key[vk] or 0) + 1
            -- High bit set == down, matching the real API's contract.
            return held_keys[vk] and -32768 or 0
        end
        -- Every pointer argument must go through unwrap(): the harness hands C
        -- pointers to mocks as wrapped objects, so writing to the wrapper instead of
        -- the buffer it points at silently loses the write and makes a later read
        -- report zeros.
        function lib.GetClipCursor(rect)
            user32_calls.clip = user32_calls.clip + 1
            if not clip_rect then return 0 end
            local buf = unwrap(rect)
            for i = 0, 3 do buf[i] = clip_rect[i] end
            return 1
        end
        function lib.ClipCursor(rect)
            user32_calls.clip = user32_calls.clip + 1
            if rect == nil then
                clip_rect = nil
            else
                local buf = unwrap(rect)
                clip_rect = {[0] = buf[0], [1] = buf[1], [2] = buf[2], [3] = buf[3]}
            end
            return 1
        end
        function lib.GetForegroundWindow() return 'WINDOW' end
        function lib.GetWindowThreadProcessId(win, out)
            -- Focused by default, so the hotkey is live unless a test says otherwise.
            unwrap(out)[0] = harness.foreground_pid or harness.own_pid or 4242
            return 1
        end
        function lib.GetCursorPos(point)
            local buf = unwrap(point)
            buf[0], buf[1] = harness.mouse_x or 0, harness.mouse_y or 0
            return 1
        end
        function lib.ScreenToClient(win, point) return 1 end
        function lib.GetClientRect(win, rect)
            local buf = unwrap(rect)
            buf[0], buf[1] = 0, 0
            buf[2], buf[3] = harness.client_w or 1920, harness.client_h or 1080
            return 1
        end
        return lib
    end
    -- One handle for the whole Lua state, like the real loader.
    local function user32_handle()
        if not user32_lib then user32_lib = new_user32() end
        return user32_lib
    end

    -- ---- fake engine (stingray) ---------------------------------------------
    -- Without this, world_ready() returns false on every frame and the whole panel
    -- lifecycle is unreachable -- the second blind spot of the same kind as the
    -- user32 one. The counters let a test assert that GUIs are created AND
    -- destroyed, which is the property that decides whether a closed panel really
    -- disappears or just stops being updated.
    harness.gui_created, harness.gui_destroyed = 0, 0
    harness.live_guis = 0
    local live_gui_ids = {}
    harness.gui_is_live = function(id) return live_gui_ids[id] == true end
    harness.main_world = 'WORLD_MAIN'
    harness.worlds_reads = 0
    _G.stingray = {
        Network = {game_session=function() return 'fixture-session' end,
            peer_id=function() return tostring(0x00112233445566) end},
        GameSession = {
            game_session_host=function() return tostring(0x00112233445566) end,
            peers=function()
                local peers={tostring(0x00112233445566)}
                for i=1,(tonumber(harness.opts.others) or 1) do peers[#peers+1]=tostring(0x00112233445566+i) end
                return peers
            end},
        Application = {
            main_world = function() return harness.main_world end,
            worlds = function()
                harness.worlds_reads = harness.worlds_reads + 1
                if harness.worlds_error then error('synthetic world list failure') end
                return harness.worlds or {harness.main_world, 'WORLD_OVERLAY'}
            end,
            -- The mod asks whether a resource is actually LOADED before using its id.
            -- Without this the font path stops at "not loaded" and the material and
            -- Gui.text steps are never exercised.
            can_get = function(kind, name) return harness.can_get ~= false end,
        },
        Gui = {
            resolution = function() return harness.res_w or 1920, harness.res_h or 1080 end,
            rect = function(gui, position, size, colour) end,
            material = function(gui, id)
                harness.material_made = (harness.material_made or 0) + 1
                return {id = id}
            end,
            text = function(gui, value, font, size, material, position, colour)
                harness.text_drawn = (harness.text_drawn or 0) + 1
                harness.last_text = value
            end,
            text_extents = function(gui, value, font, size)
                return {x = 0}, {x = #tostring(value) * size * 0.6}
            end,
        },
        Vector3 = function(x, y, z) return {x = x, y = y, z = z} end,
        Vector2 = function(x, y) return {x = x, y = y} end,
        Color = function(a, r, g, b) return {a = a, r = r, g = g, b = b} end,
        IdString64 = {from_hex = function(s)
            -- Native from_hex accepts only a 64-bit hexadecimal ID, never a path.
            -- The former identity stub hid the debug-font crash at this boundary.
            if type(s) ~= 'string' or #s ~= 16 or not s:match('^%x+$') then
                harness.invalid_hex_calls = (harness.invalid_hex_calls or 0) + 1
                error('invalid native IdString64.from_hex argument: ' .. tostring(s))
            end
            return s
        end},
        Material = {
            set_texture = function(material, texture_id, atlas_id)
                harness.texture_set = {material = material, texture = texture_id,
                                       atlas = atlas_id}
            end,
        },
        World = {
            create_screen_gui = function(world, ...)
                harness.gui_created = harness.gui_created + 1
                harness.live_guis = harness.live_guis + 1
                live_gui_ids[harness.gui_created] = true
                return {world = world, id = harness.gui_created}
            end,
            destroy_gui = function(world, gui)
                harness.gui_destroyed = harness.gui_destroyed + 1
                if gui and live_gui_ids[gui.id] then
                    live_gui_ids[gui.id] = nil
                    harness.live_guis = harness.live_guis - 1
                end
            end,
        },
        Window = {
            show_cursor = function() return false end,
            set_show_cursor = function(v) return v end,
            set_clip_cursor = function(v) return v end,
        },
    }

    ffi.load = function(name)
        if name == 'kernel32' then return kernel end
        if name == 'user32' then return user32_handle() end
        error('unexpected load: ' .. name)
    end

    -- ---- fake host environment -------------------------------------------
    written = {}
    harness.records = written
    harness.virtual_files = virtual_files
    _G.ffi = ffi
    -- LuaJIT ships a built-in `ffi` module, so `require('ffi')` (which is how the
    -- mods in this family obtain it) returns the REAL one from package.loaded and
    -- ignores the global. Without this line the mock is never used and the mod
    -- talks to the host's actual ffi -- silently, because that mostly works.
    if package and package.loaded then package.loaded['ffi'] = ffi end
    _G.CowboyBingusModLoader = {api = 1, version = 19}
    _G.os.getenv = function(name)
        if name == 'LOCALAPPDATA' then return 'C:/fake' end
        return nil
    end
    _G.os.date = function(fmt) return '2026-01-01T00:00:00Z' end
    -- Only the mod's own log/status paths are captured. Everything else (the
    -- harness's own loading of the Lua source) must fall through to the real
    -- io.open, or the fixture cannot even read its own file.
    local real_open = REAL_OPEN
    _G.io.open = function(path, mode)
        if tostring(path):find('preset%-selection%.txt') then
            if mode == nil or tostring(mode):find('r') then
                local contents=virtual_files[path]
                if contents==nil then return nil end
                return {read=function(_,count) return contents:sub(1,count or #contents) end,
                    close=function() return true end}
            end
            local contents=''
            return {write=function(self,text)
                    contents=contents..text;virtual_files[path]=contents
                    written[#written+1]={path=path,text=text};return self
                end,close=function() return true end}
        end
        if tostring(path):find('AutoChat/tasks%.txt') then
            if mode == nil or tostring(mode):find('r') then
                local contents=virtual_files[path]
                if contents==nil then return nil end
                return {read=function(_,count) return contents:sub(1,count or #contents) end,
                    close=function() return true end}
            end
            if harness.fail_next_task_write then
                harness.fail_next_task_write=false
                return nil
            end
            local contents=''
            return {write=function(self,text)
                    contents=contents..text;return self
                end,close=function()
                    if tostring(path):find('%.tmp$') then virtual_files[path]=contents end
                    return true
                end}
        end
        if mode == nil or tostring(mode):find('r') then return real_open(path, mode) end
        if tostring(path):find('AutoChat', 1, true) then
            if harness.deny_settings_write and tostring(path):find('settings%.txt%.tmp') then
                if harness.fail_task_rollback_after_settings_failure then harness.fail_next_task_write=true end
                return nil
            end
            return {
                write = function(self, text) written[#written + 1] = {path = path, text = text} return self end,
                close = function() return true end,
            }
        end
        return real_open(path, mode)
    end
    function harness.written() return written end

    -- The loader's frame callback that everything chains onto.
    harness.update_calls, harness.shutdown_calls = 0, 0
    _G.update = function(...)
        harness.update_calls = harness.update_calls + 1
        harness.qpc = (harness.qpc or 0) + 16667
        return 'prev', select('#', ...)
    end
    _G.shutdown = function(...)
        harness.shutdown_calls = harness.shutdown_calls + 1
        return 'prev-shutdown'
    end
end

function harness.log_text()
    local parts = {}
    for _, entry in ipairs(written) do
        parts[#parts + 1] = entry.text
    end
    return table.concat(parts, '')
end

-- Read the call log through Lua rather than from Python. lupa converts a Lua
-- table to a Python object once; a table appended to later would look frozen, so
-- every assertion goes through these accessors instead.
--
-- call_count / last_call refer to INVOCATIONS (the send actually happening), not
-- to the boot-time cast that acquires the function pointer.
function harness.call_count() return #harness.invocations end
function harness.last_call() return harness.invocations[#harness.invocations] end
function harness.call_at(i) return harness.invocations[i] end
function harness.cast_count() return #harness.casts end

-- Read the synthetic memory from a test, so a wrong expectation can be told apart
-- from a wrong fixture.
function harness.peek(address, size)
    local out = {}
    for i = 0, size - 1 do
        local byte = mem[address + i]
        if byte == nil then return '(unmapped at 0x' .. string.format('%X', address + i) .. ')' end
        out[i + 1] = string.format('%02X', byte:byte())
    end
    return table.concat(out, ' ')
end

-- Convenience: a synthetic, fully valid game image.
local SEND   = '\65\86\65\87\72\129\236\120\4\0\0\72\139\5\158\74\90\1\72\51\196\72\137\132\36\80\4\0\0\128\57\0'
local RPC    = '\64\83\85\86\87\65\86\65\87\72\129\236\152\0\0\0\72\139\5\201\219\165\1\72\51\196\72\137'
local BOX    = '\72\139\13\140\204\193\1\76\141\135\212\22\0\0\72\129\193\24\196\0\0'
local MSGRPC = '\65\185\1\0\0\0\72\139\215\185\142\184\221\159\232\26'
local HIST   = '\139\135\148\149\0\0\139\143\144\149\0\0'

-- Options live on the Lua side. Passing a Python dict in as the opts table looks
-- like it should work, but lupa's proxy raises KeyError for a key Lua would
-- simply read as nil, so the fixture sets them here instead.
harness.opts = {}
function harness.option(key, value) harness.opts[key] = value end
function harness.clear_options() harness.opts = {} end

function harness.build_image(opts)
    opts = opts or harness.opts
    cache = {}                    -- the memory image is about to change
    written = {}                  -- and so does the captured log
    harness.reads = 0
    harness.code_base = 0x140000000
    harness.ctx_base  = 0x200000000
    harness.region(harness.code_base, 0x2000000, 0x1000, 0x02)
    harness.region(harness.ctx_base,  0x20000,   0x1000, 0x04)

    local base = harness.code_base
    harness.bytes(base + 0x1097560, opts.break_send and (SEND:sub(1, 12) .. '\99') or SEND)
    harness.bytes(base + 0xbde430,  RPC)
    harness.bytes(base + 0x186025d, BOX)
    harness.bytes(base + 0xbeb103,  MSGRPC)
    harness.bytes(base + 0x1097a7c, HIST)
    -- Independently fingerprinted UI-only reader sites from the verified chat-view
    -- registry chain. These do not participate in M.CODE/send verification.
    harness.bytes(base + 0x1437dd9, '\72\139\45\136\240\238\1')
    harness.bytes(base + 0x185f566, '\64\136\187\184\57\1\0')
    harness.ui_registry = 0x210000000
    harness.chat_view = 0x211000000
    harness.ui_reads = 0
    harness.region(harness.ui_registry, 0x10000, 0x1000, 0x04)
    harness.region(harness.chat_view, 0x20000, 0x1000, 0x04)
    harness.u64(base + 0x3326e68, harness.ui_registry)
    harness.u32(harness.ui_registry + 0x2be8, 1)
    harness.bytes(harness.ui_registry + 0x2bf0, string.rep('\0', 16))
    harness.u64(harness.ui_registry + 0x2bf0, harness.chat_view)
    harness.u32(harness.ui_registry + 0x2bf8, 0xc3)
    harness.u8(harness.chat_view + 0x139b8, 0)

    -- Font resource ids, as the engine fills them in at run time. OFF by default: the
    -- default image leaves them zero, which is the "engine has not filled them in yet"
    -- state the mod has to survive. `font_ids = true` populates them so the real-text
    -- path can be exercised as well as the fallback.
    -- A minimal but REAL PE header, ALWAYS, written as CONTIGUOUS bytes. This used to be
    -- written only for the font_ids fixture, and that was a blind spot with a real cost:
    -- without it the read at the image base failed, read_font_ids() returned "PE header
    -- unreadable" before it touched anything, and a call to a function that DID NOT EXIST
    -- (`u32_off`) was never reached by any test. In game it faulted on the first panel
    -- draw and the only symptom was "the UI looks wrong".
    --
    -- Contiguous matters: the memory mock refuses a read that spans a byte it was never
    -- given, so a scatter of individual u32 writes reads back as nothing at all.
    local PE_AT = 0x100
    local dos = string.rep('\0', 0x40)
    -- e_lfanew at 0x3c, little endian
    dos = dos:sub(1, 0x3c) .. string.char(0x00, 0x01, 0x00, 0x00)
    harness.bytes(base, dos)
    -- 'PE\0\0', Machine, then TimeDateStamp == GAME_STAMP (0x6AB3B43F), little endian
    -- 16 bytes, not 12: the lookup reads a fixed 16-byte header, and the memory mock
    -- refuses a read that runs past the last byte it was given.
    harness.bytes(base + PE_AT,
                  'PE\0\0' .. string.rep('\0', 4)
                  .. string.char(0x3F, 0xB4, 0xB3, 0x6A) .. string.rep('\0', 4))

    if opts.font_ids then
        local material_owner = base + 0x5000000
        -- An IdString64 sits in memory as two dwords, low half first. Each id is written
        -- as one contiguous 8-byte run for the same reason as the header above.
        harness.bytes(base + 0x3772268,
                      string.char(0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11))
        harness.bytes(base + 0x3772ee8,
                      string.char(0x00, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99))
        harness.u64(base + 0x37c5478, material_owner)
        harness.bytes(material_owner + 24,
                      string.char(0x78, 0x69, 0x5A, 0x4B, 0x3C, 0x2D, 0x1E, 0x0F))
    end

    local ctx = harness.ctx_base
    local context = opts.context == nil and ctx or opts.context
    harness.u64(base + 0x347cef0, context)
    if context ~= 0 then
        -- The fields live INSIDE the context object, at ctx+offset. Writing them at
        -- ctx_base while pointing the context pointer AT ctx_base makes the mod read
        -- ctx_base+0x16390, which was never written -- the fixture must lay them out
        -- relative to the object the pointer actually names.
        -- The peer array is built from `others` -- the number of OTHER players --
        -- because that is the quantity the mod reasons about. `peer_count` is then
        -- derived as others+1, and slot 0 is always us. Getting this backwards is
        -- easy and invisible, so the fixture expresses exactly one thing:
        -- "how many players besides me are in this session".
        --
        -- `others` is a NUMBER on purpose. A Python bool arrives as 0/1 and Lua
        -- treats 0 as truthy, so a boolean here would silently mean its opposite.
        local others = tonumber(opts.others) or 1
        local count = others + 1
        harness.u32(context + 0x16390, count)
        -- Peer ids must be exactly representable as doubles. A 64-bit id above 2^53
        -- is rounded to a multiple of 256, which zeroes its low byte AND makes
        -- `own + 1 == own` -- so a fixture written that way silently models the same
        -- peer twice while looking like it models two. These stay well under 2^53.
        local own = 0x00112233445566
        harness.u64(context + 0xb398, own)
        harness.u64(context + 0x16398, own)                  -- slot 0 is us
        for i = 1, others do
            harness.u64(context + 0x16398 + i * 32, own + i)  -- the others
        end
        local chat = context + 0xc418
        harness.bytes(chat, string.char(opts.chat_flag == nil and 1 or opts.chat_flag))
        harness.u32(chat + 0x9590, opts.history_first == nil and 7 or opts.history_first)
        harness.u32(chat + 0x9594, opts.history_count == nil and 12 or opts.history_count)
    end
    if opts.deny_reads_from then harness.deny_reads_from = opts.deny_reads_from end
end

function harness.load(path)
    local handle = assert(io.open(path, 'rb'))
    local source = handle:read('*a')
    handle:close()
    if type(source) ~= 'string' or #source == 0 then
        error('empty source read from ' .. tostring(path))
    end
    local compiler = loadstring or load
    local chunk, err = compiler(source, '@auto_chat.lua')
    if not chunk then error('compile failed: ' .. tostring(err)) end
    return chunk()
end

return harness
'''


def make_harness():
    lua = luajit.LuaRuntime(unpack_returned_tuples=True)
    namespace = lua.execute(HARNESS)
    return lua, namespace


def fresh_image(**options):
    """A new Lua state, a valid synthetic game image, and the chosen options."""
    lua, h = make_harness()
    h.clear_options()
    for key, value in options.items():
        h.option(key, value)
    h.install()
    h.build_image()
    return lua, h


class AutoChatProbeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua, cls.h = make_harness()
        with io.open(SOURCE, encoding="utf-8") as source:
            cls.source = source.read()

    def fresh(self):
        """A brand-new Lua state with a clean harness and a valid image."""
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        return lua, h, mod

    # ---------------------------------------------------------------- happy path
    def test_valid_image_verifies_and_observes(self):
        lua, h, mod = self.fresh()
        self.assertEqual("match", mod.signature, "all five signatures should match")
        self.assertIn("ready", mod.status,
                      "a verified image with a resolved send function is 'ready'")
        self.assertTrue(mod.send_ready, "the send function must resolve once verified")

        # The probe must have logged the observation without ever being ticked:
        # boot does the first read.
        text = h.log_text()
        self.assertIn("signature check: PASS", text)
        self.assertIn("send function resolved", text)

    def test_build_identity_is_distinct_from_product_version_and_logged(self):
        _, h, mod = self.fresh()
        self.assertEqual("1.0.0", mod.version)
        self.assertEqual("v1.0.0-build.7", mod.build_id)
        self.assertIn("AutoChat v1.0.0 starting (build v1.0.0-build.7; send + panel)",
                      h.log_text())
        written = h.written()
        status = "".join(written[i]["text"] for i in range(1, len(written) + 1)
                         if written[i]["path"].endswith("AutoChat-STATUS.txt"))
        self.assertIn("build       : v1.0.0-build.7", status)

    def test_observation_reports_the_synthetic_values(self):
        lua, h, mod = self.fresh()
        for _ in range(3):
            lua.eval("_G.update()")
        text = h.log_text()
        self.assertIn("peer count: 2", text)
        self.assertIn("chat history: first=7 count=12", text)
        # raw byte 1 -> the reference rule says "on", and we report that rather
        # than obeying it.
        self.assertIn("chat flag byte: 1", text)

    def test_chat_flag_is_reported_raw_not_misread(self):
        lua, h = fresh_image(chat_flag=0)
        mod = h.load(SOURCE)
        for _ in range(2):
            lua.eval("_G.update()")
        self.assertIn("chat flag byte: 0", h.log_text())

    # ---------------------------------------------------------------- the gates
    def test_break_send_signature_costs_zero_further_reads(self):
        lua, h = fresh_image(break_send=True)
        mod = h.load(SOURCE)
        reads_at_boot = h.reads
        self.assertEqual("MISMATCH", mod.signature)
        self.assertIn("dormant", mod.status)
        self.assertIn("chat send", h.log_text(), "the log must name which signature broke")

        # This is the whole point: after a mismatch, frames must cost nothing.
        for _ in range(600):
            lua.eval("_G.update()")
        self.assertEqual(reads_at_boot, h.reads,
                         "a dormant probe must not read memory on any frame")
        self.assertEqual(600, h.update_calls - 1 + 1)  # update chain still ran

    def test_guard_page_is_refused(self):
        lua, h = fresh_image()
        # Mark the context page as guarded. The probe must refuse it and must
        # not attempt the read.
        h.region(h.ctx_base, 0x20000, 0x1000, 0x100)
        mod = h.load(SOURCE)
        # signatures live in a different region and still match
        self.assertEqual("match", mod.signature)
        for _ in range(3):
            lua.eval("_G.update()")
        self.assertIn("unreadable", h.log_text())

    def test_uncommitted_page_is_refused(self):
        lua, h = fresh_image()
        h.region(h.ctx_base, 0x20000, 0x2000, 0x04)   # MEM_RESERVE, not committed
        mod = h.load(SOURCE)
        for _ in range(3):
            lua.eval("_G.update()")
        self.assertIn("not committed", h.log_text())

    def test_absent_session_is_not_an_error(self):
        lua, h = fresh_image(context=0)
        mod = h.load(SOURCE)
        for _ in range(3):
            lua.eval("_G.update()")
        text = h.log_text()
        self.assertIn("network context: none", text)
        # Being on the ship is normal; it must not be reported as a failure.
        self.assertNotIn("MISMATCH", mod.signature)

    # ---------------------------------------------------------------- send path
    def test_send_is_aimed_at_the_verified_send_rva(self):
        """The single most important assertion in this file.

        A wrong-but-callable address is exactly how a mod takes the game down, so
        the send must go to game.dll + the RVA whose signature was checked -- not
        to some other resolved pointer.
        """
        lua, h = fresh_image(others=1)
        mod = h.load(SOURCE)
        self.assertTrue(mod.send_ready, "send must resolve on a valid image")

        before = h.call_count()
        ok, others = lua.eval("(function() return _G.HD2AutoChat.send_text('hello', false) end)()")
        self.assertTrue(ok, "sending should be accepted when a peer is present")
        self.assertEqual(1, others, "one other player besides us")

        self.assertEqual(before + 1, h.call_count(), "exactly one new native call")
        call = h.last_call()
        expected = h.code_base + 0x1097560
        self.assertEqual(expected, call["address"],
                         "the call must target game.dll+0x1097560, the verified RVA")

    def test_send_passes_the_chat_object_and_the_text(self):
        lua, h = fresh_image(others=1)
        mod = h.load(SOURCE)
        lua.eval("(function() return _G.HD2AutoChat.send_text('1433223', false) end)()")
        call = h.last_call()
        self.assertIsNotNone(call, "the send must have been called")
        # arg1 = the chat object, arg2 = the 0 observed in the reference call,
        # arg3 = the NUL-terminated text buffer
        self.assertEqual(h.ctx_base + 0xc418, call["arg1_address"],
                         "arg 1 must be the chat object")
        self.assertEqual(0, call["arg2"],
                         "arg 2 is passed through as the reference does")
        self.assertEqual("1433223\0", call["arg3_text"],
                         "arg 3 must be the NUL-terminated UTF-8 text")

    def test_send_refuses_an_empty_session(self):
        # A session exists but lists only us: exactly a solo host's state, and the
        # send must be refused rather than broadcast to nobody.
        lua, h = fresh_image(others=0)
        mod = h.load(SOURCE)
        before = h.call_count()
        ok, why = lua.eval("(function() return _G.HD2AutoChat.send_text('hi', false) end)()")
        self.assertFalse(ok, "an empty session must be refused")
        self.assertIn("nobody else", why)
        self.assertEqual(before, h.call_count(),
                         "a refused send must not call the native")

    def test_send_refuses_when_chat_is_off(self):
        lua, h = fresh_image(others=1, chat_flag=0)
        mod = h.load(SOURCE)
        baseline = h.call_count()
        ok, why = lua.eval("(function() return _G.HD2AutoChat.send_text('hi', false) end)()")
        self.assertFalse(ok)
        self.assertIn("text chat is off", why)
        self.assertEqual(baseline, h.call_count(), "no send may occur")

    def test_send_refuses_without_a_session(self):
        lua, h = fresh_image(context=0)
        mod = h.load(SOURCE)
        baseline = h.call_count()
        ok, why = lua.eval("(function() return _G.HD2AutoChat.send_text('hi', false) end)()")
        self.assertFalse(ok)
        self.assertIn("no network session", why)
        self.assertEqual(baseline, h.call_count(), "no send may occur")

    def test_send_is_refused_after_a_signature_mismatch(self):
        """The hard precondition: no verified signature, no call, ever."""
        lua, h = fresh_image(break_send=True, others=1)
        mod = h.load(SOURCE)
        self.assertFalse(mod.send_ready, "send must not resolve on a mismatch")
        ok, why = lua.eval("(function() return _G.HD2AutoChat.send_text('hi', false) end)()")
        self.assertFalse(ok)
        self.assertIn("not verified", why)
        self.assertEqual(0, h.call_count(),
                         "no native call may happen after a mismatch - not even the "
                         "resolver, because the signature never validated")

    def test_oversized_text_is_cut_without_splitting_a_character(self):
        """cut_utf8 must never emit a partial multi-byte character.

        A truncated character makes the game drop the whole line, so the cut has to
        land on a character boundary. This is tested through the function itself
        because that is the actual contract; going via send_text would only prove
        it for one length.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        # U+4E2D is 3 bytes, U+00A9 is 2 bytes, U+1F600 is 4 bytes.
        script = (
            "(function()\n"
            "  local ch = string.char(228, 184, 173)\n"
            "  local two = string.char(194, 169)\n"
            "  local four = string.char(240, 159, 152, 128)\n"
            "  local out = {}\n"
            "  out[#out+1] = #_G.HD2AutoChat.debug_cut(string.rep(ch, 200), 512)\n"
            "  out[#out+1] = #_G.HD2AutoChat.debug_cut(string.rep(two, 300), 512)\n"
            "  out[#out+1] = #_G.HD2AutoChat.debug_cut(string.rep(four, 200), 512)\n"
            "  out[#out+1] = #_G.HD2AutoChat.debug_cut('short', 512)\n"
            "  return table.concat(out, ',')\n"
            "end)()"
        )
        sizes = [int(v) for v in lua.eval(script).split(",")]
        # 3-byte: 512 is not a multiple of 3, so 510. 2-byte: exactly 512.
        # 4-byte: 512 is a multiple of 4, so 512. Already short: untouched.
        self.assertEqual([510, 512, 512, 5], sizes,
                         "each cut must land on a character boundary")

    def test_cut_text_is_valid_utf8(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        script = (
            "(function()\n"
            "  local ch = string.char(228, 184, 173)\n"
            "  return _G.HD2AutoChat.debug_cut(string.rep(ch, 200), 512)\n"
            "end)()"
        )
        body = lua.eval(script)
        # lupa hands a Lua string back as a Python str decoded as UTF-8, so the
        # bytes have to be recovered with an explicit encode. (Taking len() of the
        # str gives characters, not bytes, and would under-count by 3x here.)
        raw = body.encode("utf-8")
        self.assertEqual(510, len(raw), "170 whole 3-byte characters")
        self.assertEqual(b"\xe4\xb8\xad" * 170, raw,
                         "the result must decode as whole characters")
        self.assertEqual(0, len(raw) % 3)

    def test_force_is_off_by_default_and_does_not_bypass_other_guards(self):
        """`force` exists only to prove the call reaches the game.

        It must not weaken anything else: a forced send into a session whose chat
        is off, or with no session at all, still must not call the native.
        """
        lua, h = fresh_image(others=0)
        mod = h.load(SOURCE)

        # default: refused, and no native call at all
        before = h.call_count()
        ok, why = lua.eval("(function() return _G.HD2AutoChat.send_text('x', false) end)()")
        self.assertFalse(ok)
        self.assertIn("nobody else", why)
        self.assertEqual(before, h.call_count(), "the default path must not call")

        # forced: exactly one more native call, and it still reports the truth
        # about the session rather than pretending somebody is there
        before = h.call_count()
        ok, others = lua.eval(
            "(function() return _G.HD2AutoChat.send_text('x', false, true) end)()")
        self.assertTrue(ok, "a forced send must reach the native call")
        self.assertEqual(0, others, "and must still report that nobody else is present")
        self.assertEqual(before + 1, h.call_count(), "exactly one call is added")

    def test_force_does_not_bypass_the_chat_off_guard(self):
        lua, h = fresh_image(others=0, chat_flag=0)
        mod = h.load(SOURCE)
        before = h.call_count()
        ok, why = lua.eval(
            "(function() return _G.HD2AutoChat.send_text('x', false, true) end)()")
        self.assertFalse(ok, "force must not override 'text chat is off'")
        self.assertIn("text chat is off", why)
        self.assertEqual(before, h.call_count())

    def test_force_does_not_bypass_the_signature_gate(self):
        lua, h = fresh_image(break_send=True, others=0)
        mod = h.load(SOURCE)
        before = h.call_count()
        ok, why = lua.eval(
            "(function() return _G.HD2AutoChat.send_text('x', false, true) end)()")
        self.assertFalse(ok, "force must never override an unverified signature")
        self.assertIn("not verified", why)
        self.assertEqual(before, h.call_count())

    # ---------------------------------------------------------------- chain
    def test_update_always_calls_the_previous_update(self):
        lua, h, mod = self.fresh()
        before = h.update_calls
        for _ in range(5):
            lua.eval("_G.update()")
        self.assertEqual(before + 5, h.update_calls,
                         "update must never swallow the previous frame callback")

    def test_shutdown_always_calls_the_previous_shutdown(self):
        lua, h, mod = self.fresh()
        before = h.shutdown_calls
        lua.eval("_G.shutdown()")
        self.assertEqual(before + 1, h.shutdown_calls,
                         "shutdown must chain or the log handle never closes")

    # ---------------------------------------------------------------- frame cost
    def test_observation_is_on_an_interval_not_every_frame(self):
        """The per-frame cost must not include the observation.

        A frame-budget watchdog reports each mod's cost in ms per second, so work
        done in `tick` is paid 60-120 times a second. `observe()` reads memory and
        formats ~10 strings per call; running it every frame was pure cost for no
        information, because the fields it reads cannot change that fast.

        Measured as native reads: if the interval regressed to every frame, the
        reads per frame would jump by roughly the observation's own read count.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        # let boot's observation settle, then measure over a window that contains
        # several observation intervals (the interval is 30 frames)
        for _ in range(90):
            lua.eval("_G.update()")
        before = h.reads
        frames = 900
        for _ in range(frames):
            lua.eval("_G.update()")
        reads = h.reads - before
        per_frame = reads / float(frames)
        self.assertLess(per_frame, 1.5,
                        "tick must be cheap per frame; measured %.2f native reads "
                        "per frame over %d frames" % (per_frame, frames))

    def test_observation_interval_is_literal_and_sane(self):
        """Pin the constant and its use, so a later edit cannot quietly drop it.

        Asserts on behaviour (the read budget) rather than on one exact source
        line: the gate may legitimately be written several ways, but observation
        must not run every frame.
        """
        import re
        src = self.source
        m = re.search(r"local OBSERVE_FRAMES\s*=\s*(\d+)", src)
        self.assertIsNotNone(m, "OBSERVE_FRAMES must stay a literal")
        self.assertGreaterEqual(int(m.group(1)), 10,
                                "the observation interval should be at least ~10 "
                                "frames; anything near 1 is the bug this guards")
        self.assertIn("next_observe = M.frames + OBSERVE_FRAMES", src,
                      "the interval constant must actually schedule the next observation")
        self.assertIn("if M.frames >= next_observe then", src,
                      "the observation must be guarded by the interval")

    def test_disabled_use_still_costs_nothing(self):
        """A dormant mod must not pay for the frame at all."""
        lua, h = fresh_image(break_send=True)
        mod = h.load(SOURCE)
        reads_at_boot = h.reads
        for _ in range(900):
            lua.eval("_G.update()")
        self.assertEqual(reads_at_boot, h.reads,
                         "a mod that failed its signature check must read nothing "
                         "on any frame")

    def test_idle_frames_do_not_log_every_frame(self):
        lua, h, mod = self.fresh()
        for _ in range(600):
            lua.eval("_G.update()")
        # One observation at boot, one heartbeat at frame 1800; 600 idle frames
        # must add nothing.
        occurrences = h.log_text().count("observation [")
        self.assertEqual(1, occurrences,
                         "a static observation must not re-log every frame")
        self.assertGreaterEqual(mod.frames, 600)

    def test_heartbeat_fires_once_past_the_interval(self):
        lua, h, mod = self.fresh()
        for _ in range(1801):
            lua.eval("_G.update()")
        self.assertEqual(1, h.log_text().count("heartbeat:"),
                         "exactly one heartbeat at frame 1800, not one per frame")

    # ---------------------------------------------------------------- safety net
    def test_user32_declarations_are_guarded_and_match_the_reference(self):
        """user32 may be declared ONLY the way that cannot clobber anyone.

        LuaJIT's `ffi.cdef` keeps the first declaration, so a mod that declares
        user32 with different prototypes silently changes the C signature every
        other mod sees -- this workspace has a rule against it for exactly that
        reason. The panel needs GetAsyncKeyState / ShowCursor / ClipCursor, so the
        rule is relaxed deliberately, and this test pins the three properties that
        make relaxing it safe:

          1. every name is checked for an EXISTING declaration before being added;
          2. each cdef is inside a pcall, so an already-declared symbol cannot kill
             the load with "attempt to redefine";
          3. the prototypes are identical to Super Earth Armory Forge's own list,
             so whichever mod wins the race the process holds one identical
             prototype and neither mod is disabled.

        Property 3 is checked against the reference source where it is available,
        and against a frozen expected table otherwise.
        """
        src = self.source
        lowered = src.lower()

        expected = [
            'void *getforegroundwindow(void);',
            'uint32_t getwindowthreadprocessid(void*,void*);',
            'int getcursorpos(void*);',
            'int screentoclient(void*,void*);',
            'int getclientrect(void*,void*);',
            'int16_t getasynckeystate(int key);',
            'int showcursor(int show);',
            'int clipcursor(const void *rect);',
            'int getclipcursor(void *rect);',
            'int getsystemmetrics(int index);',
        ]
        for decl in expected:
            self.assertIn(decl, lowered,
                          'the panel needs %r and it must match the reference '
                          'prototype byte for byte' % decl)

        # 1 + 2: the guard must actually exist and wrap the declaration loop.
        self.assertIn('already_declared', src,
                      'user32 declarations must be probed, not added blindly')
        self.assertIn('pcall(ffi.cdef, declaration)', src,
                      'each cdef must be inside a pcall')

        # kernel32 symbols must NOT be smuggled into the user32 list.
        user32_block = src.split('USER32_DECLS', 1)[1].split('}', 1)[0].lower()
        for kernel_symbol in ('getcurrentprocessid', 'readprocessmemory',
                              'virtualquery', 'getmodulehandlea'):
            self.assertNotIn(kernel_symbol, user32_block,
                             '%s lives in kernel32; declaring it as user32 both '
                             'misleads readers and risks a mismatched prototype'
                             % kernel_symbol)

    def test_user32_prototypes_match_the_reference_source_verbatim(self):
        """Compare our declarations against Armory Forge's OWN source, not a table.

        The whole safety argument for declaring user32 is "our prototypes are
        byte-identical to the reference's, so whichever mod declares first the
        process holds one identical signature and neither is disabled". Asserting
        that against a hand-copied table in gates.py only proves the table and the
        source agree with each other -- both could be wrong together.

        This reads the reference mod's declaration list directly and compares.

        If the reference source is not present (this repo deliberately does NOT
        redistribute it), the test SKIPS with a clear reason rather than passing
        silently -- a silent pass here would be worse than no test.
        """
        reference = None
        for candidate in REFERENCE_SOURCE_CANDIDATES:
            if os.path.exists(candidate):
                reference = candidate
                break
        if reference is None:
            self.skipTest("reference source not present (not redistributed): %s"
                          % ", ".join(REFERENCE_SOURCE_CANDIDATES))

        with io.open(reference, encoding="utf-8", errors="replace") as handle:
            text = handle.read()

        # The reference declares each prototype as a quoted string in a table. If a
        # prototype is not there, the reference is not declaring that name at all,
        # which is worth reporting rather than silently skipping.
        ours = self.source
        checked, absent = [], []
        for name, prototype in gates.REFERENCE_PROTOTYPES.items():
            if prototype in text:
                checked.append(name)
                self.assertIn(prototype, ours,
                              "the reference declares %s as %r but our source does "
                              "not carry that exact string; a differing prototype "
                              "would change the C signature other mods see"
                              % (name, prototype))
            else:
                absent.append(name)
        self.assertTrue(checked,
                        "not one of the reference prototypes was found in %s; "
                        "either the reference layout changed or the expected table "
                        "in gates.py is wrong (absent: %s)"
                        % (reference, ", ".join(sorted(absent))))

    def test_user32_is_the_only_non_kernel_dependency(self):
        """Nothing beyond user32+kernel32 should be loaded: each DLL is another
        chance to declare a symbol someone else owns."""
        loads = set(re.findall(r"ffi\.load\('([^']+)'\)", self.source))
        self.assertEqual(loads - {'kernel32', 'user32', 'game'},
                         set(),
                         'unexpected ffi.load targets: %s' % loads)

    # ------------------------------------------------------- panel cursor handover
    def test_show_cursor_calls_balance_exactly_on_release(self):
        """ShowCursor is a per-thread COUNTER. Give back exactly what was taken.

        This is the defect that would leave a player stuck: the panel shows the
        cursor, and on close hands back the wrong number of calls, so the cursor
        stays visible and the aim is dead. The mod loops until ShowCursor reports
        visible, counts the calls used, and returns that many.

        The assertion is COUNTER EQUIVALENCE, not "the cursor is hidden". On the
        real API the display counter starts at 0 and 0 already means visible, so a
        correct panel leaves the cursor exactly as it found it -- which for a hidden
        initial state is the visible-adjacent counter, not a negative one. Asserting
        "hidden" would encode a wrong model of the API.
        """
        lua, h, mod = self.fresh()
        start_counter = h.user32.show_count()
        mod.debug_take_cursor()
        after_take = h.user32.show_count()
        self.assertGreater(after_take, start_counter,
                           "taking the cursor must have shown it")
        state = mod.debug_cursor_state()
        self.assertTrue(state["taken"], "the cursor must be marked as taken")
        self.assertEqual(after_take - start_counter, state["shows"],
                         "the recorded call count must equal the calls actually made")

        mod.debug_release_cursor()
        self.assertEqual(start_counter, h.user32.show_count(),
                         "the display counter must return to its starting value, or "
                         "the cursor leaks one step more visible per panel open")

    def test_take_and_release_cycles_do_not_drift(self):
        """Ten open/close cycles must leave the counter exactly where it started."""
        lua, h, mod = self.fresh()
        start = h.user32.show_count()
        for cycle in range(10):
            mod.debug_take_cursor()
            mod.debug_release_cursor()
            self.assertEqual(start, h.user32.show_count(),
                             "cycle %d left the cursor counter at %d, expected %d"
                             % (cycle, h.user32.show_count(), start))

    def test_take_is_idempotent_and_release_is_safe(self):
        """A double take must not double-count; a stray release must do nothing."""
        lua, h, mod = self.fresh()
        mod.debug_release_cursor()          # release with nothing taken
        start = h.user32.show_count()
        mod.debug_take_cursor()
        mid = h.user32.show_count()
        mod.debug_take_cursor()             # second take must be a no-op
        self.assertEqual(mid, h.user32.show_count(),
                         "a second take must not call ShowCursor again")
        mod.debug_release_cursor()
        self.assertEqual(start, h.user32.show_count(),
                         "release after a redundant take must still balance")

    def test_clip_rectangle_is_restored_not_merely_cleared(self):
        """The saved clip rect must come back, not just be unset."""
        lua, h, mod = self.fresh()
        h.user32_set_clip(10, 20, 300, 400)
        mod.debug_take_cursor()
        self.assertIsNone(h.user32.clip(),
                          "while the panel is open the pointer must not be clipped")
        state = mod.debug_cursor_state()
        self.assertIsNotNone(state["clip"],
                             "the previous clip rectangle must be saved when taken")
        mod.debug_release_cursor()
        self.assertEqual("10,20,300,400", h.user32_clip_text(),
                         "the restored rectangle must be the one that was saved; "
                         "leaving it unset would free the pointer in game")

    def test_no_user32_means_panel_input_is_inert_not_fatal(self):
        """With user32 unavailable the panel must no-op, never raise."""
        lua, h, mod = self.fresh()
        lua.execute("_G.__saved = nil")
        # Directly exercise the entry points; a raise here would mean the mod can
        # take the frame callback down on a machine where user32 will not load.
        mod.debug_take_cursor()
        mod.debug_release_cursor()
        state = mod.debug_cursor_state()
        self.assertIn("taken", state)

    def test_builtin_default_presets_are_role_specific_fixed_and_only_apply_explicitly(self):
        lua, h, mod = self.fresh()
        library, automation, language = mod.debug_preset_library(), mod.debug_automation(), mod.debug_language()
        host, client = library.list("host"), library.list("client")
        self.assertEqual((2, 2), (len(host), len(client)))
        self.assertEqual(("builtin-host-en", "builtin-host-zh", "English Default Preset", "中文默认预设"),
                         (host[1].id, host[2].id, host[1].name, host[2].name))
        self.assertEqual(("builtin-client-en", "builtin-client-zh", "English Default Preset", "中文默认预设"),
                         (client[1].id, client[2].id, client[1].name, client[2].name))
        ok, host_profile = automation.validate_profile(host[1].payload)
        self.assertTrue(ok)
        self.assertEqual("en", host_profile[b"values"][b"message_language"])
        self.assertEqual("Welcome to the squad!", host_profile[b"values"][b"welcome_message"])
        self.assertEqual("squad", host_profile[b"values"][b"output"])
        self.assertEqual(0, len(host_profile.rules))
        ok, client_profile = automation.validate_profile(client[1].payload)
        self.assertTrue(ok)
        self.assertEqual(("en", "local", True),
                         (client_profile[b"values"][b"message_language"], client_profile[b"values"][b"output"],
                          client_profile[b"values"][b"welcome"]))
        ok, chinese = automation.validate_profile(host[2].payload)
        self.assertTrue(ok)
        self.assertEqual(("zh", "欢迎加入小队！"),
                         (chinese[b"values"][b"message_language"], chinese[b"values"][b"welcome_message"]))

        # A UI locale refresh alone cannot replace saved settings or selected messages.
        self.assertTrue(library.apply("builtin-host-zh", "host"))
        self.assertTrue(automation.set("enabled", False, "host")[0])
        before = automation.export_profile("host", mod.profile_tasks("host"))
        language.update("en", 1)
        self.assertEqual(before, automation.export_profile("host", mod.profile_tasks("host")))
        self.assertEqual("zh", automation.profile("host").message_language)
        self.assertTrue(library.apply("builtin-client-en", "client"))
        self.assertEqual("local", automation.profile("client").output)
        self.assertFalse(automation.profile("host").enabled)
        # Applying the same stable built-in again restores its factory payload,
        # proving edits did not mutate the virtual built-in source.
        self.assertTrue(library.apply("builtin-host-zh", "host"))
        self.assertTrue(automation.profile("host").enabled)
        self.assertEqual("zh", automation.profile("host").message_language)
        self.assertEqual("中文默认预设", library.list("host")[2].name)

    def test_fresh_profile_defaults_to_english_messages(self):
        _, _, mod = self.fresh()
        automation = mod.debug_automation()
        self.assertEqual("en", automation.profile("host").message_language)
        self.assertEqual("Welcome to the squad!", automation.profile("host").welcome_message)

    def test_plugin_preset_capture_preserves_unregistered_blob_and_host_failure_rolls_back(self):
        lua, h, mod = self.fresh()
        result = lua.execute(r'''
            local library,mod_automation,harness=...
            local registry=HD2AutoChatAPI
            local old_state='kept-opaque'
            local function hooks(state_ref)
                return {
                    capture=function(role) assert(role=='host');return state_ref.value end,
                    validate=function(data,role) return role=='host' and type(data)=='string' end,
                    apply=function(data,role) assert(role=='host');state_ref.value=data;return true end,
                    restore=function(data,role) assert(role=='host');state_ref.value=data;return true end}
            end
            local zombie={value=old_state}
            assert(registry.register({id='future.plugin',title='Future',draw=function()end,preset=hooks(zombie)}))
            local saved,_,id=library.save('Hook Snapshot','host');assert(saved)
            assert(registry.unregister('future.plugin'))
            local active={value='state-B'}
            assert(registry.register({id='auto-chat-demo',title='Demo',draw=function()end,preset=hooks(active)}))
            local replaced,replace_why=library.replace(id,'host');assert(replaced,'replace:'..tostring(replace_why))
            local item
            for _,entry in ipairs(library.list('host')) do if entry.id==id then item=entry end end
            assert(item)
            local valid,parsed=mod_automation.validate_profile(item.payload);assert(valid,parsed)
            assert(parsed.plugins['future.plugin']=='kept-opaque')
            assert(parsed.plugins['auto-chat-demo']=='state-B')
            active.value='state-C'
            assert(library.apply(id,'host'))
            assert(active.value=='state-B')
            -- Force the host settings save to fail after plugin commit. The plugin
            -- transaction must compensate back to its state from prepare time.
            active.value='before-failure'
            assert(mod_automation.set('welcome_message','changed after save','host'))
            harness.deny_settings_write=true
            harness.fail_task_rollback_after_settings_failure=true
            local ok,why=library.apply(id,'host')
            harness.deny_settings_write=false
            harness.fail_task_rollback_after_settings_failure=false
            assert(not ok and (tostring(why):find('保存失败') or tostring(why):find('设置保存失败')))
            assert(tostring(why):find('任务文件回滚失败'))
            assert(active.value=='before-failure')
            return true
        ''', mod.debug_preset_library(), mod.debug_automation(), h)
        self.assertTrue(result)

    # ---------------------------------------------------------- retired timer
    def test_legacy_quick_timer_runtime_is_inert_after_migration(self):
        lua, h = fresh_image(others=1)
        mod = h.load(SOURCE)
        automation = mod.debug_automation()
        automation.set('quick_timer_enabled', True, 'host')
        automation.set('quick_timer_interval', 5, 'host')
        before = h.call_count()
        mod.debug_timed_send(60)
        self.assertEqual(before, h.call_count(),
                         "legacy quick fields must never drive a hidden sender")

    # ------------------------------------------------------------ panel geometry
    def test_panel_stays_on_screen_at_every_common_resolution(self):
        """A panel drawn off-screen is invisible and looks like a dead hotkey.

        The rendering cannot be exercised here, but the layout is arithmetic, so the
        failure modes that matter -- the panel hanging off an edge, rows overlapping,
        the close button unreachable -- are all checkable. This is deliberately run
        across resolutions rather than one, because the scale factor is derived from
        the resolution and a wrong derivation only shows at some of them.
        """
        lua, h, mod = self.fresh()
        for rw, rh in ((1920, 1080), (2560, 1440), (3840, 2160), (1280, 720),
                       (1366, 768), (1600, 900), (3440, 1440), (1024, 768)):
            geo = mod.debug_geometry(rw, rh)
            x, y, w, hgt = geo["x"], geo["y"], geo["w"], geo["h"]
            self.assertGreater(w, 0, "%dx%d: width must be positive" % (rw, rh))
            self.assertGreater(hgt, 0, "%dx%d: height must be positive" % (rw, rh))
            self.assertGreaterEqual(x, 0, "%dx%d: panel left edge is off-screen" % (rw, rh))
            self.assertGreaterEqual(y, 0, "%dx%d: panel bottom edge is off-screen" % (rw, rh))
            self.assertLessEqual(x + w, rw,
                                 "%dx%d: panel right edge runs off-screen" % (rw, rh))
            self.assertLessEqual(y + hgt, rh,
                                 "%dx%d: panel top edge runs off-screen" % (rw, rh))
            self.assertGreater(geo["scale"], 0, "%dx%d: scale collapsed" % (rw, rh))

    # --------------------------------------------------- panel GUI lifecycle
    def _run(self, lua, frames):
        for _ in range(frames):
            lua.eval("_G.update()")

    def test_click_regions_never_overlap_and_stay_on_screen(self):
        """The recorded hit boxes are what a click is matched against.

        Asserting on the drawn regions rather than on a recomputed layout is the point:
        the old panel derived its rows twice, once for drawing and once for hit
        testing, and a click could land on a different row than the one drawn. Now the
        regions ARE the drawn rectangles, so this checks the real thing.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 20)
        regions = mod.debug_panel()["regions"]
        self.assertIsNotNone(regions, "the panel must record its click regions")
        # the resolution the panel actually drew at, rather than an assumed one
        rw = mod.debug_geometry(1920, 1080)["resolution"]["rw"]
        rh = mod.debug_geometry(1920, 1080)["resolution"]["rh"]
        count = len(regions)
        self.assertGreaterEqual(count, 4,
                                "expected the message box, timer, and two interval "
                                "buttons at least; got %d" % count)
        boxes = []
        for i in range(1, count + 1):
            r = regions[i]
            self.assertGreater(r["w"], 0, "region %d has no width" % i)
            self.assertGreater(r["h"], 0, "region %d has no height" % i)
            self.assertGreaterEqual(r["x"], 0, "region %d is off the left edge" % i)
            self.assertGreaterEqual(r["y"], 0, "region %d is off the bottom edge" % i)
            self.assertLessEqual(r["x"] + r["w"], rw,
                                 "region %d runs off the right edge" % i)
            self.assertLessEqual(r["y"] + r["h"], rh,
                                 "region %d runs off the top edge" % i)
            boxes.append((i, r["x"], r["y"], r["x"] + r["w"], r["y"] + r["h"]))
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                overlap_x = min(a[3], b[3]) - max(a[1], b[1])
                overlap_y = min(a[4], b[4]) - max(a[2], b[2])
                self.assertFalse(overlap_x > 1 and overlap_y > 1,
                                 "click regions %d and %d overlap, so a click could "
                                 "hit the wrong control" % (a[0], b[0]))

    def test_typing_edits_the_message_and_enter_commits(self):
        """The editable field, driven through the same code the panel uses.

        The user asked for this specifically: the auto-send text has to be editable by
        typing. The logic is pure bookkeeping over key state, so it is testable without
        the engine.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer("")
        # Type three letters. Each call uses a LATER timestamp so the edge detector
        # sees a fresh press rather than the auto-repeat window.
        texts = []
        for index, key in enumerate((0x41, 0x42, 0x43)):     # A B C
            h.user32.set_key(key, True)
            value, _ = mod.debug_edit_text(1.0 + index)
            texts.append(value)
            h.user32.set_key(key, False)
            mod.debug_edit_text(2.0 + index)
        self.assertEqual("a", texts[0], "the first letter must be typed")
        self.assertEqual("ab", texts[1])
        self.assertEqual("abc", texts[2])
        # Backspace removes one whole character.
        h.user32.set_key(0x08, True)
        value, _ = mod.debug_edit_text(5.0)
        self.assertEqual("ab", value, "backspace must remove one character")
        h.user32.set_key(0x08, False)
        mod.debug_edit_text(6.0)
        # Enter commits.
        h.user32.set_key(0x0D, True)
        value, what = mod.debug_edit_text(7.0)
        self.assertEqual("commit", what)
        self.assertEqual("ab", value)

    def test_escape_cancels_an_edit_without_changing_the_message(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        original = mod.debug_cfg()["message"]
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer("something else")
        h.user32.set_key(0x1B, True)                       # Escape
        value, what = mod.debug_edit_text(1.0)
        self.assertEqual("cancel", what)
        self.assertIsNone(value, "cancel must not return the edited text")
        self.assertEqual(original, mod.debug_cfg()["message"],
                         "the stored message must be untouched until Enter")

    def test_unicode_window_events_edit_text_and_overflow_resets(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer("")
        lua.execute("""
            EDIT_EVENTS = {
                {message=0x0102, wparam=0x4F60, lparam=1},
                {message=0x0102, wparam=0x597D, lparam=1},
            }
        """)
        value, what = mod.debug_edit_text(0, lua.globals().EDIT_EVENTS, False)
        self.assertEqual(("你好", "typing"), (value, what))

        original = mod.debug_cfg()["message"]
        value, what = mod.debug_edit_text(1, lua.table(), True)
        self.assertIsNone(value)
        self.assertEqual("reset", what)
        self.assertEqual(original, mod.debug_cfg()["message"])

    def test_unicode_copy_and_cut_obey_clipboard_ownership_and_failure(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        lua.execute("""
            local h = ...
            local ffi = require('ffi')
            local kernel, user = ffi.load('kernel32'), ffi.load('user32')
            h.fake_memory, h.free_count, h.clip_set_ok = {text=''}, 0, true
            kernel.GlobalAlloc = function(flags, size)
                h.alloc_flags, h.alloc_size = flags, size
                return h.fake_memory
            end
            kernel.GlobalLock = function(memory) return memory end
            kernel.GlobalUnlock = function() h.unlock_count=(h.unlock_count or 0)+1 return 1 end
            kernel.GlobalFree = function() h.free_count=h.free_count+1 return nil end
            user.OpenClipboard = function(owner) h.clipboard_owner=owner; h.open_count=(h.open_count or 0)+1; return owner and 1 or 0 end
            user.EmptyClipboard = function() return 1 end
            user.SetClipboardData = function(format, memory)
                h.clipboard_format, h.clipboard_utf16 = format, memory.text
                return h.clip_set_ok and memory or nil
            end
            user.CloseClipboard = function() h.close_count=(h.close_count or 0)+1 return 1 end
        """, h)
        original = mod.debug_cfg()["message"]
        mod.debug_set_editing(True)
        mod.debug_set_edit_buffer("你好")

        lua.execute("EDIT_CLIP = {{message=0x0102,wparam=0x01,lparam=1},{message=0x0102,wparam=0x03,lparam=1}}")
        value, what = mod.debug_edit_text(0, lua.globals().EDIT_CLIP, False)
        self.assertEqual(("你好", "typing"), (value, what))
        self.assertEqual(13, h.clipboard_format)
        self.assertEqual('WINDOW', h.clipboard_owner,
                         'clipboard must be opened by the focused game window, never NULL')
        self.assertEqual(b"\x60\x4f\x7d\x59\x00\x00", h.clipboard_utf16.encode("latin1"))
        self.assertEqual(0, h.free_count, "successful SetClipboardData transfers ownership to Windows")

        lua.execute("local h=...; h.clip_set_ok=false; EDIT_CUT={{message=0x0102,wparam=0x01,lparam=1},{message=0x0102,wparam=0x18,lparam=1}}", h)
        value, what = mod.debug_edit_text(1, lua.globals().EDIT_CUT, False)
        self.assertEqual(("你好", "typing"), (value, what), "failed copy must leave cut text intact")
        self.assertEqual(1, h.free_count, "failed transfer frees our movable block")
        self.assertGreaterEqual(h.close_count, 2, "clipboard is closed after success and failure")
        self.assertEqual(original, mod.debug_cfg()["message"], "clipboard actions must not mutate stored settings")

        lua.execute("local h=...; h.clip_set_ok=true; EDIT_CUT_OK=EDIT_CUT", h)
        value, what = mod.debug_edit_text(2, lua.globals().EDIT_CUT_OK, False)
        self.assertEqual(("", "typing"), (value, what))
        self.assertEqual(1, h.free_count, "successful transfer leaves block ownership with Windows")

    # ------------------------------------------------------------ font / drawing
    def test_ime_context_not_ready_is_visible_to_the_editor(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 601)
        mod.debug_set_open(True)
        p = mod.debug_panel()
        p.editing, p.edit_field, p.edit_text = True, 'task:name', ''
        p.input_edit_field = 'task:name'
        panel_input = mod.debug_panel_input()
        lua.execute("""local input = ...
            input.drain=function() return {},false end
            input.status=function()
                return {broken=false,editing=true,ime_ready=false,ime_pending=false,
                        state='held',window='WINDOW'}
            end""", panel_input)
        lua.eval('update()')
        self.assertIn('IME', str(p.hint).upper(),
                      'a posted but unavailable IME context must be shown instead of silently dropping input')

    def test_panel_draws_even_when_the_font_cannot_be_resolved(self):
        """A missing font must degrade the LOOK, not blank the panel.

        The default harness image leaves the font ids zeroed, which is exactly the
        runtime state before the engine fills them in. The panel must still lay out and
        record its click regions, via the bitmap fallback.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 20)
        self.assertIn(lua.eval("tostring(_G.HD2AutoChat.draw_errors)"), ("nil",),
                      "drawing must not fault when the font is unavailable")
        regions = mod.debug_panel()["regions"]
        self.assertGreaterEqual(len(regions), 4,
                                "the panel must still lay out and record its regions "
                                "without the engine font")

    def test_a_failed_draw_is_not_recorded_as_drawn(self):
        """A throwing draw must leave the panel dirty so the next frame retries.

        The signature used to be stored BEFORE the draw. A draw that threw therefore
        left the panel marked "already drawn": every later frame saw a matching
        signature, drew nothing, and the only symptom was a permanently blank panel
        with no further errors. This pins the ordering.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 20)
        panel = mod.debug_panel()
        self.assertIsNotNone(panel["sig"],
                             "a successful draw must record its signature")
        self.assertIsNotNone(panel["ui_s"],
                             "and must have measured a layout scale")

    def test_panel_signature_cache_reuses_values_and_preserves_formatted_signature(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 2)
        panel = mod.debug_panel()

        first = mod.debug_panel_signature()
        cache = panel["_signature_cache"]
        frame = cache["frames"][1]
        epoch = frame["epoch"]
        self.assertEqual(first, mod.debug_panel_signature())
        self.assertEqual(epoch, frame["epoch"], "unchanged raw fields must reuse the assembled signature")

        scale = panel["ui_s"]
        scale_text = lua.eval("string.format('%.3f', ...)", scale)
        panel["ui_s"] = scale + 0.0001
        self.assertEqual(scale_text, lua.eval("string.format('%.3f', ...)", panel["ui_s"]))
        self.assertEqual(first, mod.debug_panel_signature())
        self.assertEqual(epoch, frame["epoch"], "scale movement below display precision must not redraw")

        cfg = mod.debug_cfg()
        cfg["elapsed"] = 0.1
        first = mod.debug_panel_signature()
        epoch = frame["epoch"]
        cfg["elapsed"] = 0.2
        self.assertEqual(first, mod.debug_panel_signature())
        self.assertEqual(epoch, frame["epoch"], "elapsed changes that round to the same integer must not redraw")

        panel["hint"] = False
        false_signature = mod.debug_panel_signature()
        self.assertNotEqual(first, false_signature, "false and nil are distinct formatted values")
        false_epoch = frame["epoch"]
        panel["hint"] = None
        self.assertNotEqual(false_signature, mod.debug_panel_signature())
        self.assertGreater(frame["epoch"], false_epoch, "nil and false transitions must invalidate the cache")

    def test_cached_signature_matches_legacy_fields_and_tracks_new_panel_state(self):
        """Preserve the old signature fields except retired task paging, plus new state."""
        fixture = Path(__file__).with_name("fixtures") / "panel_signature_v083.lua"
        legacy_function = fixture.read_text(encoding="utf-8").rstrip()
        current_source = Path(SOURCE).read_text(encoding="utf-8")
        begin = current_source.index("PANEL._signature_cache = PANEL._signature_cache or")
        end = current_source.index("\nend\n\n-- The plugin selected in the tab strip", begin) + len("\nend")
        legacy_source = current_source[:begin] + legacy_function + current_source[end:]

        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".lua", delete=False) as handle:
            handle.write(legacy_source)
            legacy_path = handle.name
        try:
            legacy_lua, legacy_h = fresh_image()
            current_lua, current_h = fresh_image()
            legacy_mod = legacy_h.load(legacy_path)
            current_mod = current_h.load(SOURCE)
            self.assertEqual(74, len(legacy_mod.debug_panel_signature().split("|")),
                             "the reference must exercise all original signature fields")
            self.assertEqual(77, len(current_mod.debug_panel_signature().split("|")),
                             "the current signature includes three panel-state fields")

            def signature_parts(mod):
                return mod.debug_panel_signature().split("|")

            def assert_legacy_fields_equivalent():
                legacy_parts = signature_parts(legacy_mod)
                current_parts = signature_parts(current_mod)
                self.assertEqual(74, len(legacy_parts))
                self.assertEqual(77, len(current_parts))
                # Slot 62 used to be task_page. It is deliberately constant now;
                # normalize only that known schema change before comparing all
                # remaining legacy fields.
                legacy_parts[61] = current_parts[61]
                self.assertEqual(legacy_parts, current_parts[:74])

            legacy_panel = legacy_mod.debug_panel()
            current_panel = current_mod.debug_panel()
            legacy_panel["task_page"] = 9
            current_panel["task_page"] = 9
            self.assertEqual("9", signature_parts(legacy_mod)[61],
                             "legacy slot 62 must demonstrate the old variable task page")
            self.assertEqual("1", signature_parts(current_mod)[61],
                             "current slot 62 deliberately remains constant")
            assert_legacy_fields_equivalent()
            for legacy_panel, current_panel in ((legacy_mod.debug_panel(), current_mod.debug_panel()),):
                legacy_panel["hint"], current_panel["hint"] = False, False
                assert_legacy_fields_equivalent()
                legacy_panel["hint"], current_panel["hint"] = None, None
                legacy_panel["ui_s"], current_panel["ui_s"] = 1.0001, 1.0001
                assert_legacy_fields_equivalent()
                legacy_cfg, current_cfg = legacy_mod.debug_cfg(), current_mod.debug_cfg()
                legacy_cfg["elapsed"], current_cfg["elapsed"] = 0.1, 0.1
                assert_legacy_fields_equivalent()
                legacy_cfg["message"], current_cfg["message"] = "contract-change", "contract-change"
                assert_legacy_fields_equivalent()

            current_mod.debug_language().update('zh', 1)
            before_new_state = signature_parts(current_mod)
            current_panel["scroll_offsets"] = lua_table = current_lua.table()
            lua_table["pings"] = 13
            after_pings_scroll = signature_parts(current_mod)
            self.assertNotEqual(before_new_state, after_pings_scroll)
            self.assertEqual("13", after_pings_scroll[74], "slot 75 records pings scroll offset")
            lua_table["pings"] = 0
            before_tasks_scroll = signature_parts(current_mod)
            lua_table["tasks"] = 27
            after_tasks_scroll = signature_parts(current_mod)
            self.assertNotEqual(before_tasks_scroll, after_tasks_scroll)
            self.assertEqual("27", after_tasks_scroll[75], "slot 76 records tasks scroll offset")
            lua_table["tasks"] = 0
            before_preview = signature_parts(current_mod)
            current_mod.ui_preview_language = 'en'
            after_preview = signature_parts(current_mod)
            self.assertNotEqual(before_preview, after_preview)
            self.assertEqual("en", after_preview[76], "slot 77 records the selected panel locale")
            self.assertEqual("zh", current_mod.debug_language().current(),
                             "panel preview must not change the game locale")
            current_mod.ui_preview_language = None
            self.assertEqual("zh", signature_parts(current_mod)[76],
                             "clearing preview follows the game locale")
        finally:
            Path(legacy_path).unlink(missing_ok=True)

    def test_panel_signature_plugin_change_and_nil_panel_signature_force_redraw(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 2)
        panel = mod.debug_panel()
        before = mod.debug_panel_signature()
        lua.globals().test_api = mod.api
        lua.execute("test_api.register{id='sigprobe',name='Signature probe',draw=function() end}")
        self.assertNotEqual(before, mod.debug_panel_signature(), "plugin registry changes belong in the signature")

        self._run(lua, 2)
        drawn = h.text_drawn or 0
        panel["sig"] = None
        lua.eval("update()")
        self.assertGreater(h.text_drawn or 0, drawn, "nil PANEL.sig must keep the established forced rebuild path")

    def test_the_font_is_actually_attempted_on_the_first_draw(self):
        """The real-text path must be REACHED, not merely present.

        This is the defect it exists for: font_resolve() was written, correct, and
        called from nowhere, so the panel silently used the bitmap fallback forever and
        the only symptom was "the text looks like the old panel". A resolver that is
        never invoked is invisible to every other test, so this asserts the attempt
        happened and recorded WHY it went the way it did.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 20)
        font = mod.debug_font()
        self.assertTrue(font["resolved"],
                        "the first draw must attempt to resolve the engine font; if it "
                        "was never tried the panel is stuck on the bitmap fallback")
        self.assertIsNotNone(font["why"],
                             "the resolver must record why it succeeded or failed, so a "
                             "bitmap panel can be explained from the log rather than "
                             "guessed at")

    # ------------------------------------------- public API / cross-mod tabs
    def test_another_mod_can_register_and_get_its_own_tab(self):
        """The cross-mod entry point, exercised the way another mod would use it.

        The user asked for other mods to be able to put their auto-send settings in this
        panel, visible as their own entry rather than buried in a shared list. This is
        that contract: register_plugin{id,title,draw} adds one tab beside DEFAULT, and
        the panel keeps them in registration order.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        before = len(mod.PLUGINS)
        lua.execute("""
            local reg = rawget(_G, 'HD2AutoChatPlugins')
            _G.__reg1 = reg.register({id = 'other_mod', title = 'OTHER MOD',
                                      draw = function(u, ctx) end})
            _G.__dup, _G.__dupwhy = reg.register({id = 'other_mod', title = 'AGAIN',
                                                  draw = function(u, ctx) end})
        """)
        mod = h.load(SOURCE)
        self.assertIsNotNone(lua.eval('_G.__reg1'),
                             "a valid plugin must register")
        self.assertEqual(before + 1, len(mod.PLUGINS))
        self.assertEqual("other_mod", mod.PLUGINS[before + 1]["id"])
        self.assertIsNone(lua.eval('_G.__dup'),
                          "a duplicate id must be refused, not shadow the first")
        self.assertIn("already", str(lua.eval('_G.__dupwhy')))

    def test_a_faulting_plugin_is_dropped_instead_of_taking_the_panel_down(self):
        """A third-party draw raises inside this panel's frame.

        Without a wrapper the panel dies with the plugin, every frame, and the user
        loses the whole UI because of someone else's bug. The faulting plugin must be
        dropped for the session, named in the log, and the panel must survive.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        # The registry is created when the mod loads, so registering comes after it --
        # which is also the real order for a mod that loads later than this one.
        lua.execute("""
            local reg = rawget(_G, 'HD2AutoChatPlugins')
            reg.register({id = 'bad_mod', title = 'BAD',
                          draw = function(u, ctx) error('boom') end})
            _G.HD2AutoChat.debug_panel().active_plugin = 'bad_mod'
        """)
        mod.debug_set_open(True)
        self._run(lua, 700)
        self._run(lua, 20)
        self.assertIsNone(lua.eval("rawget(_G.HD2AutoChat, 'PLUGIN_BY_ID')['bad_mod']"),
                          "a faulting plugin must be dropped for the session")
        self.assertIn(lua.eval("tostring(_G.HD2AutoChat.draw_errors)"), ("nil",),
                      "and must not take the panel down with it")

    def test_plugin_coordinates_are_offset_into_the_body(self):
        """A plugin lays out from its own top-left, not the panel's.

        The helpers a plugin receives are the panel's own, which expect panel
        coordinates. Without an offset a plugin drawing at (10, 10) lands on the header
        and the tab strip and covers them. The API offsets every coordinate past the
        header and tabs so the plugin body is the plugin's whole space.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        # A plugin that records where its own (0,0) actually landed.
        lua.execute("""
            local reg = rawget(_G, 'HD2AutoChatPlugins')
            _G.__seen = nil
            reg.register({id = 'probe_mod', title = 'PROBE',
                draw = function(u, ctx)
                    _G.__seen = {w = u.w, h = u.h, body_y = u.body_y, scale = u.scale}
                    u.rect(0, 0, 20, 10, u.palette.ROW)
                    u.text('X', 0, 0, 11)
                    u.region('hit', 0, 0, 20, 10)
                end})
            _G.HD2AutoChat.debug_panel().active_plugin = 'probe_mod'
        """)
        mod.debug_set_open(True)
        self._run(lua, 700)
        self._run(lua, 20)
        seen = lua.eval("_G.__seen")
        self.assertIsNotNone(seen, "the plugin's draw must have been reached")
        self.assertEqual(1000, seen["w"], "the plugin must be told the panel width")
        self.assertGreater(seen["body_y"], 0,
                           "the plugin body must start BELOW the header and tab strip, "
                           "not at the panel's own top")
        # And its region must have been recorded, offset with it. Checked in Lua: the
        # panel's regions are a Lua table, and reading them from Python mixes up the
        # indexing conventions.
        probe = lua.eval("""(function()
            local P = _G.HD2AutoChat.debug_panel()
            local n = P.regions and #P.regions or 0
            for i = 1, n do
                local r = P.regions[i]
                if tostring(r.key):find('plugin:probe_mod', 1, true) then
                    return {found = true, y = r.y, x = r.x, w = r.w, h = r.h}
                end
            end
            return {found = false, n = n}
        end)()""")
        self.assertTrue(probe["found"],
                        "the plugin's region must be recorded so its own controls are "
                        "clickable; regions seen: %s, plugin still registered: %s"
                        % (probe["n"],
                           lua.eval("tostring(rawget(_G.HD2AutoChat, 'PLUGIN_BY_ID')"
                                    "['probe_mod'] ~= nil)")))
        self.assertGreater(probe["y"], 0,
                           "a plugin's click region must be offset with its drawing, or "
                           "clicks land in the wrong place")

    def test_the_font_lookup_actually_reads_the_ids_without_faulting(self):
        """The lookup must get PAST the PE header and read the three ids.

        This is the test the missing `u32_off` needed and did not have. The lookup used
        to return "PE header unreadable" in every test -- the fixture had no PE header --
        so a call to a function that did not exist at all was never reached here, while in
        game it faulted on the first panel draw. The fixture now always carries a header,
        so the read path is genuinely exercised.
        """
        lua, h = fresh_image(font_ids=True)
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 700)
        self._run(lua, 20)
        self.assertIn(lua.eval("tostring(_G.HD2AutoChat.draw_errors)"), ("nil",),
                      "reading the font ids must not fault; it did, so the panel fell "
                      "back to the bitmap font (error: %s)"
                      % lua.eval("tostring(_G.HD2AutoChat.draw_error_text)"))
        font = mod.debug_font()
        self.assertTrue(font["resolved"], "the lookup must have been attempted")
        why = str(font["why"])
        self.assertNotIn("PE header unreadable", why,
                         "the lookup must get past the PE header; stopping there is how "
                         "the rest of the font path went untested")
        self.assertNotIn("nil value", why,
                         "the lookup reached a call to something that does not exist: %s"
                         % why)

    def test_the_real_font_path_reaches_gui_text(self):
        """Assert the font path is CALLED, not merely that drawing did not fault.

        The goal calls for exactly this, and it is the trap this file has fallen into
        twice: font_resolve was correct and called from nowhere, and later a missing
        u32_off made it fault on every attempt. Both times the panel still laid out and
        still recorded regions, so a test that only checks "the panel drew" passes while
        the text is secretly the bitmap fallback -- and the only symptom in game is "the
        UI looks wrong", which is how it was reported.

        So this one COUNTS the calls.
        """
        lua, h = fresh_image(font_ids=True)
        h.can_get = True                      # the engine reports its resources loaded
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 700)
        self._run(lua, 20)
        font = mod.debug_font()
        self.assertTrue(font["ok"],
                        "the engine font must resolve when the ids are present and the "
                        "resources are loaded; it reported: %s" % font["why"])
        self.assertGreaterEqual(h.material_made or 0, 1,
                                "resolving the font must create the ink material")
        self.assertGreaterEqual(h.text_drawn or 0, 1,
                                "Gui.text must actually be called; zero calls means the "
                                "panel is drawing the bitmap fallback while reporting "
                                "success")
        self.assertIn(lua.eval("tostring(_G.HD2AutoChat.draw_errors)"), ("nil",),
                      "and none of this may fault")

    def test_debug_font_path_never_converts_resource_path_as_hex(self):
        lua, h = fresh_image()  # no runtime UI font IDs: exercise debug font fallback
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 601)
        self.assertEqual(0, h.invalid_hex_calls or 0,
                         "a resource path must never reach native from_hex")
        self.assertTrue(mod.debug_font()["ok"], "loaded debug font must draw real text")
        self.assertGreater(h.text_drawn or 0, 0)

    def test_font_material_is_bound_again_when_gui_is_rebuilt(self):
        lua, h = fresh_image(font_ids=True)
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 601)
        made = h.material_made
        mod.debug_panel()["version"] = mod.debug_panel()["version"] + 1
        self._run(lua, 1)
        self.assertGreater(h.material_made, made,
                           "destroying a GUI also invalidates its material binding")

    def test_reused_native_gui_handle_still_rebinds_font(self):
        lua, h = fresh_image(font_ids=True)
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 601)
        lua.execute("""
            local handle = HD2AutoChat.debug_panel().gui
            local create = stingray.World.create_screen_gui
            stingray.World.create_screen_gui = function(...)
                create(...)
                return handle
            end
        """)
        made = h.material_made
        mod.debug_panel()["version"] = mod.debug_panel()["version"] + 1
        self._run(lua, 1)
        self.assertGreater(h.material_made, made,
                           "a new lifetime can reuse the same native handle")

    def test_the_bitmap_fallback_still_draws_when_the_font_is_unavailable(self):
        """The other direction: no ids, no fault, and the panel still lays out.

        A fallback that quietly drew nothing would be indistinguishable from a font
        problem, so the fallback has to be shown to produce a laid-out panel.
        """
        lua, h = fresh_image()                 # the image carries no font ids
        # And the engine reports its resources NOT loaded, so the debug-font fallback is
        # unavailable too. Without this the fallback SUCCEEDS and the bitmap path -- the
        # one that runs on a machine where the font never resolves -- goes untested.
        h.can_get = False
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 700)
        self._run(lua, 20)
        self.assertFalse(mod.debug_font()["ok"],
                         "with no ids and nothing loaded, no engine font can resolve")
        self.assertIn(lua.eval("tostring(_G.HD2AutoChat.draw_errors)"), ("nil",),
                      "the fallback must not fault")
        self.assertGreaterEqual(len(mod.debug_panel()["regions"]), 4,
                                "the panel must still lay out on the fallback path")

    def test_source_declares_no_write_symbol(self):
        for symbol in ("writeprocessmemory", "virtualallocex",
                       "createremotethread", "virtualprotectex"):
            self.assertNotIn(symbol, self.source.lower(),
                             "this is a read-only probe; %s must not appear" % symbol)

    def test_runtime_event_and_reader_diagnostics_are_wired_sanitized_and_fifo_deduplicated(self):
        self.assertIn('diagnostic = function(...) return M.record_event_diagnostic(...) end,', self.source)
        self.assertIn('diagnostic = function(...) return M.record_ping_drop(...) end,', self.source)
        lua,h,mod=self.fresh()
        self.assertTrue(mod.record_event_diagnostic('stratagem','summon','stratagem_4119049995',
            'rule-disabled','squad'))
        self.assertFalse(mod.record_event_diagnostic('stratagem','summon','stratagem_4119049995',
            'rule-disabled','squad'))
        self.assertTrue(mod.record_ping_drop('unknown_target_or_generic_name',18,3,True,4234884333,
            'DC19126D15692D04'))
        self.assertFalse(mod.record_ping_drop('unknown_target_or_generic_name',18,3,True,4234884333,
            'DC19126D15692D04'))
        lines=[str(mod.debug_runtime_diagnostics()[i])
               for i in range(1,len(mod.debug_runtime_diagnostics())+1)]
        self.assertEqual(2,len(lines),lines)
        self.assertIn('category=stratagem action=summon id=stratagem_4119049995 result=rule-disabled output=squad',lines[0])
        self.assertIn('reason=unknown_target_or_generic_name kind=18 map=3 target=true key=4234884333 resource=DC19126D15692D04',lines[1])
        for line in lines:
            self.assertNotIn('Alice',line)
            self.assertNotIn('message=',line)

        self.assertTrue(mod.record_runtime_diagnostic('event','oldest','line-oldest'))
        for i in range(1,65):
            self.assertTrue(mod.record_runtime_diagnostic('event','unique-%d'%i,'line-%d'%i))
        lines=[str(mod.debug_runtime_diagnostics()[i])
               for i in range(1,len(mod.debug_runtime_diagnostics())+1)]
        self.assertEqual(64,len(lines))
        self.assertEqual('line-64',lines[-1])
        self.assertTrue(mod.record_runtime_diagnostic('event','oldest','line-oldest-again'))
        self.assertEqual(64,len(mod.debug_runtime_diagnostics()))
        self.assertEqual('line-oldest-again',str(mod.debug_runtime_diagnostics()[64]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
