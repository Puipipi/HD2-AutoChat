-- HD2-Addon: mods/codex/auto_chat
-- ===========================================================================
--  自动聊天 / AutoChat —— 不打开聊天栏直接发消息 + 设置与自动消息 (v0.7.0)
--
--  为什么能绕开聊天栏：
--    聊天框做四件事——夺取键鼠、画框、收集按键、调用发送。把玩家卡住的是前两件。
--    我们只要最后一件：ctx+0xC418 的聊天对象 + game.dll+0x1097560 的发送函数。
--    这是聊天框自己也调的同一套东西（game.dll+0x186025d 就是它的调用点）。
--
--  本版本三部分：
--    1. 发送：5 段机器码签名校验通过后解析函数指针，把文本交给游戏。
--    2. 面板：按 K 呼出，沿用 Armory 双栏框架与已加载字体，关闭时精确归还鼠标。
--    3. 定时任务：重复间隔、一次倒计时、每天时刻；单人飞船也可发送。
--
--  红线：
--    * ffi.cdef 仅补缺失 user32 声明，原型与 Armory 一致，避免共享原型冲突。
--    * 字体/材质必须通过 Application.can_get；否则回退调试字体/点阵。
--    * create_screen_gui 只在飞船 world 解析后、且分帧阶梯式建立。
--    * update/shutdown 一定调回上一个，绝不断链。
--    * 观测每 30 帧一次并复用输出表（帧预算看门狗按 ms/秒计费）。
-- ===========================================================================
local M = {version = '0.8.1', status = 'starting', frames = 0, reads = 0,
           bytes = 0, errors = 0, signature = 'unknown', sent = 0,
           send_ready = false, panel_open = false, last_peers = nil}

-- The loader may evaluate an entry more than once; without this guard you get two
-- copies of the state and the second one silently wins.
local KEY = 'HD2AutoChat'
if rawget(_G, KEY) then return rawget(_G, KEY) end

M.status = 'boot'
rawset(_G, KEY, M)
-- Declared here, above every function that reads them: a `local` declared below
-- its reader is not in scope there and the name silently becomes a global read.
local game, game_base, send_fn = nil, nil, nil
local automation, preset_library, peer_identity, REGISTRY
local chat_buffer = nil
local verified, verify_reason = false, 'not run'
local sr, Gui, Vector3, Vector2, Color = nil, nil, nil, nil, nil
local user, kernel = nil, nil

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
-- kernel32 only. user32 is handled separately below; see the shared-declaration note.
local cdef_ok, cdef_err = pcall(ffi.cdef, [[
    void *GetCurrentProcess(void);
    uint32_t GetCurrentProcessId(void);
    void *GetModuleHandleA(const char *module_name);
    int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
    size_t VirtualQuery(const void *address, void *info, size_t length);
    int CreateDirectoryA(const char *path, void *security);
    int QueryPerformanceCounter(int64_t *counter);
    void *GlobalLock(void *mem);
    int GlobalUnlock(void *mem);
    size_t GlobalSize(void *mem);
    int MoveFileExA(const char *existing, const char *replacement, uint32_t flags);
]])if not cdef_ok then
    M.status = 'cdef failed: ' .. tostring(cdef_err)
    return M
end
local kernel_ok, kernel_or_err = pcall(function() return ffi.load('kernel32') end)
kernel = kernel_ok and kernel_or_err or nil
if not kernel then
    M.status = 'kernel32 unavailable'
    return M
end
for _, name in ipairs({'GetCurrentProcess', 'GetModuleHandleA', 'ReadProcessMemory',
                       'VirtualQuery', 'QueryPerformanceCounter'}) do
    local value = kernel[name]
    if type(value) ~= 'cdata' and type(value) ~= 'function' then
        M.status = 'missing kernel32 symbol: ' .. name
        return M
    end
end
local process = kernel.GetCurrentProcess()

-- ---------------------------------------------------------------- 2. user32
-- THE SHARED-DECLARATION PROBLEM, and how this avoids it.
--
-- LuaJIT's C namespace is process-global and `ffi.cdef` KEEPS THE FIRST
-- DECLARATION. This mod loads early (12th of 62) and Super Earth Armory Forge
-- loads late (49th); the workspace has a standing rule against declaring user32
-- here because a mismatched re-declaration once silently disabled another mod.
--
-- So we do not declare blindly. Each name is checked for an EXISTING declaration
-- first and only added if genuinely absent. The prototypes are copied verbatim
-- from Armory Forge's own list, so whichever mod wins the race the process holds
-- a byte-identical prototype and nobody is disabled.
local USER32_DECLS = {
    'void *GetForegroundWindow(void);',
    'uint32_t GetWindowThreadProcessId(void*,void*);',
    'int GetCursorPos(void*);',
    'int ScreenToClient(void*,void*);',
    'int GetClientRect(void*,void*);',
    'int16_t GetAsyncKeyState(int key);',
    'int ShowCursor(int show);',
    'int ClipCursor(const void *rect);',
    'int GetClipCursor(void *rect);',
    'int GetSystemMetrics(int index);',
    'int OpenClipboard(void *owner);',
    'int CloseClipboard(void);',
    'void *GetClipboardData(uint32_t format);',
}
local function already_declared(name)
    -- ffi.C is the process-global namespace: a symbol there means some mod already
    -- declared it, and re-declaring could differ from theirs.
    local ok, value = pcall(function() return ffi.C[name] end)
    if not ok then return false end
    return type(value) == 'cdata' or type(value) == 'function'
end
local added, reused = {}, {}
for _, declaration in ipairs(USER32_DECLS) do
    local name = declaration:match('([A-Za-z_][%w_]*)%s*%(')
    if name then
        if already_declared(name) then
            reused[#reused + 1] = name
        else
            if pcall(ffi.cdef, declaration) then added[#added + 1] = name end
        end
    end
end
M.user32_added = table.concat(added, ',')
M.user32_reused = table.concat(reused, ',')
local user_ok, user_or_err = pcall(function() return ffi.load('user32') end)
user = user_ok and user_or_err or nil

-- ---------------------------------------------------------------- 3. engine refs
-- Re-read every frame: `stingray` genuinely is absent in some states.
local function refresh_engine()
    sr = rawget(_G, 'stingray')
    if type(sr) ~= 'table' or type(sr.Gui) ~= 'table' then return false end
    Gui, Vector3, Vector2 = sr.Gui, sr.Vector3, sr.Vector2
    Color = sr.Color
    return Gui ~= nil and Vector3 ~= nil and Vector2 ~= nil
end

-- ---------------------------------------------------------------- 4. constants
-- Every absolute address is an observation of ONE build; they are only used after
-- verify() has confirmed the code signatures.
M.GAME_DLL = 'game.dll'
M.BUILD_DLL_SIZE = 15522408
M.BUILD_DLL_SHA = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

M.CONTEXT_PTR = 0x347cef0     -- game.dll + this -> network context (0 when offline)
M.PEER_COUNT  = 0x16390
M.PEERS       = 0x16398
M.PEER_STRIDE = 32
M.MAX_PEERS   = 4
M.LOCAL       = 0xb398

M.CHAT_OBJECT   = 0xc418
M.HISTORY_FIRST = 0x9590
M.HISTORY_COUNT = 0x9594
M.HISTORY_SLOTS = 64
M.HISTORY_STRIDE = 0x228
-- DERIVED, not guessed: four sends located by exact byte match at chat+0xBA0,
-- +0xDC8, +0xFF0, +0x1218 (0x228 apart), text at entry+0x208, so slot 0's entry
-- base is 0xBA0-0x208 = 0x998. An earlier revision used 0x9598 (a slipped digit)
-- and read pointer bytes, printing noise like "p_".
M.HISTORY_BASE = 0x998
M.HISTORY_TEXT_AT = 0x208

M.SEND_RVA  = 0x1097560
M.SEND_TYPE = 'void (*)(uint64_t, int, const char *)'
M.MAX_TEXT  = 512
-- Current-build read-only text capture: game.dll 0x10979C0 is add-line,
-- called by both normal chat send and receive. It never broadcasts a message.
-- Keep its optional signature separate: failure disables local output only.
M.LOCAL_LINE_RVA = 0x10979c0
M.LOCAL_LINE_BYTES = '\64\87\65\85\65\86\72\131\236\64\128\57\0\77\139\232\76\139\242\72\139\249\15\132\167\2\0\0'
M.REGION_PROBE = 4096

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

-- ---------------------------------------------------------------- 5. primitives
local MIN_PTR, MAX_PTR = 0x10000, 0x00007FFFFFFFFFFF
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
local function u32(address)
    local s = read_at(address, 4)
    if not s then return nil end
    return s:byte(1) + s:byte(2) * 256 + s:byte(3) * 65536 + s:byte(4) * 16777216
end
-- Read a little-endian u32 out of a byte string that has ALREADY been read, at a
-- 0-based offset. Distinct from u32, which takes an ADDRESS.
--
-- This was missing entirely and the font lookup called it, so read_font_ids() faulted
-- on every attempt: the ids were never read, the engine font was never resolved, and the
-- panel silently drew with the 4x5 bitmap fallback. In game the symptom was only "the UI
-- looks wrong" -- nothing said a call had failed, because font_resolve marks itself
-- resolved before doing the work, so it faulted once and then reported failure forever.
local function u32_off(bytes, offset)
    if type(bytes) ~= 'string' then return nil end
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end
local function u64(address)
    local lo, hi = u32(address), u32(address + 4)
    if not lo or not hi then return nil end
    local value = lo + hi * 4294967296
    if value ~= math.floor(value) then return nil end
    return value
end
local MEM_COMMIT, PAGE_GUARD, PAGE_NOACCESS = 0x1000, 0x100, 0x01
local MBI_SIZE = 48
local function page_state(address)
    if not sane_ptr(address) then return nil end
    local info = ffi.new('uint8_t[?]', MBI_SIZE)
    if kernel.VirtualQuery(ffi.cast('const void *', address), info, MBI_SIZE) ~= MBI_SIZE then
        return nil
    end
    local function at(offset)
        return info[offset] + info[offset + 1] * 256 + info[offset + 2] * 65536
             + info[offset + 3] * 16777216
    end
    return {state = at(0x20), protect = at(0x24), region = at(0x18),
            kind = at(0x28), allocation = at(8) + at(12) * 4294967296}
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

-- ---------------------------------------------------------------- 6. logging
local HOME = (os.getenv('LOCALAPPDATA') or os.getenv('TEMP') or '.')
             .. '/CowboyBingus/Helldivers2/'
local LOG = HOME .. 'Logs/AutoChat.log'
local STATUS = HOME .. 'AutoChat/AutoChat-STATUS.txt'
local TRIGGER = HOME .. 'AutoChat/trigger.txt'
local CONFIG = HOME .. 'AutoChat/panel.txt'
local TASK_FILE = HOME .. 'AutoChat/tasks.txt'
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
        'AutoChat / 自动聊天  v' .. M.version .. '  (SEND + PANEL)',
        'status      : ' .. tostring(M.status),
        'signature   : ' .. tostring(M.signature),
        'send ready  : ' .. tostring(M.send_ready),
        'messages sent: ' .. tostring(M.sent or 0),
        'panel       : ' .. (M.panel_open and 'open' or 'closed') .. '  (hotkey K)',
        'game input  : ' .. tostring(M.input_state or 'panel closed'),
        'auto send   : ' .. (M.options and M.options.enabled and 'enabled' or 'disabled'),
        'ping reader : ' .. tostring(M.ping_status or '-'),
        'user32 decls: added[' .. tostring(M.user32_added or '')
                       .. '] reused[' .. tostring(M.user32_reused or '') .. ']',
        'frames      : ' .. tostring(M.frames),
        'reads       : ' .. tostring(M.reads) .. '  (' .. tostring(M.bytes) .. ' bytes)',
        'errors      : ' .. tostring(M.errors),
        'module base : ' .. tostring(M.game_base_text or '-'),
        'log         : ' .. LOG,
        '',
        'Sends without opening chat. The settings panel holds game input only while open.',
        '自动发送不打开聊天栏；设置打开时屏蔽游戏键鼠，关闭后归还。',
    }
    if extra then lines[#lines + 1] = extra end
    pcall(function()
        handle:write(table.concat(lines, '\r\n') .. '\r\n')
        handle:close()
    end)
end

-- ---------------------------------------------------------------- 7. signatures
local function module_base(name)
    local handle = kernel.GetModuleHandleA(name)
    if handle == nil or handle == ffi.NULL then return nil end
    return tonumber(ffi.cast('uintptr_t', handle))
end
local function verify()
    local base = module_base(M.GAME_DLL)
    if not base then return false, 'game.dll not loaded' end
    if not sane_ptr(base) then
        return false, string.format('game.dll base %s is not a plausible pointer',
                                    tostring(base))
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
    if #failed > 0 then return false, table.concat(failed, '\n      ') end
    return true, 'all ' .. tostring(#M.CODE) .. ' code signatures match'
end

-- ---------------------------------------------------------------- 8. sending
-- text cut to at most max bytes WITHOUT splitting a UTF-8 sequence. The cut is
-- placed by walking FORWARD and remembering where a character ended; stepping back
-- from the cut is wrong for anything but 2-byte sequences and produced a
-- 510-byte "3-byte character" body that could not be decoded.
local function cut_utf8(text, max)
    if #text <= max then return text end
    local complete, index = 0, 1
    while index <= max do
        local lead = text:byte(index)
        if lead == nil then break end
        local width
        if lead < 0x80 then width = 1
        elseif lead < 0xc0 then width = 1
        elseif lead < 0xe0 then width = 2
        elseif lead < 0xf0 then width = 3
        else width = 4 end
        if index + width - 1 > max then break end
        index = index + width
        complete = index - 1
    end
    return text:sub(1, complete)
end
-- Exposed so the offline tests can exercise the cut directly: a wrong cut here
-- produces a body that cannot be decoded, which is exactly the sort of thing that
-- only shows up in game otherwise.
function M.debug_cut(text, max) return cut_utf8(text, max) end
-- Prefer the game's live session API; otherwise enumerate all four known slots.
-- PEER_COUNT is not reliable. Compare complete byte strings, never rounded doubles.
local function other_peers(ctx)
    if automation then
        local snapshot = automation.snapshot()
        if snapshot then return #snapshot.remote end
    end
    local own = read_at(ctx + M.LOCAL, 8)
    local n, seen = 0, {}
    for i = 0, M.MAX_PEERS - 1 do
        local id = read_at(ctx + M.PEERS + i * M.PEER_STRIDE, 8)
        if id and id ~= string.rep('\0', 8) and id ~= own and not seen[id] then
            seen[id], n = true, n + 1
        end
    end
    return n
end
local function history_pair(chat)
    return string.format('%s/%s', tostring(u32(chat + M.HISTORY_FIRST)),
                         tostring(u32(chat + M.HISTORY_COUNT)))
end
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

-- Shared preflight lets tasks wait for a usable chat before consuming their deadline.
-- The legacy command API retains its default peer guard; scheduled tasks allow solo.
local function send_context(allow_solo)
    if not verified then return nil, 'signature not verified - refusing to send' end
    if not send_fn then return nil, 'send function was never resolved' end
    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil then return nil, 'network context unreadable' end
    if ctx == 0 then return nil, 'no network session' end
    local chat = ctx + M.CHAT_OBJECT
    local chat_ok, chat_why = readable(chat, 1)
    if not chat_ok then return nil, 'chat object unreadable (' .. chat_why .. ')' end
    local raw = read_at(chat, 1)
    if not raw then return nil, 'the chat is unreadable' end
    if raw:byte(1) % 256 == 0 then return nil, 'text chat is off' end
    local others = other_peers(ctx)
    if others == 0 and not allow_solo then return nil, 'nobody else in the session' end
    return chat, others
end
function M.send_text(text, verbose, force)
    if type(text) ~= 'string' or #text == 0 then return false, 'empty text' end
    local chat, others = send_context(force)
    if not chat then return false, others end
    local clipped = cut_utf8(text, M.MAX_TEXT)
    if not pcall(ffi.copy, chat_buffer, clipped .. '\0') then
        return false, 'could not stage the text'
    end
    local before = history_pair(chat)
    local ok, err = pcall(send_fn, chat, 0, chat_buffer)
    if not ok then return false, 'send raised: ' .. tostring(err) end
    M.sent = (M.sent or 0) + 1
    if verbose then
        note(string.format('sent %d bytes to %d other player(s); history %s -> %s',
            #clipped, others, before, history_pair(chat)))
    end
    return true, others
end

local function local_output_context()
    local chat, why = send_context(true)
    if not chat then return nil, why end
    if read_at(game_base + M.LOCAL_LINE_RVA, #M.LOCAL_LINE_BYTES) ~= M.LOCAL_LINE_BYTES then
        return nil, '本地聊天签名不匹配；未向小队发送'
    end
    local ctx = u64(game_base + M.CONTEXT_PTR)
    local own = ctx and read_at(ctx + M.LOCAL, 8)
    if not own or own == string.rep('\0', 8) then return nil, '本机玩家身份不可用' end
    return chat, own
end
function M.display_local(text)
    if type(text) ~= 'string' or #text == 0 or text:find('%z') then return false, 'empty or invalid text' end
    local chat, own = local_output_context()
    if not chat then return false, own end
    -- Copy all 64 bits. Converting a peer ID to a Lua number loses precision.
    local peer = ffi.new('uint64_t[1]')
    ffi.copy(peer, own, 8)
    local clipped = cut_utf8(text, M.MAX_TEXT)
    ffi.copy(chat_buffer, clipped .. '\0')
    local okay, err = pcall(function()
        local fn = ffi.cast('void (*)(uint64_t, uint64_t, const char *)', game_base + M.LOCAL_LINE_RVA)
        fn(chat, peer[0], chat_buffer)
    end)
    if not okay then return false, '本地消息显示失败：' .. tostring(err) end
    M.local_shown = (M.local_shown or 0) + 1
    note('local-only message: ' .. tostring(#clipped) .. ' bytes; no network send')
    return true, 'local'
end

-- ---------------------------------------------------------------- 9. pixel font
-- Every glyph is a 4x5 bitmap drawn with Gui.rect. No engine font, no material:
-- create_screen_gui before the engine's font/material libraries exist faults at
-- NATIVE level (pcall cannot catch it) and Gui.text needs a material. Gui.rect
-- needs neither.
local GLYPHS = {}
do
    local defs = {
        ['0']='0110 1001 1001 1001 0110',['1']='0100 1100 0100 0100 1110',
        ['2']='1110 0001 0110 1000 1111',['3']='1110 0001 0110 0001 1110',
        ['4']='1001 1001 1111 0001 0001',['5']='1111 1000 1110 0001 1110',
        ['6']='0111 1000 1110 1001 0110',['7']='1111 0001 0010 0100 0100',
        ['8']='0110 1001 0110 1001 0110',['9']='0110 1001 0111 0001 1110',
        A='0110 1001 1111 1001 1001',B='1110 1001 1110 1001 1110',
        C='0111 1000 1000 1000 0111',D='1110 1001 1001 1001 1110',
        E='1111 1000 1110 1000 1111',F='1111 1000 1110 1000 1000',
        G='0111 1000 1011 1001 0111',H='1001 1001 1111 1001 1001',
        I='1110 0100 0100 0100 1110',J='0011 0001 0001 1001 0110',
        K='1001 1010 1100 1010 1001',L='1000 1000 1000 1000 1111',
        M='1001 1111 1111 1001 1001',N='1101 1011 1001 1001 1001',
        O='0110 1001 1001 1001 0110',P='1110 1001 1110 1000 1000',
        Q='0110 1001 1001 1010 0101',R='1110 1001 1110 1010 1001',
        S='0111 1000 0110 0001 1110',T='1111 0100 0100 0100 0100',
        U='1001 1001 1001 1001 0110',V='1001 1001 1001 0110 0110',
        W='1001 1001 1111 1111 1001',X='1001 0110 0110 0110 1001',
        Y='1001 0110 0100 0100 0100',Z='1111 0010 0100 1000 1111',
        ['-']='0000 0000 1111 0000 0000',['+']='0000 0100 1110 0100 0000',
        [':']='0000 0100 0000 0100 0000',['.']='0000 0000 0000 0000 0100',
        ['<']='0010 0100 1000 0100 0010',['>']='0100 0010 0001 0010 0100',
        ['/']='0001 0010 0100 1000 0000',['[']='0110 0100 0100 0100 0110',
        [']']='0110 0010 0010 0010 0110',['=']='0000 1111 0000 1111 0000',
        ['!']='0100 0100 0100 0000 0100',['?']='1110 0001 0110 0000 0100',
        ['(']='0010 0100 0100 0100 0010',[')']='0100 0010 0010 0010 0100',
        _='0000 0000 0000 0000 1111',
    }
    for ch, def in pairs(defs) do
        local rows = {}
        for row in def:gmatch('%d+') do rows[#rows + 1] = row end
        GLYPHS[ch] = rows
    end
end

-- The bitmap fallback, used only when the engine font could not be resolved. Drawn in
-- engine-resolution pixels with a TOP-LEFT origin, so the caller does not have to know
-- that the glyph rows are stored top-down.

-- ---------------------------------------------------------------- 10. real font
-- The engine's own UI font, resolved exactly the way Super Earth Armory Forge does it:
-- three IDs are read out of the RUNNING game.dll and turned into a font + an ink
-- material. They read as zero on disk because they are globals the engine fills in at
-- startup, so this must be read from the live process -- which is what this mod
-- already does.
--
-- Verified against the binary before writing this: our game.dll's PE TimeDateStamp is
-- 0x6AB3B43F, the same value Armory gates its lookup on, so these RVAs are valid for
-- this build. They are still only used after the stamp check, and the text drawing
-- falls back to the built-in 4x5 bitmap font if the lookup fails, so a mismatch
-- degrades the look instead of leaving a blank panel.
M.GAME_STAMP = 0x6AB3B43F
M.FONT_RVA = 0x3772268
M.ATLAS_RVA = 0x3772EE8
M.MATERIAL_RVA = 0x37C5478
M.ATLAS_ID = '88bac99b00000000'
-- Armory's second choice, and it matters: the three ids are runtime-populated, so a
-- lookup can succeed and still find nothing usable. Armory falls back to this debug
-- font when the game UI font is not loaded, and the same chain is copied here.
M.DEBUG_FONT = 'core/performance_hud/debug'

local FONT = {resolved = false, ok = false, why = 'not tried', font = nil,
              material = nil, ink = nil, kind = 'bitmap'}
-- Once-per-stage diagnostics remain useful when a native call aborts the process:
-- Lua's pcall cannot record a native fault after the fact.
local init_stages = {}
local function init_stage(step)
    if init_stages[step] then return end
    init_stages[step] = true
    note('panel init: ' .. step)
end

-- An IdString64 stored in memory holds the two halves swapped relative to the text
-- form of the same id, so this reads low-then-high. Getting that order wrong yields a
-- plausible-looking id that simply never draws.
local function resource_hex(bytes)
    if not bytes or #bytes ~= 8 or bytes == string.rep('\0', 8) then return nil end
    return string.format('%08x%08x', u32_off(bytes, 4), u32_off(bytes, 0))
end

local function supported_game_base()
    if not verified or not game_base then return nil end
    local dos = read_at(game_base, 64)
    local pe = dos and u32_off(dos, 60)
    if not pe or pe < 64 or pe > 0x4000 then return nil end
    local head = read_at(game_base + pe, 16)
    if not head or head:sub(1, 4) ~= 'PE\0\0' or u32_off(head, 8) ~= M.GAME_STAMP then return nil end
    return game_base
end

local function read_font_ids()
    if not game_base then return nil, 'game.dll base unknown' end
    local dos = read_at(game_base, 64)
    if not dos then return nil, 'PE header unreadable' end
    local pe = u32_off(dos, 60)
    if not pe or pe == 0 then return nil, 'e_lfanew unreadable' end
    local head = read_at(game_base + pe, 16)
    if not head then return nil, 'PE head unreadable' end
    if head:sub(1, 4) ~= 'PE\0\0' then return nil, 'not a PE image' end
    if u32_off(head, 8) ~= M.GAME_STAMP then
        return nil, string.format('game.dll is another build (stamp %s)',
                                  hex(u32_off(head, 8) or 0))
    end
    local font_id = resource_hex(read_at(game_base + M.FONT_RVA, 8))
    local atlas_id = resource_hex(read_at(game_base + M.ATLAS_RVA, 8))
    local owner = read_at(game_base + M.MATERIAL_RVA, 8)
    local owner_at = owner and (u32_off(owner, 0) + u32_off(owner, 4) * 4294967296) or nil
    local material_id = owner_at and owner_at ~= 0
                        and resource_hex(read_at(owner_at + 24, 8)) or nil
    if not (font_id and atlas_id and material_id) then
        return nil, 'the engine has not filled in its font ids yet'
    end
    return {font = font_id, material = material_id, atlas = atlas_id}
end

-- Armory asks the APPLICATION whether a resource is actually loaded before using it.
-- The ids coming out of memory only say where the engine keeps them; they do not say
-- the resource finished loading, and handing an unloaded font to Gui.text is how you
-- get a silently empty panel.
local function resource_loaded(kind, name)
    if not (sr and sr.Application) then return false end
    local can_get = rawget(sr.Application, 'can_get')
    if type(can_get) ~= 'function' then return false end
    local value = name
    if type(name) == 'string' and #name == 16 and name:match('^%x+$')
       and sr.IdString64 and type(sr.IdString64.from_hex) == 'function' then
        local ok, converted = pcall(sr.IdString64.from_hex, name)
        if ok then value = converted end
    end
    local ok, got = pcall(can_get, kind, value)
    return ok and got == true
end

-- Resolve for each GUI: destroying a GUI also destroys its material instances.
-- The ORDER is Armory Forge's: read the ids, require all three resources to be loaded,
-- then fall back to the debug font, then give up and let the bitmap font take over.
local function font_resolve(gui)
    if FONT.resolved and FONT.gui == gui then return FONT.ok end
    FONT.resolved, FONT.gui, FONT.ok = true, gui, false
    FONT.font, FONT.material, FONT.ink, FONT.kind = nil, nil, nil, 'bitmap'
    init_stage('font lookup begin')
    if not (sr and sr.IdString64 and sr.Gui and sr.Gui.material and sr.Material
            and type(sr.IdString64.from_hex) == 'function') then
        FONT.why = 'engine font API not present in this state'
        return false
    end

    local ids, why = read_font_ids()
    init_stage(ids and 'runtime font IDs available' or 'runtime font IDs unavailable')
    if ids then
        local font_ok = resource_loaded('font', ids.font)
        local mat_ok = resource_loaded('material', ids.material)
        local tex_ok = resource_loaded('texture', ids.atlas)
        if font_ok and mat_ok and tex_ok then
            init_stage('game font material binding begin')
            local ok, result = pcall(function()
                local ink = sr.Gui.material(gui, sr.IdString64.from_hex(ids.material))
                if not ink then return nil, 'no font material instance' end
                sr.Material.set_texture(ink, sr.IdString64.from_hex(M.ATLAS_ID),
                                        sr.IdString64.from_hex(ids.atlas))
                return {font = sr.IdString64.from_hex(ids.font),
                        material = sr.IdString64.from_hex(ids.material)}
            end)
            if ok and result then
                FONT.font, FONT.material, FONT.ink = result.font, result.material, result
                FONT.ok, FONT.kind = true, 'engine font ' .. tostring(ids.font)
                FONT.why = 'resolved'
                init_stage('game font material binding complete')
                return true
            end
            why = 'material setup failed: ' .. tostring(ok and result or result)
        else
            why = string.format('game UI font not loaded (font %s material %s texture %s)',
                                tostring(font_ok), tostring(mat_ok), tostring(tex_ok))
        end
    end

    -- Second choice, exactly as Armory does it.
    if resource_loaded('font', M.DEBUG_FONT) and resource_loaded('material', M.DEBUG_FONT) then
        -- Armory passes this resource PATH directly. It is not a hexadecimal ID;
        -- feeding it to native from_hex can abort the process outside Lua's pcall.
        FONT.font, FONT.material = M.DEBUG_FONT, M.DEBUG_FONT
        FONT.ok, FONT.kind = true, 'debug font (' .. tostring(why) .. ')'
        FONT.why = FONT.kind
        init_stage('debug font selected as resource path')
        return true
    end

    FONT.why = tostring(why) .. '; debug font not loaded either'
    init_stage('bitmap fallback selected')
    return false
end

-- A text call that cannot take the panel down. Real text when the font resolved,
-- otherwise the caller falls back to the bitmap font.
local function ink_text(x, y, value, size, colour, layer)
    if not FONT.ok then return false end
    local ok = pcall(Gui.text, PANEL.gui, value, FONT.font, size, FONT.material,
                     Vector3(x, y, layer or 962), colour)
    if not ok then
        -- Degrade for the rest of the session rather than faulting every frame.
        FONT.ok, FONT.why = false, 'Gui.text refused; using the bitmap font'
        return false
    end
    return true
end

-- Width in screen pixels, measured by the engine when it can. Used to lay the editing
-- cursor after the text rather than guessing per-character widths.
local function ink_width(value, size)
    if not FONT.ok then return nil end
    local ok, lo, hi = pcall(Gui.text_extents, PANEL.gui, value, FONT.font, size)
    if ok and lo and hi then
        local a, b = lo.x or lo[1], hi.x or hi[1]
        if a and b and b > a then return b - a end
    end
    return nil
end
local cfg = {timer_on = false, interval = 30,
             message = 'HELLO FROM AUTOCHAT', elapsed = 0}
local function config_load()
    local handle = io.open(CONFIG, 'r')
    if not handle then return end
    local text = handle:read('*a')
    handle:close()
    for line in tostring(text):gmatch('[^\r\n]+') do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k == 'timer_on' then cfg.timer_on = (v == 'yes')
        elseif k == 'interval' then
            cfg.interval = math.max(5, math.min(3600, tonumber(v) or 30))
        elseif k == 'message' and #v > 0 then cfg.message = v end
    end
end
local function config_save()
    local handle = io.open(CONFIG, 'w')
    if not handle then return end
    pcall(function()
        handle:write(string.format('timer_on=%s\ninterval=%d\nmessage=%s\n',
            cfg.timer_on and 'yes' or 'no', cfg.interval, cfg.message))
        handle:close()
    end)
end

-- BEGIN CHAT AUTOMATION
-- Automatic chat policy, inlined by the addon builder; no native offsets or writes.
-- Session API provenance: P2P-Ping 0.1.34 scope() / update_peer_labels().
local function build_chat_automation(env)
    local options = {enabled = true, scope = 'all', allow_solo = true,
        welcome = false, welcome_message = '欢迎加入小队！', cooldown = 5,
        welcome_delay = 2, ping = false, ping_building = true, ping_stratagem = true, ping_map = true,
        ping_sender_prefix = true, ping_sender_color = true, ping_medium_enemy = true,
        ping_large_enemy = true, ping_giant_enemy = true, ping_summon = true,
        ping_small_enemy = false, ping_flying_enemy = true,
        ping_message = '标记了{目标}（{类别}）', summon_message = '{玩家名}召唤了{目标}',
        task_stratagem_message = '{玩家名}正在开始{目标}', output = 'squad'}
    local keys = {'enabled', 'scope', 'allow_solo', 'welcome', 'welcome_message',
        'cooldown', 'welcome_delay', 'ping', 'ping_building', 'ping_stratagem', 'ping_map', 'ping_sender_prefix', 'ping_sender_color', 'ping_medium_enemy',
        'ping_large_enemy', 'ping_giant_enemy', 'ping_small_enemy', 'ping_flying_enemy', 'ping_message', 'ping_summon', 'summon_message', 'task_stratagem_message', 'output'}
    local booleans = {enabled=true, allow_solo=true, welcome=true, ping=true,
        ping_building=true, ping_stratagem=true, ping_map=true,
        ping_sender_prefix=true, ping_sender_color=true, ping_medium_enemy=true, ping_large_enemy=true,
        ping_giant_enemy=true, ping_small_enemy=true, ping_flying_enemy=true, ping_summon=true}
    local state = {pending = {}, pings = {}, ping_seen = {}, last_send = nil, last_by_peer = {}, baseline = nil, status = '等待会话'}
    local api = {options = options, state = state}

    local function attempt(fn, ...)
        if type(fn) ~= 'function' then return nil end
        local ok, a, b = pcall(fn, ...)
        if ok then return a, b end -- Preserve false: it means client / failed save.
        return nil, tostring(a)
    end
    local function callable(t, key)
        return type(t) == 'table' and type(rawget(t, key)) == 'function'
    end
    local function validate(key, value)
        if booleans[key] then
            if type(value) ~= 'boolean' then return false, '开关只能设为开启或关闭' end
        elseif key == 'scope' then
            if value ~= 'all' and value ~= 'host' then return false, '发送范围只能选仅主机或主机和客机' end
        elseif key == 'output' then
            if value ~= 'squad' and value ~= 'local' then return false, '请选择小队公屏或仅自己可见' end
        elseif key == 'cooldown' or key == 'welcome_delay' then
            local limit = key == 'cooldown' and 3600 or 60
            if type(value) ~= 'number' or value ~= value or value < 0 or value > limit
                or value ~= math.floor(value) then
                return false, '请输入 0 到 ' .. limit .. ' 之间的整数秒数'
            end
        elseif key == 'welcome_message' or key == 'ping_message' or key == 'summon_message' or key == 'task_stratagem_message' then
            if type(value) ~= 'string' or #value == 0 or #value > 512
                or value:find('%z') or not value:find('%S') then
                return false, '消息须为非空文本，最多 512 字节'
            end
        else return false, '未知的自动聊天设置' end
        return true
    end
    local function escape(text)
        return (text:gsub('[^%w%-%._~]', function(c)
            return string.format('%%%02X', string.byte(c))
        end))
    end
    local function unescape(text)
        -- Malformed percent sequences invalidate a line; never interpret it as Lua.
        local cleaned = text:gsub('%%[%x][%x]', '')
        if cleaned:find('%%') then return nil end
        return (text:gsub('%%([%x][%x])', function(h)
            return string.char(tonumber(h, 16))
        end))
    end
    local function valid_utf8(text)
        local i,n=1,#text
        while i<=n do
            local a=text:byte(i)
            if a<0x80 then i=i+1
            elseif a>=0xC2 and a<=0xDF then
                local b=text:byte(i+1);if not b or b<0x80 or b>0xBF then return false end;i=i+2
            elseif a>=0xE0 and a<=0xEF then
                local b,c=text:byte(i+1,i+2)
                if not b or not c or c<0x80 or c>0xBF or b<0x80 or b>0xBF
                    or (a==0xE0 and b<0xA0) or (a==0xED and b>0x9F) then return false end
                i=i+3
            elseif a>=0xF0 and a<=0xF4 then
                local b,c,d=text:byte(i+1,i+3)
                if not b or not c or not d or c<0x80 or c>0xBF or d<0x80 or d>0xBF
                    or b<0x80 or b>0xBF or (a==0xF0 and b<0x90) or (a==0xF4 and b>0x8F) then return false end
                i=i+4
            else return false end
        end
        return true
    end
    local function copy(source)
        local result = {}; for _, key in ipairs(keys) do result[key] = source[key] end
        result.rules = {}
        for id,rule in pairs(source.rules or {}) do
            result.rules[id] = {};for key,value in pairs(rule) do result.rules[id][key]=value end
        end
        return result
    end
    local enemy_rules = {small_enemy=true,medium_enemy=true,large_enemy=true,giant_enemy=true,flying_enemy=true}
    local rule_fields = {enabled=true,mark_message=true,call_message=true,cooldown=true}
    local function rule_key(kind,id)
        if kind=='enemy' and enemy_rules[id] then return 'enemy_'..id end
        id=tonumber(id)
        if kind=='stratagem' and id and id%1==0 and id>0 and id<4294967296 then
            return 'stratagem_'..string.format('%.0f',id)
        end
    end
    local function rule_value(field,value)
        if not rule_fields[field] then return false end
        if value==nil or value=='' then return true,nil end
        if field=='enabled' then return type(value)=='boolean',value end
        if field=='cooldown' then
            return type(value)=='number' and value==value and value%1==0 and value>=0 and value<=3600,value
        end
        return type(value)=='string' and #value<=512 and not value:find('%z') and value:find('%S')~=nil,value
    end
    local profiles
    local function serialize(candidate)
        local lines = {'# AutoChat automation settings v4'}
        for _, role in ipairs({'host','client'}) do
            for _, key in ipairs(keys) do
                lines[#lines + 1] = role .. '.' .. key .. '=' .. escape(tostring(candidate[role][key]))
            end
            local ids={};for id in pairs(candidate[role].rules or {}) do ids[#ids+1]=id end;table.sort(ids)
            for _,id in ipairs(ids) do
                for _,field in ipairs({'enabled','mark_message','call_message','cooldown'}) do
                    local value=candidate[role].rules[id][field]
                    if value~=nil then lines[#lines+1]=role..'.rule_'..id..'.'..field..'='..escape(tostring(value)) end
                end
            end
        end
        return table.concat(lines, '\n') .. '\n'
    end
    local saved_keys, legacy = {}, {}
    local role_values = {host={},client={}}
    local saved_rules = {host={},client={}}
    local saved = attempt(env.read_file)
    if type(saved) == 'string' then
        for line in saved:gmatch('[^\r\n]+') do
            local key, raw = line:match('^([%w_%.]+)=(.*)$')
            if key then
                local rr,rk,ri,rf=key:match('^(%a+)%.rule_(%a+)_([%w_]+)%.([%w_]+)$')
                if saved_rules[rr] and rule_key(rk,ri) then
                    local value=unescape(raw)
                    if rf=='enabled' then
                        if value=='true' then value=true elseif value=='false' then value=false else value=nil end
                    elseif rf=='cooldown' then value=tonumber(value) end
                    local valid,converted=rule_value(rf,value)
                    if valid and converted~=nil then
                        local id=rule_key(rk,ri);saved_rules[rr][id]=saved_rules[rr][id] or {}
                        saved_rules[rr][id][rf]=converted
                    end
                end
                local role, name = key:match('^(%a+)%.([%w_]+)$')
                if role then key = name end
                local value = unescape(raw)
                if booleans[key] then
                    if value == 'true' then value = true
                    elseif value == 'false' then value = false
                    else value = nil end
                elseif key == 'cooldown' or key == 'welcome_delay' then
                    value = value and tonumber(value) or nil
                end
                if (key == 'ping_small_items' or key == 'ping_mission') and (value == 'true' or value == 'false') then
                    legacy[key] = value == 'true'
                elseif validate(key, value) then
                    if role == 'host' or role == 'client' then role_values[role][key] = value
                    elseif not role then options[key] = value; saved_keys[key] = true end
                end
            end
        end
    end

    if not saved_keys.ping_building and legacy.ping_mission ~= nil then options.ping_building = legacy.ping_mission end
    if not saved_keys.ping_stratagem and legacy.ping_small_items ~= nil then options.ping_stratagem = legacy.ping_small_items end
    -- Upgrade only our old stock template, which hid every resolved target name.
    -- Deliberately custom category-only templates remain exactly as entered.
    local saved_version = type(saved)=='string' and tonumber(saved:match('^# AutoChat automation settings v(%d+)[\r\n]')) or 1
    if (saved_version or 1) < 2 and options.ping_message == '队友标记了{类别}，请注意！' then
        options.ping_message = '标记了{目标}（{类别}）'
    end
    profiles = {host=copy(options), client=copy(options)}
    profiles.client.welcome, profiles.client.output, profiles.client.scope = false, 'local', 'all'
    for _, role in ipairs({'host','client'}) do
        for key,value in pairs(role_values[role]) do profiles[role][key] = value end
        profiles[role].rules=saved_rules[role]
        if (saved_version or 1)<4 then
            -- First upgrade seeds the requested high-TK-risk alerts only. Once
            -- v4 is saved, clearing these fields really restores global timing.
            for _,id in ipairs({4119049995,2902516083}) do
                local key=rule_key('stratagem',id)
                profiles[role].rules[key]=profiles[role].rules[key] or {cooldown=0}
            end
        end
    end
    for _,key in ipairs(keys) do options[key] = profiles.host[key] end
    state.active_role = 'host'
    function api.profile(role) return profiles[role or state.active_role] end

    -- Portable named-profile format is deliberately data-only and parsed strictly.
    function api.export_profile(role)
        local source=profiles[role]
        if not source then return nil,'未知预设' end
        local lines={'# AutoChat profile v1'}
        for _,key in ipairs(keys) do lines[#lines+1]=key..'='..escape(tostring(source[key])) end
        local ids={};for id in pairs(source.rules or {}) do ids[#ids+1]=id end;table.sort(ids)
        for _,id in ipairs(ids) do
            for _,field in ipairs({'enabled','mark_message','call_message','cooldown'}) do
                local value=source.rules[id][field]
                if value~=nil then lines[#lines+1]='rule_'..id..'.'..field..'='..escape(tostring(value)) end
            end
        end
        local payload=table.concat(lines,'\n')..'\n'
        if #payload>1048576 then return nil,'预设超过 1 MiB' end
        return payload
    end
    function api.validate_profile(payload)
        if type(payload)~='string' or #payload>1048576 then return false,'预设格式无效或超过 1 MiB' end
        if payload:sub(-1)~='\n' or payload:find('\r',1,true) then return false,'预设须以换行结束且使用 LF' end
        local lines={};for line in payload:gmatch('([^\n]*)\n') do lines[#lines+1]=line end
        if lines[1]~='# AutoChat profile v1' then return false,'预设版本无效' end
        local values,rules,seen={}, {}, {}
        local scalar_set={};for _,key in ipairs(keys) do scalar_set[key]=true end
        for i=2,#lines do
            local key,raw=lines[i]:match('^([%w_%.]+)=(.*)$')
            if not key or key=='' or seen[key] then return false,'预设包含空白、重复或无效行' end
            seen[key]=true
            local value=unescape(raw)
            if value==nil or escape(value)~=raw then return false,'预设转义无效' end
            if not valid_utf8(value) then return false,'预设包含无效 UTF-8' end
            if scalar_set[key] then
                if booleans[key] then
                    if value=='true' then value=true elseif value=='false' then value=false else return false,'开关值无效' end
                elseif key=='cooldown' or key=='welcome_delay' then
                    if not value:match('^%d+$') then return false,'冷却值无效' end
                    value=tonumber(value)
                end
                local ok=validate(key,value);if not ok then return false,'设置值无效：'..key end
                values[key]=value
            else
                local kind,field=key:match('^rule_(.+)%.([%a_]+)$')
                if not kind then return false,'预设包含未知字段' end
                local rk,ri=kind:match('^(stratagem)_(%d+)$')
                if not rk then
                    for enemy in pairs(enemy_rules) do
                        if kind=='enemy_'..enemy then rk,ri='enemy',enemy;break end
                    end
                end
                local stable=rule_key(rk,ri)
                if not stable or stable~=kind or not rule_fields[field] or value=='' then return false,'规则无效' end
                if field=='enabled' then
                    if value=='true' then value=true elseif value=='false' then value=false else return false,'规则开关无效' end
                elseif field=='cooldown' then
                    if not value:match('^%d+$') then return false,'规则冷却无效' end
                    value=tonumber(value)
                end
                local ok,converted=rule_value(field,value)
                if not ok or converted==nil then return false,'规则值无效' end
                rules[stable]=rules[stable] or {};rules[stable][field]=converted
            end
        end
        for _,key in ipairs(keys) do if values[key]==nil then return false,'缺少设置：'..key end end
        local count=0;for _ in pairs(rules) do count=count+1 end
        if count>512 then return false,'规则数量超过 512' end
        return true,{values=values,rules=rules}
    end
    function api.import_profile(payload,role)
        if role~='host' and role~='client' then return false,'未知预设' end
        local valid,parsed=api.validate_profile(payload)
        if not valid then return false,parsed end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        for _,key in ipairs(keys) do candidate[role][key]=parsed.values[key] end
        candidate[role].rules=parsed.rules
        if attempt(env.write_file,serialize(candidate))~=true then return false,'设置保存失败，已保留原设置' end
        profiles[role]=candidate[role]
        state.rule_revision=(state.rule_revision or 0)+1
        if role==state.active_role then
            for _,key in ipairs(keys) do options[key]=profiles[role][key] end
            state.pending,state.pings,state.ping_seen,state.last_by_peer,state.last_by_rule={},{},{},{},{}
            state.baseline,state.last_send=nil,nil
        end
        state.status='设置已保存'
        return true,state.status
    end

    local function peer_key(value)
        local kind = type(value)
        if kind ~= 'number' and kind ~= 'string' and kind ~= 'cdata' and kind ~= 'userdata' then return nil end
        if kind == 'number' and (value ~= value or value == math.huge or value == -math.huge) then return nil end
        local key = tostring(value)
        if key == '' then return nil end
        -- Do not tonumber IDs: unsigned 64-bit peer IDs exceed double precision.
        local zero = key:lower():gsub('ull$', ''):gsub('ll$', ''):gsub('^0x', '')
        if zero:match('^0+$') then return nil end
        return key
    end

    function api.snapshot()
        local sr = attempt(env.engine)
        local net = type(sr) == 'table' and rawget(sr, 'Network') or nil
        local gs = type(sr) == 'table' and rawget(sr, 'GameSession') or nil
        if not (callable(net, 'game_session') and callable(net, 'peer_id') and callable(gs, 'peers')) then
            return nil, '会话接口尚未就绪'
        end
        local session = attempt(net.game_session)
        if session == nil or session == false then return nil, '尚未进入会话' end
        if callable(gs, 'in_session') and attempt(gs.in_session, session) ~= true then
            return nil, '尚未进入会话'
        end
        local mine = peer_key(attempt(net.peer_id))
        local peers = attempt(gs.peers, session)
        if not mine or type(peers) ~= 'table' then return nil, '玩家列表尚未就绪' end
        local all, remote, present = {}, {}, {}
        for index, value in pairs(peers) do
            -- The proven API returns an array; also tolerate an ID->true set.
            local key = peer_key(value == true and index or value)
            if key and not present[key] then
                present[key] = true
                all[#all + 1] = key
                if key ~= mine then remote[#remote + 1] = key end
            end
        end
        if not present[mine] then return nil, '本机玩家尚未出现在会话中' end
        table.sort(all); table.sort(remote)
        local host = callable(gs, 'game_session_host') and peer_key(attempt(gs.game_session_host, session)) or nil
        local is_host
        if host and present[host] then is_host = host == mine end
        return {session = session, context = attempt(env.context), mine = mine, host = host,
            peers = all, remote = remote, present = present, is_host = is_host}
    end

    function api.sync(snapshot)
        snapshot = snapshot or api.snapshot()
        local role = snapshot and snapshot.is_host ~= nil and (snapshot.is_host and 'host' or 'client') or nil
        if not role then return nil end
        if role ~= state.active_role then
            state.active_role = role
            for _, key in ipairs(keys) do options[key] = profiles[role][key] end
            state.pending, state.pings, state.ping_seen, state.last_by_peer, state.last_by_rule = {}, {}, {}, {}, {}
            state.baseline, state.last_send = nil, nil
            state.status = role == 'host' and '已切换主机预设' or '已切换客机预设'
        end
        return role
    end
    function api.send(text, expected_role)
        local role = api.sync()
        if not role then return false, '等待：主机身份尚未确认' end
        if expected_role and role ~= expected_role then return false, '身份已变化，取消旧预设消息' end
        if options.output == 'local' then
            local ok, why = attempt(env.send_local, text)
            return ok == true, why or '本地显示入口不可用'
        end
        local ok, why = attempt(env.send, text)
        return ok == true, why
    end

    local categories = {building='任务建筑', stratagem='战备提示', map='地图标记',
        small_enemy='小型敌人', flying_enemy='飞行敌人', medium_enemy='中型敌人', large_enemy='大型敌人', giant_enemy='巨型敌人'}
    local function clipped(value, limit)
        if #value <= limit then return value end
        local at = limit + 1
        while at > 1 and value:byte(at) >= 128 and value:byte(at) < 192 do at = at-1 end
        return value:sub(1, at-1)
    end
    local function plain(value, limit)
        return clipped(tostring(value or ''):gsub('[%c<>]', ''), limit)
    end
    local session_peer_hex
    local function identity_for(peer)
        if type(peer) ~= 'string' then return nil end
        local key = session_peer_hex(peer) or peer
        local value = attempt(env.identity, key)
        if type(value) == 'table' and value.peer_id == key then return value end
        if key ~= peer then
            value = attempt(env.identity, peer)
            if type(value) == 'table' and value.peer_id == peer then return value end
        end
    end
    session_peer_hex = function(value)
        local text=tostring(value):upper():gsub('ULL$',''):gsub('LL$','')
        if #text==16 and text:match('^%x+$') then return text end
        if text:match('^0X%x+$') then text=text:sub(3)
        elseif text:match('^%d+$') then
            local output=''
            while text ~= '' and not text:match('^0+$') do
                local quotient, carry={},0
                for i=1,#text do
                    local n=carry*10+tonumber(text:sub(i,i))
                    quotient[#quotient+1]=tostring(math.floor(n/16));carry=n%16
                end
                output=('0123456789ABCDEF'):sub(carry+1,carry+1)..output
                if #output>16 then return nil end
                text=table.concat(quotient):gsub('^0+','')
            end
            text=output
        end
        if #text>16 or text=='' or not text:match('^%x+$') then return nil end
        return string.rep('0',16-#text)..text
    end
    local function creator_present(peer, snapshot)
        if type(peer) ~= 'string' then return true end -- Legacy synthetic events have no creator.
        if identity_for(peer) then return true end -- Native lookup already checks active membership.
        if not snapshot then return false end
        if snapshot.present[peer] then return true end
        if #peer==16 and peer:match('^%x+$') then
            for _, member in ipairs(snapshot.peers) do
                if session_peer_hex(member)==peer:upper() then return true end
            end
        end
        return false
    end
    local function position_text(event)
        local p = event.position
        if type(p) ~= 'table' then return '未知位置' end
        for _, key in ipairs({'x','y','z'}) do
            local n=p[key]
            if type(n) ~= 'number' or n ~= n or math.abs(n) > 1000000 then return '未知位置' end
        end
        return string.format('(%.0f, %.0f, %.0f)', p.x, p.y, p.z)
    end
    function api.has_peer(peer) return creator_present(peer,api.snapshot()) end

    function api.format(template, peer, extra, anonymous)
        if type(template) ~= 'string' then return '' end
        if peer == nil then local s=api.snapshot();peer=s and s.mine end
        local identity = identity_for(peer)
        local name = anonymous and '小队' or identity and plain(identity.name,96) or '队友'
        local short = anonymous and '小队' or identity and plain(identity.short,16) or '队友'
        if name=='' then name='队友' end
        if short=='' then short='队友' end
        local slot = not anonymous and identity and identity.color_index
        local number = type(slot)=='number' and slot%1==0 and slot>=0 and slot<=3 and tostring(slot+1) or '?'
        local values = {['{玩家名}']=name,['{名字}']=name,['{触发者}']=name,
            ['{缩写}']=short,['{编号}']=number}
        if type(extra)=='table' then
            for key,value in pairs(extra) do
                if values[key]==nil and type(key)=='string' and type(value)=='string' then
                    values[key]=plain(value,200)
                end
            end
        end
        -- Function replacement keeps '%' and nested braces in player names literal.
        return clipped(template:gsub('{[^{}]+}',function(key)return values[key] or key end),512)
    end
    local function bucket(peer, snapshot)
        local key = peer or snapshot and snapshot.mine
        return key and (session_peer_hex(key) or tostring(key)) or '@local'
    end
    local function limits(snapshot)
        local token = snapshot and table.concat({tostring(snapshot.session),tostring(snapshot.context),
            tostring(snapshot.mine),tostring(snapshot.host)},'|') or '@unavailable'
        if state.limit_session ~= token then
            state.limit_session, state.last_by_peer, state.last_send, state.last_by_rule = token, {}, nil, {}
        end
        if snapshot then
            local present = {}
            for _,key in ipairs(snapshot.peers) do present[bucket(key,snapshot)]=true end
            for key in pairs(state.last_by_peer) do
                if not present[key] then state.last_by_peer[key]=nil end
            end
            for key in pairs(state.last_by_rule or {}) do
                if not present[key] then state.last_by_rule[key]=nil end
            end
        end
    end
    local function policy(now, others, snapshot, peer, rule_id, cooldown)
        limits(snapshot)
        if not options.enabled then return false, '自动发送已关闭' end
        if options.scope == 'host' then
            if not snapshot or snapshot.is_host == nil then return false, '等待：主机身份尚未确认' end
            if snapshot.is_host == false then return false, '等待：仅主机可自动发送' end
        end
        if not options.allow_solo and (type(others) ~= 'number' or others < 1) then
            return false, '等待：小队中没有其他玩家'
        end
        if type(now) ~= 'number' or now ~= now or now == math.huge or now == -math.huge then
            return false, '等待：计时尚未就绪'
        end
        local key=bucket(peer,snapshot)
        local independent=rule_id and cooldown~=nil
        local last=independent and (state.last_by_rule[key] or {})[rule_id] or nil
        if not independent then last=state.last_by_peer[key] end
        if last and now - last < (independent and cooldown or options.cooldown) then
            return false, '等待：该玩家的自动消息间隔中'
        end
        return true, '可以自动发送'
    end
    function api.check(now, others, peer)
        api.sync()
        return policy(now, others, api.snapshot(), peer)
    end
    function api.record(now, peer)
        if type(now) == 'number' and now == now and now ~= math.huge and now ~= -math.huge then
            local snapshot=api.snapshot();limits(snapshot)
            state.last_send = now
            state.last_by_peer[bucket(peer,snapshot)] = now
        end
    end
    local function reset()
        state.baseline, state.pending = nil, {}
    end
    function api.set(key, value, role)
        api.sync()
        role = role or state.active_role
        if not profiles[role] then return false, '未知预设' end
        local ok, why = validate(key, value)
        if not ok then return false, why end
        if profiles[role][key] == value then return true, '设置未变化' end
        local candidate = {host=copy(profiles.host), client=copy(profiles.client)}
        candidate[role][key] = value
        -- The environment writes a temporary file and renames it atomically.
        -- Commit options only after that succeeds; queue/baseline also survive failure.
        if attempt(env.write_file, serialize(candidate)) ~= true then return false, '设置保存失败，已保留原设置' end
        profiles[role][key] = value
        if role ~= state.active_role then state.status='设置已保存';return true,state.status end
        options[key] = value
        if key == 'enabled' or key == 'welcome' or key == 'scope' then reset() end
        if key == 'enabled' or key == 'scope' or key == 'ping' or key == 'output' then state.pings = {} end
        if key == 'output' then reset() end
        state.status = '设置已保存'
        return true, state.status
    end
    function api.rule(kind,id,role)
        local key=rule_key(kind,id);local profile=profiles[role or state.active_role]
        local result={};for field,value in pairs(profile and key and profile.rules[key] or {}) do result[field]=value end
        return result
    end
    local function save_rules(candidate,role)
        if attempt(env.write_file,serialize(candidate))~=true then return false,'设置保存失败，已保留原设置' end
        profiles[role].rules=candidate[role].rules
        state.rule_revision=(state.rule_revision or 0)+1
        if role==state.active_role then state.pings={} end -- Do not send an old template after editing.
        return true,'设置已保存'
    end
    function api.set_rule(kind,id,field,value,role)
        api.sync();role=role or state.active_role
        local key=rule_key(kind,id);local valid,converted=rule_value(field,value)
        if not profiles[role] or not key or not valid then return false,'无效规则；冷却须为 0–3600 秒，消息最多 512 字节' end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        candidate[role].rules[key]=candidate[role].rules[key] or {}
        candidate[role].rules[key][field]=converted
        if not next(candidate[role].rules[key]) then candidate[role].rules[key]=nil end
        return save_rules(candidate,role)
    end
    function api.set_rules(kind,ids,enabled,role)
        api.sync();role=role or state.active_role
        if not profiles[role] or type(ids)~='table' or type(enabled)~='boolean' then return false,'无效批量设置' end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        for _,id in ipairs(ids) do
            local key=rule_key(kind,id);if not key then return false,'无效战备 ID' end
            candidate[role].rules[key]=candidate[role].rules[key] or {};candidate[role].rules[key].enabled=enabled
        end
        return save_rules(candidate,role)
    end
    function api.reset_rule(kind,id,role)
        api.sync();role=role or state.active_role
        local key=rule_key(kind,id)
        if not profiles[role] or not key then return false,'无效规则' end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        local old=candidate[role].rules[key]
        candidate[role].rules[key]=old and {enabled=old.enabled} or nil
        return save_rules(candidate,role)
    end
    local function event_rule(event)
        local key=event.rule_id or (event.category=='stratagem' and rule_key('stratagem',event.stratagem_rule_id or event.stratagem_id)
            or rule_key('enemy',event.category))
        return key,key and profiles[state.active_role].rules[key] or {}
    end
    local function same_session(a, b)
        return a and b and a.session == b.session and a.context == b.context
            and a.mine == b.mine and a.host == b.host
    end
    local function poll_welcome(now)
        if not options.enabled or not options.welcome then
            reset(); state.status = options.enabled and '新人欢迎已关闭' or '自动发送已关闭'
            return false, state.status
        end
        local snapshot, why = api.snapshot()
        if not snapshot then reset(); state.status = why; return false, why end
        if options.scope == 'host' and snapshot.is_host ~= true then
            reset(); state.status = snapshot.is_host == false and '等待：仅主机可自动发送' or '等待：主机身份尚未确认'
            return false, state.status
        end
        if type(now) ~= 'number' or now ~= now or now == math.huge or now == -math.huge then
            reset(); state.status = '等待：计时尚未就绪'; return false, state.status
        end
        local previous = state.baseline
        if not same_session(previous, snapshot) then
            state.pending = {}; state.baseline = snapshot
            state.status = '已记录当前小队，等待新人加入'
            return false, state.status
        end
        -- Compare IDs, not counts: one player replacing another is still a join.
        for _, key in ipairs(snapshot.remote) do
            if not previous.present[key] then
                state.pending[key] = {due = now + options.welcome_delay, joined = now, retry = 0}
            end
        end
        for key in pairs(state.pending) do
            if not snapshot.present[key] then state.pending[key] = nil end
        end
        state.baseline = snapshot
        local candidate, entry, blocked
        for key, pending in pairs(state.pending) do
            if now >= pending.due and now >= pending.retry then
                local allowed, reason = policy(now,#snapshot.remote,snapshot,key)
                if allowed and (not entry or pending.joined < entry.joined
                    or pending.joined == entry.joined and key < candidate) then candidate, entry = key, pending
                elseif not allowed then blocked=reason end
            end
        end
        if not candidate then state.status = blocked or '等待新人欢迎'; return false, state.status end
        local allowed, reason = policy(now, #snapshot.remote, snapshot, candidate)
        if not allowed then state.status = reason; return false, reason end
        local sent, send_why = api.send(api.format(options.welcome_message,candidate), state.active_role)
        if sent == true then
            state.pending[candidate] = nil; api.record(now,candidate)
            state.status = '已发送新人欢迎'; return true, state.status
        end
        -- Chat can be temporarily disabled. Keep this welcome while the player
        -- remains present, retry at most once per five seconds, and consume no cooldown.
        entry.retry = now + 5
        state.status = '等待：欢迎语暂未发送（5 秒后重试）'
        return false, state.status, send_why
    end
    local function ping_enabled(category, action)
        if action == 'summon' or action == 'use' then return options.ping_summon end
        return options['ping_' .. category]
    end
    function api.push_ping(event, now)
        api.sync()
        if type(event) ~= 'table' or not categories[event.category] or type(event.key) ~= 'string'
            or #event.key > 128 or type(now) ~= 'number' or now ~= now
            or now == math.huge or now == -math.huge then return false end
        if not options.enabled or not options.ping or not ping_enabled(event.category,event.action) then return false end
        local rule_id,rule=event_rule(event)
        if rule.enabled==false then return false end
        for key, expires in pairs(state.ping_seen) do if now > expires then state.ping_seen[key] = nil end end
        if state.ping_seen[event.key] then return false end
        local snapshot = api.snapshot()
        if options.scope == 'host' and (not snapshot or snapshot.is_host ~= true) then return false end
        if not creator_present(event.creator_id, snapshot) then return false end
        if #state.pings>=16 then
            if rule.cooldown~=0 then return false end
            local evict
            for i,pending in ipairs(state.pings) do if pending.cooldown~=0 then evict=i;break end end
            if not evict then return false end
            table.remove(state.pings,evict)
        end
        local label = categories[event.category]
        local target = type(event.target) == 'string' and plain(event.target,200) or label
        local identity = identity_for(event.creator_id)
        local short = identity and plain(identity.short, 16) or '队友'
        if short == '' then short = '队友' end
        local objective_types = {primary='主线任务', prerequisite='主线前置任务',
            optional='支线任务', tactical='战术任务', unknown='任务'}
        local summoned = event.action == 'summon'
        local executing = event.action == 'use'
        local replacements = {['{类别}']=label, ['{目标}']=plain(target, 200),
            ['{动作}']=summoned and '召唤' or executing and '开始' or '标记',
            ['{任务名}']=plain(type(event.objective_name)=='string' and event.objective_name or target,200),
            ['{任务类型}']=objective_types[event.objective_kind] or label,
            ['{位置}']=position_text(event)}
        local template = executing and options.task_stratagem_message or summoned and options.summon_message or options.ping_message
        template=((summoned or executing) and rule.call_message or not (summoned or executing) and rule.mark_message) or template
        local text = api.format(template,event.creator_id,replacements,event.anonymous==true)
        local prefix = ''
        if options.ping_sender_prefix and not event.anonymous and type(event.creator_id) == 'string' then
            prefix = '[' .. short .. ']'
            if options.ping_sender_color and identity and type(identity.color) == 'string'
                and (#identity.color==6 or #identity.color==8) and identity.color:match('^%x+$') then
                prefix = attempt(env.colorize, prefix, identity.color) or prefix
            end
            prefix = prefix .. ' '
        end
        text = prefix .. clipped(text, math.max(0, 512 - #prefix))
        state.pings[#state.pings+1] = {key=event.key, category=event.category, action=event.action, rule_id=rule_id, cooldown=rule.cooldown, text=text, expires=now+15, retry=now,
            context=attempt(env.context), session=snapshot and snapshot.session, mine=snapshot and snapshot.mine,
            host=snapshot and snapshot.host, creator_id=event.creator_id, known_identity=identity ~= nil, role=state.active_role}
        state.ping_seen[event.key] = now + 30
        return true
    end
    local function poll_ping(now, urgent_only)
        if not options.enabled or not options.ping then state.pings = {}; return false end
        if type(now) ~= 'number' or now ~= now then return false end
        local snapshot = api.snapshot()
        local context = attempt(env.context)
        for i=#state.pings,1,-1 do
            local p = state.pings[i]
            if now > p.expires or not creator_present(p.creator_id, snapshot)
                or not ping_enabled(p.category,p.action)
                or p.context ~= context or p.session ~= (snapshot and snapshot.session)
                or p.mine ~= (snapshot and snapshot.mine) or p.host ~= (snapshot and snapshot.host) then
                table.remove(state.pings,i)
            end
        end
        local pending, index
        for i,p in ipairs(state.pings) do
            if now>=p.retry and (not urgent_only or p.cooldown==0) then
                local allowed,why=policy(now,snapshot and #snapshot.remote or nil,snapshot,p.creator_id,p.rule_id,p.cooldown)
                if allowed then pending,index=p,i;break end
                state.status=why
            end
        end
        if not pending then return false end
        local sent = api.send(pending.text, pending.role)
        if sent == true then
            table.remove(state.pings,index)
            if pending.rule_id and pending.cooldown~=nil then
                limits(snapshot);local key=bucket(pending.creator_id,snapshot)
                state.last_by_rule[key]=state.last_by_rule[key] or {};state.last_by_rule[key][pending.rule_id]=now
            else api.record(now,pending.creator_id) end
            state.status='已发送玩家标记提示'; return true, state.status
        end
        pending.retry=now+5
        state.status='等待：标记提示暂未发送（5秒后重试）'
        return false, state.status
    end
    function api.poll(now)
        api.sync()
        local urgent,urgent_why=poll_ping(now,true)
        if urgent then return urgent,urgent_why end
        local sent, why = poll_welcome(now)
        if sent then return sent, why end
        local ping_sent, ping_why = poll_ping(now)
        return ping_sent, ping_why or why
    end
    return api
end
-- END CHAT AUTOMATION
















-- BEGIN PRESET LIBRARY
-- Data-only preset storage. All game/config semantics are supplied by env.
local function build_preset_library(env)
    local MAX_PRESETS, MAX_NAME, MAX_PAYLOAD, MAX_SERIAL = 32, 96, 1024 * 1024, 99999999
    local MAX_LIBRARY = 16 * 1024 * 1024
    local LIB_MAGIC = "# AutoChat preset library v1\n"
    local FILE_MAGIC = "# AutoChat preset v1\n"
    local state = {error = nil, revision = 0}
    local entries, serial = {}, 0

    local function utf8_valid(s)
        if type(s) ~= "string" then return false end
        local i, n = 1, #s
        while i <= n do
            local a = s:byte(i)
            if a < 0x80 then i = i + 1
            elseif a >= 0xC2 and a <= 0xDF then
                local b = s:byte(i + 1); if not b or b < 0x80 or b > 0xBF then return false end; i = i + 2
            elseif a >= 0xE0 and a <= 0xEF then
                local b, c = s:byte(i + 1), s:byte(i + 2)
                if not b or not c or b < 0x80 or b > 0xBF or c < 0x80 or c > 0xBF then return false end
                if (a == 0xE0 and b < 0xA0) or (a == 0xED and b >= 0xA0) then return false end
                i = i + 3
            elseif a >= 0xF0 and a <= 0xF4 then
                local b, c, d = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
                if not b or not c or not d or b < 0x80 or b > 0xBF or c < 0x80 or c > 0xBF or d < 0x80 or d > 0xBF then return false end
                if (a == 0xF0 and b < 0x90) or (a == 0xF4 and b > 0x8F) then return false end
                i = i + 4
            else return false end
        end
        return true
    end
    local function valid_name(name)
        if type(name) ~= "string" or #name == 0 or #name > MAX_NAME or not utf8_valid(name) or not name:find("%S") then return false end
        for i = 1, #name do local b = name:byte(i); if b < 32 or b == 127 then return false end end
        return true
    end
    local function validate_payload(payload)
        if type(payload) ~= "string" or #payload == 0 or #payload > MAX_PAYLOAD then return false, "预设数据长度无效" end
        if env.validate == nil then return false, "预设校验器不可用" end
        local ok, valid, why = pcall(env.validate, payload)
        if not ok then return false, "预设数据校验失败" end
        if valid ~= true then return false, why or "预设数据无效" end
        return true
    end
    local function fail(reason) return false, reason end
    local function call(fn, ...)
        if fn == nil then return false, "预设操作不可用" end
        local ok, a, b, c = pcall(fn, ...)
        if not ok then return false, "文件操作失败" end
        return true, a, b, c
    end
    local function find(id)
        for i = 1, #entries do if entries[i].id == id then return i, entries[i] end end
    end
    local function duplicate_name(name, except)
        for i = 1, #entries do if i ~= except and entries[i].name == name then return true end end
        return false
    end
    local function encode_library(items, next_serial)
        local out = {LIB_MAGIC, tostring(next_serial), "\n", tostring(#items), "\n"}
        for i = 1, #items do
            local e = items[i]
            out[#out + 1] = e.id .. "\n" .. tostring(#e.name) .. "\n" .. tostring(#e.payload) .. "\n"
            out[#out + 1] = e.name; out[#out + 1] = e.payload
        end
        return table.concat(out)
    end
    local function parse_uint_line(data, pos, max)
        local e = data:find("\n", pos, true)
        if not e or e == pos or e - pos > 10 then return nil end
        local text = data:sub(pos, e - 1)
        if not text:match("^%d+$") or (#text > 1 and text:sub(1, 1) == "0") then return nil end
        local value = tonumber(text)
        if not value or value > max then return nil end
        return value, e + 1
    end
    local function parse_library(data)
        if type(data) ~= "string" or #data > MAX_LIBRARY or data:sub(1, #LIB_MAGIC) ~= LIB_MAGIC then return nil, nil, "预设库格式损坏" end
        local pos = #LIB_MAGIC + 1
        local saved_serial; saved_serial, pos = parse_uint_line(data, pos, MAX_SERIAL)
        if not saved_serial then return nil, nil, "预设库序号无效" end
        local count; count, pos = parse_uint_line(data, pos, MAX_PRESETS)
        if count == nil then return nil, nil, "预设库数量无效" end
        local result, ids, names, highest = {}, {}, {}, 0
        for _ = 1, count do
            local id_end = data:find("\n", pos, true)
            if not id_end or id_end - pos ~= 9 then return nil, nil, "预设编号无效" end
            local id = data:sub(pos, id_end - 1)
            local digits = id:match("^P(%d%d%d%d%d%d%d%d)$")
            local number = digits and tonumber(digits)
            if not number or number < 1 or number > MAX_SERIAL or ids[id] then return nil, nil, "预设编号重复或无效" end
            ids[id] = true; if number > highest then highest = number end
            pos = id_end + 1
            local nl; nl, pos = parse_uint_line(data, pos, MAX_NAME)
            if not nl then return nil, nil, "预设名称长度无效" end
            local pl; pl, pos = parse_uint_line(data, pos, MAX_PAYLOAD)
            if nl == 0 or not pl or pl == 0 or pos + nl + pl - 1 > #data then return nil, nil, "预设长度无效" end
            local name = data:sub(pos, pos + nl - 1); pos = pos + nl
            local payload = data:sub(pos, pos + pl - 1); pos = pos + pl
            if not valid_name(name) or names[name] then return nil, nil, "预设名称重复或无效" end
            names[name] = true
            local valid = validate_payload(payload)
            if not valid then return nil, nil, "库内预设数据无效" end
            result[#result + 1] = {id = id, name = name, payload = payload}
        end
        if pos ~= #data + 1 or highest > saved_serial then return nil, nil, "预设库含有多余数据或无效序号" end
        return result, saved_serial
    end
    local function persist(next_entries, next_serial)
        local bytes = encode_library(next_entries, next_serial)
        if #bytes > MAX_LIBRARY then return false, "预设库超过大小限制" end
        local ok, wrote, why = call(env.write_file, bytes)
        if not ok or wrote ~= true then return false, why or "保存预设库失败" end
        entries, serial = next_entries, next_serial
        state.revision = state.revision + 1
        return true
    end
    do
        local ok, data, why = call(env.read_file)
        if not ok then state.error = "读取预设库失败"
        elseif data == nil then
            if why ~= nil then state.error = why end
        else
            local loaded, loaded_serial, err = parse_library(data)
            if not loaded then state.error = err else entries, serial = loaded, loaded_serial end
        end
    end
    local api = {state = state}
    function api.list()
        local result = {}
        for i = 1, #entries do result[i] = {id = entries[i].id, name = entries[i].name, payload = entries[i].payload} end
        return result
    end
    local function ready() if state.error then return false, "预设库不可用：" .. tostring(state.error) end; return true end
    function api.save(name, role)
        local r, reason = ready(); if not r then return false, reason end
        if not valid_name(name) then return fail("名称不能为空，且须为有效UTF-8（最多96字节）") end
        if duplicate_name(name) then return fail("预设名称已存在，请先重命名现有预设") end
        if #entries >= MAX_PRESETS then return fail("最多保存32个预设") end
        local ok, payload, why = call(env.capture, role)
        if not ok or type(payload) ~= "string" then return fail(why or "读取当前配置失败") end
        local valid, vwhy = validate_payload(payload); if not valid then return fail(vwhy) end
        if serial >= MAX_SERIAL then return fail("预设编号已用尽") end
        local next_serial = serial + 1
        local next_entries = {}; for i = 1, #entries do next_entries[i] = entries[i] end
        local id = string.format("P%08d", next_serial)
        next_entries[#next_entries + 1] = {id = id, name = name, payload = payload}
        local saved, savewhy = persist(next_entries, next_serial)
        if not saved then return fail(savewhy) end
        return true, nil, id
    end
    function api.replace(id, role)
        local r, reason = ready(); if not r then return false, reason end
        local index, old = find(id); if not index then return fail("找不到该预设") end
        local ok, payload, why = call(env.capture, role)
        if not ok or type(payload) ~= "string" then return fail(why or "读取当前配置失败") end
        local valid, vwhy = validate_payload(payload); if not valid then return fail(vwhy) end
        local next_entries = {}; for i = 1, #entries do next_entries[i] = i == index and {id = old.id, name = old.name, payload = payload} or entries[i] end
        local saved, savewhy = persist(next_entries, serial); if not saved then return fail(savewhy) end
        return true
    end
    function api.remove(id)
        local r, reason = ready(); if not r then return false, reason end
        local index = find(id); if not index then return fail("找不到该预设") end
        local next_entries = {}; for i = 1, #entries do if i ~= index then next_entries[#next_entries + 1] = entries[i] end end
        local saved, savewhy = persist(next_entries, serial); if not saved then return fail(savewhy) end
        return true
    end
    function api.rename(id, name)
        local r, reason = ready(); if not r then return false, reason end
        local index, old = find(id); if not index then return fail("找不到该预设") end
        if not valid_name(name) then return fail("名称不能为空，且须为有效UTF-8（最多96字节）") end
        if duplicate_name(name, index) then return fail("预设名称已存在") end
        local next_entries = {}; for i = 1, #entries do next_entries[i] = i == index and {id = old.id, name = name, payload = old.payload} or entries[i] end
        local saved, savewhy = persist(next_entries, serial); if not saved then return fail(savewhy) end
        return true
    end
    function api.apply(id, role)
        local r, reason = ready(); if not r then return false, reason end
        local _, item = find(id); if not item then return fail("找不到该预设") end
        local valid, why = validate_payload(item.payload); if not valid then return fail(why) end
        local ok, applied, detail = call(env.apply, item.payload, role)
        if not ok or applied ~= true then return fail(detail or "应用预设失败") end
        return true
    end
    function api.export(id)
        local r, reason = ready(); if not r then return false, reason end
        local _, item = find(id); if not item then return fail("找不到该预设") end
        local valid, why = validate_payload(item.payload); if not valid then return fail(why) end
        local data = FILE_MAGIC .. tostring(#item.name) .. "\n" .. tostring(#item.payload) .. "\n" .. item.name .. item.payload
        local filename = "preset-" .. item.id .. ".autochat"
        local ok, wrote, detail, path = call(env.export_file, filename, data)
        if not ok or wrote ~= true then return fail(detail or "导出预设失败") end
        return true, nil, path or detail
    end
    function api.import(path)
        local r, reason = ready(); if not r then return false, reason end
        local ok, data, why = call(env.import_file, path)
        if not ok or type(data) ~= "string" then return fail(why or "读取预设文件失败") end
        if #data > MAX_PAYLOAD + MAX_NAME + 64 or data:sub(1, #FILE_MAGIC) ~= FILE_MAGIC then return fail("预设文件格式无效或过大") end
        local pos = #FILE_MAGIC + 1
        local nl; nl, pos = parse_uint_line(data, pos, MAX_NAME)
        if not nl then return fail("预设名称长度无效") end
        local pl; pl, pos = parse_uint_line(data, pos, MAX_PAYLOAD)
        if nl == 0 or not pl or pl == 0 or pos + nl + pl - 1 ~= #data then return fail("预设文件长度无效") end
        local name = data:sub(pos, pos + nl - 1); pos = pos + nl
        local payload = data:sub(pos, pos + pl - 1)
        if not valid_name(name) then return fail("预设名称无效") end
        if duplicate_name(name) then return fail("预设名称已存在，请先重命名现有预设") end
        local valid, vwhy = validate_payload(payload); if not valid then return fail(vwhy) end
        if #entries >= MAX_PRESETS then return fail("最多保存32个预设") end
        if serial >= MAX_SERIAL then return fail("预设编号已用尽") end
        local next_serial = serial + 1
        local next_entries = {}; for i = 1, #entries do next_entries[i] = entries[i] end
        local id = string.format("P%08d", next_serial)
        next_entries[#next_entries + 1] = {id = id, name = name, payload = payload}
        local saved, savewhy = persist(next_entries, next_serial); if not saved then return fail(savewhy) end
        return true, nil, id
    end
    return api
end
-- END PRESET LIBRARY

automation = build_chat_automation({
    engine = function() return rawget(_G, 'stingray') end,
    context = function() return game_base and u64(game_base + M.CONTEXT_PTR) or nil end,
    read_file = function()
        local f = io.open(HOME .. 'AutoChat/settings.txt', 'r')
        if not f then return nil end
        local data = f:read('*a'); f:close(); return data
    end,
    write_file = function(data)
        local path = HOME .. 'AutoChat/settings.txt'
        local f = io.open(path .. '.tmp', 'w')
        if not f then return false end
        local ok, saved = pcall(function()
            if not f:write(data) then f:close(); return false end
            if not f:close() then return false end
            return kernel.MoveFileExA(path .. '.tmp', path, 9) ~= 0
        end)
        if not ok then pcall(function() f:close() end) end
        return ok and saved == true
    end,
    identity = function(peer) return peer_identity and peer_identity.lookup(peer) or nil end,
    colorize = function(prefix, argb)
        if #argb == 6 then argb = 'FF' .. argb end
        if #argb ~= 8 or not argb:match('^%x+$') then return prefix end
        return '<c=' .. argb:upper() .. '>' .. prefix .. '<c=FFFFFFFF>'
    end,
    send = function(text) return M.send_text(text, true, true) end,
    send_local = function(text) return M.display_local(text) end,
})
local PRESET_LIBRARY_PATH = HOME .. 'AutoChat/presets.txt'
local PRESET_EXPORT_DIR = HOME .. 'AutoChat/exports/'
local function preset_read(path, limit, missing_ok)
    local f, open_err, open_code = io.open(path, 'rb')
    if not f then
        -- The offline harness uses nil,nil for an absent file; native Lua provides
        -- errno 2. Other open errors must lock the library against overwrites.
        if missing_ok and (open_code == 2 or (open_err == nil and open_code == nil)) then return nil end
        return nil, '无法读取预设文件'
    end
    local read_ok, data = pcall(function() return f:read(limit) end)
    local close_ok, closed = pcall(function() return f:close() end)
    if not read_ok or type(data) ~= 'string' then return nil, '读取预设文件失败' end
    if not close_ok or closed ~= true then return nil, '关闭预设文件失败' end
    if #data >= limit then return nil, '预设文件超过大小限制' end
    return data
end
local function preset_atomic_write(path, data)
    local temp = path .. '.tmp'
    local f = io.open(temp, 'wb')
    if not f then return false, '无法创建预设文件' end
    local ok, wrote = pcall(function()
        local result = f:write(data)
        if not result then f:close(); return false end
        if not f:close() then return false end
        return kernel.MoveFileExA(temp, path, 9) ~= 0
    end)
    if not ok then pcall(f.close, f) end
    if not ok or wrote ~= true then return false, '原子保存预设文件失败' end
    return true
end
preset_library = build_preset_library({
    read_file = function()
        return preset_read(PRESET_LIBRARY_PATH, 16 * 1024 * 1024 + 1, true)
    end,
    write_file = function(data) return preset_atomic_write(PRESET_LIBRARY_PATH, data) end,
    capture = function(role) return automation.export_profile(role) end,
    validate = function(payload) return automation.validate_profile(payload) end,
    apply = function(payload, role) return automation.import_profile(payload, role) end,
    export_file = function(filename, data)
        if type(filename) ~= 'string' or not filename:match('^preset%-P%d%d%d%d%d%d%d%d%.autochat$')
            or filename:find('[/\\:]') or filename:find('%z') then
            return false, '无效的导出文件名'
        end
        mkdir(HOME .. 'AutoChat')
        mkdir(HOME .. 'AutoChat/exports')
        if #data > 1024 * 1024 + 256 then return false, '导出文件超过大小限制' end
        local path = PRESET_EXPORT_DIR .. filename
        local ok, why = preset_atomic_write(path, data)
        return ok, why, path
    end,
    import_file = function(path)
        if type(path) ~= 'string' then return nil, '请输入导入文件路径' end
        path = path:match('^%s*(.-)%s*$')
        if path:sub(1,1) == '"' and path:sub(-1) == '"' and #path >= 2 then
            path = path:sub(2,-2):match('^%s*(.-)%s*$')
        end
        if path == '' or path:find('%z') or path:match('[/\\]$') then
            return nil, '导入路径无效；请选择文件路径'
        end
        return preset_read(path, 1024 * 1024 + 257, false)
    end,
})
M.debug_preset_library = function() return preset_library end
M.options = automation.options
function M.debug_automation() return automation end

local function session_token()
    local snapshot = automation.snapshot()
    if not snapshot then return nil end
    return table.concat({tostring(snapshot.session), tostring(snapshot.context), snapshot.mine,
        snapshot.host or '?'}, '|')
end


-- BEGIN PEER IDENTITY
-- Inlined fragment. env.base() supplies only the caller's verified game build.
-- Reads only; creator peer IDs stay as 16 hex characters (never Lua numbers).
-- Native chat HUD 12F2F60 -> 1382650 uses these exact peer/color fields.
local function build_peer_identity(env)
    local COLORS = {"FFFF9D42", "FF81ACFE", "FFF68AFF", "FF6ED754"} -- AARRGGBB
    local function read(address, size)
        local value = env.read(address, size)
        if type(value) ~= "string" or #value ~= size then error("unreadable identity") end
        return value
    end
    local function u32(bytes, offset)
        local a, b, c, d = bytes:byte(offset, offset + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
    local function pointer(bytes)
        local value = u32(bytes, 1) + u32(bytes, 5) * 4294967296
        if value < 65536 or value >= 140737488355328 then error("invalid identity pointer") end
        return value
    end
    local function hex64(bytes)
        return string.format("%08X%08X", u32(bytes, 5), u32(bytes, 1))
    end
    local function clean_name(record)
        local field = record:sub(9, 0x89)
        local ending = field:find("\0", 1, true)
        if not ending then return nil end
        local name = field:sub(1, ending - 1):gsub("<[^>]*>", ""):gsub("[<>]", "")
        local parts, index = {}, 1
        while index <= #name do
            local first = name:byte(index)
            local count, value, minimum
            if first < 0x80 then count, value, minimum = 1, first, 0
            elseif first >= 0xC2 and first <= 0xDF then count, value, minimum = 2, first - 0xC0, 0x80
            elseif first >= 0xE0 and first <= 0xEF then count, value, minimum = 3, first - 0xE0, 0x800
            elseif first >= 0xF0 and first <= 0xF4 then count, value, minimum = 4, first - 0xF0, 0x10000
            else return nil end
            for offset = 1, count - 1 do
                local next_byte = name:byte(index + offset)
                if not next_byte or next_byte < 0x80 or next_byte > 0xBF then return nil end
                value = value * 64 + next_byte - 0x80
            end
            if value < minimum or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF) then return nil end
            if value >= 32 and not (value >= 127 and value <= 159) then
                parts[#parts + 1] = name:sub(index, index + count - 1)
            end
            index = index + count
        end
        name = table.concat(parts)
        if name == "" then return nil end
        return name
    end
    local function lookup(peer_id)
        local session, base = env.session(), env.base()
        if session == nil or session == false or type(base) ~= "number" or base < 65536
            or base >= 140737488355328 or base ~= math.floor(base) then return nil end
        local roster_bytes, context_bytes = read(base + 0x347CED8, 8), read(base + 0x347CEF0, 8)
        local roster, context = pointer(roster_bytes), pointer(context_bytes)
        local count_bytes = read(context + 0x16390, 4)
        local count = u32(count_bytes, 1)
        if count < 1 or count > 32 then return nil end
        local slot_address, slot_bytes, color_index
        for index = 0, count - 1 do
            local address = context + 0x16398 + index * 0x20
            local bytes = read(address, 0x20)
            if hex64(bytes) == peer_id then
                if slot_address then return nil end
                slot_address, slot_bytes, color_index = address, bytes, u32(bytes, 0x15)
            end
        end
        if not color_index or color_index > 3 then return nil end
        local record_address, record
        for index = 0, 7 do
            local address = roster + index * 0xC0
            local bytes = read(address, 0xC0)
            if hex64(bytes) == peer_id then
                if record_address then return nil end
                record_address, record = address, bytes
            end
        end
        if not record then return nil end
        local name = clean_name(record)
        if not name then return nil end
        local native_short = record:sub(0x8A, 0x8B)
        local first = native_short:byte(1)
        local valid_short = first and first >= 33 and first <= 126 and first ~= 60 and first ~= 62
            and native_short:sub(2, 2) == tostring(color_index + 1) and record:byte(0x8C) == 0
        local short = valid_short and native_short or ("P" .. tostring(color_index + 1))
        -- Reject a join/leave, context replacement, name update or slot reassignment.
        if read(record_address, 0xC0) ~= record or read(slot_address, 0x20) ~= slot_bytes
            or read(context + 0x16390, 4) ~= count_bytes
            or read(base + 0x347CED8, 8) ~= roster_bytes
            or read(base + 0x347CEF0, 8) ~= context_bytes
            or env.session() ~= session or env.base() ~= base then return nil end
        return {name = name, short = short, native_short = valid_short and native_short or nil,
                peer_id = peer_id, color = COLORS[color_index + 1], color_index = color_index}
    end
    return {lookup = function(peer_id)
        if type(peer_id) ~= "string" or #peer_id ~= 16 or not peer_id:match("^%x+$") then return nil end
        local ok, result = pcall(lookup, peer_id:upper())
        if ok then return result end
        return nil
    end}
end
-- END PEER IDENTITY
peer_identity = build_peer_identity({base=supported_game_base, read=read_at, session=session_token})
function M.debug_identity() return peer_identity end

-- BEGIN MARKER LOCALIZATION
-- Read-only marker localization for Steam build 25480438.
-- game.dll SHA256: 2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E
-- Proof: work/fork/foundation.lua Localization.bind / extra_localized_text.
-- The complete 99-byte wrapper signature uniquely matches current DLL RVA 17802E0.
-- 17802E6: mov rax,[rip+1BA601B] => engine_root global RVA 3326308.
-- 17802EF: mov rcx,[rax+10]; 17802F3: mov rax,[rcx+3E8].
-- 17802FA: mov ecx,ebx; 17802FC: call rax => const char* (*)(uint32_t).
-- Never call the wrapper: its missing-name fallback writes a shared scratch buffer.
-- env.base() supplies only an already fingerprint-verified game base.
-- env.read(address,n) performs guarded RPM; executable(address) must accept only
-- the verified helldivers2.exe lookup thunk dispatched to by this DLL wrapper.
-- env.call invokes the proven
-- lookup ABI and returns a numeric string pointer. This fragment performs no writes.
local function build_marker_localization(env)
 local signature_hex='40534883ec20488b051b60ba018bd9488b4810488b81e80300008bcbffd04885c074058038007555488b1549c0b9014c8d0526050502488d0d93040502448bcb488d420e493bc04c8d05c26cb800480f42caba0e00000048890d1ac0b901e8ddd5d6fe'
 local signature=signature_hex:gsub('..',function(h)return string.char(tonumber(h,16))end)
 local function address(n)
  return type(n)=='number' and n==n and n%1==0 and n>=65536 and n<140737488355328
 end
 local function read(at,n)
  if not address(at) or at+n>=140737488355328 then return nil end
  local ok,s=pcall(env.read,at,n)
  if ok and type(s)=='string' and #s==n then return s end
 end
 local function pointer(at)
  local s=read(at,8);if not s then return nil end
  local a,b,c,d,e,f,g,h=s:byte(1,8)
  if h~=0 or g>=128 then return nil end
  local n=a+b*256+c*65536+d*16777216+e*4294967296+f*1099511627776+g*281474976710656
  return address(n) and n or nil
 end
 local function proof()
  local ok,base=pcall(env.base)
  if not ok or not address(base) or read(base+0x17802e0,#signature)~=signature then return nil end
  local root=pointer(base+0x3326308);if not root then return nil end
  local engine=pointer(root+0x10);if not engine then return nil end
  local target=pointer(engine+0x3e8);if not target then return nil end
  local executable,yes=pcall(env.executable,target)
  if not executable or yes~=true then return nil end
  return {base,root,engine,target}
 end
 local function unchanged(before)
  local after=proof();if not after then return false end
  for i=1,4 do if before[i]~=after[i] then return false end end
  return true
 end
 local function utf8(s)
  local i=1
  while i<=#s do
   local a=s:byte(i);local n,lo,hi=0,128,191
   if a<128 then n=0
   elseif a>=194 and a<=223 then n=1
   elseif a>=224 and a<=239 then
    n=2;if a==224 then lo=160 elseif a==237 then hi=159 end
   elseif a>=240 and a<=244 then
    n=3;if a==240 then lo=144 elseif a==244 then hi=143 end
   else return false end
   if i+n>#s then return false end
   for j=1,n do
    local b=s:byte(i+j)
    if b<(j==1 and lo or 128) or b>(j==1 and hi or 191) then return false end
   end
   i=i+n+1
  end
  return true
 end
 local function lookup(key)
  if type(key)~='number' or key%1~=0 or key<=0 or key>4294967295 then return nil end
  local before=proof();if not before then return nil end
  local ok,at=pcall(env.call,before[4],key)
  if not ok or not address(at) or not unchanged(before) then return nil end
  local chunks,offset={},0
  while offset<1024 do
   local s=read(at+offset,math.min(32,1024-offset)) or read(at+offset,1)
   if not s then return nil end
   local stop=s:find('\0',1,true)
   if stop then
    chunks[#chunks+1]=s:sub(1,stop-1)
    if not unchanged(before) then return nil end
    local value=table.concat(chunks)
    if not utf8(value) then return nil end
    value=value:gsub('[%c]',' ')
    if value=='' or value:match('^#ID%[') then return nil end
    return value
   end
   chunks[#chunks+1]=s;offset=offset+#s
  end
  return nil
 end
 return {lookup=function(key)
  local ok,value=pcall(lookup,key);if ok then return value end
 end}
end
-- END MARKER LOCALIZATION
local marker_localization = build_marker_localization({
    base = supported_game_base,
    read = read_at,
    executable = function(address)
        -- The verified DLL wrapper dispatches to this main-executable thunk,
        -- not to a function in game.dll. Pin both images and the exact entry.
        if not supported_game_base() then return false end
        local base = module_base('helldivers2.exe')
        if not base or address ~= base + 0x321da0 then return false end
        local dos = read_at(base, 64)
        local pe = dos and u32_off(dos, 60)
        if not dos or dos:sub(1,2) ~= 'MZ' or not pe or pe < 64 or pe > 0x4000 then return false end
        local head = read_at(base + pe, 16)
        if not head or head:sub(1,4) ~= 'PE\0\0' or u32_off(head,8) ~= 0x6ab382e4 then return false end
        if read_at(address,16) ~= '\x33\xd2\xe9\x99\xfe\xff\xff\xcc\xcc\xcc\xcc\xcc\xcc\xcc\xcc\xcc' then return false end
        local page = page_state(address)
        if not page or page.allocation ~= base or page.state ~= MEM_COMMIT
            or page.kind ~= 0x1000000 then return false end
        return page.protect == 0x10 or page.protect == 0x20
            or page.protect == 0x40 or page.protect == 0x80
    end,
    call = function(address, key)
        local result = ffi.cast('const char *(*)(uint32_t)', address)(key)
        if result == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', result))
    end,
})
function M.debug_localization() return marker_localization end

-- BEGIN STRATAGEM CATALOG
-- Read-only StratagemInfo discovery for Steam build 25480438.
-- env.base() must enforce the supported game.dll fingerprint. Extra pins prove
-- the row/name/icon consumers. Layout facts and provenance: docs/STRATAGEM-REFERENCE-0.8.0.md.
-- No game calls, writes, asset loading, or static native-type identity mapping.
local function build_stratagem_catalog(env)
    -- Current native payload -> HellpodRack.payloads.item -> EntityComponentMap
    -- identity graph. Provenance/collisions: docs/stratagem-resource-aliases.json.
    -- Shared variants are absent from this exact-ID index and handled separately
    -- by the visible-rule index without claiming which native ID created them.
    local verified_aliases={
        ['02EECD0B1FA49630']=3343676429, ['09183066C4EBCE28']=272480476,
        ['12C8D71AC3897A5C']=3843705076, ['16474112801385B6']=2002187052,
        ['2152D5147B0AC418']=533318241, ['25AA2FD4643CF4EE']=3923676543,
        ['26E40437EA275296']=2007887745, ['2E9D0BDC48B09E60']=3078242205,
        ['31400A6A3003E29C']=1907808218, ['35A61296619CC47E']=2625074523,
        ['3828E2051AA9E897']=336693041, ['3A50B58B0553056A']=3353508219,
        ['43A58CB89CFA197C']=3455841218, ['5990123D142B16CB']=2232989803,
        ['5F3EC9BDA2BD8553']=3330450692, ['6CFCC7F8801A0266']=774795224,
        ['7617642765AC38C7']=2934950455, ['78A8185F63A70795']=2271469939,
        ['88C2D09AD85A7C9F']=512147393, ['88F61AFFF48AC8A4']=4152191751,
        ['967ED15E0BAE363B']=3353508219, ['96DE9CD50F7306E6']=992079466,
        ['9B2140378640432E']=2636699686, ['9F80D67A12A7E40F']=1298599997,
        ['A4E796F84801B40A']=272480476, ['A6A735ACCB4A327F']=14345846,
        ['A8CFFB316F0B5C5F']=875551083, ['B0F1B354BA1D38D8']=2265180087,
        ['B16C9D490AA59B77']=3288352984, ['B2B5E0D185605F9E']=1813634375,
        ['BF4CFD2AEABFB5A4']=3572024208, ['CC786F6491FE7E65']=890972990,
        ['D54B9505C0F72873']=2822568285, ['DE18775FA447A9BF']=1337271929,
        ['E8D5F49AD7780E54']=4261593827, ['F88D61A8FE1E0766']=3843705076,
        ['FDE262593307CA2F']=2822568285, ['FE3B29B2CFA63F9B']=153819019,
    }
    local verified_candidates={
        ['11C27D3BABB38956']={458198946,1567517764,3868299561},
        ['39AB99895147A3BF']={1432571981,3868299561},
        ['4EF9A47109239A58']={1907808218,3868299561},
        ['5052EC6A928CCF1A']={867876502,1295431756},
        ['80932FA0ED6901D3']={3413606544,3753216434},
        ['89C5493E08CA4207']={2207713849,3868299561},
        ['A94913CA014F7579']={867876502,1295431756},
    }
    local state={ready=false,status='等待战备目录',entries={},rules={},generation=0}
    local api={state=state}
    local by_id,by_name,by_resource={},{},{}
    local rule_names,rule_resources={},{},{}
    local pins={
        {0x66d54c,string.char(0x4b,0x8b,0x84,0xfd,0,0xb6,0x7c,3)},
        {0x179d962,string.char(0x8b,0x75,0x2c)},
        {0x183a1e5,string.char(0x49,0x8b,0x96,0xb0,0,0,0)},
    }
    local function word(s,at)
        local a,b,c,d=s:byte(at+1,at+4);assert(d,'short catalog word')
        return a+b*256+c*65536+d*16777216
    end
    local function pointer(s,at,alignment)
        local n=word(s,at)+word(s,at+4)*4294967296
        assert(n>=65536 and n<2^47 and n%(alignment or 4)==0,'invalid catalog pointer')
        return n
    end
    local function hex(s,at) return string.format('%08X%08X',word(s,at+4),word(s,at)) end
    local function f32(s,at)
        local bits=word(s,at);local sign=bits>=2147483648 and -1 or 1
        local exponent=math.floor(bits/8388608)%256;local fraction=bits%8388608
        assert(exponent<255,'nonfinite catalog float')
        return sign*(exponent==0 and fraction*2^-149 or (1+fraction/8388608)*2^(exponent-127))
    end
    local function group(name)
        -- Same family decisions as StratagemCooldown's classify/in_scope;
        -- beacon_color is red/blue/yellow and cannot identify green equipment.
        -- Correct its broad SHIELD GENERATOR keyword: a shield backpack is
        -- blue support equipment, whereas the deployed relay stays green.
        if name:match('^BACKPACK%.') then return 'blue','support' end
        if name:find('COMBAT WALKER',1,true) then return 'blue','mech' end
        if name:find('MINE',1,true) or name:find('TESLA',1,true)
            or name:find('SHIELD GENERATOR',1,true) or name:find('RELAY',1,true) then return 'green','green' end
        local prefix=name:match('^([^.]+)')
        if prefix=='ORBITAL' then return 'red','orbital' end
        if prefix=='EAGLE' then return 'red','eagle' end
        if prefix=='TEAM WEAPONS' or prefix=='BACKPACK' or prefix=='CONSUMABLES' then return 'blue','support' end
        if prefix=='VEHICLES' then return 'blue','vehicle' end
        if prefix=='SENTRYS' or prefix=='SENTRIES' or prefix=='EMPLACEMENTS' then return 'green','green' end
        if prefix=='PRESIDENT REWARDS' then
            if name:find('MACHINEGUN',1,true) or name:find('BACKPACK',1,true) then return 'blue','support' end
            if name:find('SENTRY',1,true) then return 'green','green' end
        end
        return 'other',(prefix=='MISSIONS' or prefix=='MISSIONS CLAN STATION') and 'mission' or 'other'
    end
    local function capture(base)
        local guards,budget={},0
        local function read(at,n)
            assert(type(at)=='number' and at%1==0 and at>=65536 and at+n<2^47
                and n>0 and n<=65536,'invalid catalog read bounds')
            budget=budget+1;assert(budget<=2048,'catalog read budget')
            local s=env.read(at,n);assert(type(s)=='string' and #s==n,'catalog data unreadable')
            return s
        end
        local function guard(at,n)
            local s=read(at,n);guards[#guards+1]={at,s};return s
        end
        for _,pin in ipairs(pins) do assert(guard(base+pin[1],#pin[2])==pin[2],'catalog signature changed') end
        -- StratagemCooldown scans 0..255; every optional slot is independently
        -- qualified. A non-null pointer is never sufficient proof of a row.
        local slots=guard(base+0x37cb600,256*8)
        local entries,ids,keys,aliases={},{},{},{}
        local function unique(index,key,row)
            if key==0 or key=='0000000000000000' then return end
            if index[key]==nil then index[key]=row elseif index[key]~=row then index[key]=false end
        end
        for kind=1,255 do
            if word(slots,kind*8)~=0 or word(slots,kind*8+4)~=0 then
                local ok,at=pcall(pointer,slots,kind*8)
                local raw=ok and env.read(at,0xb8) or nil
                if type(raw)=='string' and #raw==0xb8 and word(raw,0)==kind and word(raw,4)~=0
                    and word(raw,0x74)<=3 then
                    guards[#guards+1]={at,raw}
                    local name_at=pointer(raw,0x10,1)
                    local text=guard(name_at,160);local ending=text:find('\0',1,true)
                    assert(ending,'unterminated catalog name')
                    local debug_name=text:sub(1,ending-1)
                    assert(#debug_name>=2 and not debug_name:find('[^ -~]'),'invalid catalog name')
                    local id=word(raw,4);assert(not ids[id],'duplicate stable stratagem id')
                    local name_key,upper_key=word(raw,0x2c),word(raw,0x28)
                    local color,family=group(debug_name:upper())
                    local icon=hex(raw,0xb0)
                    local cd=f32(raw,0x68);assert(cd>=0 and cd<=86400,'invalid catalog cooldown')
                    local payload_count=word(raw,0xa0);assert(payload_count<=64,'invalid catalog payload count')
                    -- Use the already validated native debug string. Resolving every
                    -- localization key here calls into a game function during the
                    -- first update; discovery and rule identity do not need it.
                    local row={id=id,type=kind,name_key=name_key,name_upper_key=upper_key,name=debug_name,
                        debug_name=debug_name,call_type=word(raw,0x74),group=color,family=family,
                        icon=icon~='0000000000000000' and icon or nil,icon_kind='material',
                        cooldown=cd,payload_count=payload_count,resource_aliases={}}
                    entries[#entries+1]=row;ids[id]=row
                    unique(keys,name_key,row);unique(keys,upper_key,row)
                end
            end
        end
        assert(#entries>0,'empty catalog')
        -- Visible configuration identity is stricter than a single marker key:
        -- both native name keys and the call type must match exactly. The rule
        -- ID names the settings representative, never the observed caller ID.
        local groups,rules,rule_keys,rule_aliases={},{},{},{}
        local function preferred(a,b)
            local function variant(row)
                local name=row.debug_name:upper()
                return name:match('^PRESIDENT REWARDS%.') or name:match('^%[TUTORIAL%]')
                    or name:match('^TUTORIAL')
            end
            local av,bv=variant(a) and 1 or 0,variant(b) and 1 or 0
            if av~=bv then return av<bv end
            local ai,bi=a.icon and 1 or 0,b.icon and 1 or 0
            if ai~=bi then return ai>bi end
            return a.id<b.id
        end
        for _,row in ipairs(entries) do
            local identity=row.name_upper_key>0 and row.name_key>0
                and table.concat({row.name_upper_key,row.name_key,row.call_type},':') or 'id:'..row.id
            groups[identity]=groups[identity] or {};local members=groups[identity]
            members[#members+1]=row
        end
        for _,members in pairs(groups) do
            table.sort(members,preferred)
            local representative=members[1];local variants={}
            for _,row in ipairs(members) do variants[#variants+1]=row.id end
            table.sort(variants);representative.variant_ids=variants
            rules[#rules+1]=representative
            for _,row in ipairs(members) do
                row.rule_id=representative.id
                row.group,row.family=representative.group,representative.family
                unique(rule_keys,row.name_key,representative)
                unique(rule_keys,row.name_upper_key,representative)
            end
        end
        table.sort(rules,function(a,b) return a.type<b.type end)
        -- A payload may identify the rack rather than its contained equipment;
        -- package/stratagem identity is not a world target identity. Only the
        -- reviewed entity graph and externally VERIFIED aliases enter this index.
        local function aliases_from(source)
            for resource,id in pairs(source) do
                local row=ids[id]
                if row and type(resource)=='string' and resource:match('^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$') then
                    resource=resource:upper();unique(aliases,resource,row)
                    unique(rule_aliases,resource,ids[row.rule_id])
                    row.resource_aliases[#row.resource_aliases+1]=resource
                end
            end
        end
        aliases_from(verified_aliases)
        aliases_from(env.resource_aliases or {})
        -- A shared resource can resolve only a shared visible policy, and only
        -- when its ENTIRE reviewed candidate set is observed in that one rule.
        -- Missing candidates or different key pairs/call types remain unknown.
        for resource,candidates in pairs(verified_candidates) do
            local representative,complete=nil,true
            for _,id in ipairs(candidates) do
                local row=ids[id]
                if not row then complete=false;break end
                local rule=ids[row.rule_id]
                if representative and representative~=rule then complete=false;break end
                representative=rule
            end
            if complete and representative then unique(rule_aliases,resource,representative)
            else rule_aliases[resource]=false end
        end
        assert(env.base()==base,'catalog build changed')
        for _,g in ipairs(guards) do assert(read(g[1],#g[2])==g[2],'catalog changed during scan') end
        return entries,ids,keys,aliases,rules,rule_keys,rule_aliases
    end
    function api.reset()
        state.ready=false;state.entries={};state.rules={};state.status='等待战备目录'
        state.last_scan=nil;by_id,by_name,by_resource={},{},{}
        rule_names,rule_resources={},{}
    end
    function api.scan(now)
        if now~=nil and (type(now)~='number' or now~=now or math.abs(now)==math.huge) then return 0,state.status end
        local base=env.base()
        if not base then api.reset();state.status='战备目录：不支持的游戏版本';return 0,state.status end
        if now and state.ready and state.base==base and state.last_scan
            and now>=state.last_scan and now-state.last_scan<5 then return #state.entries,state.status end
        local ok,entries,ids,keys,aliases,rules,rule_keys,rule_aliases=pcall(capture,base)
        if not ok then api.reset();state.status='战备目录数据暂不可读';return 0,state.status end
        state.entries,by_id,by_name,by_resource=entries,ids,keys,aliases
        state.rules,rule_names,rule_resources=rules,rule_keys,rule_aliases
        state.base=base;state.ready=true;state.last_scan=now;state.generation=state.generation+1
        state.status='战备目录读取就绪（'..#entries..'）'
        return #entries,state.status
    end
    function api.list() return state.entries end
    function api.list_rules() return state.rules end
    function api.lookup(id) return by_id[tonumber(id)] end
    function api.resolve_name_key(key) return by_name[tonumber(key)] or nil end
    function api.resolve_resource(resource)
        return type(resource)=='string' and by_resource[resource:upper()] or nil
    end
    function api.resolve_rule_name_key(key) return rule_names[tonumber(key)] or nil end
    function api.resolve_rule_resource(resource)
        return type(resource)=='string' and rule_resources[resource:upper()] or nil
    end
    return api
end
-- END STRATAGEM CATALOG

local stratagem_catalog=build_stratagem_catalog({base=supported_game_base,read=read_at})
local catalog_scan_phase = 0
function M.debug_stratagem_catalog()return stratagem_catalog end
local function enrich_stratagem_event(event,now)
    if event.category~='stratagem' then return end
    stratagem_catalog.scan(now)
    local row=stratagem_catalog.lookup(event.stratagem_id)
        or stratagem_catalog.resolve_resource(event.resource)
        or stratagem_catalog.resolve_name_key(event.localization_key)
    if row then
        event.stratagem_id=row.id;event.stratagem_rule_id=row.rule_id or row.id;event.stratagem_group=row.group
    else
        local rule=stratagem_catalog.resolve_rule_resource(event.resource)
            or stratagem_catalog.resolve_rule_name_key(event.localization_key)
        if rule then event.stratagem_rule_id=rule.id;event.stratagem_group=rule.group;event.stratagem_ambiguous=true end
    end
end
function M.debug_enrich_stratagem_event(event,now)enrich_stratagem_event(event,now)end

-- BEGIN NATIVE PING EVENTS
-- Third-party reference license (etxp HD2-G60-Smart-Targeting):
--[[
MIT License

Copyright (c) 2026 etxp

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]
-- Read-only native ping adapter for Steam build 25480438 only.
-- game.dll SHA256: 2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E
-- env.base() must already enforce that supported build; no native calls or writes here.
-- Observed ring/entity layouts (MIT):
-- https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_ping.lua
-- https://github.com/etxp/HD2-G60-Smart-Targeting/blob/main/src/g60/native_target_data.lua
-- Player/peer/avatar layouts, same DLL fingerprint:
-- https://github.com/SkyeShade/HD2Runtime/blob/master/runtime/event_world.lua
-- https://github.com/SkyeShade/HD2Runtime/blob/master/domains/event_natives.lua
-- Classification facts: current-build enemy kind intersected with AiEnemyComponentData;
-- HealthComponentData.unit_size: 0 Small, 1 Medium, 2 Large, 3 Massive (2026-09-22).
-- Hostile faction + Spottable membership are required; flying components take priority.
-- https://github.com/Darctor/Helldivers2_RawData/tree/main/Data/entities
-- https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/enums/UnitSize.txt
-- Tactical map pins use replicated actor state, not the HUD ping ring. Current
-- DLL 18B97A0 writes actor+547830 (stride78); 18B3A90 renders those same pins.
-- Objective names: 1255D60 resolves entity -> definition (32EF870,153 x A0),
-- 18B4AEC selects definition+38 or runtime+1050. Importance is runtime+1038,
-- populated from the CURRENT mission by 5D0DF0, never inferred from the name.
-- Local Custom UI confirms enemy material A1919FA085C97B18, ground 4B81B73A36657DC9;
-- Better Map Markers shares map material EA6C3908C95DD015. These asset hashes do NOT
-- prove a numeric ring-kind enum and are never used as one.
-- Special identities: current RawData EncyclopediaEntryComponentData / EntityComponentMap,
-- HD2Runtime SupportWeaponCapabilities and FileDiver actual resource paths.
-- https://github.com/Darctor/Helldivers2_RawData/blob/main/Data/settings/EntityComponentMap.json
-- https://github.com/SkyeShade/HD2Runtime/blob/master/sdk/SupportWeaponCapabilities.json
-- https://github.com/xypwn/filediver/blob/master/hashes/hashes.txt
-- Enum: https://github.com/shalzuth/HelldiversData/blob/master/data/enums/HudMarkerType.json
-- Historical HUD enum is corroborated by current DLL Map21 producer below.
-- Ordinary ammo, stims, grenades and samples are intentionally excluded.
local EXCLUDED_SUPPLIES = {
    ['9D4935FA69B6B41A']=true, ['307E09E7698881BA']=true, ['4932CBF33CD47EF9']=true,
    ['4C63119F69165321']=true, ['5016EE397FDCFB6C']=true, ['64B49B9D8A445266']=true,
    ['700E9500E95541BF']=true, ['79CCFFD281E3F3A9']=true, ['86F3CB87D97942B4']=true,
    ['92BCC263E751BD45']=true, ['97AF34FBF093409C']=true, ['A9936CBE561E8180']=true,
    ['AD972A2E815A49AA']=true, ['B39FCF5C73D5C383']=true, ['B4CA4C5B922F7965']=true,
    ['BD30758426ED2566']=true, ['BEB2A0F09E36BF72']=true, ['D463836441CD0BA7']=true,
    ['E4EEB96023DF6A99']=true,
}
-- BEGIN MISSION TARGET CATALOG
-- Generated by tools/generate_mission_targets.py from docs/mission-targets.json.
-- Current Spottable membership + reviewed resource paths; main/side roles are not inferred.
local MISSION_TARGETS = {
    ['019F988FA225DD1C'] = {'building', '逃生舱', 0},
    ['01A88312C8889D5F'] = {'building', '炮塔控制终端', 0},
    ['051DA4B57216A005'] = {'building', '任务终端', 0},
    ['06D3C4720E642FC1'] = {'building', '虫卵群', 0},
    ['0722B3A72ADE6CB1'] = {'building', 'TCS 主塔', 0},
    ['073270650F859DD0'] = {'building', '装有化学武器的背包', 3054644200},
    ['0801B6B3C5D12EBC'] = {'building', '地面全地形采集钻机', 3023900891},
    ['095686275A113614'] = {'building', '尖啸虫巢穴', 3496786382},
    ['0A12D5A29CDF2D40'] = {'building', '撤离信标', 0},
    ['0DC9084E50C051F3'] = {'building', '铂金条', 2492072473},
    ['0DF874E208040D2F'] = {'building', '虫穴', 3277626454},
    ['0E88F182E83A4275'] = {'building', '任务交互物', 0},
    ['0F1A0189B327C5CB'] = {'building', '超级固态硬盘', 714952129},
    ['10E44156F08786EF'] = {'building', '生物处理器', 0},
    ['1262CD07B196AAC3'] = {'building', '任务交互物', 0},
    ['1312B769F47256D9'] = {'building', 'SEAF 防空导弹阵地', 1563965062},
    ['142637570A721CB9'] = {'building', '轨道炮弹药供给装置', 0},
    ['15031543894C3F3C'] = {'building', 'TCS 孢子喷涌体', 3139947901},
    ['1556FE9780D5D52D'] = {'building', '任务终端', 0},
    ['15E2A2B11BA78C5A'] = {'building', '任务交互物', 0},
    ['162256BD224F6265'] = {'building', '加注站终端', 0},
    ['16D7BA33ED511664'] = {'building', '控制塔终端', 0},
    ['1A3B52A4D3F166F7'] = {'building', '光能者城市巨炮终端', 0},
    ['1B633762874A709A'] = {'building', '首都防御设施', 0},
    ['1C2360811101BCCE'] = {'building', '冷却管道', 0},
    ['1D72EBD1A6916E67'] = {'building', '装配设施曲柄', 0},
    ['22CC0ED4CEB9CB68'] = {'building', '机器人制造厂', 3794527478},
    ['23C85E970FB46685'] = {'building', '战备干扰器', 0},
    ['245F7D8792CD23E5'] = {'building', '军事通信交付点', 0},
    ['24ACA2B4D15D2E2F'] = {'building', '发电机组', 0},
    ['25C5B9818EF934E3'] = {'building', '任务终端', 0},
    ['2670E0047B2EB409'] = {'building', '探测塔', 0},
    ['2778F620A6E414AF'] = {'building', '光能者气象装置核心', 0},
    ['2862C5AFC2E837BA'] = {'building', '任务交互物', 0},
    ['29D0A1DFB5FD811F'] = {'building', '任务交互物', 0},
    ['2B581BBB45DA1225'] = {'building', '燃料提取终端', 0},
    ['2B5D3186EE3A4A84'] = {'building', '变异虫卵', 555942570},
    ['2D3BC1683A54298D'] = {'building', '情报包裹', 3717706265},
    ['317B2C0E4D10E293'] = {'building', '炮塔控制数据交付点', 0},
    ['319388D1D8ACB8F3'] = {'building', 'TCS 任务终端', 0},
    ['3231BD912357A9E1'] = {'building', '任务终端', 0},
    ['33F2BCDAE3A12592'] = {'building', '超级固态硬盘', 714952129},
    ['346C42FD9C915904'] = {'building', '轨道炮终端', 0},
    ['36C5E772F8A3B9D3'] = {'building', '超级固态硬盘', 714952129},
    ['36CC8EAD2BB18D78'] = {'building', '虫穴', 3277626454},
    ['372481E910C05A76'] = {'building', '战术摄像机', 2071327434},
    ['37EB67CB7ACE7410'] = {'building', '能量核心站', 0},
    ['3A28A51BAA029E1A'] = {'building', '抽油任务钻机', 3477736393},
    ['3A2CEF12ED32A088'] = {'building', '虫穴', 3277626454},
    ['3CE56937E0BD28BD'] = {'building', '工厂区域大门', 0},
    ['3DE2415EA33B6897'] = {'building', '黑匣子', 4046999266},
    ['3E099DDF97ACF85F'] = {'building', '样本箱', 1332022394},
    ['3E993C23A25E6B88'] = {'building', '机器人任务数据', 714952129},
    ['3F2C34C69CFC94B2'] = {'building', '任务终端', 0},
    ['3F70E3503A3293F9'] = {'building', '鹈鹕燃料运输机', 0},
    ['3F8734AEC15B82AD'] = {'building', '鹈鹕飞船', 0},
    ['4012166966A9E6E9'] = {'building', 'SEAF 火炮弹药', 3660636186},
    ['4232EE48E2CFD24E'] = {'building', '机器人制造厂', 644365486},
    ['423FF97D57AB04F5'] = {'building', '地面全地形采集钻机', 3023900891},
    ['424036E9F7DE9A1E'] = {'building', '冷却阀门', 0},
    ['42786DC1DD1EACAD'] = {'building', '核导弹', 4280970126},
    ['43EC60F66E7E046B'] = {'building', '装有化学武器的背包', 3054644200},
    ['44748FFC63F78A72'] = {'building', '“虫窝破裂者”钻机', 1998289914},
    ['459DD5EB8C68C63F'] = {'building', '工厂区域入口', 0},
    ['460576BBDCF770D0'] = {'building', '军械库发电机', 0},
    ['46918A7483D70F3E'] = {'building', '任务交互物', 2851008997},
    ['4747668D063EEC06'] = {'building', '任务终端', 0},
    ['4776A1CF3F19A13B'] = {'building', '潜行虫巢穴', 3277626454},
    ['480445A33039CE5E'] = {'building', '虫卵群', 0},
    ['4A3E722B5A865E38'] = {'building', '黑匣子', 3346432464},
    ['4C182656063F121A'] = {'building', '控制塔数据交付点', 0},
    ['4FB8EB356AC8553E'] = {'building', '机器人制造厂', 3794527478},
    ['5158E582FBEB26BD'] = {'building', '机器人制造厂', 3794527478},
    ['516E4FA1D2AE46AE'] = {'building', '任务终端', 0},
    ['52D52230745B66A0'] = {'building', '任务终端', 0},
    ['534000F7801EA508'] = {'building', '数据收集交付点', 0},
    ['542A14BA4D755F4E'] = {'building', '雷达站终端', 0},
    ['54B66A0D35FDF785'] = {'building', '有机物提取终端', 0},
    ['5684D928C9AB00D1'] = {'building', '发射代码', 767789391},
    ['5726276FED2241B3'] = {'building', '轨道炮弹药', 2928771667},
    ['57DB57121F3E7ED2'] = {'building', '非法广播塔', 0},
    ['5852B7D2F865966C'] = {'building', '采油机', 0},
    ['5A14BF4098BF4259'] = {'building', '任务终端', 0},
    ['5CF84155E60C6E4D'] = {'building', '机械虫洞', 3277626454},
    ['60544E51EE260967'] = {'building', '光能者城市巨炮', 0},
    ['62D2C45A8B9703CC'] = {'building', '中继塔', 1549126177},
    ['646F5AEBDFF603CB'] = {'building', '黑匣子交付点', 0},
    ['68053EAE33FFA084'] = {'building', '光能者科技枢纽中枢', 0},
    ['682871578A4E98EB'] = {'building', '空军基地控制塔', 0},
    ['6838D8C197CC9C78'] = {'building', '轨道炮', 0},
    ['6845B56D77E61B9F'] = {'building', '军事通信终端', 0},
    ['688949109126ECE4'] = {'building', '机械虫洞', 3277626454},
    ['68BFAC3C8A03BB83'] = {'building', '战备干扰器终端', 0},
    ['6B7EE87FB2EC6455'] = {'building', '任务交互物', 0},
    ['6C62E2E25E084083'] = {'building', 'SEAF 火炮弹药', 0},
    ['6DB870D59730EE07'] = {'building', '中型冷却管道', 0},
    ['6DC9F65AF69783BD'] = {'building', '采油阀门', 0},
    ['6E499C5C95B019FC'] = {'building', '指挥碉堡', 245997106},
    ['6FDCD0D7F8EAF267'] = {'building', 'TCS 支柱', 0},
    ['705B0136A9A9D73A'] = {'building', '任务弹头', 3660636186},
    ['75BE82ED8592A6B3'] = {'building', '鹈鹕运输机', 0},
    ['766E7B3BDF79452F'] = {'building', '任务终端', 0},
    ['7B0F8449CA9D2DA0'] = {'building', '鹈鹕运输机', 0},
    ['7BDAA1BB44C3EE1C'] = {'building', '虫族战备干扰器', 0},
    ['7C81DE10F0023D08'] = {'building', '旗帜', 2728206271},
    ['7CA1B74B22C2EB9C'] = {'building', '任务交互物', 3660636186},
    ['7E4876D0DBF9C981'] = {'building', '中继塔终端', 0},
    ['7E4C6B45BCC45C3F'] = {'building', '虫穴', 3277626454},
    ['867FFD3B4EA22E05'] = {'building', '装配设施冷却管道', 0},
    ['888536AE851DCA05'] = {'building', '数据上传交互装置', 0},
    ['888EAAFD58C03C75'] = {'building', '任务货运车', 581608860},
    ['8901F188DB366B4B'] = {'building', '虫穴', 3277626454},
    ['8A50B60B22186B9B'] = {'building', '巢穴世界采油阀门', 0},
    ['8AD7A3118BD48D1C'] = {'building', '黑匣子', 4046999266},
    ['8C31B749759CBD61'] = {'building', '虫穴', 3277626454},
    ['8F7D4D9C196018C8'] = {'building', '旗帜', 2728206271},
    ['90001FEAC563D6A1'] = {'building', '公文包', 4194145910},
    ['91209E5AF7A9660B'] = {'building', '有机物提取软管接口', 0},
    ['913B7D337E61EE4C'] = {'building', '生物处理器终端', 0},
    ['925158186B8FD952'] = {'building', '中继塔对准开关', 0},
    ['95D717E4AA9ED443'] = {'building', '光能者城市巨炮曲柄', 0},
    ['973A2984F0CA6A30'] = {'building', '机器人通信终端', 0},
    ['97DD3178E9F0AB70'] = {'building', '虫穴', 3277626454},
    ['9A0D640BF4ABB03B'] = {'building', '任务终端', 0},
    ['9A1F728716DA05B5'] = {'building', '超级地球旗杆', 0},
    ['9A6A60CF4BAD9FA5'] = {'building', '防御任务终端', 0},
    ['9B58C95349D051F9'] = {'building', '虫穴', 3277626454},
    ['9B75A86003C2A1F4'] = {'building', '采油任务终端', 0},
    ['9BFC8FCD68B09F28'] = {'building', 'SEAF 火炮', 0},
    ['9D3A7E11095E3355'] = {'building', '任务旗帜', 2728206271},
    ['9D8632A79C2D9789'] = {'building', '虫穴', 3277626454},
    ['9E0E5E86A44C62A1'] = {'building', '机器人任务数据', 714952129},
    ['9EA89CEEA6F8E766'] = {'building', '幼虫储存器', 1492050893},
    ['A09A19371FECD6A3'] = {'building', 'TCS 任务终端', 0},
    ['A0EA22BD370D4D72'] = {'building', '平民撤离门', 0},
    ['A1A7B76B29088843'] = {'building', '机器人制造厂', 3794527478},
    ['A1BDB3A13E3633DD'] = {'building', 'SEAF 防空导弹阵地', 1563965062},
    ['A1E90D748B3D8AAA'] = {'building', '任务终端', 0},
    ['A21F08920052C27E'] = {'building', '发电站', 0},
    ['A3D5F183F8A2B768'] = {'building', 'SEAF 火炮装填架', 0},
    ['A531053415EB57DA'] = {'building', '任务终端', 0},
    ['A7381B87F3A3B455'] = {'building', '超级固态硬盘', 714952129},
    ['A8AE6952B375EF6C'] = {'building', '武装运输舰制造厂', 3794527478},
    ['A8B999A49716BF41'] = {'building', '光能者传送门', 0},
    ['AA28CAF964D05500'] = {'building', '孢子喷涌体', 3139947901},
    ['AC6E5FA7DB7FE621'] = {'building', '任务终端', 0},
    ['ACC611541CD839DB'] = {'building', '撤离信标', 0},
    ['AEAEF7A1851E6C9D'] = {'building', '机器人防空炮阵地', 4042981686},
    ['AFC719AF96F10DC3'] = {'building', '受感染高塔', 3896690221},
    ['B127552416CE512E'] = {'building', '任务交互物', 0},
    ['B19C942FFD41C4A5'] = {'building', '防御任务发射井', 0},
    ['B1D938C07E30C5DB'] = {'building', '洲际导弹发射井', 0},
    ['B27FE88BC708A680'] = {'building', '任务终端', 0},
    ['B31073E494A0643A'] = {'building', '含水层钻机', 1436471677},
    ['B44F8D33E16202FB'] = {'building', '精炼厂终端', 0},
    ['B50DBC63A02C0D3B'] = {'building', '任务交互物', 0},
    ['B663751EB459D242'] = {'building', '光能者古物', 3335887011},
    ['B6A181ADCF547AEB'] = {'building', '虫穴', 3277626454},
    ['B6FE4BD12C248286'] = {'building', '装配设施夹具', 0},
    ['B7C9C0D0C39AA349'] = {'building', '黑匣子回收终端', 0},
    ['B8A49F22D83D52CF'] = {'building', '洲际导弹发射井锁', 0},
    ['BA80E8D1331D8489'] = {'building', '电力恢复终端', 0},
    ['BADBA9174CAEE9FF'] = {'building', '洲际导弹发射终端', 0},
    ['BAF9DBD86B22270A'] = {'building', '统御舰', 4134104203},
    ['BB2570AFA4C767D8'] = {'building', '数据上传交付点', 0},
    ['BB2984B9B83EBFD1'] = {'building', '光能者收割设施', 0},
    ['BC2AF8548C6D5E06'] = {'building', '虫穴', 3277626454},
    ['BD20741E0225BD33'] = {'building', '有机装配设施终端', 0},
    ['BF908A82B8E787AC'] = {'building', 'TCS 支撑建筑', 0},
    ['C02C2623B6359BB3'] = {'building', '任务交互物', 0},
    ['C066DCFAA61E740C'] = {'building', '数据收集终端', 0},
    ['C2F0CC038E724374'] = {'building', 'SEAF 火炮终端', 0},
    ['C3D9B291BD97B935'] = {'building', 'TCS 支撑建筑', 0},
    ['C71C0C7B2E688B9B'] = {'building', '机密数据', 3839214628},
    ['C8F9A2233048B836'] = {'building', '任务交互物', 354671336},
    ['CB036409F28330E7'] = {'building', '任务终端', 0},
    ['D0444F56A7D86E2B'] = {'building', '发电机', 0},
    ['D3CEB59066593FBD'] = {'building', '工厂任务终端', 0},
    ['D4A349DAAE850283'] = {'building', '光能者城市巨炮锁', 0},
    ['D564F4E9E3A98599'] = {'building', '燃料补给终端', 0},
    ['D666AA61D804D311'] = {'building', '虫穴', 3277626454},
    ['D6A1019CF530FA1D'] = {'building', '中继塔控制终端', 0},
    ['D84FFC32A6E640A8'] = {'building', '机器人运输舰', 1485224906},
    ['D86B3F92DD4AAEDC'] = {'building', '平民撤离主终端', 0},
    ['D88547FF02B212E8'] = {'building', '机器人工厂', 0},
    ['D888E2EC286A4B0D'] = {'building', '任务终端', 0},
    ['D8A28BFB827392BE'] = {'building', '聚变电池', 280534572},
    ['DB59777F0ABAF6AF'] = {'building', '任务货运集装箱', 0},
    ['DC19126D15692D04'] = {'building', '任务交互物', 0},
    ['DC901B71A3A73B9A'] = {'building', '孢肺', 989829386},
    ['DEF983C174B8E083'] = {'building', '巢穴世界燃料提取终端', 0},
    ['DF3C4F91E298BFA4'] = {'building', '任务钻机', 1998289914},
    ['DF657367D712CD8E'] = {'building', '洲际导弹发射井', 0},
    ['DFA99372CEFBF84D'] = {'building', '任务终端', 0},
    ['E02E6BD34B606A85'] = {'building', '孢子喷涌体', 3139947901},
    ['E05784031312C43F'] = {'building', '巢穴世界燃料提取阀门', 0},
    ['E09FCB5A280ACB1D'] = {'building', '任务交互物', 0},
    ['E2E6E77DCC99A1CB'] = {'building', '生物处理器', 0},
    ['E41334ADBEAF0D12'] = {'building', '雷达任务终端', 0},
    ['E48C901A7175F638'] = {'building', '科研站数据上传设施', 0},
    ['E4BE3FDF0C857B7F'] = {'building', '任务交互物', 0},
    ['E73F6B5A100B7230'] = {'building', '移动雷达', 0},
    ['E98D623E013A113B'] = {'building', '任务交互物', 0},
    ['E9929CB8800E1C8F'] = {'building', '巢穴世界管道疏通阀门', 0},
    ['EAE962D85C0C2D4A'] = {'building', '抽油任务钻机', 3477736393},
    ['EECB5C13AE48637B'] = {'building', '数据上传主终端', 0},
    ['EF3A4136B21592CB'] = {'building', '鹈鹕飞船', 0},
    ['F08AE61266335A40'] = {'building', '非法科研站', 0},
    ['F0B98FB953B13960'] = {'building', '机器人制造厂', 3794527478},
    ['F1ADE19F87015997'] = {'building', '任务终端', 0},
    ['F1C4856CC0EAF603'] = {'building', '防空导弹发射终端', 0},
    ['F41432892465C5FD'] = {'building', '超级固态硬盘', 714952129},
    ['F45D1A033E848901'] = {'building', '大型冷却管道', 0},
    ['F598598C47617605'] = {'building', '任务交互物', 0},
    ['F78BF0FF5C62140D'] = {'building', '虫穴', 3277626454},
    ['F8E53685C00D926A'] = {'building', '任务交付点', 0},
    ['FB0AF9C18AAEFEF2'] = {'building', '坠毁的收割者', 0},
    ['FBD932EAC8E28E0B'] = {'building', '主发电站', 0},
    ['FF5CC825B9571052'] = {'building', '机器人迫击炮阵地', 2649067399},
    ['FF660C3FD24531A0'] = {'building', '燃料提取软管接口', 0},
}
-- END MISSION TARGET CATALOG

-- BEGIN ENEMY TARGET CATALOG
-- Generated offline by tools/generate_enemy_catalog.py from docs/enemy-catalog.json.
-- Game 1.007.100, 2026-09-22; hostile + Spottable only; flight before size.
local ENEMY_TARGETS = {
    ['0002BA767DF856F3'] = {'small_enemy', '劫掠者', 2454424572},
    ['0883366204E1CCC5'] = {'medium_enemy', '凝视者', 1661895142},
    ['089833D2880D9E06'] = {'small_enemy', '机枪奇袭者（炽灼部队）', 586021653},
    ['08E6FFC2474287BD'] = {'medium_enemy', '监视者 MK2', 3363066353},
    ['09DFB04B2E578BC3'] = {'small_enemy', '激光装甲兵', 4039692928},
    ['09FE0BE51A23396C'] = {'medium_enemy', '惑乱者（女）', 1371180916},
    ['0AB7B92B131C228C'] = {'large_enemy', '爆裂强袭虫', 3903153972},
    ['0ADC9F9173AD8E1D'] = {'small_enemy', '无票者（中型）', 4211847317},
    ['10081ACEF6163EF6'] = {'medium_enemy', '酸液武斗虫', 3365898186},
    ['137988CEA16458F7'] = {'large_enemy', '巨型碾压者', 613980508},
    ['1448D494665D01A0'] = {'small_enemy', '凝视者 MK2', 2259733865},
    ['1897BDD32105D2DC'] = {'large_enemy', '巨型炙焰者 MK2（炽灼部队）', 1775662925},
    ['19E18B46EC55D94A'] = {'flying_enemy', '刺魟', 4160806915},
    ['1A7FCDFF98C664B0'] = {'large_enemy', '强袭虫', 1299714559},
    ['1B5B9AC4F96B36E5'] = {'small_enemy', '机械统帅（炽灼部队）', 621159586},
    ['1E66EE1F6F7FD00E'] = {'large_enemy', '巨型抹煞者', 1560770730},
    ['1F0A91729C0004E0'] = {'small_enemy', '孢裂追猎虫', 1210082392},
    ['20B9C7734DAEAD65'] = {'large_enemy', '证真者', 3776682558},
    ['215CE160A17BE4CD'] = {'small_enemy', '喷气机械统帅', 621159586},
    ['257D805CAA7E10C0'] = {'small_enemy', '装甲兵 霰弹（废案）', 4039692928},
    ['262351741C53FF0C'] = {'small_enemy', '凝视者 尖塔', 2259733865},
    ['282EB766C1FFA6A1'] = {'flying_enemy', '炮艇', 1932062202},
    ['2A12104F2853AE16'] = {'small_enemy', '火箭奇袭者', 3112705780},
    ['2AD2E055DAD21F6E'] = {'flying_enemy', '入侵的穿梭舰', 3579113113},
    ['2CF3488C4845F8BD'] = {'large_enemy', '机器人 加农炮塔', 478200978},
    ['30CF04B2EC8C9BD4'] = {'small_enemy', '侦察奇袭者', 2319746535},
    ['30F2DEE2333F227A'] = {'giant_enemy', '移动工厂 带干扰塔', 1153658728},
    ['31BAE74D2F064D8D'] = {'large_enemy', '湮灭坦克 MK2', 3455009224},
    ['32541FC4EC7C9CDC'] = {'medium_enemy', '武斗虫 MK3', 3564923972},
    ['32CDEADA234FB8DF'] = {'large_enemy', '喷气巨型碾压者', 613980508},
    ['34DFD23365472E9E'] = {'flying_enemy', '突入者', 3621116014},
    ['36AA99CCE5E60146'] = {'medium_enemy', '胆汁喷涌虫', 717622970},
    ['3AFF5FD7D5450B99'] = {'large_enemy', '巨兽级强袭虫', 1076678822},
    ['3D0E03E2D574E1CA'] = {'small_enemy', '追猎虫 MK2', 3330362068},
    ['3E0537D606438FEA'] = {'large_enemy', '巨型炙焰者', 1775662925},
    ['4019623142351CB6'] = {'small_enemy', '装甲兵 MK3', 4039692928},
    ['44458A2C52B002FB'] = {'small_enemy', '无票者（重型）', 4211847317},
    ['453FE22C634EB30F'] = {'large_enemy', '御门者', 1870840792},
    ['4E97FB073BDC7A4B'] = {'medium_enemy', '武斗虫 MK2（俘虏）', 3564923972},
    ['51EEA86BF6997E4E'] = {'small_enemy', '食腐虫 MK2', 4212839382},
    ['52018DEB9AB6827E'] = {'small_enemy', '喷气装甲兵（崩溃）', 4039692928},
    ['53D8919D7B8ABD67'] = {'large_enemy', '湮灭坦克', 3455009224},
    ['54E107DACF6929CB'] = {'medium_enemy', '狂暴者 MK2', 3201222154},
    ['57EED0EAC346CD9D'] = {'medium_enemy', '蹂躏者 MK3（炽灼部队）', 1649987991},
    ['58B2B86C11369241'] = {'medium_enemy', '燃烧机枪蹂躏者', 75849082},
    ['5CA832447445C0BA'] = {'small_enemy', '追猎虫 MK3', 3330362068},
    ['6021E22338333D88'] = {'medium_enemy', '抚育喷涌虫', 487985459},
    ['604A794EC45BB820'] = {'flying_enemy', '崇高监视者', 2745056259},
    ['611BA777783B08A2'] = {'large_enemy', '噪轰引擎 速射加农炮', 4066406510},
    ['63DF3D07B7424588'] = {'large_enemy', '铁幕坦克', 3921592399},
    ['64090088502435DD'] = {'flying_enemy', '尖啸虫', 793026793},
    ['64BA5F030B114EC1'] = {'small_enemy', '奇袭者', 2000862158},
    ['672F7DA17F3BA34A'] = {'small_enemy', '穿刺虫触手', 1046000873},
    ['67DC32DCA4F02D33'] = {'large_enemy', '肉瘤体', 2880434041},
    ['6B202392F4AB605E'] = {'large_enemy', '孢子强袭虫', 1939105083},
    ['6DAB2EADF5D8B692'] = {'large_enemy', '巨型烈焰轰炸者', 2090691137},
    ['728421351D440EBC'] = {'medium_enemy', '孢裂武斗虫', 2115960485},
    ['72A83E49CED6DB3D'] = {'small_enemy', '胆汁吐沫虫', 444529084},
    ['746A7F3BEDA32699'] = {'medium_enemy', '激进先锋（男）', 23741406},
    ['74E2285C01DA4F71'] = {'flying_enemy', '增援穿梭舰', 3579113113},
    ['78E1497571012C47'] = {'small_enemy', '无票者（轻型）', 4211847317},
    ['7B48CACDBACB3881'] = {'small_enemy', '装甲兵 MK2', 4039692928},
    ['7ECE5304F868F6B3'] = {'small_enemy', '装甲兵（无包裹）', 4039692928},
    ['82A87AD8D595B2BA'] = {'small_enemy', '炙焰装甲兵', 2861014363},
    ['843D18D4B5512B63'] = {'large_enemy', '移动工厂 连发加农炮', 478200978},
    ['856E9710E45E760F'] = {'small_enemy', '特攻奇袭者', 1467464627},
    ['883401AF2A98A5F6'] = {'small_enemy', '掠食追猎虫', 3029738043},
    ['8FF0A839830A7692'] = {'small_enemy', '食腐虫', 4212839382},
    ['905809A4C28D8A45'] = {'large_enemy', '粉碎者', 3922421925},
    ['9076EEED17FCEE35'] = {'large_enemy', '强化侦察纵步者', 1871700431},
    ['91EBD77931110AFC'] = {'medium_enemy', '重型蹂躏者 MK3', 1649987991},
    ['960B48A421A3FAAA'] = {'flying_enemy', '蟑龙', 1378841226},
    ['96110F9D6B010E02'] = {'large_enemy', '敌方单位', 478200978},
    ['9647B00CC3A9D36F'] = {'medium_enemy', '火箭蹂躏者', 2365630221},
    ['965EAE5A51ACDD4A'] = {'large_enemy', '猎杀器', 1405979473},
    ['96BA14C9EBB49CE1'] = {'large_enemy', '巨型者', 790541304},
    ['98152772A72F7838'] = {'flying_enemy', '运输船', 554367013},
    ['9926876B2375A1BB'] = {'medium_enemy', '机器人 碉堡炮塔', 3921936527},
    ['9A8A3AAE287B230C'] = {'small_enemy', '食腐虫 MK3', 4212839382},
    ['9D8827FED763650E'] = {'medium_enemy', '惑乱者（男）', 1371180916},
    ['9E2E17F2CCCCAFDD'] = {'giant_enemy', '吐酸泰坦', 2514244534},
    ['9F57782F00E6ED20'] = {'small_enemy', '装甲兵（炽灼部队）', 4039692928},
    ['A05BD1EC67B3AC4C'] = {'large_enemy', '巨兽级强袭虫 MK2', 1076678822},
    ['A1F37BF2A40FBDE4'] = {'medium_enemy', '虫窝护卫', 626718113},
    ['A35207C6F2150806'] = {'medium_enemy', '爆裂武斗虫', 953392591},
    ['A381A11C07D3EB94'] = {'medium_enemy', '爆裂喷涌虫', 2270698456},
    ['A4552F97033392F4'] = {'small_enemy', '喷气机枪奇袭者', 586021653},
    ['A6A68D8AF177F3A1'] = {'medium_enemy', '狂暴者', 3201222154},
    ['A71AAFD82C6EBC92'] = {'small_enemy', '机械统帅', 621159586},
    ['AAB438596F5E8FD9'] = {'small_enemy', '猛扑虫', 908216632},
    ['ABDB2E2A0479D8CA'] = {'large_enemy', '机器人 加农炮塔 MK2', 478200978},
    ['AC60E78435098C9D'] = {'flying_enemy', '守望者', 886803190},
    ['AE57FCDB49F74E98'] = {'small_enemy', '装甲兵 MK2（机枪版）', 4039692928},
    ['AE63E525853D7044'] = {'medium_enemy', '蹂躏者 MK3', 1649987991},
    ['AF0F9B3A163787A5'] = {'small_enemy', '喷气装甲兵', 4039692928},
    ['B056F8FC74ABA02D'] = {'small_enemy', '激光炮装甲兵（废案）', 4039692928},
    ['B2A6FA1E4284C7E6'] = {'medium_enemy', '狂暴武斗虫', 3564923972},
    ['B4ED319B39F5457B'] = {'small_enemy', '机枪奇袭者', 586021653},
    ['B5DBC0C240C921AD'] = {'medium_enemy', '狂暴者 MK3（炽灼部队）', 3201222154},
    ['B92435FBF60F0748'] = {'medium_enemy', '重型蹂躏者 MK2', 398976798},
    ['BC242702FB46B7E7'] = {'large_enemy', '噪轰引擎', 4066406510},
    ['BE39E313A1E46BB9'] = {'medium_enemy', '武斗虫 MK2', 3564923972},
    ['BE743B2FAA3A6E26'] = {'medium_enemy', '喷气蹂躏者', 1649987991},
    ['C626D2BB495A202D'] = {'medium_enemy', '蹂躏者', 1649987991},
    ['C6449FFD9EA3779C'] = {'large_enemy', '碎裂坦克', 2577770154},
    ['C9BCCCB0A54A82A4'] = {'medium_enemy', '火箭蹂躏者 MK3 （炽灼部队）', 2365630221},
    ['CBB1BA3366009C3A'] = {'medium_enemy', '激进先锋（女）', 23741406},
    ['CC188F0C80505C6C'] = {'medium_enemy', '悲怜体', 2118086817},
    ['CC7022FDD172089B'] = {'medium_enemy', '抚育喷涌虫 MK2', 487985459},
    ['CCAE5264ACD591B7'] = {'medium_enemy', '胆汁喷涌虫 MK2', 717622970},
    ['CD28A27A79BE53D5'] = {'medium_enemy', '指挥碉堡 碉堡重机枪', 3921936527},
    ['D1E990BAF22D5A52'] = {'large_enemy', '掠食追踪虫', 4106686024},
    ['D37E8D120D2836E3'] = {'giant_enemy', '移动工厂', 1153658728},
    ['D465D9C7F77A07CB'] = {'giant_enemy', '霸王虫', 3929716830},
    ['D522FD4748D443A5'] = {'large_enemy', '虫族指挥官', 3077749065},
    ['D5792F6856B06BA4'] = {'medium_enemy', '喷气狂暴者', 3201222154},
    ['D63FCBFF0851B7AF'] = {'large_enemy', '猎杀器 MK2', 1405979473},
    ['D8CBC4A807A6D035'] = {'small_enemy', '乱斗者', 1974334302},
    ['D9511E9F6BD62E3F'] = {'small_enemy', '追猎虫', 3330362068},
    ['DA40BB347C7447F2'] = {'medium_enemy', '监视者', 1899936906},
    ['DB90077E76FAA025'] = {'flying_enemy', '敌方单位', 554367013},
    ['DB964631BE1CF501'] = {'small_enemy', '孢裂食腐虫', 2842755544},
    ['DCF8E74212FBEE3B'] = {'large_enemy', '穿刺虫', 1046000873},
    ['DFBACBD977A948DC'] = {'small_enemy', '食腐虫 MK2（俘虏）', 4212839382},
    ['E0353177F1329573'] = {'medium_enemy', '烈火蹂躏者', 3498181594},
    ['E44EC9F9B3FE1D2A'] = {'large_enemy', '喷气巨型炙焰者', 1775662925},
    ['E683D2CA5618D74A'] = {'small_enemy', '奇袭者（炽灼部队）', 2000862158},
    ['E8F19A0AA958E46D'] = {'medium_enemy', '新月监视者', 3877563222},
    ['EACEE39FA017B495'] = {'medium_enemy', '武斗虫', 3564923972},
    ['EF04CB84D097A497'] = {'giant_enemy', '孢裂泰坦', 2514244534},
    ['EF570293245A17C2'] = {'large_enemy', '战争纵步者', 523260929},
    ['F0B26FA9258128D3'] = {'flying_enemy', '敌方单位', 793026793},
    ['F1610AC48CDC5240'] = {'medium_enemy', '监视者（无包裹模型）', 1899936906},
    ['F22D027B37BEF107'] = {'giant_enemy', '利维坦', 3097344451},
    ['F540CA9D9D4A422E'] = {'large_enemy', '追踪虫', 2387277009},
    ['F66D0BAD8693779A'] = {'medium_enemy', '火箭蹂躏者 MK2', 2365630221},
    ['F79CD8BB654397DF'] = {'large_enemy', '阿尔法指挥官', 570845236},
    ['F8131632AA867107'] = {'large_enemy', '侦察纵步者', 20706814},
    ['F8B5A81A86D5D4EB'] = {'medium_enemy', '重型蹂躏者', 398976798},
    ['FB9937035D652C43'] = {'small_enemy', '装甲兵', 4039692928},
    ['FC8DEC78BE8AB47D'] = {'medium_enemy', '蹂躏者 MK2 移动工厂生产', 1649987991},
    ['FD5247653C897803'] = {'large_enemy', '敌方单位', 1076678822},
}
-- END ENEMY TARGET CATALOG

local PING_TARGETS = {
    -- Current EntityComponentMap Spottable identities, cross-checked with
    -- FileDiver ammo_rack/{ammo_rack,supply_box,ammo_box} and frv_supply paths.
    ['5052EC6A928CCF1A'] = {'stratagem', '重新补给'},
    ['A94913CA014F7579'] = {'stratagem', '重新补给箱'},
    ['49119612EB284A48'] = {'stratagem', '重新补给箱'},
    ['9B2140378640432E'] = {'stratagem', 'M-103 补给车'},
    ['6CFCC7F8801A0266'] = {'stratagem', "40-K Meltagun"},
    ['A8CFFB316F0B5C5F'] = {'stratagem', "AC-8 Autocannon"},
    ['89C5493E08CA4207'] = {'stratagem', "APW-1 Anti-Materiel Rifle"},
    ['96DE9CD50F7306E6'] = {'stratagem', "ARC-3 Arc Thrower"},
    ['78A8185F63A70795'] = {'stratagem', "B/FLAM-80 Cremator"},
    ['9B75217D8312DD67'] = {'stratagem', "B/MD C4 Pack"},
    ['B0F1B354BA1D38D8'] = {'stratagem', "CQC-1 One True Flag"},
    ['5F3EC9BDA2BD8553'] = {'stratagem', "CQC-20 Breaching Hammer"},
    ['BF4CFD2AEABFB5A4'] = {'stratagem', "CQC-9 Defoliation Tool"},
    ['80932FA0ED6901D3'] = {'stratagem', "EAT-17 Expendable Anti-Tank"},
    ['7617642765AC38C7'] = {'stratagem', "EAT-411 Leveller"},
    ['B2B5E0D185605F9E'] = {'stratagem', "EAT-700 Expendable Napalm"},
    ['25AA2FD4643CF4EE'] = {'stratagem', "FAF-14 Spear"},
    ['39AB99895147A3BF'] = {'stratagem', "FLAM-40 Flamethrower"},
    ['02EECD0B1FA49630'] = {'stratagem', "GL-21 Grenade Launcher"},
    ['88C2D09AD85A7C9F'] = {'stratagem', "GL-28 Belt-Fed Grenade Launcher"},
    ['FE3B29B2CFA63F9B'] = {'stratagem', "GL-52 De-Escalator"},
    ['9F80D67A12A7E40F'] = {'stratagem', "GR-8 Recoilless Rifle"},
    ['D54B9505C0F72873'] = {'stratagem', "LAS-98 激光大炮"},
    ['35A61296619CC47E'] = {'stratagem', "LAS-99 Quasar Cannon"},
    ['43A58CB89CFA197C'] = {'stratagem', "M-1000 Maxigun"},
    ['A6A735ACCB4A327F'] = {'stratagem', "M-105 Stalwart"},
    ['2152D5147B0AC418'] = {'stratagem', "MG-206 Heavy Machine Gun"},
    ['11C27D3BABB38956'] = {'stratagem', "MG-43 Machine Gun"},
    ['B16C9D490AA59B77'] = {'stratagem', "MGX-42 Bullet Storm"},
    ['5990123D142B16CB'] = {'stratagem', "MLS-4X Commando"},
    ['DE18775FA447A9BF'] = {'stratagem', "MS-11 Solo Silo"},
    ['E8D5F49AD7780E54'] = {'stratagem', "PLAS-45 Epoch"},
    ['26E40437EA275296'] = {'stratagem', "RL-77 Airburst Rocket Launcher"},
    ['2E9D0BDC48B09E60'] = {'stratagem', "RS-422 Railgun"},
    ['3828E2051AA9E897'] = {'stratagem', "S-11 Speargun"},
    ['52071F49263415E4'] = {'stratagem', "SG-88 Break-Action Shotgun"},
    ['CC786F6491FE7E65'] = {'stratagem', "StA-X3 W.A.S.P. Launcher"},
    ['88F61AFFF48AC8A4'] = {'stratagem', "TX-41 Sterilizer"},
    ['FDE262593307CA2F'] = {'stratagem', "LAS-98 激光大炮装备架"},
    ['16474112801385B6'] = {'stratagem', "堡垒坦克"},
}

-- Current DLL receiver falls back to 330A0E0[kind] for unnamed markers.
-- Read-only verification: 3585962803=location, 689074879=enemy unit;
-- Encyclopedia's common terminal key is 4234884333. Specific keys stay intact.
local GENERIC_MISSION_NAMES = {[3585962803]=true, [689074879]=true, [4234884333]=true}

local function build_ping_events(env)
    local ffi = require('ffi')
    local state = {scene = nil, seen = {}, generation = 0, serial = 0, status = '等待标记数据'}
    local api = {state = state, supported = {small_enemy = true, flying_enemy = true,
        medium_enemy = true, large_enemy = true,
        giant_enemy = true, building = true, stratagem = true, map = true}}
    local function reset(reason)
        state.scene, state.session, state.seen = nil, nil, {}
        state.map_scene = nil
        state.status = reason or '等待标记数据'
    end
    function api.reset() reset() end
    local function u32(bytes, at)
        local a,b,c,d = bytes:byte(at + 1, at + 4)
        assert(d, 'short integer read')
        return a + b*256 + c*65536 + d*16777216
    end
    local function hex64(bytes, at)
        return string.format('%08X%08X', u32(bytes, at + 4), u32(bytes, at))
    end
    local function float(bytes, at)
        local value = ffi.new('uint32_t[1]', u32(bytes, at))
        return tonumber(ffi.cast('float *', value)[0])
    end
    local function mul32(a, b)
        local al,bl = a%65536,b%65536
        return (al*bl + ((math.floor(a/65536)*bl + math.floor(b/65536)*al)%65536)*65536)%4294967296
    end

    local function observe(base)
        local session = env.session and env.session() or false
        assert(not env.session or session ~= false and session ~= nil, 'ping session unavailable')
        local calls, mapping_guards = 0, {}
        local function read(address, n)
            assert(type(address) == 'number' and address%1 == 0 and address >= 65536
                and n > 0 and n <= 65536 and address+n < 2^47, 'invalid ping read bounds')
            calls = calls + 1; assert(calls <= 2048, 'ping read budget exceeded')
            local bytes = env.read(address, n)
            assert(type(bytes) == 'string' and #bytes == n, 'ping data unreadable')
            return bytes
        end
        local function ptr(address)
            local bytes = read(address, 8)
            local value = u32(bytes, 0) + u32(bytes, 4)*4294967296
            assert(value >= 65536 and value%8 == 0 and value < 2^47, 'invalid ping pointer')
            return value
        end
        local function word(address) return u32(read(address, 4), 0) end
        local function guarded(address, n)
            local bytes = read(address, n)
            mapping_guards[#mapping_guards+1] = {address, bytes}
            return bytes
        end
        local function guarded_ptr(address)
            local bytes = guarded(address,8)
            local value = u32(bytes,0)+u32(bytes,4)*4294967296
            assert(value >= 65536 and value%8 == 0 and value < 2^47, 'invalid guarded pointer')
            return value
        end
        local function lookup(address, key, limit)
            local header = guarded(address, 20)
            local slots = u32(header, 0) + u32(header, 4)*4294967296
            local cap, empty, factor = u32(header, 8), u32(header, 12), u32(header, 16)
            assert(slots >= 65536 and slots%4 == 0 and slots < 2^47
                and cap > 0 and cap <= 1048576, 'invalid ping entity table')
            local power = cap
            while power > 1 and power%2 == 0 do power = power/2 end
            assert(power == 1, 'invalid ping entity capacity')
            if key == empty then return nil end
            for probe = 0, math.min(cap, 256)-1 do
                local row = guarded(slots + ((mul32(key, factor)+probe)%cap)*8, 8)
                local found, index = u32(row, 0), u32(row, 4)
                if found == empty then return nil end
                if found == key then
                    if index == 0xffffffff then return nil end
                    assert(index < limit, 'invalid ping entity index')
                    return index
                end
            end
            error('ping entity lookup exhausted')
        end
        local ctx, root, players, ring = ptr(base+0x347cef0), ptr(base+0x346bf98),
            ptr(base+0x3326468), ptr(base+0x347ce30)
        if env.context then assert(env.context() == ctx, 'ping network context changed') end
        local own_bytes = read(ctx+0xb398, 8)
        local own = hex64(own_bytes, 0)
        assert(own ~= '0000000000000000', 'local ping peer unavailable')
        local count = word(players+0x84)
        assert(count > 0 and count <= 4, 'invalid ping player count')
        local creators, own_present, roster_guards = {}, false, {}
        local function owned_entity(entity, peer)
            if entity == nil or entity == 0 or entity == 0xffffffff then return end
            -- Ambiguous/recycled player bindings cannot attribute an event.
            if creators[entity] and creators[entity] ~= peer then creators[entity] = false
            elseif creators[entity] == nil then creators[entity] = peer end
        end
        for slot = 0, count-1 do
            local peer_at = players+0x2c8+slot*0x38
            local peer_bytes = read(peer_at, 8)
            local peer = hex64(peer_bytes, 0)
            roster_guards[#roster_guards+1] = {peer_at, peer_bytes}
            if peer ~= '0000000000000000' then
                if peer == own then own_present = true end
                local descriptor_at = players+0xe8+slot*8
                local descriptor_bytes = guarded(descriptor_at, 8)
                local descriptor = u32(descriptor_bytes, 0)+u32(descriptor_bytes, 4)*4294967296
                assert(descriptor >= 65536 and descriptor%8 == 0 and descriptor < 2^47, 'invalid player descriptor')
                local player_entity = read(descriptor+8, 4)
                owned_entity(u32(player_entity, 0), peer)
                roster_guards[#roster_guards+1] = {descriptor+8, player_entity}
                local network_at = players+0x3a8+slot*0x20
                local network_bytes = read(network_at, 4)
                roster_guards[#roster_guards+1] = {network_at, network_bytes}
                local network = u32(network_bytes, 0)
                if network < 0x7fff then
                    local index = lookup(root+0xf22ec8, network, 2048)
                    if index then
                        local identity_at = root+0xf32f18+index*24
                        local identity = read(identity_at, 24)
                        assert(u32(identity, 16) == network, 'ping avatar network identity changed')
                        owned_entity(u32(identity, 8), peer)
                        roster_guards[#roster_guards+1] = {identity_at, identity}
                    end
                end
            end
        end
        assert(own_present, 'local ping peer absent from roster')
        local header = read(ring, 16)
        local head, tail = u32(header, 8), u32(header, 12)
        assert(head < 128 and tail < 128, 'invalid ping ring bounds')
        local entries, entry_guards = {}, {}
        -- Map21's receiver returns before inserting a HUD record. Read the
        -- authoritative replicated actor pins, which also include our own pin.
        local map_scene
        local have_actor_global, actor_global = pcall(read, base+0x3326d20, 8)
        if have_actor_global and hex64(actor_global, 0) ~= '0000000000000000' then
            local actors = ptr(base+0x3326d20)
            mapping_guards[#mapping_guards+1] = {base+0x3326d20, actor_global}
            local actor_count = u32(guarded(actors+0x6c, 4), 0)
            assert(actor_count <= 16, 'invalid map actor count')
            map_scene = string.format('%X', actors)
            for slot = 0, actor_count-1 do
                local descriptor_bytes = guarded(actors+0x110+slot*8, 8)
                local descriptor = u32(descriptor_bytes,0)+u32(descriptor_bytes,4)*4294967296
                assert(descriptor >= 65536 and descriptor%8 == 0 and descriptor < 2^47, 'invalid map actor descriptor')
                local creator = u32(guarded(descriptor+8, 4), 0)
                if creators[creator] then
                    local address = actors+0x547830+slot*0x78
                    -- Guard only the mark bit and pin fields; other actor flags
                    -- can change normally while this read-only snapshot is taken.
                    local flags = read(address, 4)
                    local active = math.floor(u32(flags,0)/4)%2 == 1
                    local pin = guarded(address+0x50, 20)
                    entry_guards[#entry_guards+1] = {map_address=address, active=active}
                    if active and u32(pin,12) ~= 0 then
                        entries[#entries+1] = {slot=128+slot, age=0, kind=21,
                            creator=creator, creator_id=creators[creator], target_id=0xffffffff,
                            target_network=u32(pin,16), map_type=u32(pin,12), localization_key=0,
                            position={x=float(pin,0),y=float(pin,4),z=float(pin,8)},
                            map_source=true, token=string.format('%X:',creator)..pin}
                    end
                end
            end
        end
        assert(header:byte(1) == 1 or map_scene, 'ping UI inactive')
        local function token(bytes)
            return bytes:sub(1,4)..bytes:sub(17,20)..bytes:sub(25,28)..bytes:sub(33,36)
                .. string.char(math.floor(u32(bytes,0x1c)/0x2000)%2)
                .. (u32(bytes,0)==21 and bytes:sub(5,16) or '')
        end
        for step = 0, (header:byte(1) == 1 and (tail-head)%128 or 0)-1 do
            local slot = (head+step)%128
            local bytes = read(ring+16+slot*0x58, 0x58)
            local duration, age = float(bytes, 0x10), float(bytes, 0x14)
            if (not map_scene or u32(bytes,0) ~= 21)
                and duration == duration and duration > 0 and duration <= 10000
                and age == age and age >= 0 and age < duration then
                local kind, creator, target = u32(bytes, 0), u32(bytes, 0x18), u32(bytes, 0x20)
                entries[#entries+1] = {slot = slot, age = age, kind = kind, creator = creator,
                    duration = duration, native_flags = u32(bytes,0x1c),
                    creator_id = creators[creator], target_id = target,
                    position = {x=float(bytes,4),y=float(bytes,8),z=float(bytes,12)},
                    localization_key=u32(bytes,0x34), token = token(bytes)}
                entry_guards[#entry_guards+1] = {address=ring+16+slot*0x58, token=token(bytes), age=age, duration=duration}
            end
        end
        local definitions
        local importance_kinds = {[0]='primary', [1]='prerequisite', [2]='optional', [3]='tactical'}
        local function localized_name(key)
            if key == 0 or not env.localize then return nil end
            local okay, value = pcall(env.localize, key)
            if okay and type(value) == 'string' and #value > 0 and #value <= 256 then
                value = value:gsub('[%c<>]', '')
                if value ~= '' and not value:match('^#%d+$') then return value end
            end
        end
        local function objective_name(entity)
            local manager = guarded_ptr(base+0x3326da0)
            local objective_count = u32(guarded(manager+0x24,4),0)
            assert(objective_count <= 2048, 'invalid objective count')
            local index = lookup(manager+0x38, entity, 2048)
            if not index or index >= objective_count then return nil end
            local descriptors = guarded_ptr(manager+0x50)
            local descriptor_at = descriptors+index*8
            local descriptor = guarded_ptr(descriptor_at)
            local identity = guarded(descriptor,24)
            if u32(identity,8) ~= entity then return nil end
            local runtimes = guarded_ptr(manager+0x60)
            local runtime = runtimes+index*0x1078
            local importance = u32(guarded(runtime+0x1038,4),0)
            local override = guarded(runtime+0x1054,1):byte(1)
            assert(override <= 1, 'invalid objective name override')
            local key
            if override == 1 then
                key = u32(guarded(runtime+0x1050,4),0)
            else
                definitions = definitions or read(base+0x32ef870,153*0xa0)
                for n=0,152 do
                    local at = n*0xa0
                    if definitions:sub(at+0x19,at+0x20) == identity:sub(1,8) then
                        local definition = definitions:sub(at+1,at+0xa0)
                        mapping_guards[#mapping_guards+1] = {base+0x32ef870+at,definition}
                        key = u32(definition,0x38)
                        break
                    end
                end
            end
            local name = key and localized_name(key)
            if not name then return nil end
            return {target=name, localization_key=key, objective_kind=importance_kinds[importance] or 'unknown',
                objective_importance=importance, objective_name=name}
        end
        local function target(entry)
            if entry.kind == 24 or not entry.creator_id then return nil end
            if entry.kind == 0 and (entry.target_id == 0 or entry.target_id == 0xffffffff
                or entry.target_id == entry.creator) then return nil end
            if entry.kind == 21 then
                -- Empty map pins (7) and untyped HUD records carry no useful target.
                -- Only replicated objectives (1) and extraction (6) are supported.
                if entry.map_type ~= 1 and entry.map_type ~= 6 then return nil end
                for _, value in pairs(entry.position) do
                    if value ~= value or math.abs(value)>1000000 then return nil end
                end
                local event = {category='map',target=localized_name(entry.localization_key) or '地图标记',position=entry.position,
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    source='tactical_map',localization_key=entry.localization_key}
                -- Captured replicated MapMarkerType 6 is the extraction pin.
                if entry.map_type == 6 then event.target = '撤离区' end
                if entry.map_type == 1 then
                    if entry.target_network >= 0x7fff then return nil,'retry' end
                    local index = lookup(root+0xf22ec8,entry.target_network,2048)
                    if not index then return nil,'retry' end
                    local identity = guarded(root+0xf32f18+index*24,24)
                    if u32(identity,16) ~= entry.target_network then return nil,'retry' end
                    local entity = u32(identity,8)
                    local objective = objective_name(entity)
                    if not objective then return nil,'retry' end
                    for key,value in pairs(objective) do event[key]=value end
                    event.target_id = entity
                    event.source = 'map_objective'
                end
                return event
            end
            -- Captured call-ins use the persistent Stratagem marker. The current
            -- receiver sets 0x2000 only after resolving the stratagem manager;
            -- neither the category nor the displayed name alone proves a summon.
            local summoned = entry.kind == 20 and entry.duration == 9999
                and math.floor(entry.native_flags/0x2000)%2 == 1
            local action = summoned and 'summon' or 'mark'
            local localized = localized_name(entry.localization_key)
            -- The game selects these through Spottable.marker_type/override. Only
            -- accept otherwise unknown resources when the native UI label resolves.
            local native_category = (entry.kind==18 or entry.kind==19) and 'building'
                or entry.kind==20 and 'stratagem' or nil
            if native_category and (entry.target_id==0 or entry.target_id==0xffffffff) then
                if not localized then
                    return nil, entry.localization_key > 0 and 'retry' or nil
                end
                return {category=native_category,target=localized,position=entry.position,
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    localization_key=entry.localization_key,action=action,
                    source=summoned and 'stratagem_call' or 'native_marker'}
            end
            if entry.target_id == 0 or entry.target_id == 0xffffffff
                or entry.target_id == entry.creator then return nil end
            local index = lookup(root+0xf1aeb0, entry.target_id, 2048)
            if not index then return nil, 'retry' end
            local address = root+0xf32f18+index*24
            local identity = guarded(address, 24)
            if u32(identity, 8) ~= entry.target_id then return nil, 'retry' end
            local resource = hex64(identity, 0)
            if EXCLUDED_SUPPLIES[resource] then return nil end
            local mission = MISSION_TARGETS[resource]
            -- A ground-style marker is meaningful only when its actual target
            -- identity is a reviewed task resource. Empty terrain still exits
            -- above, and arbitrary objects/enemies do not become locations.
            if entry.kind == 0 and not mission then return nil end
            local enemy = ENEMY_TARGETS[resource]
            local info = mission or enemy or PING_TARGETS[resource]
            if not info and not (native_category and localized) then
                if native_category and entry.localization_key > 0 then return nil, 'retry' end
                return nil
            end
            if read(address, 24) ~= identity then return nil, 'retry' end
            local label = localized or info and info[2]
            -- Mission sites and enemies can share generic marker keys. Resolve
            -- the catalog's actual Encyclopedia name before its reviewed fallback;
            -- keep specific native marker text when it is available.
            if (mission or enemy) and (not localized or GENERIC_MISSION_NAMES[entry.localization_key]) then
                label = localized_name(info[3]) or info[2]
            end
            if info and info[2]:match('^TCS') and localized and not localized:find('TCS',1,true)
                and not GENERIC_MISSION_NAMES[entry.localization_key] then
                label = info[2] .. ' / ' .. localized
            end
            return {category = info and info[1] or native_category,
                target = label, target_id = entry.target_id,
                creator_id = entry.creator_id, resource = resource, kind = entry.kind, slot = entry.slot,
                localization_key=entry.localization_key, position=entry.position, action=action,
                source=summoned and 'stratagem_call' or 'target'}
        end
        local function validate()
            -- Recheck after target reads as well: a leaving/reordered teammate
            -- must never leave a stale attribution in the outgoing event batch.
            assert((not env.session or env.session() == session) and env.base() == base and ptr(base+0x347cef0) == ctx and ptr(base+0x346bf98) == root
                and ptr(base+0x3326468) == players and ptr(base+0x347ce30) == ring
                and read(ctx+0xb398, 8) == own_bytes and word(players+0x84) == count
                and read(ring, 16) == header, 'ping observation changed')
            for _, guard in ipairs(entry_guards) do
                if guard.map_address then
                    assert((math.floor(word(guard.map_address)/4)%2 == 1) == guard.active, 'map pin changed')
                else
                    local bytes = read(guard.address, 0x58)
                    local age = float(bytes, 0x14)
                    assert(token(bytes) == guard.token and age == age and age >= guard.age
                        and age < guard.duration, 'ping record changed')
                end
            end
            for _, guards in ipairs({roster_guards, mapping_guards}) do
                for _, guard in ipairs(guards) do
                    assert(read(guard[1], #guard[2]) == guard[2], 'ping identity mapping changed')
                end
            end
        end
        validate()
        return {base=base, session=session, scene = string.format('%X:%X:%X:%X:%X:%s', base, ctx, root, players, ring, own),
            entries = entries, map_scene=map_scene, target = target, read = read, ctx = ctx, root = root, ring = ring,
            own = own, header = header, ptr = ptr, validate = validate}
    end

    function api.poll(now)
        if type(now) ~= 'number' or now ~= now or now == math.huge or now == -math.huge then
            reset('标记计时不可用'); return 0, state.status
        end
        local okay, snapshot = pcall(function()
            local base = env.base()
            assert(type(base) == 'number' and base >= 65536 and base < 2^47, 'unverified game build')
            return observe(base)
        end)
        if not okay then reset('标记数据暂不可用'); return 0, state.status end
        local first = state.scene ~= snapshot.scene or state.session ~= snapshot.session
        local first_map = first or state.map_scene ~= snapshot.map_scene
        if first then state.generation = state.generation+1; state.seen = {} end
        local next_seen, events = {}, {}
        for _, entry in ipairs(snapshot.entries) do
            local previous = state.seen[entry.slot]
            local fresh = not previous or previous.pending or previous.token ~= entry.token or entry.age < previous.age
            next_seen[entry.slot] = {token = entry.token, age = entry.age}
            if not first and not (entry.map_source and first_map) and fresh then
                local good, event, reason = pcall(snapshot.target, entry)
                if not good or reason == 'retry' then
                    -- A target can finish streaming after its ping arrives. Preserve
                    -- freshness until it resolves or the native mark expires.
                    next_seen[entry.slot] = {token=entry.token, age=entry.age, pending=true}
                end
                if good and event then
                    state.serial = state.serial+1
                    -- Every legitimate renewal gets a distinct key even for the same
                    -- target and slot; the caller's queue can dedupe repeated polls.
                    event.key = snapshot.scene..':'..state.generation..':'..state.serial
                    event.id = event.key
                    events[#events+1] = event
                end
            end
        end
        -- Target reads may race a world transition; discard the entire batch.
        local valid = pcall(snapshot.validate)
        if not valid then reset('标记数据切换中'); return 0, state.status end
        state.scene, state.session, state.seen = snapshot.scene, snapshot.session, next_seen
        state.map_scene = snapshot.map_scene
        local emitted = 0
        for _, event in ipairs(events) do
            -- A listener may change the room while handling the previous event.
            -- Never recapture old observations as events from the new session.
            local stable, same = pcall(function()
                return env.base() == snapshot.base
                    and (not env.session or env.session() == snapshot.session)
                    and (not env.context or env.context() == snapshot.ctx)
            end)
            if not stable or not same then
                reset('标记数据切换中'); return emitted, state.status
            end
            local success, accepted = pcall(env.emit, event, now)
            if success and accepted == true then emitted = emitted+1 end
        end
        state.status = first and '已记录现有标记' or emitted > 0 and '已识别玩家标记' or '等待新的玩家标记'
        return emitted, state.status
    end
    return api
end
-- END NATIVE PING EVENTS
local ping_events = build_ping_events({
    base = supported_game_base,
    read = read_at,
    context = function() return game_base and u64(game_base + M.CONTEXT_PTR) or nil end,
    session = session_token,
    localize = function(key) return marker_localization.lookup(key) end,
    emit = function(event, now)
        enrich_stratagem_event(event,now)
        event.type = 'ping'
        local accepted = automation.push_ping(event, now)
        local notified = REGISTRY and REGISTRY.publish(event) or 0
        return accepted or notified > 0
    end,
})
function M.debug_ping_events() return ping_events end
M.ping_status = '标记消息已关闭'

-- BEGIN STRATAGEM EVENTS
-- Read-only observer for non-thrown stratagem successes on Steam build 25480438.
-- env.base enforces the game.dll fingerprint. The success-writer instructions
-- below additionally pin the per-peer record layout; no native calls or writes.
-- Stable IDs/name keys/call types: current StratagemInfo RawData, not build enums.
-- https://github.com/Darctor/Helldivers2_RawData/tree/main/Data/settings
-- Records +347CE50, stride1690, entries+1C0 x30, count+7C0; manager count+2D200.
-- 135C5D0 writes start+10 and activation+20 only after confirmed success.
-- 135C2C0 can also update start/cooldown on failure and mirrors shared cooldowns
-- to other peers. Activation changes prove success; mirrored records do NOT
-- prove which player called it, so ambiguous events explicitly name the squad.
local function build_stratagem_events(env)
    local catalog = {
        [3837064536]={'重新武装“飞鹰”',2109771423,'use',3},
        [2186648412]={'战术摄像机',2363192702,'summon',3},
        [115737856]={'撤离信标',1171875332,'summon',2},
        [1503060624]={'虫洞封堵装置',621653032,'summon',3},
        [1606251952]={'货运集装箱',2486779978,'summon',3},
        [2670122272]={'货运集装箱',2486779978,'summon',3},
        [705279885]={'移动通信中继站',3593734022,'summon',3},
        [3722314010]={'超级地球旗帜',2281165846,'summon',3},
        [599201298]={'超级地球旗帜',2281165846,'summon',3},
        [2720892179]={'虫族震动装置',1923094316,'summon',3},
        [685210453]={'勘探钻机',2631236711,'summon',3},
        [650447969]={'地震探测器',2198451684,'summon',3},
        [871315230]={'撤离信标',822640880,'summon',3},
        [509712523]={'紧急撤离信标',3901583393,'summon',3},
        [716088572]={'紧急撤离信标',822640880,'summon',3},
        [3300666223]={'上传数据',2087215146,'use',3},
        [681028671]={'数据接口',1159822780,'summon',3},
        [65564476]={'提取燃料',1360402559,'use',3},
        [913592461]={'毒素钻机',966239659,'summon',3},
        [101457192]={'装填高爆弹',2664466741,'use',3},
        [3702563421]={'装填反坦克弹',3778618418,'use',3},
        [4264661046]={'装填霰弹',527728115,'use',3},
    }
    local pins = {
        {0x135c63c,string.char(0x45,0x84,0xc9,0x0f,0x84,0x1e,1,0,0)},
        {0x135c69c,string.char(0x48,0x89,0x8c,0xfd,0xd0,1,0,0)},
        {0x135c6f9,string.char(0x48,0x89,0x8c,0xfd,0xe0,1,0,0)},
    }
    local state = {status='等待任务战备数据', previous={}, seen={}}
    local api = {state=state}
    function api.reset()
        state.scene,state.clock,state.previous,state.seen,state.last_poll=nil,nil,{},{},nil
        state.status='等待任务战备数据'
    end
    local function word(s, at)
        local a,b,c,d=s:byte(at+1,at+4);assert(d,'short task record')
        return a+b*256+c*65536+d*16777216
    end
    local function number(s,at)
        local n=word(s,at)+word(s,at+4)*4294967296
        assert(n<2^53,'inexact task timestamp');return n
    end
    local function peer(s) return string.format('%08X%08X',word(s,4),word(s,0)) end
    local function capture(base)
        local guards,budget={},0
        local function read(at,n)
            assert(type(at)=='number' and at%1==0 and at>=65536 and at+n<2^47
                and n>0 and n<=65536,'invalid task read bounds')
            budget=budget+1;assert(budget<=2048,'task read budget')
            local s=env.read(at,n);assert(type(s)=='string' and #s==n,'task data unreadable');return s
        end
        local function guard(at,n)
            local s=read(at,n);guards[#guards+1]={at,s};return s
        end
        local function ptr(at,alignment)
            local n=number(guard(at,8),0)
            assert(n>=65536 and n%(alignment or 8)==0 and n<2^47,'invalid task pointer');return n
        end
        for _,pin in ipairs(pins) do assert(guard(base+pin[1],#pin[2])==pin[2],'task success signature changed') end
        local session=env.session and env.session()
        assert(session~=nil and session~=false,'task session unavailable')
        local ctx,world,players,records,clock=ptr(base+0x347cef0),ptr(base+0x346bf98),
            ptr(base+0x3326468),ptr(base+0x347ce50),ptr(base+0x3326348)
        local own=peer(guard(ctx+0xb398,8))
        local count=word(guard(players+0x84,4),0)
        assert(count>=1 and count<=4,'invalid task roster')
        local roster,roster_order={},{}
        for i=0,count-1 do
            local p=peer(guard(players+0x2c8+i*0x38,8))
            assert(p~='0000000000000000' and not roster[p],'invalid task peer')
            roster[p]=true;roster_order[#roster_order+1]=p
        end
        assert(roster[own],'local task peer absent')
        local now=number(read(clock+0x18,8),0)
        local record_count=word(guard(records+0x2d200,4),0)
        assert(record_count<=32,'invalid task record count')
        local entries,groups,found={},{},{}
        for i=0,record_count-1 do
            local at=records+i*0x1690
            local p=peer(guard(at,8))
            if roster[p] then
                assert(not found[p],'duplicate task record peer');found[p]=true
                local n=word(guard(at+0x7c0,4),0);assert(n<=16,'invalid task entry count')
                if n>0 then
                    local data=guard(at+0x1c0,n*0x30)
                    for slot=0,n-1 do
                        local offset=slot*0x30;local kind=word(data,offset)
                        assert(kind<512,'invalid task type')
                        -- Current Info structures contain 32-bit fields and are
                        -- only 4-aligned; manager pointers above remain 8-aligned.
                        local row=ptr(base+0x37cb600+kind*8,4)
                        local info=guard(row,0x78);local id=word(info,4);local known=catalog[id]
                        local discovered=env.catalog and env.catalog.lookup(id)
                        -- Thrown call-ins already have a confirmed HUD producer;
                        -- observe non-thrown successes here to avoid duplicate warnings.
                        if not known and discovered and (discovered.call_type==2 or discovered.call_type==3) then
                            known={discovered.name,discovered.name_key,
                                (discovered.call_type==2 or (discovered.payload_count or 0)>0) and 'summon' or 'use',discovered.call_type}
                        end
                        if known and word(info,0)==kind and word(info,0x74)==known[4] then
                            local key=p..':'..id
                            assert(not entries[key],'duplicate task slot')
                            local item={peer=p,id=id,definition=known,name_key=word(info,0x2c),
                                start=number(data,offset+0x10),activation=number(data,offset+0x20)}
                            entries[key]=item
                            local group=id..':'..string.format('%.0f',item.activation)
                            groups[group]=groups[group] or {};groups[group][#groups[group]+1]=item
                        end
                    end
                end
            end
        end
        -- Commit a complete, consistent snapshot before publishing any event.
        local function validate()
            assert(env.base()==base and env.session()==session,'task session changed')
            for _,g in ipairs(guards) do assert(read(g[1],#g[2])==g[2],'task observation changed') end
        end
        validate()
        return {scene=table.concat({tostring(base),tostring(session),tostring(ctx),tostring(world),
            tostring(records),own,table.concat(roster_order,','),tostring(record_count)},'|'),
            clock=now,entries=entries,groups=groups,validate=validate}
    end
    function api.poll(now)
        if type(now)~='number' or now~=now or math.abs(now)==math.huge then return 0,state.status end
        if state.last_poll and now>=state.last_poll and now-state.last_poll<0.2 then return 0,state.status end
        state.last_poll=now
        local base=env.base()
        if not base then api.reset();state.status='任务战备：不支持的游戏版本';return 0,state.status end
        local ok,snapshot=pcall(capture,base)
        if not ok then api.reset();state.last_poll=now;state.status='任务战备数据暂不可读';return 0,state.status end
        local baseline=state.scene~=snapshot.scene or not state.clock or snapshot.clock<state.clock
        local previous,previous_clock=state.previous,state.clock
        state.scene,state.clock,state.previous=snapshot.scene,snapshot.clock,snapshot.entries
        if baseline then state.seen={};state.status='任务战备读取就绪';return 0,state.status end
        for key,expiry in pairs(state.seen) do if now>expiry then state.seen[key]=nil end end
        local emitted=0
        for key,item in pairs(snapshot.entries) do
            local old=previous[key]
            local token=item.id..':'..string.format('%.0f',item.activation)
            -- Mission entries can unlock between polls. A new slot is fresh only
            -- when its confirmed start is later than the previous game snapshot.
            local changed=old and item.activation>old.activation
                or not old and item.start>previous_clock and item.activation>0
            if changed and item.start>0 and item.start<=snapshot.clock
                and snapshot.clock-item.start<=15000000 and item.activation>=item.start
                and item.activation<=snapshot.clock+120000000 and not state.seen[token] then
                state.seen[token]=now+30
                local localized,name=pcall(function() return env.localize and env.localize(item.name_key) end)
                if not localized then name=nil end
                if type(name)~='string' or name=='' or #name>200 or name:find('[%c<>]') then name=item.definition[1] end
                local anonymous=#snapshot.groups[token]>1
                local event={key='task:'..token,category='stratagem',action=item.definition[3],target=name,
                    source='mission_stratagem',stratagem_id=item.id,localization_key=item.name_key,
                    anonymous=anonymous,creator_id=not anonymous and item.peer or nil}
                event.id=event.key
                if not pcall(snapshot.validate) then api.reset();state.status='任务战备数据切换中';return emitted,state.status end
                local delivered,accepted=pcall(env.emit,event,now)
                if delivered and accepted==true then emitted=emitted+1 end
            end
        end
        state.status='任务战备读取就绪'
        return emitted,state.status
    end
    return api
end
-- END STRATAGEM EVENTS
local stratagem_events = build_stratagem_events({
    base = supported_game_base, read = read_at, session = session_token,
    catalog = stratagem_catalog,
    localize = function(key) return marker_localization.lookup(key) end,
    emit = function(event, now)
        enrich_stratagem_event(event,now)
        event.type = 'ping'
        local accepted = automation.push_ping(event, now)
        local notified = REGISTRY and REGISTRY.publish(event) or 0
        return accepted or notified > 0
    end,
})
function M.debug_stratagem_events() return stratagem_events end
M.task_stratagem_status = '等待任务战备数据'


-- Tasks are data, never executable Lua. Percent escaping preserves UTF-8 and delimiters.
M.tasks = {}
function M.profile_tasks(role)
    local result = {}
    for _, task in ipairs(M.tasks) do
        if (task.profile or 'host') == role then result[#result+1] = task end
    end
    return result
end
local task_serial, task_revision = 0, 0
local MAX_TASKS = 32
local function single_line(value)
    return tostring(value or ''):gsub('[%c]', ' '):match('^%s*(.-)%s*$')
end
local function task_validate(name, mode, time, message)
    name, time, message = single_line(name), single_line(time), single_line(message)
    if name == '' then return nil, '请输入事件名称' end
    if #name > 96 then return nil, '事件名称过长' end
    if message == '' then return nil, '请输入发送消息' end
    if #message > 200 then return nil, '消息最多 200 字节' end
    local seconds, minute
    if mode == 'repeat' or mode == 'once' then
        seconds = time:match('^%d+$') and tonumber(time)
        if not seconds or seconds < 5 or seconds > 86400 then
            return nil, '请输入 5 至 86400 的整数秒数'
        end
        time = tostring(seconds)
    elseif mode == 'daily' then
        local hour, min = time:match('^(%d%d?):(%d%d)$')
        hour, min = tonumber(hour), tonumber(min)
        if not hour or hour > 23 or min > 59 then return nil, '请输入有效时间，例如 21:30' end
        minute = hour * 60 + min
        time = string.format('%02d:%02d', hour, min)
    else return nil, '请选择定时类型' end
    return {name = name, mode = mode, time = time, message = message,
            seconds = seconds, minute = minute, enabled = true, done = false}
end
local function escape_field(value)
    return (tostring(value or ''):gsub('[^%w %-%._:]', function(c)
        return string.format('%%%02X', c:byte())
    end))
end
local function unescape_field(value)
    return (value:gsub('%%(%x%x)', function(n) return string.char(tonumber(n, 16)) end))
end
local function serialize_tasks()
    local out = {'AutoChatTasks1'}
    for _, t in ipairs(M.tasks) do
        local row = {t.id, t.mode, t.time, t.enabled and '1' or '0',
                     t.done and '1' or '0', t.due or 0, t.last_day or '-', t.name, t.message, t.profile or 'host'}
        for i = 1, #row do row[i] = escape_field(row[i]) end
        out[#out + 1] = table.concat(row, '\t')
    end
    return table.concat(out, '\n') .. '\n'
end
local function restore_tasks(data)
    if type(data) ~= 'string' or #data > 65536 then return false end
    local first, list, ids, serial = true, {}, {}, 0
    for line in data:gmatch('[^\r\n]+') do
        if first then
            if line ~= 'AutoChatTasks1' then return false end
            first = false
        else
            local f = {}
            for v in (line .. '\t'):gmatch('(.-)\t') do f[#f + 1] = unescape_field(v) end
            if (#f ~= 9 and #f ~= 10) or #list >= MAX_TASKS then return false end
            if f[10] and f[10] ~= 'host' and f[10] ~= 'client' then return false end
            local t = task_validate(f[8], f[2], f[3], f[9])
            local id, due = tonumber(f[1]), tonumber(f[6])
            if not t or not id or id < 1 or id > 1000000000 or id ~= math.floor(id)
                or ids[id] or not due or due < 0 or due > 1e12
                or not f[4]:match('^[01]$') or not f[5]:match('^[01]$') then return false end
            t.id, t.due, t.enabled, t.done = id, due, f[4] == '1', f[5] == '1'
            t.profile = f[10] or 'host'
            t.last_day = f[7] ~= '-' and f[7] or nil
            list[#list + 1], ids[id], serial = t, true, math.max(serial, id)
        end
    end
    if first then return false end
    -- Preserve the public table identity for clients holding M.tasks.
    for i = #M.tasks, 1, -1 do M.tasks[i] = nil end
    for i, t in ipairs(list) do M.tasks[i] = t end
    task_serial, task_revision = serial, task_revision + 1
    return true
end
local function save_tasks()
    -- Same-directory replacement keeps the previous valid file if writing fails.
    local temporary = TASK_FILE .. '.tmp'
    local handle = io.open(temporary, 'w')
    if not handle then return false end
    local ok, result = pcall(function()
        local written, err = handle:write(serialize_tasks())
        if not written then error(err or 'write failed') end
        local closed, close_err = handle:close()
        if closed == nil and close_err then error(close_err) end
        if kernel.MoveFileExA(temporary, TASK_FILE, 9) == 0 then error('file replacement failed') end
        return true
    end)
    if not ok then pcall(function() handle:close() end) note('task save failed: ' .. tostring(result)) end
    return ok
end
local function load_tasks()
    local handle = io.open(TASK_FILE, 'r')
    if not handle then return end
    local data = handle:read(65537)
    handle:close()
    if not restore_tasks(data) then note('tasks: invalid file; not loaded') end
end
function M.add_task(name, mode, time, message, now, profile)
    profile = profile or automation.sync() or 'host'
    if profile ~= 'host' and profile ~= 'client' then return nil, '未知预设' end
    if #M.tasks >= MAX_TASKS then return nil, '最多添加 32 个任务' end
    local t, why = task_validate(name, mode, time, message)
    if not t then return nil, why end
    task_serial = task_serial + 1
    now = now or os.time()
    t.id, t.due, t.profile = task_serial, now + (t.seconds or 0), profile
    if mode == 'daily' then
        local c = os.date('*t', now)
        if type(c) == 'table' and c.hour * 60 + c.min >= t.minute then
            t.last_day = string.format('%04d-%02d-%02d', c.year, c.month, c.day)
        end
    end
    M.tasks[#M.tasks + 1] = t
    if not save_tasks() then table.remove(M.tasks) return nil, '保存失败，请检查配置目录' end
    task_revision = task_revision + 1
    return t
end
function M.remove_task(id)
    for i, t in ipairs(M.tasks) do
        if t.id == id then
            table.remove(M.tasks, i)
            if not save_tasks() then table.insert(M.tasks, i, t) return false end
            task_revision = task_revision + 1
            return true
        end
    end
    return false
end
function M.toggle_task(id, now)
    for _, t in ipairs(M.tasks) do
        if t.id == id then
            local old_enabled, old_done, old_due = t.enabled, t.done, t.due
            t.enabled = not t.enabled
            if t.done then t.enabled, t.done = true, false end
            if t.enabled and t.seconds then t.due = (now or os.time()) + t.seconds end
            if not save_tasks() then
                t.enabled, t.done, t.due = old_enabled, old_done, old_due
                return false
            end
            task_revision = task_revision + 1
            return true
        end
    end
    return false
end
local function run_tasks(now)
    local active_role = automation.sync()
    if not active_role then return end
    local calendar
    local ordered, order = {}, {}
    for i, t in ipairs(M.tasks) do
        ordered[i], order[t] = t, i
        if t.mode == 'daily' then calendar = calendar or os.date('*t', now) end
    end
    local function deadline(t)
        if t.mode == 'daily' and type(calendar) == 'table' then
            return now - (calendar.hour * 60 + calendar.min - t.minute) * 60 - (calendar.sec or 0)
        end
        return t.due or now
    end
    -- A short repeat cannot keep taking the cooldown slot ahead of an overdue once.
    table.sort(ordered, function(a, b)
        local da, db = deadline(a), deadline(b)
        return da < db or (da == db and order[a] < order[b])
    end)
    for _, t in ipairs(ordered) do
        local due, day = false, nil
        if (t.profile or 'host') == active_role and t.enabled and not t.done and (not t.retry_after or now >= t.retry_after) then
            if t.mode == 'daily' then
                calendar = calendar or os.date('*t', now)
                if type(calendar) == 'table' then
                    day = string.format('%04d-%02d-%02d', calendar.year, calendar.month, calendar.day)
                    due = calendar.hour * 60 + calendar.min >= t.minute and day ~= t.last_day
                end
            else due = now >= t.due end
        end
        if due then
            local ready, reason = send_context(true)
            if ready and automation.options.output == 'local' then
                local local_chat, local_why = local_output_context()
                if not local_chat then ready, reason = nil, local_why end
            end
            if ready then
                local allowed, why = automation.check(now, reason)
                if not allowed then ready, reason = nil, why end
            end
            if not ready then
                t.retry_after = now + 5
                local waiting = reason == 'text chat is off' and '等待：请开启游戏文字聊天'
                    or reason == 'no network session' and '等待：游戏会话尚未就绪'
                    or (tostring(reason):match('[\128-\255]') and tostring(reason))
                    or ('等待聊天可用：' .. tostring(reason))
                if t.result ~= waiting then note('task ' .. tostring(t.id) .. ': ' .. waiting) end
                t.result = waiting
                task_revision = task_revision + 1
            else
            local old_done, old_enabled, old_due, old_day = t.done, t.enabled, t.due, t.last_day
            if t.mode == 'once' then t.done, t.enabled = true, false
            elseif t.mode == 'repeat' then t.due = now + t.seconds
            else t.last_day = day end
            -- Persist the consumed attempt before touching the sender. A write failure
            -- must not cause a supposedly one-shot message to be replayed on restart.
            if save_tasks() then
                t.retry_after = nil
                local ok, why = automation.send(automation.format(t.message), t.profile or 'host')
                if ok then automation.record(now) end
                t.result = ok and (why == 'local' and '已显示 / 仅自己可见' or why == 0 and '已发送 / 单人会话' or ('已发送 / ' .. tostring(why) .. ' 位队友'))
                    or ('发送失败：' .. tostring(why))
                M.last_send = {ok = ok and true or false, why = t.result}
            else
                t.done, t.enabled, t.due, t.last_day = old_done, old_enabled, old_due, old_day
                t.retry_after, t.result = now + 5, '保存失败，尚未发送；5 秒后重试'
            end
            task_revision = task_revision + 1
            note('task ' .. tostring(t.id) .. ': ' .. t.result)
            end
        end
    end
end
function M.debug_run_tasks(now) run_tasks(now) end
function M.debug_serialize_tasks() return serialize_tasks() end
function M.debug_restore_tasks(data) return restore_tasks(data) end

-- BEGIN ARMORY INPUT
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
-- END ARMORY INPUT
local panel_input = build_panel_input(ffi, user, kernel, note)

-- ---------------------------------------------------------------- 11. panel
-- Staged construction: create_screen_gui must not run before the ship world
-- exists, and each stage advances only on success so a failure names the exact
-- engine call that broke instead of dying invisibly.
local PANEL = {world = nil, gui = nil, draw_guis = nil, open = false, hover = -1,
               lfail = 0, version = 0,
               rw = 0, rh = 0}
local draft = {name = '', mode = 'repeat', time = '30', message = ''}
PANEL.task_page = 1
local POSITION_FILE = HOME .. 'AutoChat/panel-position.txt'
local function load_position()
    local f = io.open(POSITION_FILE, 'r')
    if not f then return end
    local text = f:read('*a'); f:close()
    local x, y = text:match('x%s*=%s*([%d%.]+)'), text:match('y%s*=%s*([%d%.]+)')
    x, y = tonumber(x), tonumber(y)
    if x and y then PANEL.pos = {fx = x, fy = y} end
end
local function save_position()
    local f = io.open(POSITION_FILE, 'w')
    if not f then note('panel: could not save position') return end
    f:write(PANEL.pos and string.format('x = %.6f\ny = %.6f\n', PANEL.pos.fx, PANEL.pos.fy) or '')
    f:close()
end
load_position()

local function bitmap_text(x, y, value, cell, colour)
    if not (sr and sr.Gui and sr.Vector3 and sr.Vector2) then return end
    value = tostring(value):upper()
    local cx = x
    for i = 1, #value do
        local g = GLYPHS[value:sub(i, i)]
        if g then
            for r = 1, 5 do
                local row = g[r]
                for col = 1, 4 do
                    if row:sub(col, col) == '1' then
                        pcall(sr.Gui.rect, PANEL.gui,
                              sr.Vector3(cx + (col - 1) * cell,
                                         y + (5 - r) * cell, 955),
                              sr.Vector2(cell, cell), colour)
                    end
                end
            end
        end
        cx = cx + 5 * cell
    end
end

local cursor = {taken = false, shows = 0, clip = nil, engine = false, was_shown = nil}
-- Forward declarations for functions used by code that is defined earlier in the file.
-- A `local` introduced AFTER its reader leaves the reader holding nil, the call
-- raises, and -- because the panel runs inside a pcall -- the only symptom is a panel
-- that does not work. Both of these were hit for real:
--   * set_panel_open is called by panel_frame (defined later) and by the tests;
--   * panel_clear is called by world_ready, which is defined BEFORE panel_clear.
-- The second one reached the live game and was caught only by the panel_error log.
local set_panel_open
local panel_clear
local key_prev = {}
local mouse_was_down = false

local function window_fn(name)
    local f = sr and sr.Window and rawget(sr.Window, name)
    if type(f) == 'function' then return f end
    return nil
end
local function engine_cursor_shown()
    local f = window_fn('show_cursor')
    if not f then return nil end
    local ok, shown = pcall(f)
    if ok and type(shown) == 'boolean' then return shown end
    return nil
end
local function take_cursor()
    if cursor.taken or not user then return end
    cursor.taken = true
    local set_show, set_clip = window_fn('set_show_cursor'), window_fn('set_clip_cursor')
    cursor.was_shown = engine_cursor_shown()
    cursor.engine = set_show ~= nil
    if cursor.engine then
        pcall(set_show, true)
        if set_clip then pcall(set_clip, false) end
    end
    -- ShowCursor is a per-thread COUNTER and the game may already have called it.
    -- Loop until it reports visible, count the calls used, and give back EXACTLY
    -- that many, or the cursor stays visible after the panel closes.
    cursor.shows = 0
    while user.ShowCursor(true) < 0 and cursor.shows < 20 do cursor.shows = cursor.shows + 1 end
    cursor.shows = cursor.shows + 1
    local clip = ffi.new('int32_t[4]')
    if user.GetClipCursor(ffi.cast('void *', clip)) ~= 0 then
        -- Stored with EXPLICIT named fields rather than a positional table. A Lua
        -- table built as {clip[0], clip[1], ...} is 1-based while the C array it
        -- came from is 0-based, and mixing the two on the way back silently put nil
        -- into rect[3]. Named fields remove the convention from the picture.
        cursor.clip = {left = clip[0], top = clip[1], right = clip[2], bottom = clip[3]}
    else
        cursor.clip = nil
    end
    user.ClipCursor(nil)
end
local function release_cursor()
    if not cursor.taken then return end
    cursor.taken = false
    if cursor.engine and cursor.was_shown == false then
        local set_show, set_clip = window_fn('set_show_cursor'), window_fn('set_clip_cursor')
        if set_show then pcall(set_show, false) end
        if set_clip then pcall(set_clip, true) end
    end
    if user then
        for _ = 1, cursor.shows or 0 do user.ShowCursor(false) end
        if cursor.clip then
            local rect = ffi.new('int32_t[4]')
            rect[0], rect[1] = cursor.clip.left, cursor.clip.top
            rect[2], rect[3] = cursor.clip.right, cursor.clip.bottom
            user.ClipCursor(ffi.cast('void *', rect))
        else
            user.ClipCursor(nil)
        end
    end
end
local function keep_cursor()
    if not cursor.taken then return end
    if engine_cursor_shown() == false then
        local set_show, set_clip = window_fn('set_show_cursor'), window_fn('set_clip_cursor')
        if set_show then pcall(set_show, true) end
        if set_clip then pcall(set_clip, false) end
    end
end

-- Unconditional "give the pointer back".
--
-- release_cursor() is a no-op unless this process took the cursor, which is correct
-- for normal use and wrong after a crash: if the game dies with the panel open, the
-- `taken` flag dies with the Lua state and the cursor stays visible with no way back.
-- A stuck pointer cannot be fixed by reloading the mod either, because the new
-- instance has no memory of the old one.
--
-- This clears the clip rectangle and drives the Win32 display counter to hidden
-- without consulting any saved state, so it works from a cold start. It is called at
-- boot and at shutdown: boot rescues a cursor left stuck by a previous session,
-- shutdown is a belt-and-braces release for the normal path.
local function force_release_cursor()
    if not user then return end
    pcall(function() user.ClipCursor(nil) end)
    -- The display counter is per-thread and we cannot read it, so drive it to JUST
    -- hidden rather than a large negative number. Overshooting is not harmless: the
    -- take path loops until the cursor reports visible with a bounded count, so a
    -- counter pushed far below zero can no longer be brought back and the panel ends
    -- up with an invisible pointer. Measured: resetting to -32 made the panel's own
    -- loop stop at -11 and the cursor never appeared.
    pcall(function()
        local guard = 0
        while user.ShowCursor(false) >= 0 and guard < 40 do guard = guard + 1 end
    end)
    local set_show, set_clip = window_fn('set_show_cursor'), window_fn('set_clip_cursor')
    if set_show then pcall(set_show, false) end
    if set_clip then pcall(set_clip, true) end
    cursor.taken = false
    cursor.shows = 0
    cursor.clip = nil
end
local function focused()
    if not user then return false end
    local win = user.GetForegroundWindow()
    if win == nil then return false end
    local pid = ffi.new('uint32_t[1]')
    if user.GetWindowThreadProcessId(win, ffi.cast('void *', pid)) == 0 then return false end
    return tonumber(pid[0]) == tonumber(kernel.GetCurrentProcessId())
end
local function key_down(vk)
    if not user then return false end
    local ok, state = pcall(function() return user.GetAsyncKeyState(vk) end)
    if not ok or state == nil then return false end
    return tonumber(state) < 0
end
-- Edge detection AND focus: otherwise pressing K in another application would
-- toggle the panel.
local function key_pressed(vk)
    local down = key_down(vk)
    local was = key_prev[vk]
    key_prev[vk] = down
    return down and not was and focused()
end
local function mouse_state()
    if not user then return nil end
    local win = user.GetForegroundWindow()
    if win == nil then return nil end
    local pid = ffi.new('uint32_t[1]')
    if user.GetWindowThreadProcessId(win, ffi.cast('void *', pid)) == 0 then return nil end
    if tonumber(pid[0]) ~= tonumber(kernel.GetCurrentProcessId()) then return nil end
    local point, client = ffi.new('int32_t[2]'), ffi.new('int32_t[4]')
    if user.GetCursorPos(ffi.cast('void *', point)) == 0 then return nil end
    if user.ScreenToClient(ffi.cast('void *', win), ffi.cast('void *', point)) == 0 then return nil end
    if user.GetClientRect(ffi.cast('void *', win), ffi.cast('void *', client)) == 0 then return nil end
    local cw, ch = client[2] - client[0], client[3] - client[1]
    if not (cw > 0 and ch > 0) then return nil end
    local cx, cy = point[0], point[1]
    if cx < 0 or cy < 0 or cx >= cw or cy >= ch then return nil end
    -- Returned in the SAME space the draw code records its regions in: engine
    -- resolution pixels with a bottom-left origin. The client rect is not always the
    -- render resolution (borderless / DPI scaling), so the window size is remembered
    -- and used to scale, instead of assuming the two are equal.
    PANEL.client_w, PANEL.client_h = cw, ch
    return cx * PANEL.rw / cw, (ch - cy) * PANEL.rh / ch
end
-- ---------------------------------------------------------------- 11c. editing
-- Keyboard entry for the message field, built the way Super Earth Armory Forge builds
-- its name/search entry: a table of {virtual-key, normal, shifted} and an edge detector
-- that also auto-repeats.
--
-- Worth being explicit: while the field has focus this polls the WHOLE KEYBOARD via
-- GetAsyncKeyState, not just the K hotkey. That is the same thing Armory does to accept
-- typed text, and it only happens while the panel is open AND the message box is
-- focused; the rest of the time the only key read is K. Nothing is logged or sent
-- anywhere -- the characters go into the message field and nowhere else.
local NAME_KEYS = {}
for c = 0x41, 0x5A do
    NAME_KEYS[#NAME_KEYS + 1] = {c, string.char(c + 32), string.char(c)}
end
for n = 0, 9 do
    NAME_KEYS[#NAME_KEYS + 1] = {0x30 + n, tostring(n), tostring(n)}
    NAME_KEYS[#NAME_KEYS + 1] = {0x60 + n, tostring(n), tostring(n)}
end
for _, k in ipairs({{0x20, ' ', ' '}, {0xBD, '-', '_'}, {0x6D, '-', '-'},
                    {0xBE, '.', '.'}, {0xBC, ',', ','}, {0xBB, '=', '+'},
                    {0xBA, ';', ':'}, {0xBF, '/', '?'}, {0xDE, "'", '"'},
                    {0xDB, '[', '{'}, {0xDD, ']', '}'}, {0xC0, '`', '~'}}) do
    NAME_KEYS[#NAME_KEYS + 1] = k
end

local VK = {SHIFT = 0x10, CTRL = 0x11, ENTER = 0x0D, ESCAPE = 0x1B,
            BACKSPACE = 0x08, SPACE = 0x20}

-- Edge detection with auto-repeat: true on the press, then again after a delay, then
-- repeatedly. Identical timings to Armory's, so typing feels the same.
M.key_held = M.key_held or {}
local key_held = M.key_held
local function pressed(name, vk, now)
    local down = key_down(vk)
    local h = key_held[name]
    if not down then key_held[name] = nil return false end
    if not h then key_held[name] = {next = now + 0.4} return true end
    if now >= h.next then h.next = now + 0.08 return true end
    return false
end

local MAX_MESSAGE = 200

-- CF_UNICODETEXT avoids the ANSI codepage corruption of Armory's CF_TEXT path.
-- Read only on Ctrl+V in a focused field; always unlock and close, including failures.
local function clipboard_text()
    if not user then return nil end
    local ok, opened = pcall(function() return user.OpenClipboard(nil) end)
    if not ok or opened == 0 then return nil end
    local locked_handle
    local worked, value = pcall(function()
        local handle = user.GetClipboardData(13)
        if handle == nil or handle == ffi.NULL then return nil end
        local size = tonumber(kernel.GlobalSize(handle))
        if not size or size < 2 then return nil end
        local ptr = kernel.GlobalLock(handle)
        if ptr == nil or ptr == ffi.NULL then return nil end
        locked_handle = handle
        local bytes = read_at(tonumber(ffi.cast('uintptr_t', ptr)), math.min(size, 4096))
        if not bytes then return nil end
        local out, high = {}, nil
        for i = 1, #bytes - 1, 2 do
            local cp = bytes:byte(i) + bytes:byte(i + 1) * 256
            if cp == 0 then break end
            if cp >= 0xD800 and cp <= 0xDBFF then high = cp
            else
                if cp >= 0xDC00 and cp <= 0xDFFF then
                    cp = high and (0x10000 + (high - 0xD800) * 1024 + cp - 0xDC00) or 0xFFFD
                elseif high then out[#out + 1] = '\239\191\189' end
                high = nil
                if cp < 0x80 then out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
                elseif cp < 0x10000 then
                    out[#out + 1] = string.char(0xE0 + math.floor(cp / 4096),
                        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
                else
                    out[#out + 1] = string.char(0xF0 + math.floor(cp / 262144),
                        0x80 + math.floor(cp / 4096) % 64,
                        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
                end
            end
        end
        return single_line(table.concat(out))
    end)
    if locked_handle then pcall(function() kernel.GlobalUnlock(locked_handle) end) end
    pcall(function() user.CloseClipboard() end)
    return worked and value or nil
end

-- Returns the edited text, or nil to keep the current one. Pure enough to test offline:
-- it takes `now` and reads keys through key_down, which the harness controls.
local function edit_text(now)
    local text = PANEL.edit_text
    if text == nil then text = PANEL.edit_field and draft[PANEL.edit_field] or cfg.message or '' end
    local limit = PANEL.edit_field == 'preset:name' and 96
        or PANEL.edit_field == 'preset:path' and 1024 or MAX_MESSAGE

    if pressed('Enter', VK.ENTER, now) then
        PANEL.edit_text = nil
        return text, 'commit'
    end
    if pressed('Escape', VK.ESCAPE, now) then
        PANEL.edit_text = nil
        return nil, 'cancel'
    end
    if pressed('Backspace', VK.BACKSPACE, now) then
        -- Walk back over a whole UTF-8 character, not one byte: a byte cut in the
        -- middle of a multi-byte character produces text that cannot be decoded.
        local trimmed = text:gsub('[\194-\244][\128-\191]*$', '')
        if #trimmed == #text then trimmed = text:sub(1, -2) end
        text = trimmed
    end
    if key_down(VK.CTRL) then
        if pressed('SelectAll', 0x41, now) then text = '' end
        if pressed('Paste', 0x56, now) then
            local pasted = clipboard_text()
            if pasted then text = text .. cut_utf8(pasted, limit - #text) end
        end
        PANEL.edit_text = text
        return text, 'typing'
    end
    local shift = key_down(VK.SHIFT)
    for _, k in ipairs(NAME_KEYS) do
        if #text < limit and pressed('N' .. k[1], k[1], now) then
            text = text .. (shift and k[3] or k[2])
        end
    end
    PANEL.edit_text = text
    return text, 'typing'
end

-- Exposed for the offline tests: the editing logic is pure bookkeeping around key
-- state, so it can be driven without the engine.
function M.debug_edit_text(now) return edit_text(now or 0) end
function M.debug_set_editing(on)
    PANEL.editing = on and true or false
    PANEL.edit_text = nil
    PANEL.edit_backup = cfg.message
end
function M.debug_set_edit_buffer(value)
    PANEL.edit_text = value
    return PANEL.edit_text
end

local function world_ready()    refresh_engine()
    if not sr then return false end
    local ok, world = pcall(sr.Application.main_world)
    if not ok or world == nil then return false end
    local okr, rw, rh = pcall(Gui.resolution)
    if not okr or type(rw) ~= 'number' or rw < 640 or rh < 480 then return false end
    -- A new world means every gui made for the old one is stale, and the geometry
    -- must be recomputed. Teardown here (rather than only in the frame body) is what
    -- makes a world change safe: the panel is rebuilt from scratch for the new world.
    if PANEL.world ~= nil and world ~= PANEL.world then
        panel_clear()
    end
    PANEL.world = world
    PANEL.rw, PANEL.rh = rw, rh
    return true
end

-- ---------------------------------------------------------------- dest / rebuild
-- The screen GUI is DESTROYED, not left in place. A retained GUI keeps rendering
-- whatever was drawn into it, so the panel would stay on screen after closing and
-- block the HUD underneath. Destroying it also clears the signature, so the next open
-- rebuilds rather than reusing a destroyed handle.
--
-- Assigned to the forward-declared local (see above the cursor table), NOT declared
-- here with `local function`: world_ready above calls it, and a `local` introduced
-- after its reader leaves the reader holding nil.
panel_clear = function()
    if sr and PANEL.gui and PANEL.world then
        pcall(sr.World.destroy_gui, PANEL.world, PANEL.gui)
    end
    FONT.resolved, FONT.gui = false, nil
    PANEL.gui, PANEL.draw_guis = nil, nil
    PANEL.sig = nil
    -- lfail is deliberately NOT reset here: it counts how many times the engine
    -- refused to hand out a gui, and the give-up decision is per session, not per
    -- open. Resetting it would let a world that always refuses be retried forever.
    PANEL.panel_wanted = false
end

-- Everything drawn, plus the resolution the geometry is derived from. When this
-- string changes the GUI is rebuilt, which is the ONLY way a retained screen GUI
-- ever updates -- see panel_frame.
-- ---------------------------------------------------------------- 11a. public API
-- Other mods can put their own auto-send settings in this panel, as an extra tab.
--
-- The shape follows Super Earth Armory Forge's tab model rather than inventing one:
-- Armory keeps an ordered list of tab keys (ui.tab_order) and switches the whole body
-- on the selected key. Here the FIRST tab is always the default settings; every mod
-- that registers adds one more tab beside it, labelled with that mod's name, so a mod
-- using the feature is visible as a tab rather than buried in a shared list.
--
-- Registration is deliberately defensive. A third-party draw call runs inside this
-- panel's frame, and a raise there would take the panel down with it, so every plugin
-- call is wrapped and a faulting plugin is dropped for the session with its name
-- logged rather than retried every frame.
-- The registry lives on the GLOBAL, not on M, for one practical reason: another mod may
-- load BEFORE this one and register early. M does not exist yet at that point, so an
-- API that only appears on M would silently lose those registrations -- a mod loaded
-- first would just not be in the list, with nothing in any log to say why.
-- BEGIN PLUGIN REGISTRY
-- Cross-mod settings tabs. Inlined by the addon builder; no runtime require.
local function build_plugin_registry(env)
    env = type(env) == 'table' and env or {}
    local registry = type(env.registry) == 'table' and env.registry or {}
    registry.plugins = type(registry.plugins) == 'table' and registry.plugins or {}
    registry.by_id = type(registry.by_id) == 'table' and registry.by_id or {}
    registry.serial = type(registry.serial) == 'number' and registry.serial or 0
    registry.version, registry.api_version = 2, 2
    local function note(message)
        if type(env.note) == 'function' then pcall(env.note, '[plugin] ' .. message) end
        if type(registry.log) == 'function' then pcall(registry.log, message) end
    end
    local function text(value, limit)
        return type(value) == 'string' and #value > 0 and #value <= limit
            and not value:find('[%c]') and value:find('%S') ~= nil
    end
    local function context()
        if type(env.context) ~= 'function' then return nil end
        local ok, token = pcall(env.context)
        return ok and token or nil
    end
    local function fault(entry, callback, why)
        entry.faults = entry.faults + 1
        entry.last_error = callback .. ': ' .. tostring(why)
        if entry.faults <= 3 then note(entry.id .. ' ' .. entry.last_error)
        elseif entry.faults == 4 then note(entry.id .. ' further callback faults suppressed') end
    end
    local function api_for(entry)
        local token = context()
        return {version = 2, api_version = 2, id = entry.id,
            context = context,
            send = function(value, creator_id)
                if registry.by_id[entry.id] ~= entry then return false, 'plugin unregistered' end
                if context() ~= token then return false, 'session changed' end
                return registry.send(entry.id, value, creator_id)
            end}
    end
    local function invoke(entry, name, ...)
        local callback = entry['_' .. name]
        if type(callback) ~= 'function' then return true end
        local ok, a, b = pcall(callback, ...)
        if not ok then fault(entry, name, a); return false, 'plugin callback failed' end
        if a == nil then return true, b end
        return a, b
    end
    function registry.register(spec)
        if type(spec) ~= 'table' then return nil, 'register needs a table' end
        local id = rawget(spec, 'id')
        local title = rawget(spec, 'name') or rawget(spec, 'title') or id
        if not text(id, 64) or not id:match('^[%w_.%-]+$') then return nil, 'invalid plugin id' end
        if not text(title, 96) then return nil, 'invalid plugin name' end
        if registry.by_id[id] then return nil, 'plugin id already registered' end
        if #registry.plugins >= 16 then return nil, 'maximum 16 plugins' end
        if type(rawget(spec, 'draw')) ~= 'function' then return nil, 'draw callback required' end
        for _, name in ipairs({'on_click', 'revision', 'on_event'}) do
            if rawget(spec, name) ~= nil and type(rawget(spec, name)) ~= 'function' then
                return nil, 'invalid ' .. name .. ' callback'
            end
        end
        local entry = {id = id, title = title, name = title, faults = 0,
            _draw = rawget(spec, '_draw') or rawget(spec, 'draw'),
            _on_click = rawget(spec, '_on_click') or rawget(spec, 'on_click'),
            _revision = rawget(spec, '_revision') or rawget(spec, 'revision'),
            _on_event = rawget(spec, '_on_event') or rawget(spec, 'on_event')}
        entry.draw = function(u, ctx) return invoke(entry, 'draw', u, ctx, api_for(entry)) end
        registry.plugins[#registry.plugins + 1], registry.by_id[id] = entry, entry
        registry.serial = registry.serial + 1
        note('registered "' .. title .. '" (' .. id .. ')')
        return entry
    end
    function registry.unregister(id)
        if type(id) ~= 'string' then return false end
        local entry = registry.by_id[id]
        if not entry then return false end
        for i = #registry.plugins, 1, -1 do
            if registry.plugins[i] == entry then table.remove(registry.plugins, i) end
        end
        registry.by_id[id], registry.serial = nil, registry.serial + 1
        note('unregistered ' .. id)
        return true
    end
    function registry.send(id, value, creator_id)
        if type(id) ~= 'string' or not registry.by_id[id] then return false, 'plugin unregistered' end
        if type(value) ~= 'string' or #value == 0 or #value > 512
            or value:find('%z') or not value:find('%S') then return false, 'invalid message' end
        if type(env.send) ~= 'function' then return false, 'sender unavailable' end
        if creator_id ~= nil then
            if type(creator_id)~='string' or #creator_id~=16 or not creator_id:match('^%x+$') then
                return false, 'invalid trigger peer'
            end
            creator_id=creator_id:upper()
        end
        local ok, sent, why = pcall(env.send, value, id, creator_id)
        if not ok then
            note(id .. ' sender failed: ' .. tostring(sent))
            return false, 'sender failed'
        end
        note(id .. ' send ' .. (sent == true and 'accepted' or 'refused') .. ': ' .. tostring(why))
        return sent == true, why
    end
    function registry.click(id, key)
        local entry = type(id) == 'string' and registry.by_id[id] or nil
        if not entry then return false, 'plugin unregistered' end
        if not text(key, 128) then return false, 'invalid control key' end
        if not entry._on_click then return false, 'plugin has no click callback' end
        return invoke(entry, 'on_click', key, api_for(entry))
    end
    local function copy_event(source)
        local seen, remaining = {}, 128
        local function copy(value, depth)
            local kind = type(value)
            if kind == 'string' then return #value <= 2048 and value or nil end
            if kind == 'boolean' then return value end
            if kind == 'number' then
                return value == value and value ~= math.huge and value ~= -math.huge and value or nil
            end
            if kind ~= 'table' or depth > 6 or seen[value] then return nil end
            local result = {}; seen[value] = true
            for key, item in next, value do
                if remaining <= 0 then break end
                if type(key) == 'number' or type(key) == 'string' and #key <= 128 then
                    remaining = remaining - 1
                    result[key] = copy(item, depth + 1)
                end
            end
            seen[value] = nil
            return result
        end
        return copy(source, 0)
    end
    function registry.publish(event)
        if type(event) ~= 'table' then return 0 end
        local snapshot, plugins, delivered = copy_event(event), {}, 0
        for i, entry in ipairs(registry.plugins) do plugins[i] = entry end
        for _, entry in ipairs(plugins) do
            if registry.by_id[entry.id] == entry and entry._on_event then
                invoke(entry, 'on_event', copy_event(snapshot), api_for(entry))
                delivered = delivered + 1
            end
        end
        return delivered
    end
    function registry.signature()
        local parts, plugins = {tostring(registry.serial)}, {}
        for i, entry in ipairs(registry.plugins) do plugins[i] = entry end
        for _, entry in ipairs(plugins) do
            local revision = ''
            if entry._revision then
                local okay, value = pcall(entry._revision)
                if not okay then fault(entry, 'revision', value)
                elseif type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
                    or type(value) == 'boolean' or text(value, 128) then revision = tostring(value) end
            end
            parts[#parts + 1] = #entry.id .. ':' .. entry.id .. ':' .. #revision .. ':' .. revision
        end
        return table.concat(parts, '|')
    end
    -- Upgrade early registrations while keeping the registry's public table identities.
    local existing = {}
    for i, spec in ipairs(registry.plugins) do existing[i] = spec end
    for i = #registry.plugins, 1, -1 do registry.plugins[i] = nil end
    for id in pairs(registry.by_id) do registry.by_id[id] = nil end
    for _, spec in ipairs(existing) do
        local entry, why = registry.register(spec)
        if not entry then note('early plugin rejected: ' .. tostring(why)) end
    end
    return registry
end
-- END PLUGIN REGISTRY
REGISTRY = build_plugin_registry({
    registry = rawget(_G, 'HD2AutoChatPlugins'), note = note,
    context = function()
        local snapshot = automation.snapshot()
        return snapshot and table.concat({tostring(snapshot.session), tostring(snapshot.context),
            snapshot.mine, snapshot.host or '?'}, '|') or nil
    end,
    send = function(text, id, creator_id)
        local now = os.time()
        if creator_id and not automation.has_peer(creator_id) then return false, 'trigger player unavailable' end
        local chat, others = send_context(true)
        if not chat then return false, others end
        local allowed, why = automation.check(now, others, creator_id)
        if not allowed then return false, why end
        local sent, reason = automation.send(automation.format(text,creator_id), automation.state.active_role)
        if sent then automation.record(now,creator_id) end
        return sent, reason
    end,
})
rawset(_G, 'HD2AutoChatPlugins', REGISTRY)
rawset(_G, 'HD2AutoChatAPI', REGISTRY)
M.PLUGINS, M.PLUGIN_BY_ID, M.api = REGISTRY.plugins, REGISTRY.by_id, REGISTRY
local function plugin_note(message) note('[plugin] ' .. tostring(message)) end
function M.register_plugin(spec) return REGISTRY.register(spec) end
function M.unregister_plugin(id) return REGISTRY.unregister(id) end
function REGISTRY.has_listeners()
    for _, entry in ipairs(REGISTRY.plugins) do if entry._on_event then return true end end
    return false
end
local pending = rawget(_G, 'HD2AutoChatPending')
if type(pending) == 'table' then
    local keys = {}; for id in pairs(pending) do if type(id) == 'string' then keys[#keys+1] = id end end
    table.sort(keys)
    for i = 1, math.min(#keys, 32) do
        local id = keys[i]
        local okay, why = REGISTRY.register(pending[id])
        if not okay then plugin_note('pending ' .. id .. ': ' .. tostring(why)) end
        pending[id] = nil
    end
end

-- The drawing primitives below are copied from Super Earth Armory Forge's draw()
-- rather than invented, because its panel is the look that was asked for and it is
-- known to work in this game:
--
--   * panel units -> screen pixels, every edge ROUNDED TO A WHOLE PIXEL (fractional
--     positions are what make text and lines look soft at 1440p/4K);
--   * a top-left origin, converted to the engine's bottom-left space in one place;
--   * text that auto-shrinks in whole pixels to fit a width limit, with the engine
--     measuring when it can and a per-character estimate when it cannot;
--   * the same palette and z-layers.
--
-- The panel is W x H panel units; `s` is the only thing that changes with resolution.
local W_PANEL, H_PANEL = 1000, 990
local TABS_H = 30        -- the tab strip, like Armory's row across the top
local PAD = 14
local function panel_geometry(width, height)
    local want = height / 1080 * 0.8 * (PANEL.ui_scale or 1)
    local s = math.min(want, height * 0.96 / H_PANEL, (width - 60) / W_PANEL)
    local function px(v) return math.floor(v + 0.5) end
    local ox, oy = px(30 * s), px((height - H_PANEL * s) / 2)
    if PANEL.pos then ox, oy = px(PANEL.pos.fx * width), px(PANEL.pos.fy * height) end
    return s, math.max(0, math.min(width - px(W_PANEL * s), ox)),
        math.max(0, math.min(height - px(H_PANEL * s), oy))
end

local function UI() return sr.Gui, sr.Vector3, sr.Vector2, sr.Color end

-- px/rect/text close over live locals, so the layout numbers below read exactly like
-- Armory's: plain panel units, no per-call scaling arithmetic.
local UX = {}

-- What a plugin draws with. `u` mirrors the panel's own helpers so a plugin cannot
-- reach into this file's state, and it draws into the BODY: every coordinate is offset
-- past the header and tab strip automatically, so a plugin lays out from its own top
-- left and cannot draw over the tabs. Without that offset the helpers began at the
-- panel's own top left and plugin content landed on top of the tab strip.
local function plugin_api(ctx)
    local dx, dy = ctx.ox or 0, ctx.oy or 0
    local content_w, content_h = W_PANEL - 2 * PAD, H_PANEL - dy - PAD
    local function area(x, y, w, h)
        return type(x)=='number' and type(y)=='number' and type(w)=='number' and type(h)=='number'
            and x==x and y==y and w==w and h==h and x>=0 and y>=0 and w>0 and h>0
            and x+w<=content_w and y+h<=content_h
    end
    return {
        w = ctx.w, h = ctx.h, content_w=content_w, content_h=content_h, body_y = dy, scale = UX.s,
        -- These forward at CALL time. Copying UX.text into the table here would capture
        -- whatever it held when plugin_api ran, which is nothing: plugin_api is reached
        -- before draw_panel has finished assigning, so the plugin received three nil
        -- helpers. Forwarding through UX means the lookup happens when the plugin
        -- actually draws.
        -- NOTE the argument order: the panel's own text() takes the string FIRST
        -- (value, x, y, size, ...), so the offset must be applied to arguments 2 and 3,
        -- not 1 and 2. Offsetting the wrong pair made the plugin hand a string where a
        -- coordinate was expected and the call died with "attempt to perform arithmetic
        -- on a string".
        text = function(value, x, y, ...)
            return UX.text(value, x + dx, y + dy, ...)
        end,
        rect = function(x, y, ...) return UX.rect(x + dx, y + dy, ...) end,
        border = function(x, y, ...) return UX.border(x + dx, y + dy, ...) end,
        colour = UX.colour, palette = UX.palette,
        -- Recorded in the same units the helpers above take, so a plugin's click area
        -- lines up with what it drew.
        region = function(key, x, y, w, h)
            if not area(x,y,w,h) then return false end
            UX.region('plugin:' .. ctx.id .. ':' .. tostring(key), x + dx, y + dy, w, h)
        end,
        button = function(key, value, x, y, w, h, enabled, active)
            if not area(x,y,w,h) then return false end
            local C = UX.palette
            local full = 'plugin:' .. ctx.id .. ':' .. tostring(key)
            local hovered = PANEL.hover == full
            UX.rect(x+dx,y+dy,w,h,active and C.YELLOW or hovered and C.ROW_HI or C.PANEL,951)
            UX.border(x+dx,y+dy,w,h,hovered and C.TEXT or C.LINE2,952)
            UX.text(tostring(value),x+dx+8,y+dy+8,14,active and C.INK or enabled == false and C.DIM or C.TEXT,w-16)
            if enabled ~= false then UX.region(full,x+dx,y+dy,w,h) end
            return true
        end,
        note = plugin_note,
        version = M.version,
    }
end


local function panel_signature()
    local opts = automation.profile(PANEL.profile or 'host')
    local s, ox, oy = PANEL.ui_s, PANEL.ui_ox, PANEL.ui_oy
    return table.concat({
        PANEL.rw, PANEL.rh,
        string.format('%.3f', s or 0), ox or 0, oy or 0,
        tostring(PANEL.hover), tostring(PANEL.editing), tostring(PANEL.hint),
        tostring(PANEL.edit_text), tostring(PANEL.edit_field),
        PANEL.pos and PANEL.pos.fx or '-', PANEL.pos and PANEL.pos.fy or '-',
        tostring(PANEL.ui_scale or 1),
        draft.name, draft.mode, draft.time, draft.message,
        PANEL.profile or 'host', automation.state.active_role or '-', opts.output,
        tostring(PANEL.settings_view), opts and tostring(opts.enabled) or '-',
        tostring(PANEL.rule_view),tostring(PANEL.rule_selected),tostring(PANEL.rule_page),
        tostring(PANEL.rule_filter),tostring(PANEL.rule_search),tostring(automation.state.rule_revision),
        tostring(PANEL.preset_view), tostring(PANEL.preset_selected), tostring(PANEL.preset_page),
        tostring(PANEL.preset_name), tostring(PANEL.preset_path),
        tostring(preset_library.state.revision), tostring(preset_library.state.error),
        tostring(stratagem_catalog.state.generation),tostring(stratagem_catalog.state.status),
        tostring(opts.ping_small_enemy),tostring(opts.ping_flying_enemy),
        opts and tostring(opts.allow_solo) or '-', opts and opts.scope or '-',
        opts and tostring(opts.welcome) or '-', opts and opts.welcome_message or '-',
        opts and opts.cooldown or '-', opts and opts.welcome_delay or '-',
        opts and tostring(opts.ping) or '-', opts and opts.ping_message or '-',
        opts and tostring(opts.ping_summon) or '-', opts and opts.summon_message or '-',
        opts and opts.task_stratagem_message or '-', tostring(M.task_stratagem_status),
        opts and tostring(opts.ping_building) or '-', opts and tostring(opts.ping_stratagem) or '-', opts and tostring(opts.ping_medium_enemy) or '-',
        opts and tostring(opts.ping_large_enemy) or '-', opts and tostring(opts.ping_giant_enemy) or '-',
        opts and tostring(opts.ping_map) or '-', opts and tostring(opts.ping_sender_prefix) or '-',
        opts and tostring(opts.ping_sender_color) or '-', tostring(M.ping_status),
        task_revision, PANEL.task_page or 1,
        cfg.timer_on and 'on' or 'off', cfg.interval,
        string.format('%.0f', cfg.elapsed), cfg.message,
        tostring(M.sent or 0), tostring(M.last_peers or '-'),
        M.version, PANEL.version,
        tostring(PANEL.active_plugin), REGISTRY.signature(), tostring(PANEL.tab_page or 1),
        M.last_send and ((M.last_send.ok and 'ok:' or 'no:') .. tostring(M.last_send.why)) or '-',
    }, '|')
end

-- The plugin selected in the tab strip; nil means the default settings.
PANEL.active_plugin = PANEL.active_plugin

-- BEGIN ALERT PANEL
-- Dedicated configuration views using the existing Armory frame/input owner.
-- No native reads here; catalog rows and safely bound icons come from the host.
local function draw_alert_panel(canvas,p,a,catalog,chinese,version)
    local C=canvas.palette
    local function say(cn,en) return chinese and cn or en end
    local function text(v,x,y,size,c,w) canvas.text(v,x,y,size or 14,c or C.TEXT,w) end
    local function button(key,value,x,y,w,on)
        canvas.rect(x,y,w,32,on and C.YELLOW or p.hover==key and C.ROW_HI or C.PANEL,951)
        canvas.border(x,y,w,32,on and C.YELLOW or C.LINE2,952)
        text(value,x+9,y+8,13,on and C.INK or C.TEXT,w-18);canvas.region(key,x,y,w,32)
    end
    local role=p.profile or 'host';local opts=a.profile(role)
    button('profile:host',say('主机预设','HOST PRESET'),614,48,146,role=='host')
    button('profile:client',say('客机预设','CLIENT PRESET'),768,48,146,role=='client')
    text(say('输出：','OUTPUT: ')..(opts.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),
        614,86,12,C.YELLOW,300)
    button('rules:back',say('返回设置','BACK'),22,166,120,false)
    local enemy=p.rule_view=='enemy'
    text(enemy and say('敌人细分提醒','ENEMY ALERT RULES') or say('战备细分提醒','STRATAGEM ALERT RULES'),160,170,22,C.TEXT,750)
    text(say('自动消息：','AUTO MESSAGES: ')..(opts.enabled and opts.ping and 'ON' or 'OFF')..
        say('  · 空消息继承默认模板','  · BLANK MESSAGES INHERIT DEFAULTS'),22,210,12,C.MUTED,950)
    local rows={}
    if enemy then
        for _,v in ipairs({{'small_enemy','小型敌人','SMALL'}, {'medium_enemy','中型敌人','MEDIUM'},
            {'large_enemy','大型敌人','LARGE'}, {'giant_enemy','巨型敌人','MASSIVE'}, {'flying_enemy','飞行敌人','FLYING'}}) do
            rows[#rows+1]={id=v[1],name=say(v[2],v[3])}
        end
        text(say('飞行分类优先，不受原体型开关影响。','FLYING TAKES PRIORITY OVER SIZE.'),22,253,13,C.YELLOW,440)
        text(say('体型采用游戏内部 Small / Medium / Large / Massive。','SIZES FOLLOW THE GAME UNIT SIZE ENUM.'),22,278,12,C.MUTED,440)
        text(say('小型默认关闭；普通物资仍不提示。','SMALL IS OFF BY DEFAULT; NO ORDINARY SUPPLIES.'),22,303,12,C.MUTED,440)
    else
        local groups={{'red','红战备','RED'}, {'blue','蓝战备','BLUE'}, {'green','绿战备','GREEN'}}
        for i,v in ipairs(groups) do
            local y=237+(i-1)*38
            text(say(v[2],v[3]),22,y+9,14,C.TEXT,94)
            button('rules:bulk:'..v[1]..':on',say('全部开','ALL ON'),130,y,100,false)
            button('rules:bulk:'..v[1]..':off',say('全部关','ALL OFF'),238,y,100,false)
        end
        local x=22
        for _,v in ipairs({{'all','全部','ALL'},{'red','红','RED'},{'blue','蓝','BLUE'},{'green','绿','GREEN'},{'other','任务等','OTHER'}}) do
            button('rules:filter:'..v[1],say(v[2],v[3]),x,366,80,(p.rule_filter or 'all')==v[1]);x=x+86
        end
        canvas.rect(22,408,424,32,C.FIELD,951);canvas.border(22,408,424,32,C.LINE2,952)
        local search=p.edit_field=='rules:search' and p.edit_text or p.rule_search or ''
        text(search~='' and search or say('搜索名称或 ID（点击输入）','SEARCH NAME / ID'),30,416,14,C.MUTED,408)
        canvas.region('rules:search',22,408,424,32)
        local query=(p.rule_search or ''):lower()
        for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
            if ((p.rule_filter or 'all')=='all' or row.group==p.rule_filter)
                and (query=='' or row.name:lower():find(query,1,true) or tostring(row.id):find(query,1,true)
                    or row.debug_name:lower():find(query,1,true)) then rows[#rows+1]=row end
        end
        text(catalog.state.status,22,349,12,C.MUTED,424)
    end
    local selected
    for _,row in ipairs(rows) do if tostring(row.id)==tostring(p.rule_selected) then selected=row end end
    selected=selected or rows[1];p.rule_selected=selected and selected.id or nil
    local page_size=enemy and 5 or 10
    local pages=math.max(1,math.ceil(#rows/page_size))
    p.rule_page=math.max(1,math.min(pages,p.rule_page or 1))
    local top=enemy and 356 or 456
    for i=(p.rule_page-1)*page_size+1,math.min(#rows,p.rule_page*page_size) do
        local row=rows[i];local y=top+(i-(p.rule_page-1)*page_size-1)*40
        local rule=a.rule(enemy and 'enemy' or 'stratagem',row.id,role)
        local enabled=enemy and opts['ping_'..row.id] or not enemy and rule.enabled~=false
        local key='rules:select:'..row.id
        canvas.rect(22,y,424,36,row==selected and C.ROW_HI or C.PANEL,951)
        canvas.border(22,y,424,36,row==selected and C.YELLOW or C.LINE,952)
        if not enemy and canvas.icon then canvas.icon(row.icon,27,y+4,28) end
        text(row.name,enemy and 32 or 62,y+9,14,C.TEXT,enemy and 328 or 298)
        text(enabled and 'ON' or 'OFF',392,y+10,12,enabled and C.YELLOW or C.DIM,48)
        canvas.region(key,22,y,424,36)
    end
    if not enemy then
        button('rules:prev','<',22,872,60,false);text(p.rule_page..' / '..pages..'  ('..#rows..')',98,881,14,C.MUTED,260)
        button('rules:next','>',386,872,60,false)
        text(say('新目录条目自动加入；未知分类列在“任务等”。','NEW ROWS AUTO-APPEAR; UNKNOWN GROUPS IN OTHER.'),22,919,12,C.MUTED,424)
    end
    canvas.rect(470,245,508,701,C.PANEL,950);canvas.border(470,245,508,701,C.LINE,951)
    if not selected then
        text(say('等待游戏战备目录，或没有符合筛选的条目。','WAITING FOR CATALOG / NO MATCHES.'),486,270,14,C.MUTED,470)
        text(say('进入游戏后读取；不支持的版本会停止读取。','READS IN GAME; UNSUPPORTED BUILDS STOP.'),486,305,12,C.MUTED,470)
        return
    end
    local kind=enemy and 'enemy' or 'stratagem';local rule=a.rule(kind,selected.id,role)
    text(selected.name,486,262,20,C.TEXT,474)
    if not enemy then
        text(say('规则ID ','RULE ID ')..selected.id..'  · '..selected.group..'  · '..say('游戏冷却 ','GAME CD ')..string.format('%.0f',selected.cooldown)..'s',486,296,12,C.MUTED,474)
        if selected.variant_ids and #selected.variant_ids>1 then
            text(say('同名 '..#selected.variant_ids..' 个变体共用此规则','SHARED BY '..#selected.variant_ids..' SAME-NAME VARIANTS'),735,343,12,C.MUTED,225)
        end
    end
    local enabled=enemy and opts['ping_'..selected.id] or not enemy and rule.enabled~=false
    button('rules:enabled',say('此类提醒 ','THIS ALERT ')..(enabled and 'ON' or 'OFF'),486,334,230,enabled)
    local function field(name,title,y)
        local key='rule:'..kind..':'..selected.id..':'..name
        text(title,486,y,13,C.YELLOW,474)
        local value=p.edit_field==key and p.editing and p.edit_text or rule[name]
        value=value==nil and '' or tostring(value)
        local focus=p.edit_field==key and p.editing
        canvas.rect(486,y+23,474,36,C.FIELD,951);canvas.border(486,y+23,474,36,focus and C.YELLOW or C.LINE2,952)
        text(value~='' and value..(focus and '_' or '') or say('留空继承默认','BLANK = INHERIT'),494,y+33,14,focus and C.TEXT or C.MUTED,458)
        canvas.region(key,486,y+23,474,36)
    end
    field('mark_message',enemy and say('标记消息','MARK MESSAGE') or say('标记落地物品时的消息','LANDED EQUIPMENT MARK MESSAGE'),392)
    local y=478
    if not enemy then field('call_message',say('召唤 / 执行时的消息','CALL / TASK ACTION MESSAGE'),y);y=y+86 end
    field('cooldown',say('独立冷却（秒）：空 = 全局；0 = 每次新事件','RULE COOLDOWN: BLANK = GLOBAL; 0 = EVERY EVENT'),y)
    text(say('独立冷却按触发者 + 此规则分别计时。','SEPARATE TIMER PER TRIGGER PLAYER + RULE.'),486,y+78,12,C.YELLOW,474)
    text(say('0 绕过全局间隔；仍遵守总开关和事件去重。','0 BYPASSES GLOBAL INTERVAL; MASTER / DEDUPE APPLY.'),486,y+103,12,C.MUTED,474)
    text(say('变量：{玩家名} / {缩写} / {编号}','TOKENS: PLAYER NAME / SHORT / SLOT'),486,755,14,C.TEXT,474)
    text('{目标} / {类别} / {动作} / {位置}',486,786,14,C.TEXT,474)
    text(say('Enter 保存 · Esc 取消 · Ctrl+V 粘贴','ENTER SAVE · ESC CANCEL · CTRL+V PASTE'),486,828,12,C.MUTED,474)
    button('rules:inherit',say('恢复消息与冷却为默认','RESTORE MESSAGE / COOLDOWN DEFAULTS'),486,870,474,false)
    if p.hint then text(p.hint,486,919,12,C.YELLOW,474) end
end
-- END ALERT PANEL

-- BEGIN PRESET PANEL
-- Named automation preset page. The frame and hit testing belong to auto_chat.lua;
-- this renderer only records ordinary panel regions through UX.
local function draw_preset_panel(UX, PANEL, automation, preset_library, font_ok)
    local C, W, H = UX.palette, 1000, 990
    local text, rect, border, region = UX.text, UX.rect, UX.border, UX.region
    local role = PANEL.profile or 'host'
    local options = automation.profile(role)
    local function say(cn, en) return font_ok and cn or en end
    local function button(key, title, x, y, w, h, active)
        local hovered = PANEL.hover == key
        rect(x, y, w, h, active and C.YELLOW or hovered and C.ROW_HI or C.PANEL, 951)
        border(x, y, w, h, active and C.YELLOW or hovered and C.TEXT or C.LINE2, 952)
        text(title, x+w/2, y+(h-13)/2, 13, active and C.INK or C.TEXT, w-12, 'center')
        region(key, x, y, w, h)
    end
    local function field(key, title, value, y)
        text(title, 390, y, 11, C.YELLOW, 568)
        local focus = PANEL.editing and PANEL.edit_field == key
        rect(390,y+17,568,31,focus and C.ROW_HI or C.FIELD,951)
        border(390,y+17,568,31,focus and C.YELLOW or C.LINE2,952)
        local shown = focus and (PANEL.edit_text or value) or value
        text(tostring(shown or '')..(focus and '_' or ''),398,y+25,13,focus and C.TEXT or C.MUTED,552)
        region(key,390,y+17,568,31)
    end
    rect(22,158,342,H-210,C.PANEL,950);border(22,158,342,H-210,C.LINE,951)
    rect(378,158,W-400,H-210,C.PANEL,950);border(378,158,W-400,H-210,C.LINE,951)
    text(say('命名自动消息预设','NAMED AUTOMATION PRESETS'),40,178,20,C.TEXT,306)
    local entries=preset_library.list()
    text(#entries..' / 32',346,184,12,C.MUTED,nil,'right')
    if preset_library.state.error then
        text(say('预设库读取失败，已锁定写入：','LIBRARY ERROR; WRITES DISABLED:'),40,218,12,C.BAD,300)
        text(preset_library.state.error,40,240,11,C.BAD,300)
    elseif #entries==0 then text(say('暂无已保存预设','NO SAVED PRESETS'),40,224,14,C.DIM,300) end
    local pages=math.max(1,math.ceil(#entries/16))
    PANEL.preset_page=math.max(1,math.min(pages,PANEL.preset_page or 1))
    local first=(PANEL.preset_page-1)*16+1
    for i=first,math.min(#entries,first+15) do
        local entry=entries[i];local y=266+(i-first)*36
        local chosen=entry.id==PANEL.preset_selected
        rect(38,y,308,30,chosen and C.ROW_HI or C.ROW,951)
        border(38,y,308,30,chosen and C.YELLOW or C.LINE2,952)
        text(entry.name,48,y+8,13,chosen and C.YELLOW or C.TEXT,244)
        region('preset:select:'..entry.id,38,y,308,30)
    end
    button('preset:prev','<',38,H-132,40,26,PANEL.preset_page>1)
    text(PANEL.preset_page..' / '..pages,94,H-126,12,C.MUTED)
    button('preset:next','>',142,H-132,40,26,PANEL.preset_page<pages)
    button('preset:save',say('保存当前配置','SAVE CURRENT'),38,H-94,146,32,false)
    button('preset:replace',say('替换所选','REPLACE'),194,H-94,152,32,false)

    text(say('编辑目标：','EDITING:')..say(role=='host' and '主机' or '客机',role:upper()),390,178,13,C.YELLOW,270)
    text(say('当前：','ACTIVE: ')..(automation.state.active_role=='host' and say('主机','HOST') or automation.state.active_role=='client' and say('客机','CLIENT') or say('等待','WAITING')),682,178,12,C.MUTED,130)
    button('preset:back',say('返回设置','BACK TO SETTINGS'),822,168,136,30,false)
    text(say('当前配置输出：','CURRENT OUTPUT: ')..(options.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT'))..' / '..(options.scope=='all' and say('主机和客机','HOST + CLIENT') or say('仅主机','HOST ONLY')),390,201,12,C.MUTED,568)
    field('preset:name',say('预设名称','PRESET NAME'),PANEL.preset_name or '',230)
    local selected
    for _,entry in ipairs(entries) do if entry.id==PANEL.preset_selected then selected=entry;break end end
    text(selected and (say('已选：','SELECTED: ')..selected.name) or say('请选择预设','SELECT A PRESET'),390,348,13,selected and C.TEXT or C.DIM,420)
    button('preset:rename',say('改名','RENAME'),822,340,136,30,false)
    local valid,parsed
    if selected then valid,parsed=automation.validate_profile(selected.payload) end
    local saved=valid and parsed and parsed.values
    if saved then
        text(say('将载入：','WILL LOAD: ')..(saved.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT'))..' / '..(saved.scope=='all' and say('主机和客机','HOST + CLIENT') or say('仅主机','HOST ONLY')),390,376,12,C.YELLOW,568)
        text(say('自动消息：','AUTO SEND: ')..(saved.enabled and 'ON' or 'OFF')..'    '..say('标记：','PING: ')..(saved.ping and 'ON' or 'OFF'),390,394,12,C.MUTED,568)
    else text(say('无法预览所选预设内容','SELECTED PRESET CANNOT BE PREVIEWED'),390,376,12,C.BAD,568) end
    if selected then
        local count=0;for _ in selected.payload:gmatch('\nrule_[^=]+=[^\n]*') do count=count+1 end
        text(say('包含自动消息设置、模板和细粒度规则；规则字段：','AUTOMATION OPTIONS, TEMPLATES AND FINE GRAIN RULES; RULE FIELDS: ')..tostring(count),390,412,12,C.MUTED,568)
    end
    button('preset:apply',say('加载到所选角色','LOAD TO SELECTED ROLE'),390,432,210,34,false)
    button('preset:export',say('导出文件','EXPORT FILE'),612,432,160,34,false)
    button('preset:delete',say('删除','DELETE'),784,432,174,34,false)
    field('preset:path',say('导入文件路径','IMPORT FILE PATH'),PANEL.preset_path or '',488)
    button('preset:import',say('导入路径中的文件','IMPORT FILE FROM PATH'),390,556,276,34,false)
    text(PANEL.hint or say('导入只保存为命名预设；点击加载后才写入所选角色。','Import saves a named preset. Load applies it to the selected role.'),390,606,12,PANEL.hint and C.YELLOW or C.MUTED,568)
    if PANEL.preset_export_path then text(say('导出位置：','EXPORTED: ')..PANEL.preset_export_path,390,638,11,C.GOOD,568) end
end
-- END PRESET PANEL

local function draw_panel()
    if not (sr and sr.Gui and sr.Vector3 and sr.Vector2 and sr.Color) then return end
    local Gui, Vector3, Vector2, Color = UI()
    local gui = PANEL.gui
    local width, height = PANEL.rw, PANEL.rh

    -- Resolve the engine font on the first draw. This call is the whole real-text
    -- path: without it the lookup never runs, the panel draws with the bitmap
    -- fallback forever, and the symptom is simply "the text looks like the old
    -- panel" -- the font code was present, correct, and unreachable.
    font_resolve(gui)

    -- same clamp Armory uses: never bigger than the screen, never past the edge
    local s, ox, oy = panel_geometry(width, height)
    if s <= 0 then return end
    local function px(v) return math.floor(v + 0.5) end

    local function color(r, g, b, a) return Color(a or 255, r, g, b) end
    local C = {
        BG = color(11, 12, 13, 246), PANEL = color(18, 19, 21),
        ROW = color(26, 28, 31), ROW_HI = color(34, 36, 40),
        FIELD = color(10, 11, 12), LINE = color(44, 46, 50), LINE2 = color(62, 65, 70),
        TEXT = color(241, 239, 232), MUTED = color(190, 193, 197), DIM = color(158, 163, 169),
        YELLOW = color(255, 231, 16), INK = color(18, 17, 4),
        SOFT = color(255, 231, 16, 26), GOOD = color(92, 201, 170), BAD = color(255, 107, 91),
    }

    local function rect(x, y, w, h, c, z)
        local x0, x1 = px(ox + x * s), px(ox + (x + w) * s)
        local y0, y1 = px(oy + y * s), px(oy + (y + h) * s)
        if x1 <= x0 then x1 = x0 + 1 end
        if y1 <= y0 then y1 = y0 + 1 end
        pcall(Gui.rect, gui, Vector3(x0, height - y1, z or 951),
              Vector2(x1 - x0, y1 - y0), c)
    end
    local min_font = math.max(9, px(14 * height / 1080))
    local function font_px(size) return math.max(min_font, px(size * s)) end

    -- Engine measurement when available, else the same per-character estimate Armory
    -- uses (deliberately on the wide side).
    local function measure_px(value, sz)
        if FONT.ok then
            local ok, lo, hi = pcall(Gui.text_extents, gui, value, FONT.font, sz)
            if ok and lo and hi then
                local a = (lo.x ~= nil and lo.x) or lo[1]
                local b = (hi.x ~= nil and hi.x) or hi[1]
                if a and b and b > a then return b - a end
            end
        end
        local w = 0
        for ch in value:gmatch('.') do
            local b = ch:byte()
            if b >= 128 then w = w + (b >= 192 and 1.0 or 0)
            else
                w = w + (ch:find('[%%@MWmw]') and 0.98
                         or ch:find('[%u+=<>#&]') and 0.8
                         or ch:find('%d') and 0.66
                         or ch:find('[%s%.,:;!|il\'%-%(%)%[%]]') and 0.36
                         or 0.62)
            end
        end
        return w * sz
    end
    -- Armory's measure(): a text's width in PANEL units, which is what its layout code
    -- is written in. Its measure_px gives pixels, so this divides by the scale.
    local function measure(value, size)
        return measure_px(tostring(value), font_px(size)) / s
    end

    -- Keep a readable physical size. Long labels are ellipsized rather than
    -- compressed into the former 6-pixel text. Trim whole UTF-8 characters.
    local function text(value, x, y, size, c, limit, align)
        if value == nil or value == '' then return 0 end
        value = tostring(value)
        local sz = font_px(size)
        local w = measure_px(value, sz) / s
        while limit and w > limit and sz > min_font do
            sz = math.max(min_font, math.min(sz - 1, math.floor(sz * limit / w)))
            w = measure_px(value, sz) / s
        end
        if limit and w > limit then
            repeat
                local shorter = value:gsub('[\194-\244][\128-\191]*$', '')
                value = #shorter < #value and shorter or value:sub(1,-2)
            until value == '' or measure_px(value .. '..', sz) / s <= limit
            value = value .. '..'
            w = measure_px(value, sz) / s
        end
        local tx = x
        if align == 'right' then tx = x - w elseif align == 'center' then tx = x - w / 2 end
        local top = y + (size - sz / s) * 0.5
        if FONT.ok then
            local ok = pcall(Gui.text, gui, value, FONT.font, sz, FONT.material,
                             Vector3(px(ox + tx * s), px(height - oy - top * s - sz * 0.8), 954),
                             c or C.TEXT)
            if not ok then FONT.ok = false end
        end
        if not FONT.ok then
            -- Fallback: the 4x5 bitmap font, so a failed font lookup degrades the
            -- look instead of leaving a blank panel.
            bitmap_text(ox + tx * s, height - oy - (top + size) * s, value,
                        math.max(1, math.floor(sz / 5 + 0.5)), c or C.TEXT)
        end
        return w
    end
    local function border(x, y, w, h, c, z)
        rect(x, y, w, 1, c, z or 952); rect(x, y + h - 1, w, 1, c, z or 952)
        rect(x, y, 1, h, c, z or 952); rect(x + w - 1, y, 1, h, c, z or 952)
    end
    -- Text cut to fit at a readable size: "LONG MESSAGE GOES HER.."
    local function cut(value, size, limit)
        value = tostring(value)
        if measure_px(value, font_px(size)) / s <= limit then return value end
        local function shorter(v)
            local w = (v:gsub('[\194-\244][\128-\191]*$', ''))
            return #w < #v and w or v:sub(1, -2)
        end
        while #value > 3 and measure_px(value .. '..', font_px(size)) / s > limit do
            value = shorter(value)
        end
        return (value:gsub('[%s,%-]+$', '')) .. '..'
    end

    PANEL.regions = PANEL.regions or {}
    local regions = PANEL.regions
    for i = #regions, 1, -1 do regions[i] = nil end
    local function region(key, x, y, w, h)
        regions[#regions + 1] = {
            key = key,
            x = px(ox + x * s), y = px(height - oy - (y + h) * s),
            w = px(w * s), h = px(h * s),
        }
    end

    -- Published BEFORE anything draws. A plugin receives these helpers, and they must be
    -- populated by the time its draw runs -- assigning them at the end of this function
    -- (which is where they used to live) handed every plugin a nil palette, and the
    -- plugin's very first u.rect then failed on a nil index.
    UX.s, UX.ox, UX.oy, UX.height = s, ox, oy, height
    UX.text, UX.rect, UX.border = text, rect, border
    UX.colour, UX.palette = color, C
    UX.region = region
    UX.width, UX.panel_h = width, H_PANEL
    -- StratagemInfo+B0 is a material resource. Native pointers/texture hashes
    -- are never passed as bitmap materials, and unloaded assets stay blank.
    UX.icon=function(hash,x,y,size)
        if type(hash)~='string' or #hash~=16 or not hash:match('^%x+$')
            or not sr.IdString64 or type(sr.IdString64.from_hex)~='function'
            or type(Gui.bitmap_uv)~='function' or not resource_loaded('material',hash) then return false end
        local ok,id=pcall(sr.IdString64.from_hex,hash);if not ok or not id then return false end
        return pcall(Gui.bitmap_uv,gui,id,Vector2(0,0),Vector2(1,1),
            Vector3(px(ox+x*s),px(height-oy-(y+size)*s),953),Vector2(px(size*s),px(size*s)),color(255,255,255,255))
    end

    -- ---- frame: Armory's exact structure -------------------------------------
    --   * full-bleed background at z950, a 1px border at z955, and the game's thin
    --     YELLOW strip along the TOP edge (3px);
    --   * a top strip that reads as a title bar: a small muted eyebrow, the name, and
    --     the version right-aligned in DIM;
    --   * a tab strip BELOW that, 40 tall, where each tab measures its own caption;
    --   * the active tab is filled with C.PANEL, bordered C.TEXT, and carries the
    --     game's hatched stripe;
    --   * the body then starts under the strip.
    local PAD = 22
    local TAB_Y = 108          -- Armory puts its tab strip here
    local TAB_H = 40           -- ...and its tabs are this tall
    local HEAD = TAB_Y + TAB_H + 12
    local W, H = W_PANEL, H_PANEL

    rect(0, 0, W, H, C.BG, 950)
    border(0, 0, W, H, C.LINE, 955)
    rect(0, 0, W, 3, C.YELLOW, 952)                        -- the game's top strip
    region('drag', 0, 0, W, 32)

    local mx = text('AUTOCHAT', PAD, 12, 11, C.MUTED)
    text(PANEL.hover == 'drag' and '拖动移动窗口 / Ctrl+0 复位' or 'AUTOMATIC SQUAD CHAT',
         PAD + mx + 12, 12, 11, C.TEXT)
    text('v' .. M.version, W - PAD, 12, 11, C.DIM, nil, 'right')
    rect(0, 32, W, 1, C.LINE, 951)
    border(22, 44, 50, 50, C.TEXT, 952)
    rect(33, 54, 28, 20, C.YELLOW, 952); rect(36, 74, 22, 4, C.YELLOW, 952)
    rect(40, 78, 14, 4, C.YELLOW, 952); rect(44, 82, 6, 3, C.YELLOW, 952)
    rect(38, 59, 18, 4, C.INK, 953); rect(42, 63, 10, 4, C.INK, 953)
    local tw = text('AUTO', 86, 50, 34, C.TEXT)
    text('CHAT', 86 + tw + 12, 50, 34, C.YELLOW)
    text(FONT.ok and '自定义定时事件，自动发送小队消息。' or 'Schedule your squad messages.',
         88, 84, 12, C.MUTED, 420)
    text('X', W - PAD - 14, 48, 18, PANEL.hover == 'close' and C.YELLOW or C.MUTED)
    region('close', W - PAD - 28, 38, 28, 30)
    rect(470, 48, 130, 30, PANEL.preset_view and C.YELLOW or PANEL.hover == 'presets:open' and C.ROW_HI or C.PANEL, 951)
    border(470, 48, 130, 30, PANEL.preset_view and C.YELLOW or C.LINE2, 952)
    text(FONT.ok and '命名预设' or 'PRESETS', 535, 56, 13,
         PANEL.preset_view and C.INK or C.TEXT, 118, 'center')
    region('presets:open', 470, 48, 130, 30)
    if PANEL.preset_view then
        for _, item in ipairs({{'host', 614}, {'client', 768}}) do
            local role_key, role_x = item[1], item[2]
            local chosen = (PANEL.profile or 'host') == role_key
            local role_label = role_key == 'host' and 'HOST PRESET' or 'CLIENT PRESET'
            rect(role_x, 48, 146, 30, chosen and C.YELLOW or PANEL.hover == 'profile:' .. role_key and C.ROW_HI or C.PANEL, 951)
            border(role_x, 48, 146, 30, chosen and C.YELLOW or C.LINE2, 952)
            text(FONT.ok and (role_key == 'host' and '主机预设' or '客机预设') or role_label,
                 role_x + 73, 56, 13, chosen and C.INK or C.TEXT, 134, 'center')
            region('profile:' .. role_key, role_x, 48, 146, 30)
        end
        local current_role = automation.sync()
        text(FONT.ok and ('当前身份：' .. (current_role == 'host' and '主机' or current_role == 'client' and '客机' or '等待确认'))
             or ('ACTIVE: ' .. (current_role or 'WAITING'):upper()), 614, 86, 12, C.MUTED, 300)
    end

    -- the game's hatched stripe, as short diagonal steps (copied from Armory)
    local function hatch(x, y, w, c)
        local k = 0
        while k * 7 + 6 <= w do
            for j = 0, 2 do rect(x + k * 7 + j * 1.5, y + 4 - j * 2, 2.5, 2, c, 953) end
            k = k + 1
        end
    end
    -- one tab, width measured from its caption, exactly as Armory sizes them
    local function tab(key, caption, x, active)
        caption = string.upper(tostring(caption))
        local w = math.min(230, measure(caption, 15) + 30)
        local lim = w - 20
        if measure(caption, 11) > lim then
            while #caption > 3 and measure(caption .. '..', 11) > lim do
                caption = cut_utf8(caption, #caption-1)
            end
            caption = caption:gsub('[%s,]+$', '') .. '..'
        end
        rect(x, TAB_Y, w, TAB_H, active and C.PANEL or C.BG, 951)
        border(x, TAB_Y, w, TAB_H,
               active and C.TEXT or (PANEL.hover == key and C.MUTED or C.LINE2), 952)
        text(caption, x + 12, TAB_Y + 8, 15,
             active and C.TEXT
             or (PANEL.hover == key and C.TEXT or C.MUTED), w - 20)
        if active then hatch(x + 10, TAB_Y + 28, w - 20, C.TEXT) end
        region(key, x, TAB_Y, w, TAB_H)
        return w
    end

    -- ---------------------------------------------------------------- tab strip
    -- Armory's model: an ordered list of tab keys, one selected at a time, the whole
    -- body switched on it. Tab 1 is always the default settings; every mod that
    -- registered adds one more beside it, so a mod using this feature is visible AS A
    -- TAB instead of being buried in a shared list.
    -- The tab order, exactly like Armory's ui.tab_order: armory puts its tabs left to
    -- right in one strip and switches the whole body on the selected key. Tab 1 is
    -- always the SETTINGS tab; every registered mod appends one after it.
    local tabs = {{key = 'tab:default', title = FONT.ok and '设置' or 'SETTINGS', id = nil}}
    for i = 1, #M.PLUGINS do
        tabs[#tabs + 1] = {key = 'tab:' .. M.PLUGINS[i].id,
                           title = M.PLUGINS[i].title, id = M.PLUGINS[i].id}
    end
    if PANEL.active_plugin and not M.PLUGIN_BY_ID[PANEL.active_plugin] then
        PANEL.active_plugin = nil                       -- it unregistered itself
    end
    local page_size = 3
    local pages = math.max(1, math.ceil(#tabs/page_size))
    PANEL.tab_page = math.max(1, math.min(pages, PANEL.tab_page or 1))
    local tab_x = PAD
    local tab_keys = {}
    for i = (PANEL.tab_page-1)*page_size+1, math.min(#tabs,PANEL.tab_page*page_size) do
        local entry = tabs[i]
        local reached = tab(entry.key, entry.title, tab_x, entry.id == PANEL.active_plugin)
        tab_keys[entry.key] = entry.id
        tab_x = tab_x + reached + 6
    end
    if pages > 1 then
        if PANEL.tab_page > 1 then
            tab('tabs:prev', '<', W-200, false)
        end
        text(PANEL.tab_page .. '/' .. pages, W-135, TAB_Y+12, 12, C.MUTED)
        if PANEL.tab_page < pages then tab('tabs:next', '>', W-80, false) end
    end
    PANEL.tab_keys = tab_keys
    local body_y = TAB_Y + TAB_H + 12

    -- ---------------------------------------------------------- plugin body
    local active = PANEL.active_plugin and M.PLUGIN_BY_ID[PANEL.active_plugin] or nil
    if active then
        local ok, result, err = pcall(active.draw, plugin_api({
            id = active.id, w = W_PANEL, h = H_PANEL,
            ox = PAD, oy = body_y + 10,
        }), {body_y = body_y, panel_w = W_PANEL, panel_h = H_PANEL})
        if not ok or result == false and active.last_error then
            -- A third-party draw runs inside this panel's frame. Drop it for the
            -- session with its name in the log rather than faulting every frame.
            active.faults = (active.faults or 0) + 1
            plugin_note('"' .. active.title .. '" draw failed: ' .. tostring(active.last_error or err or result))
            M.unregister_plugin(active.id)
            PANEL.active_plugin = nil
        end
        -- The plugin owns the body; the default rows below are not drawn.
        UX.s, UX.ox, UX.oy, UX.height = s, ox, oy, height
        UX.text, UX.rect = text, rect
        UX.border, UX.colour, UX.palette = border, color, C
        UX.region = region
        UX.width, UX.panel_h = width, H_PANEL
        PANEL.ui_s, PANEL.ui_ox, PANEL.ui_oy = s, ox, oy
        return
    end

    -- ---------------------------------------------------------- settings body
    if PANEL.rule_view then
        stratagem_catalog.scan(os.time())
        draw_alert_panel(UX,PANEL,automation,stratagem_catalog,FONT.ok,M.version)
        PANEL.ui_s,PANEL.ui_ox,PANEL.ui_oy=s,ox,oy
        return
    end
    if PANEL.preset_view then
        draw_preset_panel(UX, PANEL, automation, preset_library, FONT.ok)
        PANEL.ui_s,PANEL.ui_ox,PANEL.ui_oy=s,ox,oy
        return
    end
    -- The row helpers below are Armory's own, copied from its draw(): `label` is the
    -- small uppercase yellow eyebrow, `head` pairs it with a big title underneath, and
    -- `button` carries Armory's hover / filled / disabled states. The body is laid out
    -- as labelled rows, which is the shape of an Armory settings page rather than a list
    -- of my own devising.
    -- Armory's two-column settings frame, with the same original dimensions.
    local LX, LW, TOP = 22, 330, 158
    local X0 = LX + LW + 14
    local RW, BOT = W - 22 - X0, H - 52
    rect(LX, TOP, LW, BOT - TOP, C.PANEL, 950)
    border(LX, TOP, LW, BOT - TOP, C.LINE, 951)
    rect(X0, TOP, RW, BOT - TOP, C.PANEL, 950)
    border(X0, TOP, RW, BOT - TOP, C.LINE, 951)
    local IX, IW = LX + 14, LW - 28
    local RX, RIW = X0 + 16, RW - 32
    local function label(value, x, y, c, limit)
        return text(string.upper(tostring(value)), x, y, 11, c or C.YELLOW, limit)
    end
    local function head(x, y, lab, title)
        label(lab, x, y)
        text(string.upper(tostring(title)), x, y + 16, 21, C.TEXT, IW)
    end
    local function button(key, caption, x, y, w, h, enabled, filled, ink)
        local size = 13
        w = w or (measure(caption, size) + 28)
        local hovered = PANEL.hover == key and enabled ~= false
        if filled then
            rect(x, y, w, h, enabled == false and C.YELLOW_DK or C.YELLOW, 951)
            if hovered then border(x, y, w, h, C.TEXT, 953) end
        else
            rect(x, y, w, h, hovered and C.ROW_HI or C.PANEL, 951)
            border(x, y, w, h,
                   enabled == false and C.LINE or hovered and C.TEXT or C.LINE2)
        end
        local c = enabled == false and C.DIM or filled and C.INK or ink or C.TEXT
        text(caption, x + w / 2, y + (h - size) / 2, size, c, w - 14, 'center')
        region(key, x, y, w, h)
        return w
    end
    local function checkbox(key, x, y, on)
        local hovered = PANEL.hover == key
        border(x, y, 16, 16, on and C.YELLOW or hovered and C.YELLOW or C.MUTED, 952)
        if on then rect(x + 4, y + 4, 8, 8, C.YELLOW, 953) end
        region(key, x - 5, y - 4, 26, 24)
    end

    local function caption(cn, en) return FONT.ok and cn or en end
    local function field(key, title, value, y)
        label(title, IX, y)
        local focus = PANEL.edit_field == key and PANEL.editing
        local shown = focus and (PANEL.edit_text or value) or value
        rect(IX, y + 18, IW, 30, focus and C.ROW_HI or C.FIELD, 951)
        border(IX, y + 18, IW, 30, focus and C.YELLOW or C.LINE2, 952)
        text(cut(tostring(shown) .. (focus and '_' or ''), 14, IW - 18),
             IX + 8, y + 25, 14, focus and C.TEXT or C.MUTED, IW - 18)
        region(key:match('^option:') and key or ('task:' .. key), IX, y + 18, IW, 30)
    end
    local editing_role = PANEL.profile or 'host'
    button('profile:host', caption('主机预设', 'HOST PRESET'), 614, 48, 146, 30, true, editing_role == 'host')
    button('profile:client', caption('客机预设', 'CLIENT PRESET'), 768, 48, 146, 30, true, editing_role == 'client')
    local current_role = automation.sync()
    text(caption('当前身份：' .. (current_role == 'host' and '主机' or current_role == 'client' and '客机' or '等待确认'),
         'ACTIVE: ' .. (current_role or 'WAITING'):upper()), 614, 86, 12, C.MUTED, 300)
    local y = TOP + 14
    head(IX, y, 'AUTOCHAT', PANEL.settings_view == 'automation' and caption('自动消息设置', 'AUTO MESSAGE SETTINGS')
        or PANEL.settings_view == 'pings' and caption('玩家标记消息', 'PLAYER PING MESSAGES')
        or caption('添加定时任务', 'ADD SCHEDULED TASK'))
    y = y + 55
    local navw = (IW - 12) / 3
    button('view:tasks', caption('定时任务', 'TASKS'), IX, y, navw, 30, true,
           PANEL.settings_view ~= 'automation' and PANEL.settings_view ~= 'pings')
    button('view:automation', caption('自动消息', 'AUTO SEND'), IX + navw + 6,
           y, navw, 30, true, PANEL.settings_view == 'automation')
    button('view:pings', caption('标记消息', 'PING'), IX + 2 * (navw + 6),
           y, navw, 30, true, PANEL.settings_view == 'pings')
    y = y + 44
    if PANEL.settings_view == 'pings' and M.options then
        local opts = automation.profile(PANEL.profile or 'host')
        for _, item in ipairs({{'ping','玩家标记自动消息','ENABLE PING MESSAGES'},
            {'ping_building','任务建筑','MISSION BUILDINGS'}, {'ping_stratagem','战备物品标记','STRATAGEM EQUIPMENT'},
            {'ping_summon','战备召唤 / 任务执行','CALL-INS / TASK ACTIONS'},
            {'ping_map','地图任务 / 撤离区','MAP OBJECTIVES / EXTRACTION'},
            {'ping_sender_prefix','显示触发者缩写','TRIGGER PLAYER PREFIX'},
            {'ping_sender_color','缩写使用队员颜色','PLAYER COLOR PREFIX'}}) do
            button('opt:' .. item[1], caption(item[2], item[3]) .. (opts[item[1]] and ' [ON]' or ' [OFF]'),
                   IX, y, IW, 30, true, opts[item[1]])
            y = y + 34
        end
        button('rules:open:stratagem',caption('战备细分设置 →','STRATAGEM RULES >'),IX,y,IW,30,true,false);y=y+34
        button('rules:open:enemy',caption('敌人体型 / 飞行提醒 →','ENEMY / FLYING RULES >'),IX,y,IW,30,true,false);y=y+34
        field('option:ping_message', caption('标记提示消息', 'PING MESSAGE'), opts.ping_message, y)
        y = y + 64
        field('option:summon_message', caption('召唤提示消息', 'CALL-IN MESSAGE'), opts.summon_message, y)
        y = y + 58
        field('option:task_stratagem_message', caption('任务执行消息', 'TASK ACTION MESSAGE'), opts.task_stratagem_message, y)
        y = y + 58
        text(caption('本人和队友；共享记录显示“小队”', 'SELF + TEAM; SHARED CALLS: SQUAD'), IX, y, 12, C.YELLOW, IW)
        text(caption(M.ping_status or '等待标记数据', 'NATIVE READER: ' .. (opts.ping and 'ACTIVE' or 'OFF')), IX, y + 22, 12, C.MUTED, IW)
        text(caption(M.task_stratagem_status or '等待任务战备数据', 'TASK STRATAGEM READER'), IX, y + 40, 12, C.MUTED, IW)
        text(caption('变量：{类别} / {目标} / {位置} / {动作}', 'TOKENS: CATEGORY / TARGET / POSITION / ACTION'), IX, y + 62, 12, C.MUTED, IW)
        text(caption('{任务名} / {任务类型}（地图任务）', 'OBJECTIVE NAME / OBJECTIVE TYPE'), IX, y + 84, 12, C.MUTED, IW)
        text(caption('{玩家名} / {缩写} / {编号}', 'PLAYER NAME / SHORT / SLOT'), IX, y + 106, 12, C.MUTED, IW)
        if PANEL.hint then text(PANEL.hint, IX, y + 128, 11, C.YELLOW, IW) end
    elseif PANEL.settings_view == 'automation' and M.options then
        local opts = automation.profile(PANEL.profile or 'host')
        local function toggle(key, zh, en)
            button('opt:' .. key, caption(zh, en) .. (opts[key] and ' [ON]' or ' [OFF]'),
                   IX, y, IW, 30, true, opts[key])
            y = y + 40
        end
        toggle('enabled', '自动发送总开关', 'ENABLE AUTO SEND')
        label(caption('发送角色范围', 'WHO SENDS'), IX, y)
        y = y + 18
        button('scope:host', caption('仅主机', 'HOST ONLY'), IX, y, (IW - 8) / 2, 30, true, opts.scope == 'host')
        button('scope:all', caption('主机和客机', 'HOST + CLIENT'), IX + (IW + 8) / 2, y,
               (IW - 8) / 2, 30, true, opts.scope == 'all')
        y = y + 42
        label(caption('消息输出方式', 'MESSAGE OUTPUT'), IX, y)
        y = y + 18
        button('output:squad', caption('小队公屏', 'SQUAD CHAT'), IX, y, (IW - 8)/2, 30, true, opts.output == 'squad')
        button('output:local', caption('仅自己可见', 'ONLY ME'), IX + (IW + 8)/2, y, (IW - 8)/2, 30, true, opts.output == 'local')
        y = y + 40
        toggle('allow_solo', '无人房间也发送', 'ALLOW SOLO SEND')
        field('option:cooldown', caption('每人自动消息最短间隔（秒）', 'PER-PLAYER MESSAGE INTERVAL (SECONDS)'), tostring(opts.cooldown), y)
        y = y + 64
        text(caption('按触发玩家分别计时；0为不限制', 'EACH TRIGGER PLAYER HAS A SEPARATE TIMER; 0 = UNLIMITED'),
             IX, y - 13, 10, C.DIM, IW)
        toggle('welcome', '新人加入自动欢迎', 'WELCOME NEW PLAYERS')
        field('option:welcome_message', caption('欢迎消息', 'WELCOME MESSAGE'), opts.welcome_message, y)
        y = y + 64
        field('option:welcome_delay', caption('欢迎延迟（秒）', 'WELCOME DELAY (SECONDS)'), tostring(opts.welcome_delay), y)
        y = y + 66
        button('view:pings', caption('玩家标记分类设置 >', 'PING CATEGORIES >'), IX, y, IW, 30, true)
        y = y + 44
        text(PANEL.hint or caption('修改后自动保存；Enter 确认，Esc 取消', 'AUTO SAVED / ENTER CONFIRMS / ESC CANCELS'),
             IX, y, 12, PANEL.hint and C.YELLOW or C.MUTED, IW)
        text(caption('欢迎语可用 {玩家名}、{缩写}、{编号}', 'WELCOME: {玩家名} / {缩写} / {编号}'), IX, y + 38, 11, C.DIM, IW)
    else
    field('name', caption('事件名称', 'EVENT NAME'), draft.name, y)
    y = y + 62
    label(caption('定时类型', 'SCHEDULE TYPE'), IX, y)
    y = y + 18
    local modes = {{'repeat', '重复间隔', 'REPEAT'}, {'once', '一次倒计时', 'COUNTDOWN'},
                   {'daily', '每天定时', 'DAILY'}}
    local bw = (IW - 12) / 3
    for i, mode in ipairs(modes) do
        button('mode:' .. mode[1], caption(mode[2], mode[3]), IX + (i - 1) * (bw + 6),
               y, bw, 30, true, draft.mode == mode[1])
    end
    y = y + 44
    field('time', draft.mode == 'daily' and caption('每天发送时间 (HH:MM)', 'LOCAL TIME (HH:MM)')
          or caption('时间（秒）', 'TIME (SECONDS)'), draft.time, y)
    y = y + 62
    field('message', caption('发送消息', 'MESSAGE TO SEND'), draft.message, y)
    y = y + 62
    button('task:add', caption('添加定时任务', 'ADD TASK'), IX, y, IW, 32, true, true)
    y = y + 43
    text(PANEL.hint or caption('点击输入框填写；Enter 确认，Esc 取消', 'CLICK TO TYPE. ENTER CONFIRMS / ESC CANCELS'),
         IX, y, 12, PANEL.hint and C.YELLOW or C.DIM, IW)
    text(caption('重复 / 倒计时：5–86400 秒', 'REPEAT / COUNTDOWN: 5-86400 S'), IX, y + 32, 12, C.MUTED, IW)
    text(caption('每天定时：使用本机时间', 'DAILY: LOCAL SYSTEM TIME'), IX, y + 52, 12, C.MUTED, IW)
    end
    -- The right column uses the same row controls as the settings form.
    IX, IW = RX, RIW
    y = TOP + 14
    head(IX, y, caption('设置', 'SETTINGS'), (PANEL.profile or 'host') == 'host'
         and caption('主机定时任务', 'HOST TASKS') or caption('客机定时任务', 'CLIENT TASKS'))
    local visible_tasks = M.profile_tasks(PANEL.profile or 'host')
    text(#visible_tasks .. ' / 32', IX + IW, y + 20, 12, C.MUTED, nil, 'right')
    y = y + 58
    local pages = math.max(1, math.ceil(#visible_tasks / 7))
    PANEL.task_page = math.max(1, math.min(pages, PANEL.task_page or 1))
    local start = (PANEL.task_page - 1) * 7 + 1
    if #visible_tasks == 0 then
        text(caption('暂无任务，填写上方表单即可添加', 'NO TASKS. FILL THE FORM ABOVE.'), IX, y + 12, 13, C.DIM, IW)
    end
    for i = start, math.min(#visible_tasks, start + 6) do
        local t = visible_tasks[i]
        rect(IX, y, IW, 68, C.ROW, 951)
        local state = t.done and caption('已执行', 'DONE')
                      or t.enabled and caption('运行中', 'ON') or caption('暂停', 'PAUSED')
        text(cut(t.name, 14, IW - 160), IX + 8, y + 7, 14, C.TEXT, IW - 160)
        text(t.mode:upper() .. ' / ' .. t.time .. (t.mode == 'daily' and '' or ' S') .. ' / ' .. state,
             IX + 8, y + 27, 11, t.enabled and C.GOOD or C.DIM, IW - 140)
        text(cut(t.result or t.message, 11, IW - 16), IX + 8, y + 48, 11, C.MUTED, IW - 16)
        button('toggle:' .. t.id, t.done and caption('重启', 'RESTART') or t.enabled
               and caption('暂停', 'PAUSE') or caption('启用', 'ENABLE'),
               IX + IW - 136, y + 7, 72, 28, true)
        button('delete:' .. t.id, caption('删除', 'DEL'), IX + IW - 58, y + 7, 50, 28, true)
        y = y + 76
    end
    -- Fixed footer keeps pagination reachable on both empty and full pages.
    y = BOT - 40
    button('page:prev', '<', IX, y, 34, 26, PANEL.task_page > 1)
    text(PANEL.task_page .. ' / ' .. pages, IX + 48, y + 6, 12, C.MUTED)
    button('page:next', '>', IX + 112, y, 34, 26, PANEL.task_page < pages)
    text(caption('仅在游戏运行时执行 · 本机时间', 'WHILE GAME RUNS / LOCAL TIME'), IX, H - 30, 11, C.DIM, IW)

    UX.s, UX.ox, UX.oy, UX.height = s, ox, oy, height
    UX.text, UX.rect = text, rect
    UX.border, UX.colour, UX.palette = border, color, C
    UX.region = region
    UX.width, UX.panel_h = width, H_PANEL
    -- Remembered for the signature and the hit-test, so the layout that was drawn is
    -- the layout that is compared and clicked against.
    PANEL.ui_s, PANEL.ui_ox, PANEL.ui_oy = s, ox, oy
end

-- Assigned now that take_cursor / release_cursor / panel_clear all exist. The
-- forward declaration sits above (before the hook that closes over it), because a
-- `local` declared after its reader would leave the reader holding nil.
set_panel_open = function(open)
    open = open and true or false
    if open == PANEL.open then return PANEL.open end
    PANEL.open = open
    M.panel_open = open
    PANEL.version = (PANEL.version or 0) + 1
    if open then
        PANEL.profile = PANEL.profile or automation.sync() or 'host'
        PANEL.armed, mouse_was_down = nil, nil
        take_cursor()
    else
        panel_input.release()
        if PANEL.drag then PANEL.drag = nil; pcall(save_position) end
        PANEL.armed, mouse_was_down = nil, nil
        PANEL.editing, PANEL.edit_field, PANEL.edit_text = nil, nil, nil
        release_cursor()
        panel_clear()
    end
    return PANEL.open
end

local function panel_frame()
    -- Not before the world exists: creating a screen GUI too early faults at native
    -- level, and pcall does not catch native faults.
    if M.frames < 600 then return end
    if not world_ready() then panel_input.release(); return end

    -- hotkey K (0x4B)
    local toggle = key_pressed(0x4B)
    if toggle and not PANEL.editing then
        set_panel_open(not PANEL.open)
        note('panel ' .. (PANEL.open and 'opened' or 'closed'))
        write_status()
    end

    if not PANEL.open then
        panel_input.release()
        release_cursor()
        return
    end
    if PANEL.lfail >= 3 then
        -- Three refusals from the engine. Stop calling into it every frame; the panel
        -- stays off for the rest of the session. lfail resets on any success, so an
        -- isolated refusal does not count toward the three.
        panel_input.release()
        release_cursor()
        return
    end

    local is_focused = focused()
    panel_input.hold(os.clock(), is_focused and user.GetForegroundWindow() or nil, key_down(0x4B))
    M.input_state = panel_input.status().state
    keep_cursor()
    local gx, gy = mouse_state()
    local down = key_down(0x01)
    local pressed, released = mouse_was_down ~= nil and down and not mouse_was_down,
        not down and mouse_was_down
    mouse_was_down = down

    -- Panel-space hit testing, the way Armory does it: the regions are recorded in
    -- SCREEN pixels while drawing, and the pointer is converted into the same space.
    -- Nothing recomputes the layout here, so a region can never disagree with what was
    -- drawn -- which is what happened when the two were derived separately.
    local function to_panel(cx, cy)
        if not (UX.s and UX.s > 0) then return nil end
        return (cx - UX.ox) / UX.s, (UX.height - cy - UX.oy) / UX.s
    end
    local function hit(px_, py_)
        local regions = PANEL.regions
        if not (regions and px_) then return nil end
        for i = 1, #regions do
            local r = regions[i]
            if px_ >= r.x and px_ <= r.x + r.w
               and py_ >= r.y and py_ <= r.y + r.h then
                return r.key
            end
        end
        return nil
    end

    -- gx/gy are already in engine resolution with a bottom-left origin, which is
    -- exactly the space the regions were recorded in, so no further conversion.
    local hovered = hit(gx, gy)
    PANEL.hover = hovered

    if not focused() then
        if PANEL.drag then PANEL.drag = nil; pcall(save_position) end
        PANEL.armed, mouse_was_down = nil, nil
        return
    end
    if PANEL.drag then
        local d = PANEL.drag
        PANEL.hover = 'drag'
        if down and gx then
            local s = select(1, panel_geometry(PANEL.rw, PANEL.rh))
            local x = math.max(0, math.min(PANEL.rw - W_PANEL * s, d.x + gx - d.cx))
            local y = math.max(0, math.min(PANEL.rh - H_PANEL * s, d.y + PANEL.rh - gy - d.cy))
            PANEL.pos = {fx = x / PANEL.rw, fy = y / PANEL.rh}
        elseif not down then
            PANEL.drag = nil
            pcall(save_position)
        end
    elseif pressed and hovered == 'drag' then
        PANEL.drag = {cx = gx, cy = PANEL.rh - gy, x = UX.ox, y = UX.oy}
        PANEL.armed = nil
    end
    local clicked = released and PANEL.armed ~= nil and PANEL.armed == hovered and not PANEL.drag
    if pressed and hovered ~= 'drag' then PANEL.armed = hovered end
    if released then PANEL.armed = nil end
    local reset = key_pressed(0x30) or key_pressed(0x60)
    local zoom_in = key_pressed(0xBB) or key_pressed(0x6B)
    local zoom_out = key_pressed(0xBD) or key_pressed(0x6D)
    if not PANEL.editing and key_down(0x11) then
        if reset then
            PANEL.ui_scale, PANEL.pos, PANEL.drag = 1, nil, nil
            pcall(save_position)
        elseif zoom_in then
            PANEL.ui_scale = math.min(2, (PANEL.ui_scale or 1) + 0.1)
        elseif zoom_out then
            PANEL.ui_scale = math.max(0.8, (PANEL.ui_scale or 1) - 0.1)
        end
    end
    local function finish_edit(commit)
        if commit and PANEL.edit_field then
            local option = PANEL.edit_field:match('^option:(.+)$')
            local kind,id,rule_field=PANEL.edit_field:match('^rule:([^:]+):([^:]+):([^:]+)$')
            if kind then
                local value=PANEL.edit_text or ''
                if rule_field=='cooldown' and value~='' then value=tonumber(value) or false end
                local ok,why=automation.set_rule(kind,id,rule_field,value,PANEL.profile or 'host')
                PANEL.hint=why;if not ok then return false end
            elseif PANEL.edit_field=='rules:search' then
                PANEL.rule_search=PANEL.edit_text or '';PANEL.rule_page=1
            elseif option then
                local value = PANEL.edit_text
                if option == 'cooldown' or option == 'welcome_delay' then value = tonumber(value) end
                local ok, why = automation.set(option, value, PANEL.profile or 'host')
                if not ok then PANEL.hint = why; return false end
            elseif PANEL.edit_field == 'preset:name' then
                PANEL.preset_name = PANEL.edit_text or ''
            elseif PANEL.edit_field == 'preset:path' then
                PANEL.preset_path = PANEL.edit_text or ''
            else
                draft[PANEL.edit_field] = PANEL.edit_text or draft[PANEL.edit_field]
            end
        end
        PANEL.editing, PANEL.edit_field, PANEL.edit_text = nil, nil, nil
        M.key_held = key_held
        for k in pairs(key_held) do key_held[k] = nil end
        return true
    end
    if clicked and hovered then
        local field = hovered:match('^task:(name)$') or hovered:match('^task:(time)$')
                      or hovered:match('^task:(message)$')
        local option = hovered:match('^option:(.+)$')
        local preset_field = hovered == 'preset:name' or hovered == 'preset:path'
        local opt_toggle = hovered:match('^opt:(.+)$')
        local scope = hovered:match('^scope:(.+)$')
        local mode = hovered:match('^mode:(%a+)$')
        local toggle_id = hovered:match('^toggle:(%d+)$')
        local delete_id = hovered:match('^delete:(%d+)$')
        local keys = PANEL.tab_keys
        if clicked and hovered ~= 'close' and not finish_edit(true) then
            clicked = false
        elseif hovered:match('^rule:') then
            local kind,id,rule_field=hovered:match('^rule:([^:]+):([^:]+):([^:]+)$')
            local value=automation.rule(kind,id,PANEL.profile or 'host')[rule_field]
            PANEL.editing,PANEL.edit_field,PANEL.edit_text=true,hovered,value==nil and '' or tostring(value)
            PANEL.hint='Enter 保存 / Esc 取消 / Ctrl+V 粘贴'
        elseif hovered=='rules:search' then
            PANEL.editing,PANEL.edit_field,PANEL.edit_text=true,hovered,PANEL.rule_search or ''
        elseif hovered:match('^rules:open:') then
            PANEL.rule_view=hovered:match('^rules:open:(.+)$');PANEL.rule_selected=nil;PANEL.rule_page=1;PANEL.preset_view=nil;PANEL.hint=nil
        elseif hovered=='rules:back' then PANEL.rule_view=nil;PANEL.hint=nil
        elseif hovered:match('^rules:select:') then
            PANEL.rule_selected=hovered:match('^rules:select:(.+)$');PANEL.hint=nil
        elseif hovered:match('^rules:filter:') then
            PANEL.rule_filter=hovered:match('^rules:filter:(.+)$');PANEL.rule_page=1;PANEL.rule_selected=nil
        elseif hovered=='rules:prev' or hovered=='rules:next' then
            PANEL.rule_page=math.max(1,(PANEL.rule_page or 1)+(hovered=='rules:next' and 1 or -1))
        elseif hovered:match('^rules:bulk:') then
            local group,value=hovered:match('^rules:bulk:([^:]+):([^:]+)$');local ids={}
            for _,row in ipairs(stratagem_catalog.list_rules()) do if row.group==group then ids[#ids+1]=row.id end end
            if #ids>0 then local _,why=automation.set_rules('stratagem',ids,value=='on',PANEL.profile or 'host');PANEL.hint=why
            else PANEL.hint='该分类尚无可读取的战备' end
        elseif hovered=='rules:enabled' and PANEL.rule_selected then
            local kind=PANEL.rule_view;local id=PANEL.rule_selected;local role=PANEL.profile or 'host'
            local ok,why
            if kind=='enemy' then ok,why=automation.set('ping_'..id,not automation.profile(role)['ping_'..id],role)
            else ok,why=automation.set_rule(kind,id,'enabled',automation.rule(kind,id,role).enabled==false,role) end
            PANEL.hint=why
        elseif hovered=='rules:inherit' and PANEL.rule_selected then
            local ok,why=automation.reset_rule(PANEL.rule_view,PANEL.rule_selected,PANEL.profile or 'host');PANEL.hint=why
        elseif hovered == 'presets:open' then
            PANEL.preset_view = true
            PANEL.rule_view, PANEL.active_plugin, PANEL.hint = nil, nil, nil
        elseif hovered == 'preset:back' then
            PANEL.preset_view, PANEL.hint = nil, nil
            PANEL.settings_view = 'automation'
        elseif hovered:match('^preset:select:') then
            PANEL.preset_selected = hovered:match('^preset:select:(.+)$')
            PANEL.hint = nil
        elseif hovered == 'preset:prev' or hovered == 'preset:next' then
            local pages = math.max(1, math.ceil(#preset_library.list()/16))
            PANEL.preset_page = math.max(1, math.min(pages, (PANEL.preset_page or 1)
                + (hovered == 'preset:next' and 1 or -1)))
        elseif preset_field then
            local key = hovered == 'preset:name' and 'preset_name' or 'preset_path'
            PANEL.editing, PANEL.edit_field, PANEL.edit_text = true, hovered, PANEL[key] or ''
            PANEL.hint = 'Enter 确认输入 / Esc 取消'
        elseif hovered == 'preset:save' then
            local ok, why, id = preset_library.save(PANEL.preset_name or '', PANEL.profile or 'host')
            PANEL.hint = ok and '已保存当前自动消息配置' or why
            if ok then
                PANEL.preset_selected = id
                PANEL.preset_page = math.ceil(#preset_library.list()/16)
            end
        elseif hovered == 'preset:replace' then
            if not PANEL.preset_selected then PANEL.hint = '请先选择预设'
            else
                local ok, why = preset_library.replace(PANEL.preset_selected, PANEL.profile or 'host')
                PANEL.hint = ok and '已替换所选预设内容' or why
            end
        elseif hovered == 'preset:rename' then
            if not PANEL.preset_selected then PANEL.hint = '请先选择预设'
            else
                local ok, why = preset_library.rename(PANEL.preset_selected, PANEL.preset_name or '')
                PANEL.hint = ok and '预设名称已更新' or why
            end
        elseif hovered == 'preset:apply' then
            if not PANEL.preset_selected then PANEL.hint = '请先选择预设'
            else
                local ok, why = preset_library.apply(PANEL.preset_selected, PANEL.profile or 'host')
                PANEL.hint = ok and '已加载到所选角色' or why
            end
        elseif hovered == 'preset:export' then
            if not PANEL.preset_selected then PANEL.hint = '请先选择预设'
            else
                local ok, why, path = preset_library.export(PANEL.preset_selected)
                PANEL.hint = ok and '预设已导出' or why
                PANEL.preset_export_path = ok and path or nil
            end
        elseif hovered == 'preset:delete' then
            if not PANEL.preset_selected then PANEL.hint = '请先选择预设'
            else
                local ok, why = preset_library.remove(PANEL.preset_selected)
                PANEL.hint = ok and '预设已删除' or why
                if ok then PANEL.preset_selected = nil; PANEL.preset_export_path = nil end
            end
        elseif hovered == 'preset:import' then
            local ok, why, id = preset_library.import(PANEL.preset_path or '')
            PANEL.hint = ok and '预设已导入，请选择后加载' or why
            if ok then
                PANEL.preset_selected = id
                PANEL.preset_page = math.ceil(#preset_library.list()/16)
            end
        elseif option then
            PANEL.editing, PANEL.edit_field, PANEL.edit_text = true, hovered, tostring(automation.profile(PANEL.profile or 'host')[option])
            PANEL.hint = 'Enter 保存 / Esc 取消 / Ctrl+V 粘贴'
        elseif opt_toggle then
            local ok, why = automation.set(opt_toggle, not automation.profile(PANEL.profile or 'host')[opt_toggle], PANEL.profile or 'host')
            PANEL.hint = ok and '设置已保存' or why
        elseif scope then
            local ok, why = automation.set('scope', scope, PANEL.profile or 'host')
            PANEL.hint = ok and '设置已保存' or why
        elseif hovered:match('^profile:') then
            PANEL.profile = hovered:match('^profile:(.+)$')
            PANEL.task_page = 1
            PANEL.hint = '正在编辑' .. (PANEL.profile == 'host' and '主机' or '客机') .. '预设；根据身份自动启用'
        elseif hovered:match('^output:') then
            local ok, why = automation.set('output', hovered:match('^output:(.+)$'), PANEL.profile or 'host')
            PANEL.hint = ok and '输出方式已保存' or why
        elseif hovered:match('^plugin:') then
            local id, key = hovered:match('^plugin:([^:]+):(.+)$')
            if id == PANEL.active_plugin then
                local ok, why = REGISTRY.click(id, key)
                if not ok then PANEL.hint = why end
            end
        elseif hovered == 'tabs:prev' or hovered == 'tabs:next' then
            PANEL.tab_page = math.max(1, (PANEL.tab_page or 1) + (hovered == 'tabs:next' and 1 or -1))
        elseif hovered == 'view:tasks'  or hovered == 'view:automation' or hovered == 'view:pings' then
            PANEL.settings_view = hovered:match('^view:(.+)$')
            PANEL.preset_view = nil
            PANEL.hint = nil
        elseif field then
            PANEL.editing, PANEL.edit_field, PANEL.edit_text = true, field, draft[field]
            PANEL.hint = 'Enter 确认 / Esc 取消 / Ctrl+V 粘贴'
        elseif mode then
            finish_edit(true)
            draft.mode = mode
            draft.time = mode == 'daily' and '21:30' or '30'
            PANEL.hint = nil
        elseif hovered == 'task:add' then
            finish_edit(true)
            local t, why = M.add_task(draft.name, draft.mode, draft.time, draft.message, nil, PANEL.profile or 'host')
            PANEL.hint = t and '任务已添加' or why
            if t then
                PANEL.task_page = math.ceil(#M.profile_tasks(PANEL.profile or 'host') / 7)
                draft.name, draft.message = '', ''
            end
        elseif toggle_id then
            finish_edit(true)
            PANEL.hint = M.toggle_task(tonumber(toggle_id)) and '任务状态已保存' or '保存失败'
        elseif delete_id then
            finish_edit(true)
            PANEL.hint = M.remove_task(tonumber(delete_id)) and '任务已删除' or '保存失败'
        elseif hovered == 'page:prev' or hovered == 'page:next' then
            finish_edit(true)
            PANEL.task_page = math.max(1, math.min(math.max(1, math.ceil(#M.profile_tasks(PANEL.profile or 'host') / 7)),
                PANEL.task_page + (hovered == 'page:next' and 1 or -1)))
        elseif hovered == 'close' then
            set_panel_open(false)
        elseif keys and keys[hovered] ~= nil or (keys and hovered == 'tab:default') then
            finish_edit(true)
            -- Resolved through the map the tab strip built while drawing, so a click can
            -- only select a tab that was actually drawn.
            PANEL.active_plugin = keys[hovered] or nil
            PANEL.rule_view,PANEL.preset_view=nil,nil
            PANEL.version = (PANEL.version or 0) + 1
            note('panel: tab -> ' .. tostring(PANEL.active_plugin or 'default'))
        elseif hovered == 'timer' then
            cfg.timer_on = not cfg.timer_on
            cfg.elapsed = 0
            config_save()
            note('panel: timed send ' .. (cfg.timer_on and 'ON' or 'OFF'))
        elseif hovered == 'minus' then
            cfg.interval = math.max(5, cfg.interval - 5)
            config_save()
        elseif hovered == 'plus' then
            cfg.interval = math.min(3600, cfg.interval + 5)
            config_save()
        elseif hovered == 'message' then
            PANEL.editing = not PANEL.editing
            PANEL.hint = PANEL.editing
                        and 'TYPE THE MESSAGE   ENTER SAVES   ESC CANCELS'
                        or nil
            PANEL.edit_backup = cfg.message
            note('panel: message editing ' .. (PANEL.editing and 'ON' or 'OFF'))
        end
        PANEL.version = (PANEL.version or 0) + 1
        write_status()
    end
    if not PANEL.open then return end

    -- Message editing. While the field has focus the editor owns the keyboard, so the
    -- K hotkey cannot fire mid-word.
    if PANEL.editing then
        local now = (M.frames or 0) / 120
        local value, what = edit_text(now)
        if PANEL.edit_field then
            if what == 'commit' then
                PANEL.edit_text = value
                local option = PANEL.edit_field:match('^option:') or PANEL.edit_field:match('^rule:')
                local search=PANEL.edit_field=='rules:search'
                local preset_text=PANEL.edit_field=='preset:name' or PANEL.edit_field=='preset:path'
                if finish_edit(true) then
                    PANEL.hint = option and '设置已保存' or search and '搜索已应用'
                        or preset_text and '输入已确认；点击对应按钮执行操作'
                        or '输入已确认，点击“添加定时任务”保存'
                end
            elseif what == 'cancel' then
                finish_edit(false)
                PANEL.hint = '已取消本次输入'
            end
        elseif what == 'commit' then
            cfg.message = value or cfg.message
            config_save()
            PANEL.editing = nil
            PANEL.hint = 'MESSAGE SAVED'
            note('panel: message set to: ' .. tostring(cfg.message))
        elseif what == 'cancel' then
            cfg.message = PANEL.edit_backup or cfg.message
            PANEL.editing = nil
            PANEL.hint = 'EDIT CANCELLED'
            note('panel: message edit cancelled')
        else
            cfg.message = value or cfg.message
            PANEL.hint = 'ENTER SAVES   ESC CANCELS'
        end
    end

    -- One path for both creating and updating, exactly like Armory: a retained screen
    -- GUI renders the primitives it was given until it is REBUILT, so the rebuild is
    -- the redraw. Creating in the ladder and then immediately rebuilding (the first
    -- version of this) destroyed a gui that had just been made, which is pure waste
    -- and doubles the number of engine objects per open.
    local signature = panel_signature()
    if signature ~= PANEL.sig then
        if PANEL.gui then
            pcall(sr.World.destroy_gui, PANEL.world, PANEL.gui)
            FONT.resolved, FONT.gui = false, nil
            PANEL.gui, PANEL.draw_guis = nil, nil
        end
        init_stage('create_screen_gui begin')
        local okg, gui = pcall(sr.World.create_screen_gui, PANEL.world, 'scale', 1, 1)
        if not okg or gui == nil then
            PANEL.lfail = PANEL.lfail + 1
            note('panel: the world refused a gui (' .. PANEL.lfail .. '/3): '
                 .. tostring(gui))
            return
        end
        PANEL.lfail = 0
        PANEL.gui = gui
        init_stage('create_screen_gui complete')
        PANEL.draw_guis = {{gui = gui}}
        -- The signature is recorded only AFTER the draw succeeds. Assigning it first
        -- meant a throwing draw left the panel marked "already drawn": the signature
        -- matched from then on, nothing was ever drawn again, and the only symptom was
        -- an empty panel. A failed draw must leave the panel dirty so the next frame
        -- retries rather than rendering nothing forever.
        PANEL.sig = nil
        local draw_ok, draw_err = pcall(draw_panel)
        if not draw_ok then
            -- Named, not swallowed. A throwing draw leaves the panel blank, and
            -- "blank panel" is indistinguishable from "font missing" or "wrong
            -- origin" without the message.
            M.draw_errors = (M.draw_errors or 0) + 1
            M.draw_error_text = tostring(draw_err)
            if M.draw_errors <= 3 then
                note('draw_panel error: ' .. tostring(draw_err))
            end
            return
        end
        PANEL.sig = signature
        init_stage('first draw complete / ' .. tostring(FONT.kind))
    end
end

-- ---------------------------------------------------------------- 12. driver
local HEARTBEAT_FRAMES = 1800
local next_heartbeat = HEARTBEAT_FRAMES
local OBSERVE_FRAMES = 30
local next_observe = 0
local observe_out = {}
local last_shape = ''
local last_verdict = nil
local observed_once = false

local function observe(out)
    for i = #out, 1, -1 do out[i] = nil end
    local ctx = u64(game_base + M.CONTEXT_PTR)
    if ctx == nil then
        out[1] = 'network context: UNREADABLE'
        return out, 'context_unreadable'
    end
    if ctx == 0 then
        out[1] = 'network context: none (not in a session)'
        return out, 'no_session'
    end
    out[1] = 'network context: ' .. hex(ctx)
    local others = other_peers(ctx)
    M.last_peers = others
    -- The raw field and the enumerated count are BOTH reported because they
    -- disagree: PEER_COUNT reads 0 in host and client roles while a real peer is
    -- present, so it is not "how many people are in the session". The send guard
    -- uses `other players`, never the raw field.
    out[2] = string.format('peer count: %s (enumerated other players: %d)',
        tostring(u32(ctx + M.PEER_COUNT)), others)
    local chat = ctx + M.CHAT_OBJECT
    local ok, why = readable(chat, 1)
    if not ok then
        out[3] = 'chat object: unreadable (' .. why .. ')'
        return out, 'chat_unreadable'
    end
    local raw = read_at(chat, 1)
    out[3] = string.format('chat flag byte: %s', raw and raw:byte(1) or 'unreadable')
    out[4] = string.format('chat history: first=%s count=%s',
        tostring(u32(chat + M.HISTORY_FIRST)), tostring(u32(chat + M.HISTORY_COUNT)))
    return out, 'observed'
end
local function shape_of(values)
    if #values == 0 then return '' end
    local parts = {}
    for i = 1, #values do parts[i] = values[i]:gsub('%d+', '#') end
    return table.concat(parts, '|')
end

-- ---------------------------------------------------------------- 13. trigger
local last_trigger = nil
local next_trigger_poll = 0
local TRIGGER_POLL_FRAMES = 30
local function trigger_read()
    local handle = io.open(TRIGGER, 'r')
    if not handle then return nil end
    local text = handle:read('*a')
    handle:close()
    if type(text) ~= 'string' then return nil end
    for line in text:gmatch('[^\r\n]+') do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if #line > 0 then return line end
    end
    return nil
end
local function trigger_clear()
    local handle = io.open(TRIGGER, 'w')
    if handle then handle:write('') handle:close() end
end
-- `timed on|off|interval N|message TEXT` drives the panel's settings without a
-- mouse, which is also how the offline harness exercises them.
local function handle_config_command(body)
    local action, rest = body:match('^timed%s+(%a+)%s*(.*)$')
    if not action then return false end
    action = action:lower()
    if action == 'on' then cfg.timer_on, cfg.elapsed = true, 0
    elseif action == 'off' then cfg.timer_on, cfg.elapsed = false, 0
    elseif action == 'interval' then
        cfg.interval = math.max(5, math.min(3600, tonumber(rest) or cfg.interval))
    elseif action == 'message' and #rest > 0 then
        cfg.message = rest
    else
        note('timed: unknown action ' .. action)
        return true
    end
    config_save()
    note(string.format('timed: timer_on=%s interval=%d message=%s',
        tostring(cfg.timer_on), cfg.interval, cfg.message))
    return true
end
local function poll_trigger()
    if M.frames < next_trigger_poll then return end
    next_trigger_poll = M.frames + TRIGGER_POLL_FRAMES
    local request = trigger_read()
    if request == nil then return end
    if request == last_trigger then return end
    last_trigger = request
    trigger_clear()
    if request == 'panel' then
        if not PANEL.open then
            PANEL.open = true
            M.panel_open = true
            take_cursor()
        end
        note('trigger: panel opened')
        write_status()
        return
    end
    if request == 'config' then
        note(string.format('config: timer_on=%s interval=%d message=%s',
            tostring(cfg.timer_on), cfg.interval, cfg.message))
        return
    end
    if handle_config_command(request) then return end
    local force = false
    local body = request
    if request:sub(1, 5) == 'send!' then force, body = true, request:sub(6) end
    if #body == 0 then note('trigger: nothing to send') return end
    note(string.format('trigger: sending %d bytes: %s%s', #body, body,
        force and '   [FORCED - reaches nobody in a solo session]' or ''))
    local ok, why = M.send_text(body, true, force)
    if ok then
        note(string.format('trigger: send returned success (%s other player(s))', tostring(why)))
    else
        note('trigger: send refused - ' .. tostring(why))
    end
end

-- ---------------------------------------------------------------- 14. timed send
-- Uses the NORMAL send path with every guard intact: no session, chat off, or
-- nobody else present => refused, and the reason is named in the log.
local function timed_send(dt)
    if not cfg.timer_on then cfg.elapsed = 0 return end
    cfg.elapsed = cfg.elapsed + dt
    if cfg.elapsed < cfg.interval then return end
    cfg.elapsed = 0
    local chat, others = send_context(false)
    local allowed, why = automation.check(os.time(), others)
    local ok = false
    if chat and allowed then
        ok, why = automation.send(automation.format(cfg.message), automation.state.active_role)
        if ok then automation.record(os.time()) end
    elseif not chat then why = others end
    -- Recorded on the MOD, not only in the log. A refusal whose only trace is a file the
    -- player never opens is indistinguishable from "the feature does nothing" -- which
    -- is exactly how this was reported. The panel prints this line, so "it is ON but
    -- nothing is being sent" answers itself on screen instead of needing a log dig.
    M.last_send = {
        ok = ok and true or false,
        why = ok and ('SENT TO ' .. tostring(why) .. ' PLAYER(S)') or string.upper(tostring(why)),
    }
    if not ok then note('timed send refused - ' .. tostring(why)) end
end

-- Exposed for the offline tests. The cursor handover is the part of the panel most
-- likely to leave the player stuck with a visible cursor and a dead aim, and it is
-- pure bookkeeping around counters, so it can be checked without the engine.
function M.debug_take_cursor() take_cursor() end
function M.debug_release_cursor() release_cursor() end
function M.debug_cursor_state()
    return {taken = cursor.taken, shows = cursor.shows,
            clip = cursor.clip, engine = cursor.engine,
            was_shown = cursor.was_shown}
end
;function M.debug_panel() return PANEL end
function M.debug_font() return {resolved = FONT.resolved, ok = FONT.ok, why = FONT.why, kind = FONT.kind} end
function M.debug_panel_signature() return panel_signature() end
function M.debug_cfg() return cfg end
function M.debug_last_send() return M.last_send end
function M.debug_timed_send(dt) timed_send(dt) end
function M.debug_send_text(text, verbose, force) return M.send_text(text, verbose, force) end
-- Panel layout is pure arithmetic, so it can be checked without an engine: a panel
-- that would draw off-screen is a defect the tests can catch even though the rendering
-- itself cannot be exercised here. The numbers come from the same expression the
-- drawing uses, so a layout change cannot drift away from this check.
function M.debug_geometry(rw, rh)
    PANEL.rw, PANEL.rh = rw, rh
    local s, ox, oy = panel_geometry(rw, rh)
    return {
        scale = s,
        x = ox, y = oy,
        w = math.floor(0.5 + W_PANEL * s),
        h = math.floor(0.5 + H_PANEL * s),
        panel_units = {w = W_PANEL, h = H_PANEL},
        resolution = {rw = rw, rh = rh},
    }
end
function M.debug_ready() return world_ready() end
function M.debug_key(K) return key_pressed(K) end
-- Open/close go through ONE function so the tests exercise the SAME path the hotkey
-- and the CLOSE row use. A test that poked PANEL.open directly would not cover the
-- cursor handover or the teardown, which is most of what can go wrong.
--
-- Forward-declared near the PANEL table (further up); assigned once the cursor and
-- teardown functions exist.
function M.debug_set_open(open) return set_panel_open(open) end

local function tick()
    M.frames = M.frames + 1
    if not verified then return end
    pcall(poll_trigger)
    -- The panel gets its OWN pcall so a failure is NAMEABLE. Wrapped in the generic
    -- frame pcall it would be swallowed, the panel would simply not appear, and the
    -- cause would be invisible -- which is how a mock bug in the mouse path hid
    -- behind 60 green tests. Logged a few times only, so a per-frame fault cannot
    -- flood the log.
    local panel_ok, panel_err = pcall(panel_frame)
    if not panel_ok then
        panel_input.release()
        M.panel_errors = (M.panel_errors or 0) + 1
        if M.panel_errors <= 5 then
            note('panel_error ' .. tostring(panel_err))
        elseif M.panel_errors == 6 then
            note('panel_error: further panel faults suppressed for this session')
        end
    end

    if M.frames >= next_observe then
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
            note(string.format('heartbeat: frames=%d reads=%d bytes=%d errors=%d sent=%d',
                M.frames, M.reads, M.bytes, M.errors, M.sent or 0))
            write_status()
        end
        -- Real elapsed seconds, independent of FPS. The task deadlines use the same
        -- local system clock as daily schedules, so a low-FPS frame cannot slow time.
        local now = os.time()
        local elapsed = M.scheduler_time and math.max(0, now - M.scheduler_time) or 0
        M.scheduler_time = now
        automation.sync()
        timed_send(elapsed)
        if M.options.enabled and M.options.ping or REGISTRY.has_listeners() then
            if catalog_scan_phase == 0 then
                catalog_scan_phase = 1
                note('stratagem catalog scan begin')
            end
            local _, catalog_status = stratagem_catalog.scan(now)
            if catalog_scan_phase == 1 then
                catalog_scan_phase = 2
                note('stratagem catalog scan complete: ' .. tostring(catalog_status))
            end
            local _, status = ping_events.poll(now)
            if status ~= M.ping_status then note('ping reader: ' .. tostring(status)) end
            M.ping_status = status
            local _, task_status = stratagem_events.poll(now)
            M.task_stratagem_status = task_status
        else
            ping_events.reset()
            stratagem_events.reset()
            M.task_stratagem_status = '任务战备消息已关闭'
            M.ping_status = M.options.enabled and '标记消息已关闭' or '自动发送已关闭'
        end
        automation.poll(now)
        run_tasks(now)
    end
end
local function summarize()
    -- Release everything owned: the cursor, and the gui. A gui left behind would be
    -- rendered by the engine after the mod is gone.
    pcall(panel_input.release)
    pcall(force_release_cursor)
    pcall(panel_clear)
    note(string.format('shutdown: frames=%d reads=%d bytes=%d errors=%d sent=%d',
        M.frames, M.reads, M.bytes, M.errors, M.sent or 0))
    write_status()
end

-- ---------------------------------------------------------------- 15. boot
note(string.format('AutoChat v%s starting (send + panel)', M.version))
note('user32 declarations: added[' .. tostring(M.user32_added)
     .. '] reused[' .. tostring(M.user32_reused) .. ']')
config_load()
load_tasks()
-- Convert the old enabled timer once; an invisible second scheduler must not survive
-- the new settings UI. Old panel.txt remains available to legacy tool commands.
if cfg.timer_on then
    local migration_saved = #M.tasks > 0
    if #M.tasks == 0 then
        local migrated, why = M.add_task('旧版定时发送', 'repeat', tostring(cfg.interval),
                                        cut_utf8(cfg.message, 200), nil, 'host')
        migration_saved = migrated ~= nil
        if not migrated then
            note('legacy timer migration failed: ' .. tostring(why))
            PANEL.hint = '旧版任务迁移失败；已暂时停用，下次启动重试'
        end
    end
    cfg.timer_on = false
    if migration_saved then config_save() end
end
-- Rescue the pointer FIRST, before anything else can fail. If a previous session died
-- with the panel open, the cursor is still visible and this is the only place that can
-- put it back: the state that would have released it died with the old Lua state.
force_release_cursor()
note('cursor reset at boot (recovers a pointer left stuck by a previous session)')

local ok_verify, verify_reason2 = verify()
verified, verify_reason = ok_verify, verify_reason2
if verified then
    M.signature = 'match'
    note('signature check: PASS')
    note('  ' .. verify_reason)
    local send_ok, send_why = setup_send()
    if send_ok then
        M.send_ready = true
        M.status = 'ready (signature ok, send resolved, panel on K)'
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

-- ---------------------------------------------------------------- 16. chaining
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

write_status()
note('installed: ' .. tostring(M.status))

-- `return` must be the last statement in its block, so it is wrapped: the in-game
-- README comment below is part of the same chunk.
do return M end

--[===[AutoChat / 自动聊天  v0.8.1 candidate  —— SETTINGS + PLAYER TEMPLATES + ADDON API

English
-------
Sends a squad chat line WITHOUT opening the chat box, so your keyboard and mouse
are never taken away for sending. Press K in game to open the settings panel.

Why a chat can be sent without the chat box: the box seizes the keyboard and
mouse, draws itself, collects keys, and THEN calls the send function. Being stuck
in the chat box is the first two steps. This mod needs only the last one -- the
same chat object and the same sender the box itself uses -- so there is no box and
no input lock.

Before anything is sent, five machine-code signatures are checked against the
running game.dll. If any does not match, the mod goes dormant and says which one
changed: an unverified address is an arbitrary address.

Custom alert rules (0.8.0; startup scan safeguard in 0.8.1)
Settings > Ping > Stratagem rules / Enemy rules opens the dedicated editors.
Each stratagem has an enable switch, separate mark/call templates and cooldown.
Blank messages inherit defaults; blank cooldown uses the global player timer.
Explicit rule cooldown is independent per trigger player + rule; 0 bypasses
global cooldown and prioritizes new events, while master/scope/dedup still apply.
First upgrade seeds 500kg and Orbital Napalm Barrage with 0s; fully editable.
Native names/icon materials/stable IDs follow the workspace StratagemCooldown
reader. Search/filter and red/blue/green bulk enable/disable are available.
Icons draw only when the game's material is already loaded. Same-name variants
with the same call type share one GUI rule (resupply/reward and jump packs).
Actual event variant IDs remain unknown when ambiguous. Unresolved identities
that cannot select even a shared rule retain the default templates/cooldown.
Enemy groups: Small / Medium / Large / Massive, plus independent Flying.
Small defaults off. Flight wins over size. Reviewed current catalog covers 142
spottable hostile resources (12 flying), not a guarantee for future game builds.
Native new stratagem rows auto-appear on a supported layout; unknown groups use
Other. New enemy facts and changed binaries require verification/update.
The catalog editor displays validated internal English debug names to avoid bulk
native localization calls during its first scan. Event messages still try live
localization first and use the debug name if that lookup is unavailable. Game
startup remains unverified for this candidate.
中文：设置→标记消息→战备细分设置 / 敌人体型与飞行提醒。
空消息沿用默认；冷却留空使用全局，独立秒数按触发者+规则计时，0绕过全局。
500千克炸弹和轨道凝固汽油弹幕首次升级预设0秒；可编辑或恢复默认。
战备可搜索、逐项开关、分别设置召唤/落地标记模板，红蓝绿一键开关。
图标只显示游戏已加载材质；同名且呼叫方式一致的奖励等变体共用规则。
0.8.1 候选版的战备目录编辑器显示内部英文调试名；事件消息先尝试实时本地化，失败时用调试名。实际游戏启动仍待验收。
不能确定具体变体时不冒认ID；连同名规则也无法确定时使用默认提醒。
飞行优先于体型；小型默认关闭；当前142条可标记敌对资源，12条飞行。
新增战备在兼容布局下自动发现；新敌人及游戏二进制更新仍需校验。

Role presets and private output (0.7.9)
---------------------------------------
HOST PRESET / CLIENT PRESET select what you EDIT. The current session role selects
what RUNS. Welcome, ping categories, templates, cooldown, output and tasks are separate.
Old settings/tasks remain with host. Client copies old ping preferences, disables
welcome and defaults to ONLY ME. Host keeps its saved welcome choice (off on a fresh install).
AUTO MESSAGES > SQUAD CHAT / ONLY ME selects output for all automatic messages and
registered addon sends. ONLY ME calls native chat add-line without a network send;
other players do not receive it. It retains normal chat name formatting.
An unknown role waits; local signature failure never falls back to public chat.
Role changes clear old welcome/ping queues and cooldown. Deadlines continue while
another role is active. There are 32 task slots total across both presets.
Manual console send/force remain explicit squad sends. New native local display
requires an in-game check; offline tests do not establish multiplayer visibility.

The panel (hotkey K)
--------------------
  - Armory Forge's 1000x990 frame, shield, title strip, tabs and two-column layout
  - uses verified loaded game fonts; readable sizes and higher text contrast
  - long labels are truncated instead of shrinking text to 6 pixels
  - while it is open the mouse is released so you can click; on close the cursor
    and the clip rectangle are restored exactly as they were
  - game keyboard/mouse input is blocked while open (including ESC and O);
    raw registrations are restored on close, focus loss, errors and shutdown
  - drag the top strip to move; CTRL +/- scales; CTRL+0 resets position and scale
  - buttons activate on release inside the same control, as in Armory
  - SETTINGS: event name, schedule mode, custom time and message fields
  - repeat every N seconds / countdown once / daily HH:MM (local system clock)
  - click fields to type; ENTER confirms, ESC cancels, CTRL+V pastes Unicode
  - click ADD TASK to save; up to 32 tasks, with pause / enable / restart / delete

Timed send
----------
Tasks run while the game is running, using real elapsed time independent of FPS.
Repeat/countdown accept 5-86400 seconds. Daily tasks run at most once per local day.
Countdown deadlines persist across restarts; overdue tasks attempt once on launch.
Unavailable chat, role restrictions and cooldown leave tasks pending with a reason.
An enabled legacy timer is migrated to a visible task. Oldest deadlines get priority
so short repeat tasks cannot starve countdowns. The AUTO MESSAGES section has a master
switch, host-only / host+client scope, allow-solo switch, per-player cooldown, newcomer
welcome switch, custom welcome text and welcome delay. Defaults: enabled, all roles,
solo allowed, 5s cooldown, welcomes off, 2s welcome delay. Existing peers are not
welcomed when enabling the feature or entering another lobby.
PING has independent task-building, stratagem, medium/large/giant-enemy and tactical
map switches. Ordinary ammo, grenades, stims and samples are excluded. Static
resources include TCS structures, LAS-98 and Bastion; native special-marker names
are resolved through the verified main-EXE lookup dispatched to by game.dll.
Replicated actor map pins
provide world XYZ coordinates; objective pins resolve their actual map name and
current-mission importance. Unknown targets without a verified name are skipped.
New self and teammate marks are observed; first observations establish a baseline.
Resupply pods/boxes and the M-103 Supply FRV are included as stratagem equipment.
Empty ground and map pins are excluded; objective and extraction pins remain.
Call-ins/task actions share a switch; separate templates: {玩家名}召唤了{目标}, {玩家名}正在开始{目标}.
Manual equipment marks keep the mark template; {动作} resolves to 召唤, 开始 or 标记. Shared calls with ambiguous attribution say 小队.
Mission/extraction catalog: 220 current spottable resources (184 specific, 36 generic task widgets).
Includes radar, broadcast, research, SEAF, fuel/data/ICBM, faction sites and mission carry items.
Generic location/terminal names use verified unit names; empty terrain remains excluded.
Specific native names take priority; map objective names/importance remain dynamic.
The exact old stock category-only template is upgraded to include {目标}.
Custom templates remain unchanged. A generic native location label does not
identify a specific building; objective map pins provide the actual task name.
Templates: {类别}, {目标}, {触发者}, {位置}; objective pins add {任务名} and
{任务类型} (primary, prerequisite, optional, tactical). Optional player short-label/colour
prefixes identify the triggerer; the actual network sender remains the local player.
The automatic-message minimum interval is tracked separately for each trigger
player. Their welcomes and pings share their timer; another player is independent.
Tasks and addon sends without a trigger use the local-player timer. Default 5s,
0 disables the limit. Multiple newcomers each retain their own pending welcome.
Player placeholders work in welcome/ping/task/addon messages: {玩家名} (name),
{缩写} (HUD label, e.g. A2), {编号} (actual squad slot, e.g. 2). {名字} and
{触发者} alias the name. Missing profile: 队友 / 队友 / ?. Unknown tokens remain literal.
HD2AutoChatAPI v2 registers named tabs beside SETTINGS, buttons, click/event callbacks
and policy-governed sends. The separately packaged Interface Demo registers a passive
example tab with an event counter switch and a test-send button. Settings persist in:

  %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\tasks.txt
  %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\settings.txt
  %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\panel-position.txt

Files / 文件位置
  log      %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\AutoChat.log
  status   %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\AutoChat-STATUS.txt
  settings %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\tasks.txt

简体中文
-------
**不打开聊天栏**即可把一条聊天发给小队，键鼠不会被夺走。游戏内按 **K** 呼出面板。

为什么能不发聊天栏就发聊天：聊天框做四件事——夺取键鼠、画框、收集按键、调发送。
"被卡在聊天栏"是前两件。本模组只要最后一件：聊天框自己用的那个聊天对象和那个发送
函数。所以没有框，也没有输入锁。

面板（快捷键 K）
  - 沿用 Armory Forge 的 1000×990 框架、盾形标识、双栏、标签与控件
  - 字体先校验游戏资源已加载；提高字号与对比度，长文字省略，不再缩成6像素
  - 打开时解除鼠标锁定以便点击；关闭时把光标与裁剪矩形**原样**归还
  - 打开面板时屏蔽游戏键鼠，包括 Esc、O；关闭、失焦、异常和退出时归还输入
  - 拖动顶部条移动窗口；Ctrl +/- 缩放，Ctrl+0 复位；按钮松开时激活
  - 设置 → 添加定时任务：事件名称、定时类型、时间、发送消息均可自定义
  - 支持重复间隔、一次倒计时（5–86400 秒）和每天时刻（HH:MM，本机时间）
  - 中文可 Ctrl+V 粘贴；Enter 确认，Esc 取消，再点“添加定时任务”保存
  - 最多 32 个独立任务，可暂停、启用、删除、重启

任务按真实时间计时，仅在游戏运行时执行。倒计时保存截止时刻；重启后到期任务尝试一次。
聊天未就绪、角色条件不满足或冷却中时，任务保持等待，不会直接消耗一次倒计时。
最早到期的任务优先，避免短周期任务一直占用发送机会。
自动消息：总开关、仅主机/主机和客机、无人房间允许发送、自动消息最短间隔、新人欢迎及自定义欢迎语/延迟。
默认允许主客机及单人发送，冷却5秒，新人欢迎关闭，欢迎延迟2秒；启用时不欢迎已有队友。
标记消息：任务建筑、战备提示、中型/大型/巨型敌人、地图标记分别开关；不再提示普通弹药、针剂、手雷、样本。
静态资源包含 TCS、LAS-98激光大炮、堡垒坦克、重新补给和M-103补给车；特殊标记优先读取游戏本地化名称（需校验当前DLL）。
本人和队友的新标记均可触发；本人标记与本机定时任务共用本人的消息间隔。
目录外的特殊目标要求游戏提供特殊类型与可读名称，名称未加载会在标记有效期内重试。
地图图钉读取实际同步状态；任务图钉使用游戏地图名称，支持“获取发射代码”等主线前置目标。
{目标}/{任务名}显示名称，{任务类型}读取当局主线、前置、支线或战术属性，不按名字猜；{位置}为世界XYZ。
普通地面空点和地图空白点不发消息；地图任务与撤离区保留。
战备召唤/任务执行共用开关、分别自定义消息；默认 {玩家名}召唤了{目标} 或 {玩家名}正在开始{目标}。
{动作} 按事件显示“召唤”“开始”或“标记”；共享战备无法确认触发者时显示“小队”。任务/撤离目录220个资源：184个具体名称、36个通用任务交互物。
包含雷达、广播、科研、SEAF、燃料/数据/导弹和各阵营设施；泛地点/终端使用已核实资源名。
任务携带物归任务建筑开关；普通物资与空地不发，不按最近坐标猜任务。
游戏只返回“特殊地点”且无目标ID时使用原标签；地图任务图钉使用具体任务名。
默认标记功能关闭，开启后响应本人和队友的新标记；消息支持 {类别}/{目标}/{触发者}/{位置}。
地图任务另支持 {任务名}/{任务类型}，变量提示在“标记消息”面板显示。旧默认模板自动加入 {目标}；其他自定义模板保留。
可开启真实队友缩写和队色前缀；实际聊天发件人仍为运行本模组的玩家，不冒用其他玩家身份。
自动消息最短间隔按触发玩家分别计算：同一人的欢迎和标记共用，A不占用B/C的间隔；默认5秒，0为不限制。
同时加入的新人各有独立欢迎队列，逐条发送；定时任务与不指定触发者的扩展发送使用本机玩家间隔。
欢迎、标记、定时任务与扩展消息支持 {玩家名}/{缩写}/{编号}；{名字}/{触发者}也是名字。
例如：欢迎 {玩家名}（{缩写}，{编号}号）加入小队！ 数据缺失时显示“队友/队友/?”，不猜编号。
其他模组可通过 HD2AutoChatAPI v2 注册显示名菜单、按钮、点击与标记回调及统一策略发送。
独立接口示例包注册“接口示例”，含计数开关和发送测试按钮；加载时不自动发送。
设置保存在 `AutoChat\tasks.txt`；旧版已启用的单计时器迁移成可见任务。

按 K 呼出；退出输入后再按 K，或点右上角 X 关闭。
本版本尚未实机验收，离线布局预览不是游戏截图。
]===]
