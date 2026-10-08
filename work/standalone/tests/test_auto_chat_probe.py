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
import sys
import unittest

try:
    import lupa.luajit21 as luajit
except ImportError:  # pragma: no cover
    sys.exit("lupa is required: python -m pip install lupa")

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
local function ptr(value) return setmetatable({value = value}, cptr) end
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
        if type(value) == 'table' and getmetatable(value) == cptr then return value.value end
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
    harness.calls = {}
    ffi.cast = function(ctype, value)        if type(ctype) == 'string' and ctype:find('%(') then
            local address = unwrap(value)
            harness.calls[#harness.calls + 1] = {address = address}
            return function(a1, a2, a3)
                -- Record plain numbers/strings as well as the raw arguments. A
                -- cdata pointer does not survive the trip into Python as anything
                -- useful, so the numeric summary is what a test compares.
                local top = harness.calls[#harness.calls]
                top.args = {a1, a2, a3}
                top.arg1_address = type(a1) == 'table' and a1.value or a1
                top.arg2 = a2
                top.arg3_text = type(a3) == 'table' and a3.text or tostring(a3)
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

    ffi.load = function(name)
        if name == 'kernel32' then return kernel end
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
function harness.call_count() return #harness.calls end
function harness.last_call() return harness.calls[#harness.calls] end
function harness.call_at(i) return harness.calls[i] end

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

        ok, others = lua.eval("(function() return _G.HD2AutoChat.send_text('hello', false) end)()")
        self.assertTrue(ok, "sending should be accepted when a peer is present")
        self.assertEqual(1, others, "one other player besides us")

        self.assertEqual(1, h.call_count(), "exactly one native call")
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
        ok, why = lua.eval("(function() return _G.HD2AutoChat.send_text('hi', false) end)()")
        self.assertFalse(ok, "an empty session must be refused")
        self.assertIn("nobody else", why)
        self.assertEqual(1, h.call_count(),
                         "a refused send must not call the native (the only native "
                         "call is the one that produced the function pointer)")

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
                         "no native call may happen after a mismatch")

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

    # ---------------------------------------------------------------- static cost
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
    def test_source_declares_no_user32_symbol(self):
        lowered = self.source.lower()
        for symbol in ("getcursorpos", "getasynckeystate", "getforegroundwindow",
                       "screentoclient", "getclientrect", "getwindowthreadprocessid",
                       "getcurrentprocessid", "showcursor", "clipcursor"):
            self.assertNotIn(symbol, lowered,
                             "%s would clobber another mod's ffi.cdef" % symbol)

    def test_source_declares_no_write_symbol(self):
        for symbol in ("writeprocessmemory", "virtualprotect", "virtualallocex",
                       "createremotethread"):
            self.assertNotIn(symbol, self.source.lower(),
                             "this is a read-only probe; %s must not appear" % symbol)


if __name__ == "__main__":
    unittest.main(verbosity=2)
