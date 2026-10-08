-- HD2-Addon: mods/codex/auto_chat
-- ===========================================================================
--  自动聊天 / AutoChat —— 不打开聊天栏直接发消息 + 游戏内面板 (v0.3.0)
--
--  为什么能绕开聊天栏：
--    聊天框做四件事——夺取键鼠、画框、收集按键、调用发送。把玩家卡住的是前两件。
--    我们只要最后一件：ctx+0xC418 的聊天对象 + game.dll+0x1097560 的发送函数。
--    这是聊天框自己也调的同一套东西（game.dll+0x186025d 就是它的调用点）。
--
--  本版本三部分：
--    1. 发送：5 段机器码签名校验通过后解析函数指针，把文本交给游戏。
--    2. 面板：按 K 呼出；打开时解除鼠标锁定，关闭时精确归还。面板用 Gui.rect
--       逐像素画（含 4x5 点阵字体），不碰引擎字体/材质。
--    3. 定时发送：每隔 N 秒把预设文本发一条；空会话按设计拒绝。
--
--  红线：
--    * ffi.cdef 里**不声明 user32**——改为只复用别的模组（如 Super Earth Armory
--      Forge）已注册的声明。LuaJIT 的 ffi.cdef 保留第一次声明，本模组先加载，
--      若自行声明就顶掉别人；原型逐字照抄 Armory Forge，保证谁先声明都一致。
--    * 面板绘制走 Gui.rect（唯一被证明安全的原语）；不用 Gui.text / 材质。
--    * create_screen_gui 只在飞船 world 解析后、且分帧阶梯式建立。
--    * update/shutdown 一定调回上一个，绝不断链。
--    * 观测每 30 帧一次并复用输出表（帧预算看门狗按 ms/秒计费）。
-- ===========================================================================
local M = {version = '0.3.0', status = 'starting', frames = 0, reads = 0,
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

-- ---------------------------------------------------------------- 6. logging
local HOME = (os.getenv('LOCALAPPDATA') or os.getenv('TEMP') or '.')
             .. '/CowboyBingus/Helldivers2/'
local LOG = HOME .. 'Logs/AutoChat.log'
local STATUS = HOME .. 'AutoChat/AutoChat-STATUS.txt'
local TRIGGER = HOME .. 'AutoChat/trigger.txt'
local CONFIG = HOME .. 'AutoChat/panel.txt'
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
        'user32 decls: added[' .. tostring(M.user32_added or '')
                       .. '] reused[' .. tostring(M.user32_reused or '') .. ']',
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
-- How many peers are NOT us. Only the low 32 bits are compared: a 64-bit id is not
-- exactly representable as a double and comparing rounded doubles could match the
-- wrong entry.
local function other_peers(ctx)
    local own = u32(ctx + M.LOCAL)
    local count = u32(ctx + M.PEER_COUNT)
    if count == nil then return 0 end
    if count > M.MAX_PEERS then count = M.MAX_PEERS end
    local n = 0
    for i = 0, count - 1 do
        local lo = u32(ctx + M.PEERS + i * M.PEER_STRIDE)
        if lo ~= nil and lo ~= own then n = n + 1 end
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

-- Returns true plus how many other players are in the session, or false and why.
-- `force` exists only to prove the call reaches the game when solo; the default
-- keeps the peer guard, and a forced send reaches nobody.
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
    local others = other_peers(ctx)
    if others == 0 and not force then return false, 'nobody else in the session' end
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

-- ---------------------------------------------------------------- 10. config
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

-- ---------------------------------------------------------------- 11. panel
-- Staged construction: create_screen_gui must not run before the ship world
-- exists, and each stage advances only on success so a failure names the exact
-- engine call that broke instead of dying invisibly.
local PANEL = {world = nil, gui = nil, draw_guis = nil, open = false, hover = -1,
               lfail = 0, version = 0,
               rows = {}, rw = 0, rh = 0}
for i = 0, 3 do PANEL.rows[#PANEL.rows + 1] = {id = i} end

local cursor = {taken = false, shows = 0, clip = nil, engine = false, was_shown = nil}
-- Forward declaration for the single open/close path used by the hotkey, the CLOSE
-- row and the tests. It must be declared BEFORE any closure that captures it: a
-- `local` introduced after its reader leaves the reader holding nil, and the call
-- raises on the first hotkey press.
local set_panel_open
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
local function colour(a, r, g, b)
    if not Color then return nil end
    return Color(a, r, g, b)
end
local function geometry(rw, rh)
    local scale = math.min(rw / 1920, rh / 1080)
    local row_h = 26 * scale
    local head_h = 34 * scale
    local w = 460 * scale
    local h = head_h + (#PANEL.rows) * row_h + 26 * scale
    local x = 40 * scale
    local y = rh - h - 40 * scale
    return scale, x, y, w, h, row_h, head_h
end
local function draw_targets()
    return PANEL.draw_guis or (PANEL.gui and {{gui = PANEL.gui}}) or {}
end
local function rect(x, y, w, h, c, layer)
    local targets = draw_targets()
    for i = 1, #targets do
        local entry = targets[i]
        pcall(Gui.rect, entry.gui or entry, Vector3(x, y, layer or 980),
              Vector2(w, h), c)
    end
end
local function draw_panel_unused_v1()
    local scale, x, y, w, h, row_h, head_h = geometry(PANEL.rw, PANEL.rh)
    local white = colour(255, 242, 244, 247)
    local dim = colour(255, 150, 160, 170)
    local gold = colour(255, 255, 215, 60)
    local green = colour(255, 126, 211, 115)
    rect(x, y, w, h, colour(220, 18, 26, 34))
    rect(x, y + h - 3 * scale, w, 3 * scale, gold)

    local cell = math.max(1, math.floor(2 * scale + 0.5))
    local function text(px, py, s, c)
        local cx = px
        s = tostring(s):upper()
        for i = 1, #s do
            local g = GLYPHS[s:sub(i, i)]
            if g then
                for r = 1, 5 do
                    local row = g[r]
                    for col = 1, 4 do
                        if row:sub(col, col) == '1' then
                            rect(cx + (col - 1) * cell, py + (5 - r) * cell,
                                 cell, cell, c or white)
                        end
                    end
                end
            end
            cx = cx + 5 * cell
        end
        return cx
    end

    local pad = 10 * scale
    text(x + pad, y + h - head_h + 10 * scale, 'AUTOCHAT v' .. M.version, gold)
    text(x + pad, y + h - head_h - 8 * scale,
         'K=CLOSE  SENT ' .. tostring(M.sent or 0)
         .. '  PEERS ' .. tostring(M.last_peers or '?'), dim)

    for i = 1, #PANEL.rows do
        local row = PANEL.rows[i]
        local ry = y + h - head_h - 14 * scale - i * row_h
        rect(x + pad, ry, w - 2 * pad, row_h - 3 * scale,
             (PANEL.hover == row.id) and colour(220, 40, 56, 70)
                                      or colour(200, 26, 36, 46))
        local label
        if row.id == 0 then
            label = 'TIMED SEND: ' .. (cfg.timer_on and 'ON' or 'OFF')
        elseif row.id == 1 then
            label = 'INTERVAL ' .. tostring(cfg.interval) .. 'S   -'
        elseif row.id == 2 then
            label = 'INTERVAL ' .. tostring(cfg.interval) .. 'S   +'
        else
            label = 'CLOSE PANEL'
        end
        text(x + pad * 2, ry + (row_h - 3 * scale) / 2 - 3 * scale, label,
             (row.id == 0 and cfg.timer_on) and green or white)
    end

    text(x + pad, y + 8 * scale,
         'MSG ' .. cfg.message .. '  ' .. string.format('%.0f', cfg.elapsed)
         .. '/' .. tostring(cfg.interval) .. 'S', dim)
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
    -- client pixels (top-left) -> Gui units (bottom-left)
    return cx * PANEL.rw / cw, (ch - cy) * PANEL.rh / ch
end
local function world_ready()
    refresh_engine()
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
-- block the HUD underneath. Every teardown path resets the build ladder too, so the
-- panel can be opened again in the same session rather than working exactly once.
local function panel_clear()
    if sr and PANEL.gui and PANEL.world then
        pcall(sr.World.destroy_gui, PANEL.world, PANEL.gui)
    end
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
local function panel_signature()
    local scale, x, y, w, h = geometry(PANEL.rw, PANEL.rh)
    return table.concat({
        PANEL.rw, PANEL.rh,
        math.floor(scale * 1000 + 0.5), math.floor(x + 0.5), math.floor(y + 0.5),
        math.floor(w + 0.5), math.floor(h + 0.5),
        tostring(PANEL.hover),
        cfg.timer_on and 'on' or 'off', cfg.interval,
        string.format('%.0f', cfg.elapsed), cfg.message,
        tostring(M.sent or 0), tostring(M.last_peers or '-'),
        M.version, PANEL.version,
    }, '|')
end

-- Draw everything in one pass, exactly as Armory's draw() does. Nothing here may
-- allocate per frame: this runs only when the signature changes.
local function draw_panel()
    local scale, x, y, w, h, row_h, head_h = geometry(PANEL.rw, PANEL.rh)
    local white = colour(255, 242, 244, 247)
    local dim = colour(255, 150, 160, 170)
    local gold = colour(255, 255, 215, 60)
    local green = colour(255, 126, 211, 115)
    rect(x, y, w, h, colour(220, 18, 26, 34))
    rect(x, y + h - 3 * scale, w, 3 * scale, gold)

    local cell = math.max(1, math.floor(2 * scale + 0.5))
    local function text(px, py, s, c)
        local cx = px
        s = tostring(s):upper()
        for i = 1, #s do
            local g = GLYPHS[s:sub(i, i)]
            if g then
                for r = 1, 5 do
                    local row = g[r]
                    for col = 1, 4 do
                        if row:sub(col, col) == '1' then
                            rect(cx + (col - 1) * cell, py + (5 - r) * cell,
                                 cell, cell, c or white)
                        end
                    end
                end
            end
            cx = cx + 5 * cell
        end
        return cx
    end

    local pad = 10 * scale
    text(x + pad, y + h - head_h + 10 * scale, 'AUTOCHAT v' .. M.version, gold)
    text(x + pad, y + h - head_h - 8 * scale,
         'K=CLOSE  SENT ' .. tostring(M.sent or 0)
         .. '  PEERS ' .. tostring(M.last_peers or '?'), dim)

    for i = 1, #PANEL.rows do
        local row = PANEL.rows[i]
        local ry = y + h - head_h - 14 * scale - i * row_h
        rect(x + pad, ry, w - 2 * pad, row_h - 3 * scale,
             (PANEL.hover == row.id) and colour(220, 40, 56, 70)
                                      or colour(200, 26, 36, 46))
        local label
        if row.id == 0 then
            label = 'TIMED SEND: ' .. (cfg.timer_on and 'ON' or 'OFF')
        elseif row.id == 1 then
            label = 'INTERVAL ' .. tostring(cfg.interval) .. 'S   -'
        elseif row.id == 2 then
            label = 'INTERVAL ' .. tostring(cfg.interval) .. 'S   +'
        else
            label = 'CLOSE PANEL'
        end
        text(x + pad * 2, ry + (row_h - 3 * scale) / 2 - 3 * scale, label,
             (row.id == 0 and cfg.timer_on) and green or white)
    end

    text(x + pad, y + 8 * scale,
         'MSG ' .. cfg.message .. '  ' .. string.format('%.0f', cfg.elapsed)
         .. '/' .. tostring(cfg.interval) .. 'S', dim)
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
        take_cursor()
    else
        release_cursor()
        panel_clear()
    end
    return PANEL.open
end

local function panel_frame()
    -- Not before the world exists: creating a screen GUI too early faults at native
    -- level, and pcall does not catch native faults.
    if M.frames < 600 then return end
    if not world_ready() then return end

    -- hotkey K (0x4B)
    if key_pressed(0x4B) then
        set_panel_open(not PANEL.open)
        note('panel ' .. (PANEL.open and 'opened' or 'closed'))
        write_status()
    end

    if not PANEL.open then
        release_cursor()
        return
    end
    if PANEL.lfail >= 3 then
        -- Three refusals from the engine. Stop calling into it every frame; the panel
        -- stays off for the rest of the session. lfail resets on any success, so an
        -- isolated refusal does not count toward the three.
        return
    end

    keep_cursor()
    local gx, gy = mouse_state()
    local down = key_down(0x01)
    local clicked = down and not mouse_was_down
    mouse_was_down = down

    local scale, x, y, w, h, row_h, head_h = geometry(PANEL.rw, PANEL.rh)
    local pad = 10 * scale
    local hover = -1
    if gx then
        for i = 1, #PANEL.rows do
            local row = PANEL.rows[i]
            local ry = y + h - head_h - 14 * scale - i * row_h
            if gx >= x + pad and gx <= x + w - pad
               and gy >= ry and gy <= ry + row_h - 3 * scale then
                hover = row.id
                if clicked then
                    if row.id == 0 then
                        cfg.timer_on = not cfg.timer_on
                        cfg.elapsed = 0
                        config_save()
                        note('panel: timed send ' .. (cfg.timer_on and 'ON' or 'OFF'))
                    elseif row.id == 1 then
                        cfg.interval = math.max(5, cfg.interval - 5)
                        config_save()
                    elseif row.id == 2 then
                        cfg.interval = math.min(3600, cfg.interval + 5)
                        config_save()
                    elseif row.id == 3 then
                        set_panel_open(false)
                        note('panel closed from its own button')
                    end
                    PANEL.version = (PANEL.version or 0) + 1
                    write_status()
                    if not PANEL.open then return end
                end
            end
        end
    end
    PANEL.hover = hover
    if not PANEL.open then return end

    -- One path for both creating and updating, exactly like Armory: a retained screen
    -- GUI renders the primitives it was given until it is REBUILT, so the rebuild is
    -- the redraw. Creating in the ladder and then immediately rebuilding (the first
    -- version of this) destroyed a gui that had just been made, which is pure waste
    -- and doubles the number of engine objects per open.
    local signature = panel_signature()
    if signature ~= PANEL.sig then
        if PANEL.gui then
            pcall(sr.World.destroy_gui, PANEL.world, PANEL.gui)
            PANEL.gui, PANEL.draw_guis = nil, nil
        end
        local okg, gui = pcall(sr.World.create_screen_gui, PANEL.world, 'scale', 1, 1)
        if not okg or gui == nil then
            PANEL.lfail = PANEL.lfail + 1
            note('panel: the world refused a gui (' .. PANEL.lfail .. '/3): '
                 .. tostring(gui))
            return
        end
        PANEL.lfail = 0
        PANEL.gui = gui
        PANEL.draw_guis = {{gui = gui}}
        PANEL.sig = signature
        draw_panel()
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
    local ok, why = M.send_text(cfg.message, true)
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
function M.debug_panel() return PANEL end
function M.debug_panel_signature() return panel_signature() end
function M.debug_cfg() return cfg end
function M.debug_timed_send(dt) timed_send(dt) end
function M.debug_send_text(text, verbose, force) return M.send_text(text, verbose, force) end
-- Panel layout is pure arithmetic, so it can be checked without an engine. A panel
-- that draws off-screen or with overlapping rows is a defect the tests can catch
-- even though the rendering itself cannot be exercised here.
function M.debug_geometry(rw, rh)
    PANEL.rw, PANEL.rh = rw, rh
    local scale, x, y, w, h, row_h, head_h = geometry(rw, rh)
    local rows = {}
    for i = 1, #PANEL.rows do
        rows[i] = {
            y = y + h - head_h - 14 * scale - i * row_h,
            h = row_h - 3 * scale,
        }
    end
    return {scale = scale, x = x, y = y, w = w, h = h,
            row_h = row_h, head_h = head_h, rows = rows,
            resolution = {rw = rw, rh = rh}}
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
    pcall(panel_frame)

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
        timed_send(OBSERVE_FRAMES / 120)
    end
end
local function summarize()
    -- Release everything owned: the cursor, and the gui. A gui left behind would be
    -- rendered by the engine after the mod is gone.
    pcall(release_cursor)
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

--[===[AutoChat / 自动聊天  v0.3.0  —— SEND + IN-GAME PANEL

English
-------
Sends a squad chat line WITHOUT opening the chat box, so your keyboard and mouse
are never taken away. Press K in game to open a small control panel.

Why a chat can be sent without the chat box: the box seizes the keyboard and
mouse, draws itself, collects keys, and THEN calls the send function. Being stuck
in the chat box is the first two steps. This mod needs only the last one -- the
same chat object and the same sender the box itself uses -- so there is no box and
no input lock.

Before anything is sent, five machine-code signatures are checked against the
running game.dll. If any does not match, the mod goes dormant and says which one
changed: an unverified address is an arbitrary address.

The panel (hotkey K)
--------------------
  - draws every pixel, text included, with Gui.rect: no engine font, no material
  - while it is open the mouse is released so you can click; on close the cursor
    and the clip rectangle are restored exactly as they were
  - rows: TIMED SEND on/off, INTERVAL -/+, CLOSE PANEL

Timed send
----------
With TIMED SEND on, the configured message is sent every INTERVAL seconds. It uses
the normal send path with every guard intact: with no session, with the game's text
chat off, or with nobody else in the squad it is refused and the reason goes to the
log. Settings persist in:

  %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\panel.txt

Files / 文件位置
  log      %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\AutoChat.log
  status   %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\AutoChat-STATUS.txt
  settings %LOCALAPPDATA%\CowboyBingus\Helldivers2\AutoChat\panel.txt

简体中文
-------
**不打开聊天栏**即可把一条聊天发给小队，键鼠不会被夺走。游戏内按 **K** 呼出面板。

为什么能不发聊天栏就发聊天：聊天框做四件事——夺取键鼠、画框、收集按键、调发送。
"被卡在聊天栏"是前两件。本模组只要最后一件：聊天框自己用的那个聊天对象和那个发送
函数。所以没有框，也没有输入锁。

面板（快捷键 K）
  - 每个像素（含文字）都用 Gui.rect 画：不用引擎字体，不用材质
  - 打开时解除鼠标锁定以便点击；关闭时把光标与裁剪矩形**原样**归还
  - 四行：定时发送开关、间隔 -/+、关闭面板

定时发送：开启后每隔「间隔」秒发一条预设文本。走正常发送路径，所有守卫都在——
没有会话、游戏文字聊天关闭、或小队里没有别人时都会被拒绝，并把原因写进日志。
设置保存在 `AutoChat\panel.txt`。

按 K 呼出；再按 K 或点 CLOSE PANEL 关闭。
]===]
