-- HD2-Addon: mods/codex/auto_chat
-- ===========================================================================
--  自动聊天 / Auto Chat —— 只读探针 (v0.1.0)
--
--  目标功能（还没做）：不打开聊天栏，直接把一条文字聊天发给小队。
--
--  为什么能绕开聊天栏：
--    游戏自己的聊天框做四件事——夺取键鼠、画框、收集按键、调用发送。
--    "把玩家卡在聊天栏"的是前两件。我们只要最后一件：
--      ctx+0xC418 的聊天对象  +  game.dll+0x1097560 的发送函数
--    这是聊天框自己也调的同一套东西，所以不需要聊天框在场。
--    这不是猜的：第三方模组 mods/cowboybingus/better_lobby_management
--    已经这么发了，本文件的偏移与机器码全部取它的源码记录。
--
--  本版本（0.1.0）做什么：
--    **只读。** 一个字节都不写，一条包都不发。
--    校验那 5 段机器码是否仍然对得上，并把观测结果写进日志与 STATUS 文件。
--    签名对不上就整局停手并说明是哪一段变了——绝不拿没验证的地址去调。
--
--  红线（与仓库其余模组一致）：
--    * ffi.cdef 里**不出现 user32 符号**（LuaJIT 的 C 命名空间是进程全局的，
--      重复声明会静默保留第一条，曾弄坏过别的模组）；
--    * 只在已提交、可读、非 guard 的页上读；每次读取都有界；
--    * 结算数（frame 数、读次数、字节数）写进日志，绝不每帧刷屏；
--    * update/shutdown 一定调回上一个，绝不断链。
-- ===========================================================================
local M = {version = '0.2.8', status = 'starting', frames = 0, reads = 0,
           bytes = 0, errors = 0, signature = 'unknown', sent = 0,
           send_ready = false}

-- The loader may evaluate an entry more than once. Without this guard you get
-- two copies of the state, and the second one silently wins.
local KEY = 'HD2AutoChat'
if rawget(_G, KEY) then return rawget(_G, KEY) end

M.status = 'boot'
rawset(_G, KEY, M)
-- Filled in by boot() once the signatures have matched. Declared here, above
-- every function that reads them: a `local` declared below its reader is not in
-- scope there, and the name silently becomes a global read (nil).
local game, game_base, send_fn = nil, nil, nil
local chat_buffer, chat_args = nil, nil
local verified, verify_reason = false, 'not run'

-- ---------------------------------------------------------------- environment
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then
    M.status = 'no ffi'
    return M
end
if ffi.os ~= 'Windows' or not ffi.abi('64bit') then
    M.status = 'not windows x64'
    return M
end
local loader = rawget(_G, 'CowboyBingusModLoader')
if type(loader) ~= 'table' or type(loader.api) ~= 'number' or loader.api < 1
    or type(loader.version) ~= 'number' or loader.version < 15 then
    M.status = 'needs bingus shared loader v15+ (api 1)'
    return M
end

-- ---------------------------------------------------------------- 1. platform
-- Read path only. No write symbol is declared and no user32 symbol appears.
--
-- The prototypes are not free choices. LuaJIT's C namespace is process-global and
-- `ffi.cdef` KEEPS THE FIRST declaration, so whatever another mod registered wins
-- and this block is a silent no-op. `VirtualQuery` is the dangerous one: the
-- majority of mods in this workspace declare it as returning `size_t` (the byte
-- count, 48 on success), and one group uses `int`. If the other spelling is
-- already registered, a `== 0` failure test reads the wrong value and the page
-- guard stops guarding -- which is exactly the state that produces a crash the
-- real code would have prevented. So this declares the majority spelling and
-- compares against 48, and it only ever CALLS it after the signature check.
local cdef_ok, cdef_err = pcall(ffi.cdef, [[
    void *GetCurrentProcess(void);
    void *GetModuleHandleA(const char *module_name);
    int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
    size_t VirtualQuery(const void *address, void *info, size_t length);
    int CreateDirectoryA(const char *path, void *security);
    int QueryPerformanceCounter(int64_t *counter);
]])
if not cdef_ok then
    M.status = 'cdef failed: ' .. tostring(cdef_err)
    return M
end
-- Wrapped in a function on purpose: `pcall(ffi.load, 'kernel32')` passes the C
-- function unbound, and in a host that exposes `ffi.load` as a Python-implemented
-- callable the name argument arrives as the wrong value entirely. The mod family
-- already writes it this way for the same reason.
local kernel_ok, kernel_or_err = pcall(function() return ffi.load('kernel32') end)
local kernel = kernel_ok and kernel_or_err or nil
if not kernel then
    M.status = 'kernel32 unavailable'
    return M
end
local READ_SYMBOLS = {'GetCurrentProcess', 'GetModuleHandleA', 'ReadProcessMemory',
                      'VirtualQuery', 'QueryPerformanceCounter'}
for _, name in ipairs(READ_SYMBOLS) do
    local value = kernel[name]
    -- In LuaJIT a loaded C function is cdata, not a Lua function.
    if type(value) ~= 'cdata' and type(value) ~= 'function' then
        M.status = 'missing kernel32 symbol: ' .. name
        return M
    end
end
local process = kernel.GetCurrentProcess()

-- ---------------------------------------------------------------- 2. constants
-- Every absolute address below is an observation of ONE build. They are only
-- ever used after `verify()` has confirmed the code signatures. Source of the
-- numbers: mods/cowboybingus/better_lobby_management (third-party, read-only).
M.GAME_DLL = 'game.dll'
-- Steam build 25480438 / EXE 1.8.46015.0, read from this machine's install.
M.BUILD_DLL_SIZE = 15522408
M.BUILD_DLL_SHA = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

