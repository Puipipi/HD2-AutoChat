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
import re
import sys
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
    if ctype == 'uint8_t[?]' then
        return setmetatable({n = arg, chars = {}, text = ''}, Bytes)
    end
    if ctype == 'size_t[1]' then
        return setmetatable({0, n = 1}, {__index = function() return 0 end})
    end
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
    for i = 1, #str do mem[address + i - 1] = str:sub(i, i) end
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
    local bytes = le_bytes(value, 4)
    for i = 1, 4 do mem[address + i - 1] = bytes[i] end
end

function harness.u64(address, value)
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
        return nil
    end
    -- A per-address byte cache. The naive version rebuilt a Lua table on every
    -- read, which made a 600-frame test take tens of seconds; this keeps the
    -- suite fast enough that nobody is tempted to skip it.
    function kernel.ReadProcessMemory(process, address, buf, size, got)
        harness.reads = harness.reads + 1
        address = unwrap(address)
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
    function kernel.QueryPerformanceCounter() return 1 end
    -- The mod requires this at boot (it compares the foreground window's pid to its
    -- own before honouring the hotkey), so the mock must provide it or the mod
    -- stops at "missing kernel32 symbol".
    harness.own_pid = harness.own_pid or 4242
    function kernel.GetCurrentProcessId() return harness.own_pid end

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
            unwrap(out)[0] = harness.own_pid or 4242
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
    harness.main_world = 'WORLD_MAIN'
    _G.stingray = {
        Application = {
            main_world = function() return harness.main_world end,
            worlds = function() return {harness.main_world} end,
        },
        Gui = {
            resolution = function() return harness.res_w or 1920, harness.res_h or 1080 end,
            rect = function(gui, position, size, colour) end,
        },
        Vector3 = function(x, y, z) return {x = x, y = y, z = z} end,
        Vector2 = function(x, y) return {x = x, y = y} end,
        Color = function(a, r, g, b) return {a = a, r = r, g = g, b = b} end,
        IdString64 = {from_hex = function(s) return s end},
        World = {
            create_screen_gui = function(world, ...)
                harness.gui_created = harness.gui_created + 1
                harness.live_guis = harness.live_guis + 1
                return {world = world, id = harness.gui_created}
            end,
            destroy_gui = function(world, gui)
                harness.gui_destroyed = harness.gui_destroyed + 1
                harness.live_guis = harness.live_guis - 1
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
        if mode == nil or tostring(mode):find('r') then return real_open(path, mode) end
        if tostring(path):find('AutoChat', 1, true) then
            return {
                write = function(_, text) written[#written + 1] = {path = path, text = text} end,
                close = function() end,
            }
        end
        return real_open(path, mode)
    end
    function harness.written() return written end

    -- The loader's frame callback that everything chains onto.
    harness.update_calls, harness.shutdown_calls = 0, 0
    _G.update = function(...)
        harness.update_calls = harness.update_calls + 1
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
        cls.source = io.open(SOURCE, encoding="utf-8").read()

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

    # ------------------------------------------------------------ timed send
    def test_timed_send_does_nothing_until_the_interval_elapses(self):
        lua, h = fresh_image(others=1)
        mod = h.load(SOURCE)
        cfg = mod.debug_cfg()
        cfg["timer_on"] = False
        before = h.call_count()
        mod.debug_timed_send(1000)
        self.assertEqual(before, h.call_count(),
                         "with the timer off nothing may be sent even with peers present")

    def test_timed_send_respects_the_peer_guard(self):
        """The timer must NOT bypass the guard: solo means refused, with a reason.

        The whole point of the peer guard is that broadcasting into a session with
        nobody in it reaches nobody. A timed send that skipped it would fire on a
        loop forever with no recipient, which is the failure this pins.
        """
        lua, h = fresh_image(others=0)
        mod = h.load(SOURCE)
        cfg = mod.debug_cfg()
        cfg["timer_on"] = True
        cfg["interval"] = 10
        cfg["elapsed"] = 0
        before = h.call_count()
        mod.debug_timed_send(11)            # past the interval
        self.assertEqual(before, h.call_count(),
                         "a timed send into a session with nobody else in it must be "
                         "refused; the timer is not a way around the peer guard")

    def test_timed_send_uses_the_normal_path_when_peers_exist(self):
        """With another player present the timer sends for real, through the same
        verified call the manual trigger uses."""
        lua, h = fresh_image(others=1)
        mod = h.load(SOURCE)
        cfg = mod.debug_cfg()
        cfg["timer_on"] = True
        cfg["interval"] = 10
        cfg["elapsed"] = 0
        before = h.call_count()
        mod.debug_timed_send(11)
        self.assertEqual(before + 1, h.call_count(),
                         "with a peer present the timer must make exactly one send")

    def test_timed_send_fires_once_per_interval_and_resets(self):
        lua, h = fresh_image(others=1)
        mod = h.load(SOURCE)
        cfg = mod.debug_cfg()
        cfg["timer_on"] = True
        cfg["interval"] = 10
        cfg["elapsed"] = 0
        mod.debug_timed_send(4)
        self.assertAlmostEqual(4, cfg["elapsed"], places=3,
                               msg="elapsed must accumulate below the interval")
        mod.debug_timed_send(4)
        self.assertAlmostEqual(8, cfg["elapsed"], places=3)
        # Crossing the interval resets the accumulator whether or not the send was
        # accepted, so a refused send cannot pile up and then burst.
        mod.debug_timed_send(4)
        self.assertAlmostEqual(0, cfg["elapsed"], places=3,
                               msg="crossing the interval must reset the accumulator")

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

    def test_panel_rows_do_not_overlap_and_are_clickable(self):
        """Each row must have a positive height and must not sit inside another.

        Overlapping hit-boxes would make a click land on whichever row is iterated
        first, so "INTERVAL -" could fire "CLOSE PANEL" instead.
        """
        lua, h, mod = self.fresh()
        for rw, rh in ((1920, 1080), (3840, 2160), (1280, 720), (1024, 768)):
            geo = mod.debug_geometry(rw, rh)
            # A Lua sequence arrives in Python as a 1-based mapping, not a list.
            rows = geo["rows"]
            count = len(rows)
            self.assertEqual(4, count, "%dx%d: expected four rows" % (rw, rh))
            spans = []
            for index in range(1, count + 1):
                row = rows[index]
                self.assertGreater(row["h"], 0,
                                   "%dx%d row %d: hit-box height must be positive"
                                   % (rw, rh, index))
                spans.append((index, row["y"], row["y"] + row["h"]))
            spans.sort(key=lambda s: s[1])
            for (i1, lo1, hi1), (i2, lo2, hi2) in zip(spans, spans[1:]):
                self.assertLessEqual(hi1, lo2 + 1e-9,
                                     "%dx%d: rows %d and %d overlap (%.2f > %.2f)"
                                     % (rw, rh, i1, i2, hi1, lo2))

    # --------------------------------------------------- panel GUI lifecycle
    def _run(self, lua, frames):
        for _ in range(frames):
            lua.eval("_G.update()")

    def test_closing_the_panel_destroys_its_gui(self):
        """A retained screen GUI keeps drawing what was put in it.

        So a panel that is merely "not updated any more" stays on screen and sits on
        top of the HUD. Closing must DESTROY the gui, and the panel must be openable
        again -- otherwise it works exactly once per session.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        self.assertEqual(0, h.live_guis, "nothing may be created while closed")

        mod.debug_set_open(True)
        self._run(lua, 20)
        self.assertEqual(1, h.gui_created,
                         "opening must create exactly ONE gui; creating one per frame "
                         "would leak an engine object every frame")
        self.assertEqual(1, h.live_guis, "and exactly one must be live")

        mod.debug_set_open(False)
        self._run(lua, 5)
        self.assertEqual(0, h.live_guis,
                         "closing must destroy the gui, not just stop drawing into it")
        self.assertEqual(1, h.gui_destroyed, "exactly one destroy per open")

    def test_panel_can_be_reopened_in_the_same_session(self):
        """Reopening must rebuild, and must not leak the previous gui."""
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        for cycle in (1, 2, 3):
            mod.debug_set_open(True)
            self._run(lua, 20)
            self.assertEqual(1, h.live_guis,
                             "cycle %d: opening must leave exactly one live gui"
                             % cycle)
            self.assertEqual(cycle, h.gui_created,
                             "cycle %d: one gui built per open, no more" % cycle)
            mod.debug_set_open(False)
            self._run(lua, 5)
            self.assertEqual(0, h.live_guis, "cycle %d: close must destroy" % cycle)
        self.assertEqual(3, h.gui_destroyed, "every gui must be destroyed exactly once")

    def test_an_idle_open_panel_does_not_rebuild_every_frame(self):
        """The whole point of the signature: a static panel must stop rebuilding.

        Rebuilding per frame would work visually and quietly burn the frame budget,
        which is the class of problem a frame watchdog reports.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 20)
        settled = h.gui_created
        self._run(lua, 300)          # nothing changes: no input, no timer
        self.assertEqual(settled, h.gui_created,
                         "an idle panel rebuilt %d times over 300 frames; the signature "
                         "must make it stop" % (h.gui_created - settled))

    def test_shutdown_destroys_the_panel(self):
        """Unloading the mod must not leave a gui behind in the world."""
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 120)
        self.assertEqual(1, h.live_guis)
        lua.eval("_G.shutdown()")
        self.assertEqual(0, h.live_guis,
                         "shutdown must release the gui it created")

    def test_no_gui_is_created_before_the_world_is_ready(self):
        """Creating a screen gui too early faults at NATIVE level, which pcall cannot
        catch, so the frame gate before it must hold."""
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        mod.debug_set_open(True)
        self._run(lua, 599)          # the gate opens at frame 600
        self.assertEqual(0, h.gui_created,
                         "no gui may be created before the frame gate opens")
        self._run(lua, 90)
        self.assertGreaterEqual(h.gui_created, 1,
                                "after the gate opens the panel must build")

    def test_resolution_change_forces_a_rebuild(self):
        """Geometry is derived from the resolution, so a change must rebuild.

        Without it the panel keeps rendering last resolution's layout -- a retained
        gui does not reflow on its own.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 120)
        before = h.gui_created
        h.res_w, h.res_h = 2560, 1440
        self._run(lua, 10)
        self.assertGreater(h.gui_created, before,
                           "a resolution change must rebuild the gui")

    def test_a_panel_fault_is_logged_and_then_bounded(self):
        """A fault inside the panel must be visible, and must not flood the log.

        Wrapped in the generic frame pcall a panel fault is swallowed: the panel just
        never appears and nothing says why. This is not hypothetical -- a mock that
        could not allocate `uint32_t[1]` made the mouse path raise on every frame and
        the only symptom was a panel that did not show. The fault is logged a few
        times and then suppressed, so a per-frame failure cannot fill the log.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 10)
        self.assertEqual(1, h.live_guis, "the panel should be up before we break input")

        # mouse_state calls this with no pcall of its own, so breaking it raises
        # inside panel_frame -- exactly the kind of fault that used to vanish.
        lua.execute("""
            local ffi = require('ffi')
            local u = ffi.load('user32')
            u.GetCursorPos = nil
        """)
        self._run(lua, 40)
        errors = lua.eval("_G.HD2AutoChat.panel_errors")
        self.assertIsNotNone(errors, "the panel fault must be counted")
        self.assertGreaterEqual(errors, 1, "the fault must have been observed")
        logged = [r for r in h.records
                  if "panel_error" in str(r.get("text", ""))]
        self.assertLessEqual(len(logged), 6,
                             "a per-frame panel fault must be suppressed after a few "
                             "log lines, not written every frame")

    def test_a_world_change_does_not_fault_the_panel(self):
        """The world change path calls teardown, and it faulted in the real game.

        `world_ready` runs before `panel_clear` is assigned in the file, so calling
        teardown from there hit a nil global: "attempt to call global 'panel_clear'".
        The panel still opened, so the only symptom was a panel that misbehaved later,
        and it was found in a live session rather than here. The unit tests never
        changed the world, which is exactly why this test now does.
        """
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 20)
        self.assertEqual(1, h.live_guis, "the panel should be up first")
        before_destroyed = h.gui_destroyed

        h.main_world = "WORLD_SOMEWHERE_ELSE"      # ship -> mission, or back
        self._run(lua, 20)
        errors = lua.eval("_G.HD2AutoChat.panel_errors")
        self.assertIn(errors, (None, 0),
                      "a world change must not fault the panel (panel_errors=%s)"
                      % errors)
        self.assertGreater(h.gui_destroyed, before_destroyed,
                           "the gui made for the old world must be destroyed")
        self.assertEqual(1, h.live_guis,
                         "and exactly one fresh gui must serve the new world")

    def test_no_forward_reference_calls_a_name_declared_later(self):
        """Static tripwire for the trap that produced the nil `panel_clear` call.

        A `local` declared below its reader is not in scope there: the name silently
        becomes a GLOBAL read, so the failure is a nil call at run time, inside a
        pcall, with no compile error. This checks the two functions that are called
        from code defined above them are forward-declared, which is the only shape
        that works.
        """
        src = self.source
        # Both must be declared as bare locals before use, and assigned later.
        for name in ("set_panel_open", "panel_clear"):
            self.assertIn("local %s\n" % name, src,
                          "%s must be forward-declared as a bare local before any "
                          "closure captures it" % name)
            self.assertIn("%s = function" % name, src,
                          "%s must be assigned (not re-declared with `local "
                          "function`) so the forward declaration is the one used"
                          % name)
            self.assertNotIn("local function %s(" % name, src,
                             "%s must not also be declared with `local function`: that "
                             "creates a SECOND local, and the earlier readers keep "
                             "pointing at the nil forward declaration" % name)

    def test_a_stuck_cursor_is_recovered_at_boot(self):
        """A pointer left visible by a crashed session must come back at next load.

        release_cursor() is a no-op unless THIS Lua state took the cursor. If the game
        dies with the panel open, `taken` dies with it and the cursor stays visible
        forever -- and reloading the mod cannot help, because the new instance has no
        memory of the old one. The user hit exactly this.

        Boot therefore resets unconditionally, without consulting saved state, so it
        works from a cold start.
        """
        lua, h = fresh_image()
        # Simulate the aftermath: the Win32 display counter is positive (visible) and
        # the clip rectangle is whatever the dead session left behind.
        for _ in range(3):
            h.user32_show(True)
        h.user32_set_clip(0, 0, 100, 100)
        self.assertTrue(h.user32.cursor_visible(),
                        "precondition: the cursor must start out stuck visible")

        mod = h.load(SOURCE)          # boot runs here
        self.assertFalse(h.user32.cursor_visible(),
                         "loading the mod must put a stuck cursor back")
        self.assertIsNone(h.user32.clip(),
                          "and must clear the clip rectangle so the pointer can move")

    def test_shutdown_releases_the_cursor(self):
        lua, h = fresh_image()
        mod = h.load(SOURCE)
        self._run(lua, 700)
        mod.debug_set_open(True)
        self._run(lua, 10)
        self.assertTrue(h.user32.cursor_visible(),
                        "the panel should have shown the cursor")
        lua.eval("_G.shutdown()")
        self.assertFalse(h.user32.cursor_visible(),
                         "shutdown must not leave the cursor visible")

    def test_source_declares_no_write_symbol(self):
        for symbol in ("writeprocessmemory", "virtualprotect", "virtualallocex",
                       "createremotethread"):
            self.assertNotIn(symbol, self.source.lower(),
                             "this is a read-only probe; %s must not appear" % symbol)


if __name__ == "__main__":
    unittest.main(verbosity=2)
