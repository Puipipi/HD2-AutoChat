-- HD2-Addon: mods/codex/auto_chat
-- ===========================================================================
--  自动聊天 / AutoChat —— 不打开聊天栏直接发消息 + 游戏内面板 (v0.4.0)
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
local M = {version = '0.4.0', status = 'starting', frames = 0, reads = 0,
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

-- An IdString64 stored in memory holds the two halves swapped relative to the text
-- form of the same id, so this reads low-then-high. Getting that order wrong yields a
-- plausible-looking id that simply never draws.
local function resource_hex(bytes)
    if not bytes or #bytes ~= 8 or bytes == string.rep('\0', 8) then return nil end
    return string.format('%08x%08x', u32_off(bytes, 4), u32_off(bytes, 0))
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

-- Resolve once, on the first draw. Returns true when real text can be drawn.
-- The ORDER is Armory Forge's: read the ids, require all three resources to be loaded,
-- then fall back to the debug font, then give up and let the bitmap font take over.
local function font_resolve(gui)
    if FONT.resolved then return FONT.ok end
    FONT.resolved = true
    if not (sr and sr.IdString64 and sr.Gui and sr.Gui.material and sr.Material
            and type(sr.IdString64.from_hex) == 'function') then
        FONT.why = 'engine font API not present in this state'
        return false
    end

    local ids, why = read_font_ids()
    if ids then
        local font_ok = resource_loaded('font', ids.font)
        local mat_ok = resource_loaded('material', ids.material)
        local tex_ok = resource_loaded('texture', ids.atlas)
        if font_ok and mat_ok and tex_ok then
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
        local ok, id = pcall(sr.IdString64.from_hex, M.DEBUG_FONT)
        if ok and id then
            FONT.font, FONT.material = id, id
            FONT.ok, FONT.kind = true, 'debug font (' .. tostring(why) .. ')'
            FONT.why = FONT.kind
            return true
        end
    end

    FONT.why = tostring(why) .. '; debug font not loaded either'
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

-- ---------------------------------------------------------------- 11. panel
-- Staged construction: create_screen_gui must not run before the ship world
-- exists, and each stage advances only on success so a failure names the exact
-- engine call that broke instead of dying invisibly.
local PANEL = {world = nil, gui = nil, draw_guis = nil, open = false, hover = -1,
               lfail = 0, version = 0,
               rw = 0, rh = 0}

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

-- Returns the edited text, or nil to keep the current one. Pure enough to test offline:
-- it takes `now` and reads keys through key_down, which the harness controls.
local function edit_text(now)
    local text = PANEL.edit_text
    if text == nil then text = cfg.message or '' end

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
    local shift = key_down(VK.SHIFT)
    for _, k in ipairs(NAME_KEYS) do
        if #text < MAX_MESSAGE and pressed('N' .. k[1], k[1], now) then
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
local REGISTRY = rawget(_G, 'HD2AutoChatPlugins')
if type(REGISTRY) ~= 'table' then
    REGISTRY = {version = 1, plugins = {}, by_id = {}}
    rawset(_G, 'HD2AutoChatPlugins', REGISTRY)
end
M.PLUGINS = REGISTRY.plugins
M.PLUGIN_BY_ID = REGISTRY.by_id

local function plugin_note(message)
    if type(REGISTRY.log) == 'function' then pcall(REGISTRY.log, message) end
    note('[plugin] ' .. tostring(message))
end

-- Published immediately, before the boot sequence below can fail, so registering works
-- regardless of how this mod's own startup goes. The API sits on the REGISTRY rather
-- than on M because M is not reachable from a mod that loaded first, and this avoids
-- touching PANEL, which is declared further down.
function REGISTRY.register(spec)
    if type(spec) ~= 'table' then return nil, 'register needs a table' end
    local id = tostring(spec.id or '')
    if id == '' then return nil, 'a plugin needs a stable id' end
    if REGISTRY.by_id[id] then return nil, 'that id is already registered' end
    if type(spec.draw) ~= 'function' then
        return nil, 'a plugin needs a draw(u, ctx) function'
    end
    local entry = {id = id, title = tostring(spec.title or id),
                   draw = spec.draw, faults = 0}
    REGISTRY.plugins[#REGISTRY.plugins + 1] = entry
    REGISTRY.by_id[id] = entry
    plugin_note('registered "' .. entry.title .. '" (' .. id .. ')')
    REGISTRY.serial = (REGISTRY.serial or 0) + 1
    return entry
end

function REGISTRY.unregister(id)
    id = tostring(id or '')
    local entry = REGISTRY.by_id[id]
    if not entry then return false end
    for i = #REGISTRY.plugins, 1, -1 do
        if REGISTRY.plugins[i] == entry then table.remove(REGISTRY.plugins, i) end
    end
    REGISTRY.by_id[id] = nil
    plugin_note('unregistered "' .. entry.title .. '"')
    REGISTRY.serial = (REGISTRY.serial or 0) + 1
    return true
end

-- Convenience aliases on M for callers that already have it.
function M.register_plugin(spec) return REGISTRY.register(spec) end
function M.unregister_plugin(id) return REGISTRY.unregister(id) end


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
local W_PANEL, H_PANEL = 460, 300
local TABS_H = 30        -- the tab strip, like Armory's row across the top
local PAD = 14

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
    return {
        w = ctx.w, h = ctx.h, body_y = dy, scale = UX.s,
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
            UX.region('plugin:' .. ctx.id .. ':' .. tostring(key), x + dx, y + dy, w, h)
        end,
        note = plugin_note,
        version = M.version,
    }
end


local function panel_signature()
    local s, ox, oy = PANEL.ui_s, PANEL.ui_ox, PANEL.ui_oy
    return table.concat({
        PANEL.rw, PANEL.rh,
        string.format('%.3f', s or 0), ox or 0, oy or 0,
        tostring(PANEL.hover), tostring(PANEL.editing), tostring(PANEL.hint),
        cfg.timer_on and 'on' or 'off', cfg.interval,
        string.format('%.0f', cfg.elapsed), cfg.message,
        tostring(M.sent or 0), tostring(M.last_peers or '-'),
        M.version, PANEL.version,
        tostring(PANEL.active_plugin), tostring(REGISTRY.serial or 0),
        M.last_send and ((M.last_send.ok and 'ok:' or 'no:') .. tostring(M.last_send.why)) or '-',
    }, '|')
end

-- The plugin selected in the tab strip; nil means the default settings.
PANEL.active_plugin = PANEL.active_plugin

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
    local want = height / 1080 * 0.8 * (PANEL.ui_scale or 1)
    local fit = height * 0.96 / H_PANEL
    local s = math.min(want, fit, (width - 60) / W_PANEL)
    if s <= 0 then return end
    local function px(v) return math.floor(v + 0.5) end
    local ox = px(30 * s)
    local oy = px((height - H_PANEL * s) / 2)
    if oy < 0 then oy = 0 end

    local function color(r, g, b, a) return Color(a or 255, r, g, b) end
    local C = {
        BG = color(11, 12, 13, 246), PANEL = color(18, 19, 21),
        ROW = color(26, 28, 31), ROW_HI = color(34, 36, 40),
        FIELD = color(10, 11, 12), LINE = color(44, 46, 50), LINE2 = color(62, 65, 70),
        TEXT = color(233, 230, 220), MUTED = color(143, 146, 150), DIM = color(93, 97, 102),
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
    local function font_px(size) return math.max(7, px(size * s)) end

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

    -- Real text, shrunk in whole pixels to fit `limit`, with right/center alignment.
    -- Returns its width in panel units. `nil` limit means no shrinking.
    local function text(value, x, y, size, c, limit, align)
        if value == nil or value == '' then return 0 end
        value = tostring(value)
        local sz = font_px(size)
        local w = measure_px(value, sz) / s
        while limit and w > limit and sz > 6 do
            sz = math.max(6, math.min(sz - 1, math.floor(sz * limit / w)))
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
    local TAB_Y, TAB_H = 108, 40
    local HEAD = TAB_Y + TAB_H + 12
    local W, H = W_PANEL, H_PANEL

    rect(0, 0, W, H, C.BG, 950)
    border(0, 0, W, H, C.LINE, 955)
    rect(0, 0, W, 3, C.YELLOW, 952)                        -- the game's top strip

    local mx = text('AUTOCHAT', PAD, 12, 11, C.MUTED)
    text('AUTOMATIC SQUAD CHAT', PAD + mx + 12, 12, 11, C.TEXT)
    text('v' .. M.version, W - PAD, 12, 11, C.DIM, nil, 'right')

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
                caption = caption:sub(1, -2)
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
    -- always the default settings; every registered mod appends one after it.
    local tabs = {{key = 'tab:default', title = 'DEFAULT', id = nil}}
    for i = 1, #M.PLUGINS do
        tabs[#tabs + 1] = {key = 'tab:' .. M.PLUGINS[i].id,
                           title = M.PLUGINS[i].title, id = M.PLUGINS[i].id}
    end
    if PANEL.active_plugin and not M.PLUGIN_BY_ID[PANEL.active_plugin] then
        PANEL.active_plugin = nil                       -- it unregistered itself
    end
    local tab_x = PAD
    local tab_keys = {}
    for i = 1, #tabs do
        local entry = tabs[i]
        local active = (entry.id == PANEL.active_plugin)
        local reached = tab(entry.key, entry.title, tab_x, active)
        tab_keys[entry.key] = entry.id
        tab_x = tab_x + reached
        if tab_x > W - PAD - 90 then break end          -- the strip is one row
    end
    PANEL.tab_keys = tab_keys
    local body_y = TAB_Y + TAB_H + 12

    -- ---------------------------------------------------------- plugin body
    local active = PANEL.active_plugin and M.PLUGIN_BY_ID[PANEL.active_plugin] or nil
    if active then
        local ok, err = pcall(active.draw, plugin_api({
            id = active.id, w = W_PANEL, h = H_PANEL,
            ox = PAD, oy = body_y + 10,
        }), {body_y = body_y, panel_w = W_PANEL, panel_h = H_PANEL})
        if not ok then
            -- A third-party draw runs inside this panel's frame. Drop it for the
            -- session with its name in the log rather than faulting every frame.
            active.faults = (active.faults or 0) + 1
            plugin_note('"' .. active.title .. '" draw failed: ' .. tostring(err))
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

    local y = body_y + 12

    -- message field: click it, then type. This is the row that needed real text.
    text('MESSAGE', PAD, y, 10, C.DIM)
    y = y + 14
    local focus = PANEL.editing
    rect(PAD, y, W_PANEL - PAD * 2, 26, focus and C.ROW_HI or C.FIELD, 953)
    border(PAD, y, W_PANEL - PAD * 2, 26, focus and C.YELLOW or C.LINE, 954)
    local shown = cfg.message or ''
    if focus then shown = shown .. '_' end                     -- the caret
    local field_w = W_PANEL - PAD * 2 - 16
    text(cut(shown, 13, field_w), PAD + 8, y + 7, 13,
         focus and C.TEXT or C.MUTED, field_w)
    region('message', PAD, y, W_PANEL - PAD * 2, 26)
    y = y + 34

    -- timed send
    rect(PAD, y, W_PANEL - PAD * 2, 26,
         PANEL.hover == 'timer' and C.ROW_HI or C.ROW, 953)
    text('TIMED SEND', PAD + 8, y + 7, 13, C.TEXT)
    text(cfg.timer_on and 'ON' or 'OFF', W_PANEL - PAD - 8, y + 7, 13,
         cfg.timer_on and C.GOOD or C.DIM, nil, 'right')
    region('timer', PAD, y, W_PANEL - PAD * 2, 26)
    y = y + 30

    -- interval
    rect(PAD, y, W_PANEL - PAD * 2, 26,
         PANEL.hover == 'interval' and C.ROW_HI or C.ROW, 953)
    text('INTERVAL', PAD + 8, y + 7, 13, C.TEXT)
    local btn_w, btn_h = 26, 20
    local right = W_PANEL - PAD - 8
    rect(right - btn_w, y + 3, btn_w, btn_h,
         PANEL.hover == 'plus' and C.ROW_HI or C.FIELD, 954)
    text('+', right - btn_w / 2, y + 7, 13, C.YELLOW, nil, 'center')
    region('plus', right - btn_w, y + 3, btn_w, btn_h)
    rect(right - btn_w * 3 - 6, y + 3, btn_w, btn_h,
         PANEL.hover == 'minus' and C.ROW_HI or C.FIELD, 954)
    text('-', right - btn_w * 2.5 - 6, y + 7, 13, C.YELLOW, nil, 'center')
    region('minus', right - btn_w * 3 - 6, y + 3, btn_w, btn_h)
    text(tostring(cfg.interval) .. 'S', right - btn_w * 3 - 14, y + 7, 13,
         C.TEXT, nil, 'right')
    y = y + 34

    local last = M.last_send
    if last then
        text(cut(last.why, 10, W_PANEL - PAD * 2), PAD, y, 10,
             last.ok and C.GOOD or C.BAD, W_PANEL - PAD * 2)
        y = y + 14
    end
    text('NEXT IN ' .. string.format('%.0f', cfg.elapsed) .. 'S   '
         .. (cfg.timer_on and 'RUNNING' or 'STOPPED'),
         PAD, y, 10, cfg.timer_on and C.GOOD or C.DIM, W_PANEL - PAD * 2)
    y = y + 18
    text('CLICK THE MESSAGE BOX, TYPE, ENTER TO SAVE', PAD, y, 10, C.DIM,
         W_PANEL - PAD * 2)
    y = y + 18
    if PANEL.hint then text(PANEL.hint, PAD, y, 10, C.YELLOW, W_PANEL - PAD * 2) end

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

    if clicked and hovered then
        local keys = PANEL.tab_keys
        if keys and keys[hovered] ~= nil or (keys and hovered == 'tab:default') then
            -- Resolved through the map the tab strip built while drawing, so a click can
            -- only select a tab that was actually drawn.
            PANEL.active_plugin = keys[hovered] or nil
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
        if what == 'commit' then
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
        PANEL.version = (PANEL.version or 0) + 1
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
function M.debug_timed_send(dt) timed_send(dt) end
function M.debug_send_text(text, verbose, force) return M.send_text(text, verbose, force) end
-- Panel layout is pure arithmetic, so it can be checked without an engine: a panel
-- that would draw off-screen is a defect the tests can catch even though the rendering
-- itself cannot be exercised here. The numbers come from the same expression the
-- drawing uses, so a layout change cannot drift away from this check.
function M.debug_geometry(rw, rh)
    PANEL.rw, PANEL.rh = rw, rh
    local want = rh / 1080 * 0.8 * (PANEL.ui_scale or 1)
    local fit = rh * 0.96 / H_PANEL
    local s = math.min(want, fit, (rw - 60) / W_PANEL)
    local ox = math.floor(0.5 + 30 * s)
    local oy = math.floor(0.5 + (rh - H_PANEL * s) / 2)
    if oy < 0 then oy = 0 end
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
        timed_send(OBSERVE_FRAMES / 120)
    end
end
local function summarize()
    -- Release everything owned: the cursor, and the gui. A gui left behind would be
    -- rendered by the engine after the mod is gone.
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

--[===[AutoChat / 自动聊天  v0.4.0  —— SEND + IN-GAME PANEL

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
  - a MESSAGE box you can click and type into (ENTER saves, ESC cancels),
    a TIMED SEND toggle and INTERVAL -/+ buttons

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