M.CONTEXT_PTR = 0x347cef0     -- game.dll + this -> network context (0 when offline)
M.PEER_COUNT  = 0x16390       -- context + this -> uint32 peers in the session
M.PEERS       = 0x16398       -- context + this -> peer array (32-byte stride)
M.PEER_STRIDE = 32
M.MAX_PEERS   = 4
-- context + this -> the local player's peer id. The reference mod calls the
-- accessor and compares whole u64 ids; only the low 32 bits are read here, which
-- is exact (no double rounding) and sufficient to identify our own entry.
M.LOCAL       = 0xb398

M.CHAT_OBJECT   = 0xc418      -- context + this -> the game's text chat object
M.HISTORY_FIRST = 0x9590      -- chat + this -> uint32 ring index of the oldest line
M.HISTORY_COUNT = 0x9594      -- chat + this -> uint32 lines currently held (max 64)
-- The ring's shape, read out of the game's own history accessor rather than
-- guessed: the accessor masks the index with 0x3f and multiplies by 0x228, so
-- there are 64 slots of 552 bytes each.
M.HISTORY_SLOTS = 64
M.HISTORY_STRIDE = 0x228
-- chat + this -> the first ring slot. DERIVED, not guessed: four messages sent
-- back to back were located by exact byte match at chat+0xBA0, +0xDC8, +0xFF0,
-- +0x1218 -- 0x228 apart, matching the stride -- and the text sits at entry+0x208,
-- so slot 0's entry base is 0xBA0-0x208 = 0x998. An earlier revision used 0x9598
-- (a slipped digit) which read pointer bytes and reported noise like "p_".
M.HISTORY_BASE = 0x998
M.HISTORY_TEXT_AT = 0x208      -- entry + this -> the message text
M.HISTORY_TEXT_SCAN = 0x140   -- how far into a slot to look for the text

-- The send entry point and its call shape. This is the one offset the whole mod
-- exists to use, and it is only ever called after its 32-byte signature matched.
M.SEND_RVA  = 0x1097560
M.SEND_TYPE = 'void (*)(uint64_t, int, const char *)'
M.MAX_TEXT  = 512             -- the game drops a line longer than this
M.REGION_PROBE = 4096         -- how far past the chat object to look for its strings

-- Verified machine-code prefixes. Each is only as long as the part whose
-- meaning is actually understood; the byte strings in the third-party source
-- continue past this with an un-recomputed rip-relative displacement, and
-- asserting bytes nobody reasoned about would turn a relink into a false alarm.
M.CODE = {
    {rva = 0x1097560, name = 'chat send',
     bytes = '\65\86\65\87\72\129\236\120\4\0\0\72\139\5\158\74\90\1\72\51\196\72\137\132\36\80\4\0\0\128\57\0'},
    {rva = 0xbde430, name = 'rpc send',
     bytes = '\64\83\85\86\87\65\86\65\87\72\129\236\152\0\0\0\72\139\5\201\219\165\1\72\51\196\72\137'},
    {rva = 0x186025d, name = 'chat box send',
     bytes = '\72\139\13\140\204\193\1\76\141\135\212\22\0\0\72\129\193\24\196\0\0'},
    {rva = 0xbeb103, name = 'chat message rpc',
     bytes = '\65\185\1\0\0\0\72\139\215\185\142\184\221\159\232\26'},
    {rva = 0x1097a7c, name = 'chat history',
     bytes = '\139\135\148\149\0\0\139\143\144\149\0\0'},
}

-- ---------------------------------------------------------------- 3. primitives
local MIN_PTR, MAX_PTR = 0x10000, 0x00007FFFFFFFFFFF
-- A double that cannot be a x64 user-mode pointer (negative, fractional, or
-- >= 2^64) makes ffi.cast raise. Refuse it before it reaches the FFI layer.
local function sane_ptr(v)
    if type(v) ~= 'number' then return false end
    if v ~= math.floor(v) or v < MIN_PTR or v > MAX_PTR then return false end
    return true
end
local function hex(n)
    if type(n) ~= 'number' or n ~= n then return tostring(n) end
    n = math.floor(n)
    if n <= 0 then return '0x0' end
    local digits, out = '0123456789ABCDEF', ''
    while n > 0 do
        local r = n % 16
        out = digits:sub(r + 1, r + 1) .. out
        n = (n - r) / 16
    end
    return '0x' .. out
end
local function bhex(s)
    if type(s) ~= 'string' then return '' end
    return (s:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

-- Read up to 1 MiB from our own process. Returns nil unless the whole request
-- was satisfied, so a partial read can never be mistaken for a full one.
local function read_at(address, size)
    if not sane_ptr(address) then return nil end
    if type(size) ~= 'number' or size <= 0 or size > 0x100000 then return nil end
    local buf = ffi.new('uint8_t[?]', size)
    local got = ffi.new('size_t[1]')
    if kernel.ReadProcessMemory(process, ffi.cast('void *', address),
                                buf, size, got) == 0 then return nil end
    if tonumber(got[0]) ~= size then return nil end
    M.reads, M.bytes = M.reads + 1, M.bytes + size
    return ffi.string(buf, size)
end
-- Bounded scalar reads. nil means "could not read", never "zero".
local function u32(address)
    local s = read_at(address, 4)
    if not s then return nil end
    return s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536 + s:byte(4) * 16777216
end
local function u64(address)
    local lo, hi = u32(address), u32(address + 4)
    if not lo or not hi then return nil end
    local value = lo + hi * 4294967296
    if value ~= math.floor(value) then return nil end
    return value
end

-- Page guard, mirroring the failure catalog: never touch a page that is not
-- committed and readable, and never touch a guard page. MEMORY_BASIC_INFORMATION
-- is 48 bytes on x64; only State (+0x20), Protect (+0x24) and RegionSize (+0x18)
-- are needed, so raw offsets are used instead of a ctype (one less thing to get
-- wrong).
local MEM_COMMIT, PAGE_GUARD, PAGE_NOACCESS = 0x1000, 0x100, 0x01
local MBI_SIZE = 48          -- MEMORY_BASIC_INFORMATION on x64
local function page_state(address)
    if not sane_ptr(address) then return nil end
    local info = ffi.new('uint8_t[?]', MBI_SIZE)
    -- 48 bytes on success. Anything else means the query failed; `~= 48` is
    -- correct for both the size_t and the int spelling because a failure is 0 in
    -- both, and a success is 48 in both.
    if kernel.VirtualQuery(ffi.cast('const void *', address), info, MBI_SIZE) ~= MBI_SIZE then
        return nil
    end
    local function at(offset)
        return info[offset] + info[offset + 1] * 256 + info[offset + 2] * 65536
             + info[offset + 3] * 16777216
    end
    return {state = at(0x20), protect = at(0x24), region = at(0x18)}
end
local function readable(address, size)
    local page = page_state(address)
    if not page then return false, 'VirtualQuery failed' end
    if page.state ~= MEM_COMMIT then return false, 'not committed' end
    local p = page.protect
    if p == 0 or p == PAGE_NOACCESS then return false, 'no access' end
    if p >= PAGE_GUARD then return false, 'guard page' end
    if size and page.region and page.region < size then return false, 'page too small' end
    return true
end

-- ---------------------------------------------------------------- 4. logging
local HOME = (os.getenv('LOCALAPPDATA') or os.getenv('TEMP') or '.')
             .. '/CowboyBingus/Helldivers2/'
local LOG = HOME .. 'Logs/AutoChat.log'
local STATUS = HOME .. 'AutoChat/AutoChat-STATUS.txt'
-- Drop text in here to have it sent as a chat line; see poll_trigger().
local TRIGGER = HOME .. 'AutoChat/trigger.txt'
local function mkdir(path) pcall(kernel.CreateDirectoryA, path:gsub('/', '\\'), nil) end
mkdir(HOME)
mkdir(HOME .. 'Logs')
mkdir(HOME .. 'AutoChat')

local log_open = true
local function note(line)
    if not log_open then return end
    local handle = io.open(LOG, 'a')
    if not handle then log_open = false return end
    local ok = pcall(function()
        handle:write(string.format('%s %s\n', os.date('!%Y-%m-%dT%H:%M:%SZ'), line))
        handle:close()
    end)
    if not ok then log_open = false end
end

local function write_status(extra)
    local handle = io.open(STATUS, 'w')
    if not handle then return end
    local lines = {
        'AutoChat / 自动聊天  v' .. M.version .. '  (SEND CAPABLE / 可发送)',
        'status      : ' .. tostring(M.status),
        'signature   : ' .. tostring(M.signature),
        'send ready  : ' .. tostring(M.send_ready),
        'messages sent: ' .. tostring(M.sent or 0),
        'frames      : ' .. tostring(M.frames),
        'reads       : ' .. tostring(M.reads) .. '  (' .. tostring(M.bytes) .. ' bytes)',
        'errors      : ' .. tostring(M.errors),
        'module base : ' .. tostring(M.game_base_text or '-'),
        'log         : ' .. LOG,
        '',
        'Sends a chat line without opening the chat box; never takes input.',
        '不打开聊天栏即可发送聊天；从不夺取输入。',
    }
    if extra then lines[#lines + 1] = extra end
    pcall(function()
        handle:write(table.concat(lines, '\r\n') .. '\r\n')
        handle:close()
    end)
end

-- ---------------------------------------------------------------- 5. signatures
-- Runs exactly once. On any mismatch the probe goes dormant: a changed
-- signature means the recorded offsets no longer describe this binary, and
-- using them anyway is how a mod crashes the game from inside a pcall.
local game, game_base = nil, nil
local verified, verify_reason = false, 'not run'

local function module_base(name)
    local handle = kernel.GetModuleHandleA(name)
    if handle == nil or handle == ffi.NULL then return nil end
    return tonumber(ffi.cast('uintptr_t', handle))
end

local function verify()
    local base = module_base(M.GAME_DLL)
    if not base then return false, 'game.dll not loaded' end
    if not sane_ptr(base) then
        return false, string.format('game.dll base %s is not a plausible pointer', tostring(base))
    end
    game, game_base = base, base
    M.game_base_text = hex(base)

    local failed = {}
    for _, entry in ipairs(M.CODE) do
        local address = base + entry.rva
        local want = #entry.bytes
        local got = read_at(address, want)
        if not got then
            failed[#failed + 1] = string.format('%s @%s unreadable', entry.name, hex(entry.rva))
        elseif got ~= entry.bytes then
            failed[#failed + 1] = string.format('%s @%s mismatch\n      want %s\n      got  %s',
                entry.name, hex(entry.rva), bhex(entry.bytes), bhex(got))
        end
    end
    if #failed > 0 then
        return false, table.concat(failed, '\n      ')
    end
    return true, 'all ' .. tostring(#M.CODE) .. ' code signatures match'
end

-- ---------------------------------------------------------------- 5b. sending
-- The whole point of the mod: hand text to the game's own chat send without the
-- chat box ever existing, so nothing seizes the keyboard and mouse.
--
-- The send is a 3-argument native call: (chat object, 0, UTF-8 text buffer). The
-- second argument is 0 in the reference call site and its meaning is NOT
-- established here - it is passed through exactly as observed rather than guessed
-- at. The text buffer must be a NUL-terminated C string; the game sends at most
-- 512 bytes and silently drops a line that is not valid UTF-8.

-- text cut to at most max bytes WITHOUT splitting a UTF-8 sequence. A truncated
-- multi-byte character makes the game drop the whole line.
--
-- The cut is placed by walking FORWARD and remembering the last position at which
-- a character ended, rather than by stepping back from the cut. Stepping back is
-- wrong for anything but 2-byte sequences: it removes one byte, lands on another
-- continuation byte, and a length check on the result then sees a legal-looking
-- multiple of 3 while the bytes are in fact invalid. (That bug was caught by the
-- oversized-text test, which found a 510-byte "3-byte character" body that could
-- not be decoded.)
local function cut_utf8(text, max)
    if #text <= max then return text end
    local complete, index = 0, 1
    while index <= max do
        local lead = text:byte(index)
        if lead == nil then break end
        local width
        if lead < 0x80 then width = 1
        elseif lead < 0xc0 then width = 1        -- stray continuation: treat as one byte
        elseif lead < 0xe0 then width = 2
        elseif lead < 0xf0 then width = 3
        else width = 4 end
        if index + width - 1 > max then break end
        index = index + width
        complete = index - 1
    end
    return text:sub(1, complete)
end

-- How many peers in the session are NOT us. Read-only; the peer array is only
-- walked inside the count the game itself reports, clamped by the layout that was
-- actually observed (4 slots at a 32-byte stride). Only the low 32 bits of each
-- id are compared: a 64-bit value is not exactly representable as a double, and
-- comparing two rounded doubles could match the wrong entry.
local function other_peers(ctx)
    local own = u32(ctx + M.LOCAL)
    local count = u32(ctx + M.PEER_COUNT)
    if count == nil then return 0 end
    if count > M.MAX_PEERS then count = M.MAX_PEERS end
    local n = 0
    local detail = {}
    for i = 0, count - 1 do
        local lo = u32(ctx + M.PEERS + i * M.PEER_STRIDE)
        detail[#detail + 1] = string.format('%s', tostring(lo))
        if lo ~= nil and lo ~= own then n = n + 1 end
    end
    M.last_peer_detail = string.format('own=%s count=%s entries=%s others=%d',
        tostring(own), tostring(count), table.concat(detail, ','), n)
    return n
end

-- "first/count" of the chat's history ring. Used before AND after a send: a
-- changed pair is the game's own evidence that the whole send path ran, which is
-- what makes "it worked" a measurement rather than a claim.
local function history_pair(chat)
    local first, count = u32(chat + M.HISTORY_FIRST), u32(chat + M.HISTORY_COUNT)
    return string.format('%s/%s', tostring(first), tostring(count))
end

-- Resolves the send function. Called once, and ONLY after verify() confirmed the
-- signature at that RVA: an unverified RVA is an arbitrary address, and calling
-- it is how a mod takes the process down.
--
-- `ffi.load('game.dll')` is not used because it cannot work: ffi.load goes through
-- LoadLibraryA, and this game.dll is mapped by the game rather than resolved by
-- name. Casting the verified absolute address to a typed function pointer is the
-- correct route, and it is why the signature check is a hard precondition here
-- rather than a nicety.
local function setup_send()
    local entry
    for _, candidate in ipairs(M.CODE) do
        if candidate.rva == M.SEND_RVA then entry = candidate break end
    end
    if not entry then return false, 'chat send signature missing from the table' end
    local okay, resolved = pcall(ffi.cast, M.SEND_TYPE, game_base + entry.rva)
    if not okay or resolved == nil then
        return false, 'could not take the address of the send function: ' .. tostring(resolved)
    end
    send_fn = resolved
    chat_buffer = ffi.new('uint8_t[?]', M.MAX_TEXT + 1)
    return true
end

-- Reads a bounded window of the chat object as text: byte runs of printable
-- ASCII/UTF-8 that are at least 4 characters long. Used only to SHOW what is
-- already in the chat, so a message can be confirmed without a second player.
local function chat_strings(chat, limit)
    local blob = read_at(chat, M.REGION_PROBE)
    if not blob then return {}, 0 end
    local found, current = {}, {}
    for i = 1, #blob do
        local byte = blob:byte(i)
        -- printable ASCII, or a UTF-8 continuation/lead byte (>= 0x80)
        if (byte >= 0x20 and byte < 0x7f) or byte >= 0x80 then
            current[#current + 1] = string.char(byte)
        else
            if #current >= 4 then found[#found + 1] = table.concat(current) end
            current = {}
            if #found >= (limit or 12) then break end
        end
    end
    if #found < (limit or 12) and #current >= 4 then found[#found + 1] = table.concat(current) end
    return found, #blob
end

-- Returns true plus how many other players are in the session, or false and why.
-- Every reason is named: "blocked" costs hours, "the chat is off" costs seconds.
--
-- `force` exists for exactly ONE purpose: establishing that the call itself
-- reaches the game, on a machine where no second player is available. Sending
-- into a session that lists nobody reaches nobody, so a forced send proves the
-- plumbing and NOT delivery. The default keeps the guard, and the log says which
-- path was taken.
function M.send_text(text, verbose, force)
    if not verified then return false, 'signature not verified - refusing to send' end
    if not send_fn then return false, 'send function was never resolved' end
    if type(text) ~= 'string' or #text == 0 then return false, 'empty text' end

    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil then return false, 'network context unreadable' end
    if ctx == 0 then return false, 'no network session' end

    local chat = ctx + M.CHAT_OBJECT
    local chat_ok, chat_why = readable(chat, 1)
    if not chat_ok then return false, 'chat object unreadable (' .. chat_why .. ')' end
    local raw = read_at(chat, 1)
    if not raw then return false, 'the chat is unreadable' end
    if raw:byte(1) % 256 == 0 then return false, 'text chat is off' end

    -- Counted BEFORE sending, not after: this is a precondition, and reporting it
    -- as the return value is not the same thing as enforcing it. Sending into a
    -- session that lists nobody is refused rather than broadcast to nobody.
    local others = other_peers(ctx)
    if others == 0 and not force then return false, 'nobody else in the session' end

    local clipped = cut_utf8(text, M.MAX_TEXT)
    local copied = pcall(ffi.copy, chat_buffer, clipped .. '\0')
    if not copied then return false, 'could not stage the text' end

    -- The chat address is a plain integer and the functype takes it as one. Handing
    -- a Lua number to a `void *` parameter raises "cannot convert 'number' to
    -- 'void *'"; that refusal is a Lua-level error, so pcall catches it and the game
    -- keeps running. That is how this was found -- in-game, not by an offline test.
    local before = history_pair(chat)
    local ok, err = pcall(send_fn, chat, 0, chat_buffer)
    if not ok then
        -- A Lua error here is a Lua-level refusal, not a native fault; the latter
        -- does not return at all.
        return false, 'send raised: ' .. tostring(err)
    end
    M.sent = (M.sent or 0) + 1
    if verbose then
        note(string.format('sent %d bytes to %d other player(s); history %s -> %s',
            #clipped, others, before, history_pair(chat)))
    end
    return true, others
end

-- Shows what the chat object currently holds, whatever the session looks like.
function M.inspect_chat()
    if not verified then return nil, 'signature not verified' end
    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil then return nil, 'context unreadable' end
    if ctx == 0 then return nil, 'no network session' end
    local chat = ctx + M.CHAT_OBJECT
    local strings, scanned = chat_strings(chat, 16)
    return strings, scanned
end

-- Diagnostic hooks, called by no shipping code path. They let the offline harness
-- ask exactly what a read returns and how a string is cut, so that "wrong
-- expectation" and "wrong implementation" can be told apart instead of guessed at.
function M.debug_read(address, size)
    return read_at(address, size)
end

function M.debug_cut(text, max)
    return cut_utf8(text, max)
end

function M.debug_others()
    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil or ctx == 0 then return nil end
    return other_peers(ctx)
end

-- Dumps the chat history ring, slot by slot, and reports the first readable text
-- run in each occupied slot. This is the view that lets a message be CONFIRMED:
-- if a line appears here, the chat really holds it.
--
-- The ring's shape (64 slots, 0x228 stride) came from the game's own history
-- accessor: it masks the index with 0x3f and multiplies by 0x228. Where the text
-- sits INSIDE a slot is not assumed -- each occupied slot is scanned, and the
-- offset of the first readable run is reported so the layout shows itself.
function M.dump_ring()
    if not verified then return nil, 'signature not verified' end
    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil or ctx == 0 then return nil, 'no network session' end
    local chat = ctx + M.CHAT_OBJECT
    local first, count = u32(chat + M.HISTORY_FIRST), u32(chat + M.HISTORY_COUNT)
    if first == nil or count == nil then return nil, 'history indices unreadable' end
    if count > M.HISTORY_SLOTS then return nil, 'implausible history count ' .. tostring(count) end

    local lines = {}
    for i = 0, count - 1 do
        local slot = (first + i) % M.HISTORY_SLOTS
        local base = chat + M.HISTORY_BASE + slot * M.HISTORY_STRIDE
        local blob = read_at(base, M.HISTORY_STRIDE)
        if blob then
            -- Read the text WHERE IT ACTUALLY IS. The entry is a 0x228-byte record
            -- with the message at +0x208; reading from the record start and taking
            -- the longest printable run picked up pointer bytes instead and printed
            -- noise like "p_". The offset is now a named constant, so if the layout
            -- moves it is one number to change rather than a silent scan.
            local text = nil
            if M.HISTORY_TEXT_AT + 2 <= #blob then
                local at = M.HISTORY_TEXT_AT + 1
                local run = {}
                for b = at, #blob do
                    local byte = blob:byte(b)
                    if byte == 0 then break end
                    if byte >= 0x20 and byte < 0x7f or byte >= 0x80 then
                        run[#run + 1] = string.char(byte)
                    else
                        break
                    end
                end
                if #run >= 2 then text = table.concat(run) end
            end
            lines[#lines + 1] = {slot = slot, offset = M.HISTORY_TEXT_AT,
                                 text = text or ''}
        end
    end
    return lines, count
end

-- Searches the chat object for an exact UTF-8 byte sequence, returning the
-- offsets where it was found. This answers "is that text actually in the chat?"
-- without needing a second player and without trusting any field offset: either
-- the bytes are there or they are not.
--
-- Read in chunks: a single large ReadProcessMemory fails outright if ANY page in
-- the range is not committed, which would turn a readable chat into "nothing
-- found". Chunking keeps an unreadable page local instead of losing the window.
function M.find_in_chat(needle, span)
    if not verified then return nil, 0 end
    if type(needle) ~= 'string' or #needle == 0 then return nil, 0 end
    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil or ctx == 0 then return nil, 0 end
    local chat = ctx + M.CHAT_OBJECT
    local window = span or (M.REGION_PROBE * 16)
    if window > 0x100000 then window = 0x100000 end

    local hits, scanned = {}, 0
    local chunk = 4096
    local overlap = #needle - 1
    local carry = ''
    local offset = 0
    while offset < window do
        local size = chunk
        if offset + size > window then size = window - offset end
        local blob = read_at(chat + offset, size)
        if blob then
            scanned = scanned + size
            local haystack = carry .. blob
            local at = 1
            while true do
                local from, to = haystack:find(needle, at, true)
                if not from then break end
                hits[#hits + 1] = (offset - #carry) + (from - 1)
                at = to + 1
                if #hits >= 32 then break end
            end
            carry = haystack:sub(#haystack - overlap + 1)
        else
            carry = ''
        end
        offset = offset + size
    end
    return hits, scanned
end

-- ---------------------------------------------------------------- 6. observation
-- Records what the offsets currently hold. Kept as a diagnostic: the send path
-- does not depend on it.
--
-- `out` is reused across calls rather than allocated fresh. This function used to
-- run EVERY frame and build ~10 freshly formatted strings each time, only for
-- tick() to discover "nothing changed" and throw them away. A frame budget
-- watchdog times each mod's share of the frame, and that was pure per-frame cost
-- for no information. It now runs on an interval, and reuses its table.
local function observe(out)
    -- reuse the table, but never leave a previous call's lines behind
    for i = #out, 1, -1 do out[i] = nil end

    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil then
        out[1] = 'network context: UNREADABLE'
        return out, 'context_unreadable'
    end
    if ctx == 0 then
        out[#out + 1] = 'network context: none (not in a session) - this is normal on the ship'
        return out, 'no_session'
    end
    out[#out + 1] = 'network context: ' .. hex(ctx)

    local ok, why = readable(ctx + M.PEER_COUNT, 4)
    if not ok then
        out[#out + 1] = 'peers: unreadable (' .. why .. ')'
        return out, 'peers_unreadable'
    end
    local count = u32(ctx + M.PEER_COUNT)
    out[#out + 1] = string.format('peer count: %s (max observed layout %d)',
        tostring(count), M.MAX_PEERS)

    local chat = ctx + M.CHAT_OBJECT
    if chat ~= nil and not sane_ptr(chat) then
        out[#out + 1] = 'chat object: address out of range'
        return out, 'chat_bad_address'
    end
    local chat_ok, chat_why = readable(chat, 1)
    if not chat_ok then
        out[#out + 1] = 'chat object: unreadable (' .. chat_why .. ')'
        return out, 'chat_unreadable'
    end
    -- Record the raw byte rather than a yes/no. The reference mod treats
    -- (raw % 256) == 0 as "text chat is off", but that is exactly the kind of
    -- assumption this probe exists to check, so it is reported, not obeyed.
    local raw = read_at(chat, 1)
    local raw_byte = raw and raw:byte(1) or nil
    if raw_byte ~= nil then
        out[#out + 1] = string.format('chat flag byte: %d (raw; -1 would be unreadable)', raw_byte)
        out[#out + 1] = string.format('  interpreted as text-chat-off by the reference rule: %s',
            tostring(raw_byte % 256 == 0))
    else
        out[#out + 1] = 'chat flag byte: unreadable'
    end

    local first, count_lines = u32(chat + M.HISTORY_FIRST), u32(chat + M.HISTORY_COUNT)
    if first == nil or count_lines == nil then
        out[#out + 1] = 'chat history: unreadable'
    else
        out[#out + 1] = string.format(
            'chat history: first=%d count=%d (plausible 64-line ring: %s)',
            first, count_lines, tostring(count_lines <= 64))
    end

    return out, 'observed'
end

-- ---------------------------------------------------------------- 7. boot
note(string.format('AutoChat v%s starting (send capable)', M.version))
note(string.format('base=%s loader api=%s version=%s',
    tostring(M.game_base_text or '-'), tostring(loader.api), tostring(loader.version)))

local ok_verify, verify_reason2 = verify()
verified, verify_reason = ok_verify, verify_reason2
if verified then
    M.signature = 'match'
    note('signature check: PASS')
    note('  ' .. verify_reason)
    -- The send entry point is resolved HERE and nowhere else: this is the only
    -- point in the mod where the signature at that RVA is known to be good.
    local send_ok, send_why = setup_send()
    if send_ok then
        M.send_ready = true
        M.status = 'ready (signature ok, send resolved)'
        note('send function resolved - text can be handed to the game')
    else
        M.send_ready = false
        M.status = 'observing only: ' .. tostring(send_why)
        note('send path unavailable: ' .. tostring(send_why))
    end
else
    M.signature = 'MISMATCH'
    M.send_ready = false
    M.status = 'signature mismatch - dormant'
    note('signature check: FAIL - no offset from this file will be used')
    note('  ' .. verify_reason)
end

-- Trigger-driver and heartbeat state. Declared BEFORE the functions that read
-- them: a `local` declared below its reader is not in scope there, and the name
-- silently becomes a global read (nil), which is how `0 >= nil` throws on frame
-- one. The observation state lives with the tick loop further down.
local HEARTBEAT_FRAMES = 1800          -- ~30s at 120fps; one line, not one per frame
local next_heartbeat = HEARTBEAT_FRAMES
local last_trigger = nil               -- contents last acted on, so a file is sent once
local next_trigger_poll = 0
local TRIGGER_POLL_FRAMES = 30         -- a few times a second

-- ---------------------------------------------------------------- 7b. driver
-- An external trigger file, so the send path can be exercised without shipping a
-- hotkey that would also be live for every user. Write text into
--   <root>\AutoChat\trigger.txt
-- and it is sent once, then recorded in the log. A repeated message can be sent
-- by deleting and re-creating the file, or by writing different text.
local function trigger_read()
    local handle = io.open(TRIGGER, 'r')
    if not handle then return nil end
    local text = handle:read('*a')
    handle:close()
    if type(text) ~= 'string' then return nil end
    -- first non-empty line only; the file is a command, not a message queue
    for line in text:gmatch('[^\r\n]+') do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if #line > 0 then return line end
    end
    return nil
end

local function trigger_clear()
    -- Truncating rather than deleting keeps the file's existence stable for an
    -- editor that holds it open.
    local handle = io.open(TRIGGER, 'w')
    if handle then handle:write('') handle:close() end
end

local function poll_trigger()
    if M.frames < next_trigger_poll then return end
    next_trigger_poll = M.frames + TRIGGER_POLL_FRAMES

    -- 'inspect' is a read-only request: show what the chat object holds now.
    local request = trigger_read()
    if request == nil then return end
    if request == 'inspect' then
        if last_trigger == 'inspect' then return end
        last_trigger = 'inspect'
        trigger_clear()
        local strings, scanned = M.inspect_chat()
        if not strings then
            note('inspect: ' .. tostring(scanned))
            return
        end
        note(string.format('inspect: scanned %d bytes of the chat object, %d readable run(s)',
            scanned or 0, #strings))
        for i = 1, #strings do note(string.format('  [%d] %s', i, strings[i])) end
        return
    end

    -- `dump <slot>` prints one ring slot as hex+ASCII, so the layout of a chat
    -- entry can be read off instead of guessed at.
    local slot_wanted = request:match('^dump%s+(%d+)$')
    if slot_wanted then
        if request == last_trigger then return end
        last_trigger = request
        trigger_clear()
        local ctx = u64(game_base + M.CONTEXT_PTR)
        if ctx == nil or ctx == 0 then note('dump: no network session') return end
        local chat = ctx + M.CHAT_OBJECT
        local slot = tonumber(slot_wanted)
        local base = chat + M.HISTORY_BASE + slot * M.HISTORY_STRIDE
        note(string.format('dump: slot %d at chat+0x%X (0x%X bytes)',
            slot, M.HISTORY_BASE + slot * M.HISTORY_STRIDE, M.HISTORY_STRIDE))
        for offset = 0, M.HISTORY_STRIDE - 1, 16 do
            local blob = read_at(base + offset, 16)
            if blob then
                local hex, text = {}, {}
                for i = 1, 16 do
                    local b = blob:byte(i)
                    hex[#hex + 1] = string.format('%02X', b)
                    text[#text + 1] = (b >= 0x20 and b < 0x7f) and string.char(b) or '.'
                end
                note(string.format('  +0x%03X  %s  %s', offset,
                    table.concat(hex, ' '), table.concat(text)))
            else
                note(string.format('  +0x%03X  <unreadable>', offset))
            end
        end
        return
    end

    -- `ring` dumps the chat history ring: the view that confirms a line really
    -- landed in the chat, whether it came from us or from another player.
    if request == 'ring' then
        if last_trigger == 'ring' then return end
        last_trigger = 'ring'
        trigger_clear()
        local lines, count = M.dump_ring()
        if not lines then
            note('ring: ' .. tostring(count))
            return
        end
        note(string.format('ring: %s lines held; %d produced readable text',
            tostring(count), #lines))
        for i = 1, #lines do
            note(string.format('  slot %2d  +0x%X  %s',
                lines[i].slot, lines[i].offset, lines[i].text))
        end
        return
    end

    -- `find <text>` searches the chat object for an exact byte sequence and
    -- reports where it sits. This is how a message can be PROVEN present (or
    -- proven absent) without a second player and without trusting a field offset.
    local needle = request:match('^find%s+(.+)$')
    if needle then
        if request == last_trigger then return end
        last_trigger = request
        trigger_clear()
        local hits, scanned = M.find_in_chat(needle)
        note(string.format('find %q: %d hit(s) in %d bytes scanned',
            needle, hits and #hits or 0, scanned or 0))
        for i = 1, #(hits or {}) do
            note(string.format('  hit at chat+0x%X', hits[i]))
        end
        return
    end

    if request == last_trigger then return end
    last_trigger = request
    trigger_clear()
    -- `send!` forces the peer guard open for plumbing verification only. It is
    -- deliberately not the default: it reaches nobody in a solo session.
    local force = false
    local body = request
    if request:sub(1, 5) == 'send!' then
        force, body = true, request:sub(6)
    end
    if #body == 0 then
        note('trigger: nothing to send')
        return
    end
    note(string.format('trigger: sending %d bytes: %s%s', #body, body,
        force and '   [FORCED - peer guard bypassed, reaches nobody in a solo session]' or ''))
    local ok, why = M.send_text(body, true, force)
    if ok then
        note(string.format('trigger: send returned success (%s other player(s))', tostring(why)))
    else
        note('trigger: send refused - ' .. tostring(why))
    end
end

-- ---------------------------------------------------------------- 8. tick
-- The frame callback. This is the hot path: a frame-budget watchdog reports each
-- mod's cost in ms per second, so anything done here is paid 60-120 times a
-- second whether or not it can change.
--
-- What is deliberately NOT done here:
--   * no string.format, no table allocation, no gsub on the steady path;
--   * observation on an interval, not every frame (it cannot change faster than
--     the game updates it, and it was ~10 allocations per frame to discover that);
--   * the trigger file is read on its own interval, not per frame.
local OBSERVE_FRAMES = 30              -- ~4x a second at 120fps
local next_observe = 0
local observe_out = {}                 -- reused by observe(); never reallocated
local last_shape = ''
local last_verdict = nil
local observed_once = false

local function shape_of(values)
    -- Compare the *shape* of the observation (which fields were readable, and the
    -- digits stripped off) so an idle session produces no further log lines.
    -- Builds one string; called only from the observation interval, not per frame.
    if #values == 0 then return '' end
    local parts = {}
    for i = 1, #values do
        parts[i] = values[i]:gsub('%d+', '#')
    end
    return table.concat(parts, '|')
end

local function tick()
    M.frames = M.frames + 1
    if not verified then return end

    -- Trigger polling has its own frame gate inside poll_trigger(), so this call
    -- is a comparison on most frames.
    pcall(poll_trigger)

    if M.frames < next_observe then return end
    next_observe = M.frames + OBSERVE_FRAMES

    local values, verdict = observe(observe_out)
    local shape = shape_of(values)
    if not observed_once or verdict ~= last_verdict or shape ~= last_shape then
        observed_once = true
        last_verdict, last_shape = verdict, shape
        note('observation [' .. verdict .. ']')
        for i = 1, #values do note('  ' .. values[i]) end
        write_status('last verdict: ' .. verdict)
    end

    if M.frames >= next_heartbeat then
        next_heartbeat = M.frames + HEARTBEAT_FRAMES
        note(string.format('heartbeat: frames=%d reads=%d bytes=%d errors=%d verdict=%s',
            M.frames, M.reads, M.bytes, M.errors, tostring(last_verdict)))
        write_status()
    end
end

local function summarize()
    local tail = 'no observation yet'
    if last_verdict then tail = 'last verdict: ' .. last_verdict end
    note(string.format('shutdown: frames=%d reads=%d bytes=%d errors=%d %s',
        M.frames, M.reads, M.bytes, M.errors, tail))
    write_status(tail)
end

-- ---------------------------------------------------------------- 9. chaining
-- The global `update` is the frame callback. It must be called back
-- unconditionally and its returns passed through, or every mod after this one
-- in the chain loses its frame and the game misbehaves.
local previous = rawget(_G, 'update')
if type(previous) ~= 'function' then
    M.status = 'no update chain - dormant'
    note('no global update - dormant (nothing installed)')
    write_status()
    return M
end
local previous_shutdown = rawget(_G, 'shutdown')
shutdown = function(...)
    pcall(summarize)
    if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
end

local function pack(...) return {n = select('#', ...), ...} end
local unpack = rawget(_G, 'unpack') or table.unpack
update = function(...)
    local results = pack(previous(...))
    local ok, err = pcall(tick)
    if not ok then
        M.errors = M.errors + 1
        if M.errors <= 5 then note('frame_error ' .. tostring(err)) end
    end
    if unpack then return unpack(results, 1, results.n) end
end

if verified then
    M.status = 'ready: signature ok, send resolved'
else
    M.status = 'dormant: signature mismatch (nothing used)'
end
write_status()
note('probe installed: ' .. tostring(M.status))

-- `return` has to be the last statement in its block, so it is wrapped in a do
-- block: the in-game README comment below is part of the same chunk and would
-- otherwise be a syntax error. The build extracts that block into README.txt.
do return M end

--[===[AutoChat / 自动聊天  v0.2.8  —— SEND CAPABLE

English
-------
Sends a chat line to your squad WITHOUT opening the chat box, so your keyboard
and mouse are never taken away. This is why the mod exists: being stuck in the
chat box is caused by the box seizing input, and the box is not needed to send.

Before anything is sent, five machine-code signatures are checked against the
running game.dll. If any one of them does not match, the mod goes dormant and
says which one changed: an unverified address is an arbitrary address, and
calling it is how a mod takes the game down.

How to send
-----------
Put a line of text into this file (created for you):

  %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\trigger.txt

The first non-empty line is sent once, then the file is cleared. To send the
same text again, write it again. While the file contains the word

  inspect

the mod does not send anything; it instead dumps every readable text run inside
the chat object into the log, so on-screen chat can be confirmed without a second
player being present.

You must be in a squad with at least one other player: the mod refuses to send
into an empty session, and says so by name.

Where the files are / 文件位置
  log     %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\AutoChat.log
  status  %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\AutoChat-STATUS.txt
  trigger %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\trigger.txt

What this build does NOT do
---------------------------
It does not patch game memory: no write primitive is declared and the build
refuses to package if one appears. It does not open, draw, or take input for any
UI. It cannot send if the game's own chat flag reads as off, and it will not send
if the signature check failed -- check the log for which.

简体中文
-------
**不打开聊天栏**就把一条聊天发给小队——键鼠从头到尾不会被夺走。"卡在聊天栏"
是聊天框抢输入造成的，而发消息根本不需要那个框。

发送之前会先校验 5 段机器码签名。任何一段对不上就整局停手，并写明是哪一段
变了：没验证过的地址就是任意地址，调用它就是让模组把游戏带崩。

怎么发：把一行文字写进 `AutoChat\trigger.txt`，第一行非空内容会被发一次然后
清空；要再发一遍就再写一次。写 `inspect` 则不发送，而是把聊天对象里所有可读
文本段倾倒进日志——这样不用第二个玩家也能确认聊天确实在动。

必须在至少还有一名其他玩家的小队里；空会话会被拒绝并写明原因。

本版本不写游戏内存（没有声明任何写原语，构建时出现就会拒绝打包），不画界面、
不夺取任何输入。游戏自己的聊天开关读出来是关的时候不会发。
]===]
