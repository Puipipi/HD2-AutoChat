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
local M = {version = '1.0.0', build_id = 'v1.0.0-build.7', status = 'starting', frames = 0, reads = 0,
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
local apply_preset_snapshot, apply_host_preset_snapshot
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
    int QueryPerformanceFrequency(int64_t *frequency);
    void *GlobalLock(void *mem);
    int GlobalUnlock(void *mem);
    void *GlobalAlloc(uint32_t flags, size_t bytes);
    void *GlobalFree(void *mem);
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
local monotonic_now = (function()
    local ticks, frequency = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
    local ready = false
    return function()
        if not ready then
            local ok, result = pcall(function()
                return kernel.QueryPerformanceFrequency(frequency)
            end)
            ready = ok and result ~= 0 and tonumber(frequency[0]) > 0
            if not ready then return nil end
        end
        local ok, result = pcall(function() return kernel.QueryPerformanceCounter(ticks) end)
        if not ok or result == 0 then return nil end
        return tonumber(ticks[0]) / tonumber(frequency[0])
    end
end)()

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
    'int EmptyClipboard(void);',
    'void *SetClipboardData(uint32_t format, void *memory);',
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

M.runtime_diagnostic_state={seen={},lines={},order={}}
function M.record_runtime_diagnostic(kind,key,line)
    if type(kind)~='string' or not kind:match('^[%a_]+$') or type(key)~='string'
        or #key>128 or type(line)~='string' or #line>400 then return false end
    local state=M.runtime_diagnostic_state
    local signature=kind..'|'..key
    if state.seen[signature] then return false end
    state.seen[signature]=true
    state.order[#state.order+1]=signature
    if #state.order>64 then
        local expired=table.remove(state.order,1)
        state.seen[expired]=nil
    end
    state.lines[#state.lines+1]=line
    if #state.lines>64 then table.remove(state.lines,1) end
    note(line)
    return true
end
function M.record_event_diagnostic(category,action,stable_id,result,output)
    if not ({building=true,stratagem=true,map=true,supplies=true,small_enemy=true,flying_enemy=true,
        medium_enemy=true,large_enemy=true,giant_enemy=true,unknown=true})[category] then category='unknown' end
    if action~='mark' and action~='summon' and action~='use' then action='unknown' end
    if type(stable_id)~='string' or not (stable_id:match('^stratagem_%d+$') or stable_id:match('^enemy_[%a_]+$')) then stable_id='-' end
    if type(result)~='string' or not result:match('^[%a_%-]+$') then result='unknown' end
    if output~='local' and output~='squad' then output='unknown' end
    local key=category..'|'..action..'|'..stable_id..'|'..result..'|'..output
    return M.record_runtime_diagnostic('event',key,
        'ping event category='..category..' action='..action..' id='..stable_id..' result='..result..' output='..output)
end
function M.record_ping_drop(reason,kind,map_type,has_target,localization_key,resource)
    if type(reason)~='string' or not reason:match('^[%a_%-]+$') then reason='unknown' end
    kind=type(kind)=='number' and math.floor(kind) or -1
    map_type=type(map_type)=='number' and math.floor(map_type) or -1
    localization_key=type(localization_key)=='number' and math.floor(localization_key) or 0
    resource=type(resource)=='string' and #resource==16 and resource:match('^[0-9A-Fa-f]+$') and resource:upper() or '-'
    local key=table.concat({reason,kind,map_type,has_target and 1 or 0,localization_key,resource},'|')
    return M.record_runtime_diagnostic('reader',key,
        'ping reader dropped reason='..reason..' kind='..kind..' map='..map_type..' target='
        ..tostring(has_target==true)..' key='..localization_key..' resource='..resource)
end
function M.debug_runtime_diagnostics() return M.runtime_diagnostic_state.lines end

local function write_status(extra)
    local handle = io.open(STATUS, 'w')
    if not handle then return end
    local lines = {
        'AutoChat / 自动聊天  v' .. M.version .. '  (SEND + PANEL)',
        'build       : ' .. tostring(M.build_id),
        'status      : ' .. tostring(M.status),
        'signature   : ' .. tostring(M.signature),
        'send ready  : ' .. tostring(M.send_ready),
        'messages sent: ' .. tostring(M.sent or 0),
        'panel       : ' .. (M.panel_open and 'open' or 'closed') .. '  (hotkey K)',
        'game input  : ' .. tostring(M.input_state or 'panel closed'),
        'panel context: ' .. tostring(M.panel_context or 'not checked'),
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
-- BEGIN AUTOCHAT LANGUAGE
-- Pure language selection and presentation strings. No game APIs or native reads.
M.build_language = function(env)
    env=type(env)=='table' and env or {}
    local state={locale='en',option=nil,due=0}
    local M={}

    -- English fallback is deliberate for every language outside Chinese.
    local phrases={
        ['category.building']={zh='任务建筑',en='MISSION BUILDING'},
        ['category.stratagem']={zh='战备提示',en='STRATAGEM'},
        ['category.map']={zh='地图标记',en='MAP MARKER'},
        ['category.poi']={zh='特殊目标',en='SPECIAL TARGET'},
        ['category.mission_items']={zh='任务物品',en='MISSION ITEMS'},
        ['category.small_enemy']={zh='小型敌人',en='SMALL ENEMY'},
        ['category.flying_enemy']={zh='飞行敌人',en='FLYING ENEMY'},
        ['category.medium_enemy']={zh='中型敌人',en='MEDIUM ENEMY'},
        ['category.large_enemy']={zh='大型敌人',en='LARGE ENEMY'},
        ['category.giant_enemy']={zh='巨型敌人',en='GIANT ENEMY'},
        ['category.supplies']={zh='普通物资',en='SUPPLIES'},
        ['supply.sample']={zh='样本',en='SAMPLES'},
        ['supply.ammunition']={zh='弹药',en='AMMUNITION'},
        ['supply.stim_case']={zh='针剂盒',en='STIM CASE'},
        ['supply.grenade_case']={zh='手雷盒',en='GRENADE CASE'},
        ['supply.mission_sample_box']={zh='任务样本箱',en='MISSION SAMPLE BOX'},
        ['toggle.supplies']={zh='普通物资提醒',en='SUPPLY ALERTS'},
        ['toggle.poi']={zh='特殊目标提醒',en='SPECIAL TARGET ALERTS'},
        ['toggle.mission_items']={zh='任务物品提醒',en='MISSION ITEM ALERTS'},
        ['tab.special_targets']={zh='特殊目标',en='SPECIAL TARGETS'},
        ['tab.mission_items']={zh='任务物品',en='MISSION ITEMS'},
        ['label.enabled']={zh='启用',en='ENABLED'},
        ['label.message']={zh='消息模板',en='MESSAGE TEMPLATE'},
        ['label.cooldown']={zh='冷却（秒）',en='COOLDOWN (SECONDS)'},
        ['label.inherit_default']={zh='留空继承默认',en='BLANK = INHERIT DEFAULT'},
        ['action.mark']={zh='标记',en='marked'},
        ['action.summon']={zh='召唤',en='called in'},
        ['action.start']={zh='开始',en='started'},
        ['objective.primary']={zh='主线任务',en='PRIMARY OBJECTIVE'},
        ['objective.prerequisite']={zh='主线前置任务',en='PREREQUISITE'},
        ['objective.optional']={zh='支线任务',en='OPTIONAL OBJECTIVE'},
        ['objective.tactical']={zh='战术任务',en='TACTICAL OBJECTIVE'},
        ['objective.unknown']={zh='任务',en='OBJECTIVE'},
    }
    local stock={
        ['欢迎加入小队！']='Welcome to the squad!',
        ['标记了{目标}']='Marked {target}',
        ['{玩家名}召唤了{目标}']='{player_name} called in {target}',
        ['{玩家名}正在开始{目标}']='{player_name} started {target}',
        ['自动聊天测试消息']='HELLO FROM AUTOCHAT',
        -- Exact canonical UI copy; legacy message presets are handled below.
    }
    local stock_en={}
    for zh,en in pairs(stock) do stock_en[en]=en end

    -- Exact UI statuses and errors emitted by the catalog and preset flows.
    -- Unknown strings pass through untouched so preset names and custom text
    -- are never guessed at or translated as if they were interface copy.
    local statuses={
        ['等待战备目录']='Waiting for stratagem catalog',
        ['战备目录：不支持的游戏版本']='Stratagem catalog: unsupported game version',
        ['战备目录数据暂不可读']='Stratagem catalog data is temporarily unreadable',
        ['选择主机或客机配置后，点击应用按钮写入该角色。']='Select a host or client configuration, then apply the preset to that role.',
        ['输入已确认；点击对应按钮执行操作']='Input confirmed; click the corresponding button to apply it',
        ['已取消本次输入']='Input cancelled',
        ['Enter 保存 / Esc 取消 / Ctrl+V 粘贴']='Enter saves / Esc cancels / Ctrl+V pastes',
        ['Enter 确认输入 / Esc 取消']='Enter confirms / Esc cancels',
        ['已保存当前自动消息配置']='Current automatic message settings saved',
        ['请先选择预设']='Select a preset first',
        ['已替换所选预设内容']='Selected preset replaced with current settings',
        ['预设名称已更新']='Preset renamed',
        ['预设已导出']='Preset exported',
        ['预设已删除']='Preset deleted',
        ['预设已导入，请选择后加载']='Preset imported; select it to apply',
        ['设置已保存']='Settings saved',
        ['任务状态已保存']='Task status saved',
        ['任务已删除']='Task deleted',
        ['保存失败']='Save failed',
        ['该分类尚无可读取的战备']='No readable stratagems in this category',
        ['中文输入不可用：窗口 IME 上下文未就绪']='Chinese input is unavailable: the window IME is not ready',
        ['输入队列溢出，已取消并保留原值']='Input queue overflow; edit cancelled and the original value was kept',
        ['搜索已应用']='Search applied',
        ['预设数据长度无效']='Preset data length is invalid',
        ['预设校验器不可用']='Preset validator is unavailable',
        ['预设数据校验失败']='Preset data validation failed',
        ['预设数据无效']='Preset data is invalid',
        ['预设操作不可用']='Preset operation is unavailable',
        ['文件操作失败']='File operation failed',
        ['预设库格式损坏']='Preset library is corrupt',
        ['预设库序号无效']='Preset library serial is invalid',
        ['预设库数量无效']='Preset library count is invalid',
        ['预设编号无效']='Preset ID is invalid',
        ['预设编号重复或无效']='Preset ID is duplicated or invalid',
        ['预设角色无效']='Preset role is invalid',
        ['预设名称长度无效']='Preset name length is invalid',
        ['预设长度无效']='Preset length is invalid',
        ['预设名称重复或无效']='Preset name is duplicated or invalid',
        ['库内预设数据无效']='Preset data in the library is invalid',
        ['预设库含有多余数据或无效序号']='Preset library contains trailing data or an invalid serial',
        ['旧版预设无法安全复制到客机预设池']='Legacy presets cannot be safely copied to the client preset pool',
        ['预设角色无效']='Preset role is invalid',
        ['预设库超过大小限制']='Preset library exceeds the size limit',
        ['保存预设库失败']='Failed to save preset library',
        ['读取预设库失败']='Failed to read preset library',
        ['请选择主机或客机预设池']='Select a host or client preset pool',
        ['名称不能为空，且须为有效UTF-8（最多96字节）']='Name must be valid UTF-8, nonempty, and at most 96 bytes',
        ['此角色的预设名称已存在，请先重命名现有预设']='A preset with this name already exists for this role; rename it first',
        ['此角色的预设名称已存在']='A preset with this name already exists for this role',
        ['读取当前配置失败']='Failed to read current settings',
        ['预设编号已用尽']='Preset ID range is exhausted',
        ['找不到该预设']='Preset not found',
        ['所选预设不属于当前角色']='Selected preset does not belong to the current role',
        ['应用预设失败']='Failed to apply preset',
        ['导出预设失败']='Failed to export preset',
        ['读取预设文件失败']='Failed to read preset file',
        ['预设文件格式无效或过大']='Preset file format is invalid or too large',
        ['预设名称长度无效']='Preset name length is invalid',
        ['预设文件长度无效']='Preset file length is invalid',
        ['预设名称无效']='Preset name is invalid',
        ['预设格式无效或超过 1 MiB']='Preset format is invalid or exceeds 1 MiB',
        ['预设须以换行结束且使用 LF']='Preset must end with a newline and use LF line endings',
        ['预设版本无效']='Preset version is invalid',
        ['预设包含空白、重复或无效行']='Preset contains a blank, duplicate, or invalid line',
        ['预设转义无效']='Preset escaping is invalid',
        ['预设包含无效 UTF-8']='Preset contains invalid UTF-8',
        ['定时任务数量无效']='Scheduled task count is invalid',
        ['定时任务字段无效']='Scheduled task field is invalid',
        ['定时任务编号无效']='Scheduled task index is invalid',
        ['定时任务开关无效']='Scheduled task switch is invalid',
        ['旧版预设发送范围无效']='Legacy preset send scope is invalid',
        ['开关值无效']='Switch value is invalid',
        ['冷却值无效']='Cooldown value is invalid',
        ['设置值无效：']='Invalid setting: ',
        ['预设包含未知字段']='Preset contains an unknown field',
        ['规则无效']='Rule is invalid',
        ['规则开关无效']='Rule switch is invalid',
        ['规则冷却无效']='Rule cooldown is invalid',
        ['规则值无效']='Rule value is invalid',
        ['缺少设置：']='Missing setting: ',
        ['缺少定时任务数量']='Scheduled task count is missing',
        ['定时任务字段不完整']='Scheduled task fields are incomplete',
        ['定时任务名称或消息无效']='Scheduled task name or message is invalid',
        ['定时任务间隔无效']='Scheduled task interval is invalid',
        ['定时任务时间无效']='Scheduled task time is invalid',
        ['定时任务类型无效']='Scheduled task type is invalid',
        ['定时任务数量不匹配']='Scheduled task count does not match the data',
        ['未知预设']='Unknown preset',
        ['任务编号已用尽']='Task ID range is exhausted',
        ['保存定时任务失败；原任务已恢复']='Failed to save scheduled tasks; previous tasks were restored',
        ['快捷定时迁移失败；预设未应用']='Quick timer migration failed; preset was not applied',
        ['请输入事件名称']='Enter an event name',
        ['事件名称过长']='Event name is too long',
        ['请输入发送消息']='Enter a message to send',
        ['消息最多 200 字节']='Message must be at most 200 bytes',
        ['请输入 5 至 86400 的整数秒数']='Enter a whole number of seconds from 5 to 86400',
        ['请输入有效时间，例如 21:30']='Enter a valid time, for example 21:30',
        ['请选择定时类型']='Select a schedule type',
    }
    local status_prefixes={
        ['预设应用失败：']='Preset apply failed: ',
        ['预设库不可用：']='Preset library unavailable: ',
        ['设置值无效：']='Invalid setting: ',
        ['缺少设置：']='Missing setting: ',
    }

    function M.current() return state.locale end
    function M.is_chinese(locale)
        local selected=(locale=='zh' or locale=='en') and locale or state.locale
        return selected=='zh'
    end
    function M.set_dirty(callback) env.dirty=callback end
    function M.update(option,frame)
        if option~='zh' and option~='en' and option~='auto' then option='auto' end
        if option=='zh' or option=='en' then
            state.option=option
            if state.locale~=option then
                state.locale=option
                if env.dirty~=nil then pcall(env.dirty) end
            end
            return state.locale
        end
        frame=tonumber(frame) or 0
        if state.option~='auto' or frame>=state.due then
            state.option='auto'
            state.due=frame+120
            local ok,value=pcall(env.read_game or function() return nil end)
            local selected=ok and (value=='zh' and 'zh' or value=='en' and 'en' or nil) or nil
            if selected and selected~=state.locale then
                state.locale=selected
                if env.dirty~=nil then pcall(env.dirty) end
            end
        end
        return state.locale
    end
    function M.text(chinese,english,locale)
        local selected=(locale=='zh' or locale=='en') and locale or state.locale
        if selected=='zh' then return tostring(chinese or english or '') end
        return tostring(english or chinese or '')
    end
    function M.phrase(key, locale)
        local row=phrases[key]
        local selected=(locale=='zh' or locale=='en') and locale or state.locale
        return row and row[selected] or tostring(key or '')
    end
    function M.status(value,locale)
        local selected=(locale=='zh' or locale=='en') and locale or state.locale
        if type(value)~='string' or selected=='zh' then return value end
        local translated=statuses[value]
        if translated then return translated end
        if value:match('^战备目录读取就绪（%d+）$') then
            return 'Stratagem catalog ready ('..value:match('（(%d+)）')..')'
        end
        for prefix,english in pairs(status_prefixes) do
            if value:sub(1,#prefix)==prefix then
                local suffix=value:sub(#prefix+1)
                return english..(statuses[suffix] or suffix)
            end
        end
        return value
    end
    function M.stock_template(value, locale)
        if type(value)~='string' then return value end
        -- Migrate only exact shipped message templates in settings and presets;
        -- user-written parenthetical text remains unchanged.
        local old_marker={
            ['队友标记了{类别}，请注意！']={zh='标记了{目标}',en='Marked {target}'},
            ['标记了{目标}（{类别}）']={zh='标记了{目标}',en='Marked {target}'},
            ['Marked {目标} ({类别})']={zh='标记了{目标}',en='Marked {target}'},
            ['Marked {target} ({category})']={zh='标记了{目标}',en='Marked {target}'},
            ['{玩家名} called in {目标}']={zh='{玩家名}召唤了{目标}',en='{player_name} called in {target}'},
            ['{玩家名} started {目标}']={zh='{玩家名}正在开始{目标}',en='{player_name} started {target}'},
        }
        local replacement=old_marker[value]
        if replacement then
            if locale=='zh' then return replacement.zh end
            if locale=='en' then return replacement.en end
            value=replacement[state.locale] or replacement.en
        end
        if locale=='zh' or locale=='en' then return value end
        local selected=state.locale
        if selected=='zh' then
            for zh,en in pairs(stock) do if value==en then return zh end end
            return value
        end
        return stock[value] or stock_en[value] or value
    end
    function M.stock_templates() return stock end
    function M.phrases() return phrases end
    return M
end

-- END AUTOCHAT LANGUAGE
-- BEGIN GAME LANGUAGE READER
-- Read-only Text Language reader for one reviewed Helldivers 2 build.
-- Production process access is built from kernel32/bcrypt; tests may inject a fake env.
M.build_game_language_reader = function(options)
    options=type(options)=='table' and options or {}
    local env=options.env or {}
    if type(env)~='table' then env={} end
    local ffi=options.ffi
    local kernel,bcrypt,process

    local function production_setup()
        if not ffi then return false end
        -- cdef declarations are process-global and may already exist in the loader.
        -- Declare each one separately so a duplicate cannot suppress later APIs.
        local declarations={
            'void *GetCurrentProcess(void);',
            'void *GetModuleHandleA(const char *module_name);',
            'uint32_t GetModuleFileNameW(void *module, uint16_t *filename, uint32_t size);',
            'void *CreateFileW(const uint16_t *name, uint32_t access, uint32_t share, void *security, uint32_t creation, uint32_t flags, void *template_file);',
            'int ReadFile(void *file, void *buffer, uint32_t size, uint32_t *received, void *overlapped);',
            'int CloseHandle(void *handle);',
            'int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *received);',
            'int32_t BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name, const uint16_t *implementation, uint32_t flags);',
            'int32_t BCryptCreateHash(void *algorithm, void **hash, uint8_t *object, uint32_t object_size, uint8_t *secret, uint32_t secret_size, uint32_t flags);',
            'int32_t BCryptHashData(void *hash, uint8_t *input, uint32_t input_size, uint32_t flags);',
            'int32_t BCryptFinishHash(void *hash, uint8_t *output, uint32_t output_size, uint32_t flags);',
            'int32_t BCryptDestroyHash(void *hash);',
            'int32_t BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags);',
        }
        for _,declaration in ipairs(declarations) do pcall(ffi.cdef,declaration) end
        if options.api then
            kernel=options.api.kernel
            bcrypt=options.api.bcrypt
            if not kernel or not bcrypt then return false end
        else
            local loaded,k=pcall(ffi.load,'kernel32')
            if not loaded then return false end
            kernel=k
            loaded,bcrypt=pcall(ffi.load,'bcrypt')
            if not loaded then kernel=nil;return false end
        end
        local symbols={'GetCurrentProcess','GetModuleHandleA','GetModuleFileNameW','CreateFileW',
            'ReadFile','CloseHandle','ReadProcessMemory'}
        for _,name in ipairs(symbols) do
            local good,value=pcall(function() return kernel[name] end)
            if not good or (type(value)~='cdata' and type(value)~='function')
                or (type(value)=='cdata' and value==ffi.NULL) then
                kernel,bcrypt=nil,nil;return false
            end
        end
        local crypto={'BCryptOpenAlgorithmProvider','BCryptCreateHash','BCryptHashData',
            'BCryptFinishHash','BCryptDestroyHash','BCryptCloseAlgorithmProvider'}
        for _,name in ipairs(crypto) do
            local good,value=pcall(function() return bcrypt[name] end)
            if not good or (type(value)~='cdata' and type(value)~='function')
                or (type(value)=='cdata' and value==ffi.NULL) then
                kernel,bcrypt=nil,nil;return false
            end
        end
        process=options.api and options.api.process or kernel.GetCurrentProcess()
        return process~=nil and process~=ffi.NULL
    end

    local function is_handle(value)
        if not ffi then return false end
        local ok,result=pcall(function()
            return value~=nil and value~=ffi.NULL and value~=ffi.cast('void*',-1)
        end)
        return ok and result
    end
    local function wide_ascii(value)
        local out=ffi.new('uint16_t[?]',#value+1)
        for i=1,#value do out[i-1]=value:byte(i) end
        out[#value]=0
        return out
    end
    local function module_path(module)
        local path=ffi.new('uint16_t[32768]')
        local length=kernel.GetModuleFileNameW(module,path,32768)
        if length==0 or length>=32768 then return nil end
        return path
    end
    local function hash_file(path)
        if not path then return nil end
        local file=kernel.CreateFileW(path,0x80000000,7,nil,3,0x08000000,nil)
        if not is_handle(file) then return nil end
        local algorithm,hash=ffi.new('void*[1]'),ffi.new('void*[1]')
        local digest
        local ok,result=pcall(function()
            local name=wide_ascii('SHA256')
            assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm,name,nil,0)==0,'SHA256 provider')
            assert(algorithm[0]~=nil and algorithm[0]~=ffi.NULL,'SHA256 provider handle')
            assert(bcrypt.BCryptCreateHash(algorithm[0],hash,nil,0,nil,0,0)==0,'SHA256 hash')
            assert(hash[0]~=nil and hash[0]~=ffi.NULL,'SHA256 hash handle')
            local buffer,received=ffi.new('uint8_t[1048576]'),ffi.new('uint32_t[1]')
            while true do
                assert(kernel.ReadFile(file,buffer,1048576,received,nil)~=0,'module read')
                if received[0]==0 then break end
                assert(bcrypt.BCryptHashData(hash[0],buffer,received[0],0)==0,'SHA256 update')
            end
            local bytes=ffi.new('uint8_t[32]')
            assert(bcrypt.BCryptFinishHash(hash[0],bytes,32,0)==0,'SHA256 finish')
            local hex={}
            for i=0,31 do hex[#hex+1]=string.format('%02X',bytes[i]) end
            return table.concat(hex)
        end)
        if hash[0]~=nil and hash[0]~=ffi.NULL then
            pcall(function() bcrypt.BCryptDestroyHash(hash[0]) end)
        end
        if algorithm[0]~=nil and algorithm[0]~=ffi.NULL then
            pcall(function() bcrypt.BCryptCloseAlgorithmProvider(algorithm[0],0) end)
        end
        pcall(function() kernel.CloseHandle(file) end)
        if not ok then return nil end
        digest=result
        return digest
    end

    local setup_ok=false
    if ffi and (options.api or not env.game_module or not env.exe_module
        or not env.hash_module or not env.read) then
        setup_ok=production_setup()
    end
    if setup_ok then
        if env.game_module==nil then env.game_module=function()
                local p=kernel.GetModuleHandleA('game.dll')
                if not is_handle(p) then return nil end
                return tonumber(ffi.cast('uintptr_t',p))
            end end
        if env.exe_module==nil then env.exe_module=function()
                local p=kernel.GetModuleHandleA(nil)
                if not is_handle(p) then return nil end
                return tonumber(ffi.cast('uintptr_t',p))
            end end
        if env.hash_module==nil then env.hash_module=function(base)
                local p=ffi.cast('void*',base)
                return hash_file(module_path(p))
            end end
        if env.read==nil then env.read=function(address,size)
                local buffer,received=ffi.new('uint8_t[?]',size),ffi.new('size_t[1]')
                local ok=kernel.ReadProcessMemory(process,ffi.cast('const void*',address),buffer,size,received)
                if ok==0 or tonumber(received[0])~=size then return nil end
                return ffi.string(buffer,size)
            end end
    end
    env=type(env)=='table' and env or {}
    local expected_game='2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
    local expected_exe='F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
    local prologue='\x48\x89\x5c\x24\x08\x48\x89\x74\x24\x10\x57\x48\x83\xec\x20\x8b'
    local checked,verified,unsupported=false,false,false
    local game_base
    local M={}

    local function read(address,size)
        if env.read==nil then return nil end
        local ok,value=pcall(env.read,address,size)
        if not ok or type(value)~='string' or #value~=size then return nil end
        return value
    end
    local function u32(bytes)
        if type(bytes)~='string' or #bytes<4 then return nil end
        local a,b,c,d=bytes:byte(1,4)
        return a+b*256+c*65536+d*16777216
    end
    local function u64ptr(bytes)
        if type(bytes)~='string' or #bytes<8 then return nil end
        local a,b,c,d,e,f,g,h=bytes:byte(1,8)
        -- The reviewed game's user-mode pointers are canonical low 47-bit addresses.
        if g~=0 or h~=0 then return nil end
        local p=a+b*256+c*65536+d*16777216+e*4294967296+f*1099511627776
        if p<65536 or p>=140737488355328 then return nil end
        return p
    end
    local function ptr(at) return u64ptr(read(at,8)) end

    local function verify()
        if checked then return verified end
        local ok,result=pcall(function()
            if env.game_module==nil or env.exe_module==nil or env.hash_module==nil then return nil end
            local game=env.game_module()
            local exe=env.exe_module()
            if type(game)~='number' or type(exe)~='number' then return nil end
            local game_hash=env.hash_module(game)
            local exe_hash=env.hash_module(exe)
            if type(game_hash)~='string' or type(exe_hash)~='string'
                then return nil end
            if game_hash:upper()~=expected_game or exe_hash:upper()~=expected_exe then return 'unsupported' end
            local signature=read(game+0x14c0350,#prologue)
            if not signature then return nil end
            if signature~=prologue then return 'unsupported' end
            game_base=game
            return true
        end)
        if ok and result=='unsupported' then checked=true;unsupported=true end
        verified=ok and result==true
        if verified then checked=true end
        return verified
    end

    function M.read()
        if not verify() then return nil end
        local settings=ptr(game_base+0x3326340)
        if not settings then return nil end
        local index_bytes=read(settings+705712,4)
        local index=index_bytes and u32(index_bytes)
        if not index or index>=15 then return nil end
        local record=ptr(game_base+0x37c5650+index*8)
        local text=record and ptr(record+8)
        local bytes=text and (read(text,16) or read(text,8))
        if not bytes or read(settings+705712,4)~=index_bytes then return nil end
        local ending=bytes:find('\0',1,true)
        if not ending then return nil end
        local code=bytes:sub(1,ending-1)
        if #code<2 or #code>12 or not code:match('^%a[%a%-]*$') then return nil end
        code=code:lower()
        if code=='cn' or code=='tw' or code=='zh' or code=='zhs' or code=='zht'
            or code=='zh-cn' or code=='zh-tw' then return 'zh' end
        return 'en'
    end
    function M.verified() return verified end
    function M.unsupported() return unsupported end
    function M.expected_fingerprints() return expected_game,expected_exe end
    function M.hash_file_path(path)
        if not setup_ok or type(path)~='string' or path=='' then return nil end
        for i=1,#path do if path:byte(i)>127 then return nil end end
        return hash_file(wide_ascii(path))
    end
    return M
end

-- END GAME LANGUAGE READER
-- BEGIN CHAT AUTOMATION
-- Automatic chat policy, inlined by the addon builder; no native offsets or writes.
-- Session API provenance: P2P-Ping 0.1.34 scope() / update_peer_labels().
local function build_chat_automation(env)
    local options = {enabled = true, allow_solo = true,
        welcome = false, welcome_message = 'Welcome to the squad!', cooldown = 5,
        welcome_delay = 2, message_language = 'en', ping = false, ping_building = true, ping_stratagem = true, ping_map = true,
        ping_supplies = false,
        ping_sender_prefix = true, ping_sender_color = true, ping_medium_enemy = true,
        ping_large_enemy = true, ping_giant_enemy = true, ping_summon = true,
        ping_small_enemy = false, ping_flying_enemy = true,
        ping_message = 'Marked {target}', summon_message = '{player_name} called in {target}',
        task_stratagem_message = '{player_name} started {target}', output = 'squad',
        quick_timer_enabled = false, quick_timer_interval = 30,
        quick_timer_message = 'HELLO FROM AUTOCHAT'}
    local keys = {'enabled', 'allow_solo', 'welcome', 'welcome_message',
        'cooldown', 'welcome_delay', 'message_language', 'ping', 'ping_building', 'ping_stratagem', 'ping_map', 'ping_supplies', 'ping_sender_prefix', 'ping_sender_color', 'ping_medium_enemy',
        'ping_large_enemy', 'ping_giant_enemy', 'ping_small_enemy', 'ping_flying_enemy', 'ping_message', 'ping_summon', 'summon_message', 'task_stratagem_message', 'output',
        'quick_timer_enabled', 'quick_timer_interval', 'quick_timer_message'}
    local booleans = {enabled=true, allow_solo=true, welcome=true, ping=true, quick_timer_enabled=true,
        ping_building=true, ping_stratagem=true, ping_map=true, ping_supplies=true,
        ping_sender_prefix=true, ping_sender_color=true, ping_medium_enemy=true, ping_large_enemy=true,
        ping_giant_enemy=true, ping_small_enemy=true, ping_flying_enemy=true, ping_summon=true}
    local state = {pending = {}, pings = {}, ping_seen = {}, last_send = nil, last_by_peer = {}, baseline = nil,
        status = '等待会话', legacy_quick_timer_missing = false}
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
        elseif key == 'output' then
            if value ~= 'squad' and value ~= 'local' then return false, '请选择小队公屏或仅自己可见' end
        elseif key == 'message_language' then
            if value ~= 'auto' and value ~= 'zh' and value ~= 'en' then return false, '消息语言无效' end
        elseif key == 'cooldown' or key == 'welcome_delay' or key == 'quick_timer_interval' then
            local minimum = key == 'quick_timer_interval' and 5 or 0
            local limit = (key == 'cooldown' or key == 'quick_timer_interval') and 3600 or 60
            if type(value) ~= 'number' or value ~= value or value < minimum or value > limit
                or value ~= math.floor(value) then
                return false, '请输入 ' .. minimum .. ' 到 ' .. limit .. ' 之间的整数秒数'
            end
        elseif key == 'welcome_message' or key == 'ping_message' or key == 'summon_message' or key == 'task_stratagem_message' or key == 'quick_timer_message' then
            local maximum = key == 'quick_timer_message' and 200 or 512
            if type(value) ~= 'string' or #value == 0 or #value > maximum
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
    local factory_profiles = {host=copy(options),client=copy(options)}
    factory_profiles.client.welcome, factory_profiles.client.output = false, 'local'
    local enemy_rules = {small_enemy=true,medium_enemy=true,large_enemy=true,giant_enemy=true,flying_enemy=true}
    local rule_fields = {enabled=true,mark_message=true,call_message=true,cooldown=true}
    local function rule_key(kind,id)
        if kind=='enemy' and enemy_rules[id] then return 'enemy_'..id end
        id=tonumber(id)
        if kind=='stratagem' and id and id%1==0 and id>0 and id<4294967296 then
            return 'stratagem_'..string.format('%.0f',id)
        end
    end
    factory_profiles.host.rules={}
    factory_profiles.client.rules={}
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
        local lines = {'# AutoChat automation settings v6'}
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
                elseif key == 'cooldown' or key == 'welcome_delay' or key == 'quick_timer_interval' then
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
    state.legacy_quick_timer_missing = (saved_version or 1)<5
    for _, role in ipairs({'host','client'}) do
        for _, key in ipairs({'quick_timer_enabled','quick_timer_interval','quick_timer_message'}) do
                if role_values[role][key] == nil then state.legacy_quick_timer_missing = true end
        end
    end
    if (saved_version or 1) < 2 and options.ping_message == '队友标记了{类别}，请注意！' then
        options.ping_message = '标记了{目标}'
    end
    profiles = {host=copy(options), client=copy(options)}
    profiles.client.welcome, profiles.client.output = false, 'local'
    for _, role in ipairs({'host','client'}) do
        for key,value in pairs(role_values[role]) do profiles[role][key] = value end
        if role_values[role].message_language==nil and not saved_keys.message_language and saved~=nil then
            profiles[role].message_language='auto'
        end
        profiles[role].rules=saved_rules[role]
    end
    for _,key in ipairs(keys) do options[key] = profiles.host[key] end
    state.active_role = 'host'
    function api.profile(role) return profiles[role or state.active_role] end
    function api.migrate_legacy_quick_timer(enabled, interval, message)
        if not state.legacy_quick_timer_missing then return true, '快捷定时配置已存在' end
        local valid, why=validate('quick_timer_interval',interval)
        if not valid then return false,why end
        valid,why=validate('quick_timer_message',message)
        if not valid then return false,why end
        if type(enabled)~='boolean' then return false,'旧快捷定时开关无效' end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        candidate.host.quick_timer_enabled=enabled
        candidate.host.quick_timer_interval=interval
        candidate.host.quick_timer_message=message
        candidate.client.quick_timer_enabled=false
        if attempt(env.write_file,serialize(candidate))~=true then return false,'快捷定时配置迁移失败' end
        profiles=candidate
        state.legacy_quick_timer_missing=false
        if state.active_role=='host' then for _,key in ipairs(keys) do options[key]=profiles.host[key] end end
        return true,'快捷定时配置已迁移到主机预设'
    end

    -- Portable named-profile format is deliberately data-only and parsed strictly.
    local function encode_profile(source,tasks,plugin_blobs)
        local lines={'# AutoChat profile v5'}
        for _,key in ipairs(keys) do
            if not key:match('^quick_timer_') then lines[#lines+1]=key..'='..escape(tostring(source[key])) end
        end
        local ids={};for id in pairs(source.rules or {}) do ids[#ids+1]=id end;table.sort(ids)
        for _,id in ipairs(ids) do
            for _,field in ipairs({'enabled','mark_message','call_message','cooldown'}) do
                local value=source.rules[id][field]
                if value~=nil then lines[#lines+1]='rule_'..id..'.'..field..'='..escape(tostring(value)) end
            end
        end
        tasks=type(tasks)=='table' and tasks or {}
        lines[#lines+1]='task_count='..tostring(#tasks)
        for i,task in ipairs(tasks) do
            if type(task)~='table' then return nil,'定时任务无效' end
            local fields={name=task.name,mode=task.mode,time=task.time,message=task.message,
                enabled=tostring(task.enabled==true and task.done~=true)}
            for _,field in ipairs({'name','mode','time','message','enabled'}) do
                local value=fields[field]
                if type(value)~='string' then return nil,'定时任务字段无效' end
                lines[#lines+1]='task_'..i..'.'..field..'='..escape(value)
            end
        end
        if plugin_blobs~=nil and type(plugin_blobs)~='table' then return nil,'插件预设数据无效' end
        plugin_blobs=plugin_blobs or {}
        local plugin_ids={}
        for id,blob in pairs(plugin_blobs) do
            if type(id)~='string' or #id<1 or #id>64 or not id:match('^[%w_.%-]+$')
                or type(blob)~='string' then return nil,'插件预设数据无效' end
            plugin_ids[#plugin_ids+1]=id
        end
        table.sort(plugin_ids)
        lines[#lines+1]='plugin_count='..tostring(#plugin_ids)
        for _,id in ipairs(plugin_ids) do lines[#lines+1]='plugin.'..id..'='..escape(plugin_blobs[id]) end
        local payload=table.concat(lines,'\n')..'\n'
        if #payload>1048576 then return nil,'预设超过 1 MiB' end
        return payload
    end
    function api.export_profile(role, tasks, plugin_blobs)
        local source=profiles[role]
        if not source then return nil,'未知预设' end
        return encode_profile(source,tasks,plugin_blobs)
    end
    function api.export_default_profile(role, language, templates)
        local source=factory_profiles[role]
        if not source then return nil,'未知预设' end
        if language~='zh' and language~='en' then return nil,'消息语言无效' end
        source=copy(source)
        -- Built-in presets are explicitly complete reminder configurations.
        -- Keep role policy (allow_solo/output) from the factory profile, and
        -- leave retired quick-timer settings and per-user rules untouched.
        for _,key in ipairs({'enabled','welcome','ping','ping_building','ping_stratagem','ping_map',
            'ping_supplies','ping_summon','ping_small_enemy','ping_flying_enemy',
            'ping_medium_enemy','ping_large_enemy','ping_giant_enemy'}) do
            source[key]=true
        end
        source.message_language=language
        for key,value in pairs(type(templates)=='table' and templates or {}) do
            if key=='welcome_message' or key=='ping_message' or key=='summon_message'
                or key=='task_stratagem_message' or key=='quick_timer_message' then
                source[key]=value
            end
        end
        return encode_profile(source,{}, {})
    end
    function api.validate_profile(payload)
        if type(payload)~='string' or #payload>1048576 then return false,'预设格式无效或超过 1 MiB' end
        if payload:sub(-1)~='\n' or payload:find('\r',1,true) then return false,'预设须以换行结束且使用 LF' end
        local lines={};for line in payload:gmatch('([^\n]*)\n') do lines[#lines+1]=line end
        local version=tonumber(lines[1]:match('^# AutoChat profile v(%d+)$'))
        if version~=1 and version~=2 and version~=3 and version~=4 and version~=5 then return false,'预设版本无效' end
        local values,rules,seen,tasks_by_id,plugin_blobs={}, {}, {}, {}, {}
        local task_count,plugin_count
        local scalar_set={};for _,key in ipairs(keys) do scalar_set[key]=true end
        for i=2,#lines do
            local key,raw=lines[i]:match('^([%w_%.%-]+)=(.*)$')
            if not key or key=='' or seen[key] then return false,'预设包含空白、重复或无效行' end
            seen[key]=true
            local value=unescape(raw)
            if value==nil or escape(value)~=raw then return false,'预设转义无效' end
            local plugin_id=key:match('^plugin%.([%w_.%-]+)$')
            if not valid_utf8(value) and not plugin_id then return false,'预设包含无效 UTF-8' end
            local task_index,task_field=key:match('^task_(%d+)%.([%a_]+)$')
            if key=='plugin_count' then
                if version<5 or not value:match('^%d+$') then return false,'插件数据数量无效' end
                plugin_count=tonumber(value)
                if plugin_count>#lines then return false,'插件数据数量与文件长度不符' end
            elseif plugin_id then
                if version<5 or #plugin_id>64 then return false,'插件数据编号无效' end
                plugin_blobs[plugin_id]=value
            elseif key=='task_count' then
                if version<2 or not value:match('^%d+$') then return false,'定时任务数量无效' end
                task_count=tonumber(value)
                if task_count>#lines then return false,'定时任务数量与文件长度不符' end
            elseif task_index then
                local fields={name=true,mode=true,time=true,message=true,enabled=true}
                if version<2 or not fields[task_field] then return false,'定时任务字段无效' end
                local index=tonumber(task_index)
                if not index or index<1 or index%1~=0 then return false,'定时任务编号无效' end
                if task_field=='enabled' then
                    if value=='true' then value=true elseif value=='false' then value=false else return false,'定时任务开关无效' end
                end
                tasks_by_id[index]=tasks_by_id[index] or {}
                tasks_by_id[index][task_field]=value
            elseif key=='scope' then
                if version~=1 then return false,'预设版本无效' end
                if value~='all' and value~='host' then return false,'旧版预设发送范围无效' end
            elseif scalar_set[key] then
                if booleans[key] then
                    if value=='true' then value=true elseif value=='false' then value=false else return false,'开关值无效' end
                elseif key=='cooldown' or key=='welcome_delay' or key=='quick_timer_interval' then
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
        for _,key in ipairs(keys) do
            if values[key]==nil then
                if version<4 and key=='ping_supplies' then values[key]=false
                elseif (version<3 or version>=4) and key=='quick_timer_enabled' then values[key]=false
                elseif (version<3 or version>=4) and key=='quick_timer_interval' then values[key]=30
                elseif (version<3 or version>=4) and key=='quick_timer_message' then values[key]='HELLO FROM AUTOCHAT'
                elseif key=='message_language' then values[key]='auto'
                else return false,'缺少设置：'..key end
            end
        end
        local task_list
        if version>=2 then
            if task_count==nil then return false,'缺少定时任务数量' end
            task_list={}
            for i=1,task_count do
                local t=tasks_by_id[i]
                if not t or t.name==nil or t.mode==nil or t.time==nil or t.message==nil or t.enabled==nil then
                    return false,'定时任务字段不完整'
                end
                if t.name=='' or #t.name>96 or t.name:find('[%c]') or not t.name:find('%S')
                    or t.message=='' or #t.message>200 or t.message:find('[%c]') or not t.message:find('%S') then
                    return false,'定时任务名称或消息无效'
                end
                if t.mode=='repeat' or t.mode=='once' then
                    local seconds=t.time:match('^%d+$') and tonumber(t.time)
                    if not seconds or seconds<5 or seconds>86400 then return false,'定时任务间隔无效' end
                    t.time=tostring(seconds)
                elseif t.mode=='daily' then
                    local hour,minute=t.time:match('^(%d%d?):(%d%d)$');hour,minute=tonumber(hour),tonumber(minute)
                    if not hour or hour>23 or minute>59 then return false,'定时任务时间无效' end
                    t.time=string.format('%02d:%02d',hour,minute)
                else return false,'定时任务类型无效' end
                task_list[i]={name=t.name,mode=t.mode,time=t.time,message=t.message,enabled=t.enabled}
            end
            for i in pairs(tasks_by_id) do if i>task_count then return false,'定时任务数量不匹配' end end
        end
        if version>=5 then
            if plugin_count==nil then return false,'缺少插件数据数量' end
            local actual=0;for _ in pairs(plugin_blobs) do actual=actual+1 end
            if actual~=plugin_count then return false,'插件数据数量不匹配' end
        end
        return true,{values=values,rules=rules,tasks=task_list,
            plugins=version>=5 and plugin_blobs or nil,version=version}
    end
    function api.import_profile(payload,role)
        if role~='host' and role~='client' then return false,'未知预设' end
        local valid,parsed=api.validate_profile(payload)
        if not valid then return false,parsed end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        for _,key in ipairs(keys) do
            if (parsed.version < 3 or parsed.version >= 4) and key:match('^quick_timer_') then
                -- Older portable profiles did not own this setting; loading one
                -- must not silently change the destination role's timer.
                candidate[role][key]=profiles[role][key]
            elseif parsed.version < 4 and key=='ping_supplies' then
                candidate[role][key]=profiles[role][key]
            else candidate[role][key]=parsed.values[key] end
        end
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
    function api.settings()
        local role = api.sync()
        if not role then return nil, 'role unavailable' end
        local snapshot = copy(profiles[role])
        snapshot.role = role
        return snapshot
    end
    function api.send(text, expected_role, output_override)
        local role = api.sync()
        if not role then return false, '等待：主机身份尚未确认' end
        if expected_role and role ~= expected_role then return false, '身份已变化，取消旧预设消息' end
        local output = output_override or options.output
        if output ~= 'local' and output ~= 'squad' then return false, '输出方式无效' end
        local invalid_text = output == 'local' and 'empty or invalid text' or 'empty text'
        if type(text) ~= 'string' or #text == 0 then return false, invalid_text end
        while true do
            if text:sub(1, 2) == '\r\n' then text = text:sub(3)
            elseif text:sub(1, 1) == '\n' then text = text:sub(2)
            else break end
        end
        if #text == 0 then return false, invalid_text end
        text = '\n' .. text
        if output == 'local' then
            local ok, why = attempt(env.send_local, text)
            return ok == true, why or '本地显示入口不可用'
        end
        local ok, why = attempt(env.send, text)
        return ok == true, why
    end

    local categories = {building='任务建筑', stratagem='战备提示', map='地图标记',
        supplies='普通物资',
        small_enemy='小型敌人', flying_enemy='飞行敌人', medium_enemy='中型敌人', large_enemy='大型敌人', giant_enemy='巨型敌人'}
    local categories_en = {building='OBJECTIVE BUILDING',stratagem='STRATAGEM',map='MAP MARKER',
        supplies='SUPPLIES',small_enemy='SMALL ENEMY',flying_enemy='FLYING ENEMY',
        medium_enemy='MEDIUM ENEMY',large_enemy='LARGE ENEMY',giant_enemy='GIANT ENEMY'}
    function api.category_label(category,language)
        local ok,value=pcall(env.category_label or function() return nil end,category,language)
        if ok and type(value)=='string' and value~='' then return value end
        return language=='en' and (categories_en[category] or 'UNKNOWN') or categories[category] or '未知'
    end
    function api.phrase(key,fallback,language)
        local ok,value=pcall(env.phrase or function() return nil end,key,language)
        if ok and type(value)=='string' and value~='' and value~=key then return value end
        if language=='en' then
            local english={['action.mark']='marked',['action.summon']='called in',['action.start']='started',
                ['objective.primary']='PRIMARY OBJECTIVE',['objective.prerequisite']='PREREQUISITE',
                ['objective.optional']='OPTIONAL OBJECTIVE',['objective.tactical']='TACTICAL OBJECTIVE',
                ['objective.unknown']='OBJECTIVE'}
            return english[key] or fallback
        end
        return fallback
    end
    function api.stock_template(value,language)
        local ok,result=pcall(env.stock_template or function() return value end,value,language)
        return ok and type(result)=='string' and result or value
    end
    local function clipped(value, limit)
        if #value <= limit then return value end
        local at = limit + 1
        while at > 1 and value:byte(at) >= 128 and value:byte(at) < 192 do at = at-1 end
        return value:sub(1, at-1)
    end
    local function plain(value, limit)
        return clipped(tostring(value or ''):gsub('[%c<>]', ''), limit)
    end
    local function clip_color_markup(value,limit)
        local reset='<c=FFFFFFFF>'
        local out,used,at,active={},0,1,false
        while at<=#value do
            local start_pos,end_pos,hex=value:find('<c=([%x]+)>',at)
            if not start_pos then
                local tail=value:sub(at)
                local budget=math.max(0,limit-used-(active and #reset or 0))
                if #tail>budget then tail=clipped(tail,budget) end
                out[#out+1]=tail
                used=used+#tail
                if active then out[#out+1]=reset;active=false end
                break
            end
            local prefix=value:sub(at,start_pos-1)
            local prefix_budget=math.max(0,limit-used-(active and #reset or 0))
            if #prefix>prefix_budget then
                prefix=clipped(prefix,prefix_budget)
                out[#out+1]=prefix;used=used+#prefix
                if active then out[#out+1]=reset end
                return table.concat(out)
            end
            out[#out+1]=prefix;used=used+#prefix
            local token=value:sub(start_pos,end_pos)
            local closing=hex:upper()=='FFFFFFFF'
            if used+#token>limit or not closing and used+#token+#reset>limit then
                if active and used+#reset<=limit then out[#out+1]=reset end
                return table.concat(out)
            end
            out[#out+1]=token;used=used+#token
            active=not closing
            at=end_pos+1
        end
        if active and used+#reset<=limit then out[#out+1]=reset end
        return table.concat(out)
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
    local function position_text(event,language)
        local p = event.position
        local unknown=language=='en' and 'Unknown position' or '未知位置'
        if type(p) ~= 'table' then return unknown end
        for _, key in ipairs({'x','y','z'}) do
            local n=p[key]
            if type(n) ~= 'number' or n ~= n or math.abs(n) > 1000000 then return unknown end
        end
        return string.format('(%.0f, %.0f, %.0f)', p.x, p.y, p.z)
    end
    function api.has_peer(peer) return creator_present(peer,api.snapshot()) end
    function api.canonical_peer(peer)
        local snapshot = api.snapshot()
        if not snapshot or peer ~= nil and not creator_present(peer, snapshot) then return nil end
        return session_peer_hex(peer or snapshot.mine)
    end

    function api.format(template, peer, extra, anonymous, color_player_names, language)
        if type(template) ~= 'string' then return '' end
        if peer == nil then local s=api.snapshot();peer=s and s.mine end
        local identity = identity_for(peer)
        local group,teammate=language=='en' and 'Squad' or '小队',language=='en' and 'Teammate' or '队友'
        local name = anonymous and group or identity and plain(identity.name,96) or teammate
        local short = anonymous and group or identity and plain(identity.short,16) or teammate
        local has_player_name = not anonymous and identity ~= nil and name ~= ''
        if name=='' then name=teammate end
        if short=='' then short=teammate end
        if has_player_name and not (name:sub(1,1)=='[' and name:sub(-1)==']') then
            name='['..name..']'
        end
        if color_player_names and not anonymous and identity and type(identity.color)=='string'
            and (#identity.color==6 or #identity.color==8) and identity.color:match('^%x+$') then
            local color=identity.color:upper()
            if #color==6 then color='FF'..color end
            name='<c='..color..'>'..name..'<c=FFFFFFFF>'
        end
        local slot = not anonymous and identity and identity.color_index
        local number = type(slot)=='number' and slot%1==0 and slot>=0 and slot<=3 and tostring(slot+1) or '?'
        local values = {['{玩家名}']=name,['{名字}']=name,['{触发者}']=name,
            ['{player}']=name,['{player_name}']=name,['{name}']=name,
            ['{缩写}']=short,['{short}']=short,['{abbr}']=short,
            ['{编号}']=number,['{slot}']=number,['{number}']=number}
        if type(extra)=='table' then
            for key,value in pairs(extra) do
                if values[key]==nil and type(key)=='string' and type(value)=='string' then
                    values[key]=plain(value,200)
                end
            end
        end
        -- Function replacement keeps '%' and nested braces in player names literal.
        local formatted=template:gsub('{[^{}]+}',function(key)return values[key] or key end)
        return color_player_names and clip_color_markup(formatted,511) or clipped(formatted,511)
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
    local function policy(now, others, snapshot, peer, rule_id, cooldown, ignore_cooldown)
        limits(snapshot)
        if not options.enabled then return false, '自动发送已关闭' end
        if not options.allow_solo and (type(others) ~= 'number' or others < 1) then
            return false, '等待：小队中没有其他玩家'
        end
        if type(now) ~= 'number' or now ~= now or now == math.huge or now == -math.huge then
            return false, '等待：计时尚未就绪'
        end
        if not ignore_cooldown then
            local key=bucket(peer,snapshot)
            local independent=rule_id and cooldown~=nil
            local last=independent and (state.last_by_rule[key] or {})[rule_id] or nil
            if not independent then last=state.last_by_peer[key] end
            if last and now - last < (independent and cooldown or options.cooldown) then
                return false, '等待：该玩家的自动消息间隔中', 'cooldown-active'
            end
        end
        return true, '可以自动发送'
    end
    local function pending_ping_reserves(now, snapshot, peer, rule_id, cooldown)
        if type(snapshot) ~= 'table' then return false end
        local actor = bucket(peer, snapshot)
        local independent = rule_id ~= nil and cooldown ~= nil
        local effective = independent and cooldown or options.cooldown
        if type(effective) ~= 'number' or effective <= 0 then return false end
        local context = attempt(env.context)
        for _, pending in ipairs(state.pings) do
            local other_independent = pending.rule_id ~= nil and pending.cooldown ~= nil
            local other_effective = other_independent and pending.cooldown or options.cooldown
            if type(other_effective) == 'number' and other_effective > 0
                and type(pending.expires) == 'number' and pending.expires >= now
                and pending.role == state.active_role and pending.context == context
                and pending.session == snapshot.session and pending.mine == snapshot.mine
                and pending.host == snapshot.host
                and creator_present(pending.creator_id,snapshot)
                and bucket(pending.creator_id, snapshot) == actor
                and independent == other_independent
                and (not independent or rule_id == pending.rule_id) then
                return true
            end
        end
        return false
    end
    function api.check(now, others, peer, bypass_cooldown)
        api.sync()
        return policy(now, others, api.snapshot(), peer, nil, nil, bypass_cooldown == true)
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
        if key == 'enabled' or key == 'welcome' then reset() end
        if key == 'enabled' or key == 'ping' or key == 'output' then state.pings = {} end
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
    function api.set_rule_field_batch(kind,ids,field,value,role)
        api.sync();role=role or state.active_role
        if not profiles[role] or type(ids)~='table' or #ids==0
            or (field~='cooldown' and field~='mark_message' and field~='call_message') then
            return false,'无效批量规则设置'
        end
        local removing=value==nil or value==''
        local valid,converted=rule_value(field,value)
        if not valid then return false,'无效规则字段值' end
        local keys_by_id,unique={},{}
        for _,id in ipairs(ids) do
            local key=rule_key(kind,id)
            if not key then return false,'无效战备 ID' end
            if not unique[key] then unique[key]=true;keys_by_id[#keys_by_id+1]=key end
        end
        if #keys_by_id==0 then return false,'没有可更新的规则' end
        local candidate={host=copy(profiles.host),client=copy(profiles.client)}
        for _,key in ipairs(keys_by_id) do
            local rule=candidate[role].rules[key]
            if removing then
                if rule then
                    rule[field]=nil
                    if not next(rule) then candidate[role].rules[key]=nil end
                end
            else
                rule=rule or {};candidate[role].rules[key]=rule;rule[field]=converted
            end
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
    local function event_diagnostic(event,rule_id,result)
        if type(env.diagnostic)~='function' then return end
        local category=type(event)=='table' and categories[event.category] and event.category or 'unknown'
        local action=type(event)=='table' and (event.action=='summon' or event.action=='use' or event.action=='mark')
            and event.action or 'unknown'
        local stable_id='-'
        if type(rule_id)=='string' and (rule_id:match('^stratagem_%d+$') or rule_id:match('^enemy_[%a_]+$')) then
            stable_id=rule_id
        end
        local output=profiles[state.active_role] and profiles[state.active_role].output or 'unknown'
        pcall(env.diagnostic,category,action,stable_id,result,output)
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
                local allowed, reason = policy(now,#snapshot.remote,snapshot,key,nil,nil,true)
                if allowed and (not entry or pending.joined < entry.joined
                    or pending.joined == entry.joined and key < candidate) then candidate, entry = key, pending
                elseif not allowed then blocked=reason end
            end
        end
        if not candidate then state.status = blocked or '等待新人欢迎'; return false, state.status end
        local allowed, reason = policy(now, #snapshot.remote, snapshot, candidate,nil,nil,true)
        if not allowed then state.status = reason; return false, reason end
        local sent, send_why = api.send(api.format(api.stock_template(options.welcome_message, options.message_language),candidate,nil,nil,
            options.ping_sender_color==true,options.message_language), state.active_role)
        if sent == true then
            state.pending[candidate] = nil
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
        if not api.sync() then state.status='等待：主机身份尚未确认';event_diagnostic(event,nil,'role-unknown');return false,'retry' end
        if type(event) ~= 'table' or not categories[event.category] or type(event.key) ~= 'string'
            or #event.key > 128 or type(now) ~= 'number' or now ~= now
            or now == math.huge or now == -math.huge then event_diagnostic(event,nil,'invalid-event');return false end
        local rule_id,rule=event_rule(event)
        if not options.enabled then event_diagnostic(event,rule_id,'master-disabled');return false end
        if not options.ping then event_diagnostic(event,rule_id,'ping-disabled');return false end
        if not ping_enabled(event.category,event.action) then event_diagnostic(event,rule_id,'category-disabled');return false end
        if rule.enabled==false then event_diagnostic(event,rule_id,'rule-disabled');return false end
        for key, expires in pairs(state.ping_seen) do if now > expires then state.ping_seen[key] = nil end end
        if state.ping_seen[event.key] then event_diagnostic(event,rule_id,'duplicate-event');return false end
        local snapshot = api.snapshot()
        if not creator_present(event.creator_id, snapshot) then event_diagnostic(event,rule_id,'creator-not-in-roster');return false,'retry' end
        -- Cooldown-active notifications are consumed here rather than retained
        -- until their bucket reopens. Reserve the bucket while an accepted ping
        -- is pending so a burst cannot stack behind its first event.
        local allowed, _, code = policy(now,snapshot and #snapshot.remote or nil,
            snapshot,event.creator_id,rule_id,rule.cooldown)
        if (not allowed and code == 'cooldown-active')
            or (allowed and pending_ping_reserves(now,snapshot,event.creator_id,rule_id,rule.cooldown)) then
            state.ping_seen[event.key] = now + 30
            event_diagnostic(event,rule_id,'cooldown-active')
            return false
        end
        -- Keep the historical 16 normal slots and reserve 16 additional slots
        -- for urgent zero-cooldown events. Never evict a message already accepted.
        if #state.pings>=32 then event_diagnostic(event,rule_id,'queue-full');return false,'retry' end
        if rule.cooldown~=0 then
            local normal_count=0
            for _,pending in ipairs(state.pings) do
                if pending.cooldown~=0 then normal_count=normal_count+1 end
            end
            if normal_count>=16 then event_diagnostic(event,rule_id,'queue-full');return false,'retry' end
        end
        local message_language=options.message_language
        local label = api.category_label(event.category,message_language)
        local raw_target=type(event.display_name)=='string' and event.display_name or event.target
        if type(event.target_names)=='table' then
            local selected=event.target_names[message_language]
            if type(selected)=='string' and selected~='' then raw_target=selected end
        end
        local target = type(raw_target) == 'string' and plain(raw_target,200) or label
        local identity = identity_for(event.creator_id)
        local fallback_teammate=message_language=='en' and 'Teammate' or '队友'
        local short = identity and plain(identity.short, 16) or fallback_teammate
        if short == '' then short = fallback_teammate end
        local objective_types = {primary='主线任务', prerequisite='主线前置任务',
            optional='支线任务', tactical='战术任务', unknown='任务'}
        local objective_kind=tostring(event.objective_kind or 'unknown')
        local objective_type=api.phrase('objective.'..objective_kind,objective_types[objective_kind] or label,message_language)
        local summoned = event.action == 'summon'
        local executing = event.action == 'use'
        local objective_name=event.objective_name
        if type(event.objective_names)=='table' then
            local selected=event.objective_names[message_language]
            if type(selected)=='string' and selected~='' then objective_name=selected end
        end
        local action_text=summoned and api.phrase('action.summon','召唤',message_language)
            or executing and api.phrase('action.start','开始',message_language)
            or api.phrase('action.mark','标记',message_language)
        local replacements = {['{类别}']=label,['{category}']=label,
            ['{目标}']=plain(target,200),['{target}']=plain(target,200),['{stratagem}']=plain(target,200),['{战备}']=plain(target,200),
            ['{动作}']=action_text,['{action}']=action_text,
            ['{任务名}']=plain(type(objective_name)=='string' and objective_name or target,200),
            ['{objective}']=plain(type(objective_name)=='string' and objective_name or target,200),
            ['{task}']=plain(type(objective_name)=='string' and objective_name or target,200),
            ['{任务类型}']=objective_type or label,['{objective_type}']=objective_type or label,
            ['{task_type}']=objective_type or label,['{位置}']=position_text(event,message_language),
            ['{position}']=position_text(event,message_language)}
        local template = executing and options.task_stratagem_message or summoned and options.summon_message or options.ping_message
        template=((summoned or executing) and rule.call_message or not (summoned or executing) and rule.mark_message) or template
        template=api.stock_template(template,message_language)
        local text = api.format(template,event.creator_id,replacements,event.anonymous==true,
            options.ping_sender_color==true,message_language)
        local prefix = ''
        if options.ping_sender_prefix and not event.anonymous and type(event.creator_id) == 'string' then
            prefix = '[' .. short .. ']'
            if options.ping_sender_color and identity and type(identity.color) == 'string'
                and (#identity.color==6 or #identity.color==8) and identity.color:match('^%x+$') then
                prefix = attempt(env.colorize, prefix, identity.color) or prefix
            end
            prefix = prefix .. ' '
        end
        text = prefix .. (options.ping_sender_color and clip_color_markup(text, math.max(0, 511 - #prefix))
            or clipped(text, math.max(0, 511 - #prefix)))
        state.pings[#state.pings+1] = {key=event.key, category=event.category, action=event.action, rule_id=rule_id, cooldown=rule.cooldown, text=text, expires=now+15, retry=now,
            context=attempt(env.context), session=snapshot and snapshot.session, mine=snapshot and snapshot.mine,
            host=snapshot and snapshot.host, creator_id=event.creator_id, known_identity=identity ~= nil, role=state.active_role}
        state.ping_seen[event.key] = now + 30
        event_diagnostic(event,rule_id,'queued')
        return true
    end
    local function poll_ping(now, urgent_only)
        if not options.enabled or not options.ping then
            local reason=options.enabled and 'ping-disabled' or 'master-disabled'
            for _,pending in ipairs(state.pings) do event_diagnostic(pending,pending.rule_id,reason) end
            state.pings = {}; return false
        end
        if type(now) ~= 'number' or now ~= now then return false end
        local snapshot = api.snapshot()
        local context = attempt(env.context)
        for i=#state.pings,1,-1 do
            local p = state.pings[i]
            local reason
            if now > p.expires then reason='queue-expired'
            elseif not creator_present(p.creator_id, snapshot) then reason='creator-not-in-roster'
            elseif not ping_enabled(p.category,p.action) then reason='category-disabled'
            elseif p.context ~= context or p.session ~= (snapshot and snapshot.session)
                or p.mine ~= (snapshot and snapshot.mine) or p.host ~= (snapshot and snapshot.host) then reason='session-changed' end
            if not reason then
                local allowed, _, code = policy(now,snapshot and #snapshot.remote or nil,
                    snapshot,p.creator_id,p.rule_id,p.cooldown)
                if not allowed and code == 'cooldown-active' then reason='cooldown-active' end
            end
            if reason then
                event_diagnostic(p,p.rule_id,reason)
                table.remove(state.pings,i)
            end
        end
        local pending, index
        for i,p in ipairs(state.pings) do
            if now>=p.retry and (not urgent_only or p.cooldown==0) then
                local allowed,why=policy(now,snapshot and #snapshot.remote or nil,snapshot,p.creator_id,p.rule_id,p.cooldown)
                if allowed then pending,index=p,i;break end
                local reason=why=='等待：小队中没有其他玩家' and 'solo-disabled'
                    or why=='等待：计时尚未就绪' and 'clock-unavailable'
                    or why=='等待：该玩家的自动消息间隔中' and 'cooldown-active'
                    or why=='自动发送已关闭' and 'master-disabled' or 'policy-blocked'
                state.status=why;event_diagnostic(p,p.rule_id,reason)
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
            state.status='已发送玩家标记提示';event_diagnostic(pending,pending.rule_id,'sent');return true, state.status
        end
        pending.retry=now+5
        state.status='等待：标记提示暂未发送（5秒后重试）';event_diagnostic(pending,pending.rule_id,'send-refused')
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
    local MAX_NAME, MAX_PAYLOAD, MAX_SERIAL = 96, 1024 * 1024, 9007199254740991
    local MAX_LIBRARY = 16 * 1024 * 1024
    local LIB_MAGIC_V1 = "# AutoChat preset library v1\n"
    local LIB_MAGIC = "# AutoChat preset library v2\n"
    local FILE_MAGIC = "# AutoChat preset v1\n"
    local state = {error = nil, revision = 0}
    local entries, serial = {}, 0
    local builtins = {host={},client={}}

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
    for _, role in ipairs({'host','client'}) do
        local source=type(env.builtins)=='table' and env.builtins[role] or nil
        for _,item in ipairs(type(source)=='table' and source or {}) do
            if type(item)=='table' and type(item.id)=='string' and item.id:match('^builtin%-[%w%-]+$')
                and type(item.name)=='string' and type(item.payload)=='string' then
                local valid=validate_payload(item.payload)
                if valid then builtins[role][#builtins[role]+1]={id=item.id,role=role,name=item.name,payload=item.payload,builtin=true} end
            end
        end
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
    local function valid_role(role) return role == "host" or role == "client" end
    local function duplicate_name(name, role, except)
        for i = 1, #entries do
            if i ~= except and entries[i].role == role and entries[i].name == name then return true end
        end
        for _,item in ipairs(builtins[role] or {}) do if item.name==name then return true end end
        return false
    end
    local function find_builtin(id,role)
        for _,candidate in ipairs(role and {role} or {'host','client'}) do
            for _,item in ipairs(builtins[candidate] or {}) do
                if item.id==id then return item end
            end
        end
    end
    local function encode_library(items, next_serial)
        local out = {LIB_MAGIC, tostring(next_serial), "\n", tostring(#items), "\n"}
        for i = 1, #items do
            local e = items[i]
            out[#out + 1] = e.id .. "\n" .. e.role .. "\n" .. tostring(#e.name) .. "\n" .. tostring(#e.payload) .. "\n"
            out[#out + 1] = e.name; out[#out + 1] = e.payload
        end
        return table.concat(out)
    end
    local function parse_uint_line(data, pos, max)
        local e = data:find("\n", pos, true)
        if not e or e == pos or e - pos > 16 then return nil end
        local text = data:sub(pos, e - 1)
        if not text:match("^%d+$") or (#text > 1 and text:sub(1, 1) == "0") then return nil end
        local value = tonumber(text)
        if not value or value > max then return nil end
        return value, e + 1
    end
    local function parse_library(data)
        if type(data) ~= "string" or #data > MAX_LIBRARY then return nil, nil, "预设库格式损坏" end
        local legacy = data:sub(1, #LIB_MAGIC_V1) == LIB_MAGIC_V1
        local magic = legacy and LIB_MAGIC_V1 or LIB_MAGIC
        if data:sub(1, #magic) ~= magic then return nil, nil, "预设库格式损坏" end
        local pos = #magic + 1
        local saved_serial; saved_serial, pos = parse_uint_line(data, pos, MAX_SERIAL)
        if not saved_serial then return nil, nil, "预设库序号无效" end
        local count; count, pos = parse_uint_line(data, pos, MAX_LIBRARY)
        if count == nil then return nil, nil, "预设库数量无效" end
        local result, ids, names, highest = {}, {}, {}, 0
        for _ = 1, count do
            local id_end = data:find("\n", pos, true)
            if not id_end or id_end - pos < 9 or id_end - pos > 17 then return nil, nil, "预设编号无效" end
            local id = data:sub(pos, id_end - 1)
            local digits = id:match("^P(%d%d%d%d%d%d%d%d+)$")
            local number = digits and tonumber(digits)
            if not number or number < 1 or number > MAX_SERIAL or ids[id] then return nil, nil, "预设编号重复或无效" end
            ids[id] = true; if number > highest then highest = number end
            pos = id_end + 1
            local role = "host"
            if not legacy then
                local role_end=data:find("\n",pos,true)
                if not role_end then return nil,nil,"预设角色无效" end
                role=data:sub(pos,role_end-1);pos=role_end+1
                if not valid_role(role) then return nil,nil,"预设角色无效" end
            end
            local nl; nl, pos = parse_uint_line(data, pos, MAX_NAME)
            if not nl then return nil, nil, "预设名称长度无效" end
            local pl; pl, pos = parse_uint_line(data, pos, MAX_PAYLOAD)
            if nl == 0 or not pl or pl == 0 or pos + nl + pl - 1 > #data then return nil, nil, "预设长度无效" end
            local name = data:sub(pos, pos + nl - 1); pos = pos + nl
            local payload = data:sub(pos, pos + pl - 1); pos = pos + pl
            local name_key=role.."\0"..name
            if not valid_name(name) or names[name_key] or legacy and names[name] then return nil, nil, "预设名称重复或无效" end
            names[name_key], names[name] = true, true
            local valid = validate_payload(payload)
            if not valid then return nil, nil, "库内预设数据无效" end
            result[#result + 1] = {id = id, role=role, name = name, payload = payload}
        end
        if pos ~= #data + 1 or highest > saved_serial then return nil, nil, "预设库含有多余数据或无效序号" end
        if legacy then
            local legacy_entries={};for i,item in ipairs(result) do legacy_entries[i]=item end
            for _,item in ipairs(legacy_entries) do
                if saved_serial>=MAX_SERIAL then return nil,nil,"预设编号超出安全整数范围，旧版库未迁移" end
                saved_serial=saved_serial+1
                result[#result+1]={id=string.format("P%08.0f",saved_serial),role="client",name=item.name,payload=item.payload}
            end
        end
        return result, saved_serial, nil, legacy
    end
    local function persist(next_entries, next_serial)
        for _,item in ipairs(next_entries) do
            if not valid_role(item.role) then return false,"预设角色无效" end
        end
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
            local loaded, loaded_serial, err, migrated = parse_library(data)
            if not loaded then state.error = err
            elseif migrated then
                local migrated_bytes=encode_library(loaded,loaded_serial)
                if #migrated_bytes>MAX_LIBRARY then
                    state.error="旧版预设复制后会超过大小限制；原文件已保留"
                else
                    local ok,wrote,why=call(env.write_file,migrated_bytes)
                    if not ok or wrote~=true then state.error="旧版预设迁移未能写入；原文件已保留"..(why and ("："..tostring(why)) or "")
                    else entries,serial=loaded,loaded_serial;state.revision=1 end
                end
            else entries, serial = loaded, loaded_serial end
        end
    end
    local api = {state = state}
    local list_cache={host={revision=-1},client={revision=-1}}
    local function list_view(role)
        if role~=nil and not valid_role(role) then return {} end
        if role and list_cache[role].revision==state.revision then return list_cache[role].items end
        local result = {}
        for _,item in ipairs(role and builtins[role] or {}) do
            result[#result+1]={id=item.id,role=item.role,name=item.name,payload=item.payload,builtin=true}
        end
        for i = 1, #entries do
            if role==nil or entries[i].role==role then
                result[#result+1] = {id = entries[i].id, role=entries[i].role, name = entries[i].name, payload = entries[i].payload}
            end
        end
        if role then list_cache[role]={revision=state.revision,items=result} end
        return result
    end
    api._list_view=list_view
    function api.list(role)
        local source=list_view(role)
        local result={}
        for i,item in ipairs(source) do
            result[i]={id=item.id,role=item.role,name=item.name,payload=item.payload,builtin=item.builtin==true}
        end
        return result
    end
    local function ready() if state.error then return false, "预设库不可用：" .. tostring(state.error) end; return true end
    function api.save(name, role)
        local r, reason = ready(); if not r then return false, reason end
        if not valid_role(role) then return fail("请选择主机或客机预设池") end
        if not valid_name(name) then return fail("名称不能为空，且须为有效UTF-8（最多96字节）") end
        if duplicate_name(name,role) then return fail("此角色的预设名称已存在，请先重命名现有预设") end
        local ok, payload, why = call(env.capture, role, nil)
        if not ok or type(payload) ~= "string" then return fail(why or "读取当前配置失败") end
        local valid, vwhy = validate_payload(payload); if not valid then return fail(vwhy) end
        if serial >= MAX_SERIAL then return fail("预设编号已用尽") end
        local next_serial = serial + 1
        local next_entries = {}; for i = 1, #entries do next_entries[i] = entries[i] end
        local id = string.format("P%08.0f", next_serial)
        next_entries[#next_entries + 1] = {id = id, role=role, name = name, payload = payload}
        local saved, savewhy = persist(next_entries, next_serial)
        if not saved then return fail(savewhy) end
        return true, nil, id
    end
    function api.replace(id, role)
        local r, reason = ready(); if not r then return false, reason end
        if find_builtin(id) then return fail("内置预设不能覆盖") end
        local index, old = find(id); if not index then return fail("找不到该预设") end
        if not valid_role(role) or role~=old.role then return fail("所选预设不属于当前角色") end
        local ok, payload, why = call(env.capture, role, old.payload)
        if not ok or type(payload) ~= "string" then return fail(why or "读取当前配置失败") end
        local valid, vwhy = validate_payload(payload); if not valid then return fail(vwhy) end
        local next_entries = {}; for i = 1, #entries do next_entries[i] = i == index and {id = old.id, role=old.role, name = old.name, payload = payload} or entries[i] end
        local saved, savewhy = persist(next_entries, serial); if not saved then return fail(savewhy) end
        return true
    end
    function api.remove(id)
        local r, reason = ready(); if not r then return false, reason end
        if find_builtin(id) then return fail("内置预设不能删除") end
        local index = find(id); if not index then return fail("找不到该预设") end
        local next_entries = {}; for i = 1, #entries do if i ~= index then next_entries[#next_entries + 1] = entries[i] end end
        local saved, savewhy = persist(next_entries, serial); if not saved then return fail(savewhy) end
        return true
    end
    function api.rename(id, name)
        local r, reason = ready(); if not r then return false, reason end
        if find_builtin(id) then return fail("内置预设不能重命名") end
        local index, old = find(id); if not index then return fail("找不到该预设") end
        if not valid_name(name) then return fail("名称不能为空，且须为有效UTF-8（最多96字节）") end
        if duplicate_name(name, old.role, index) then return fail("此角色的预设名称已存在") end
        local next_entries = {}; for i = 1, #entries do next_entries[i] = i == index and {id = old.id, role=old.role, name = name, payload = old.payload} or entries[i] end
        local saved, savewhy = persist(next_entries, serial); if not saved then return fail(savewhy) end
        return true
    end
    function api.apply(id, role)
        local r, reason = ready(); if not r then return false, reason end
        local _, item = find(id); item=item or find_builtin(id,role); if not item then return fail("找不到该预设") end
        local valid, why = validate_payload(item.payload); if not valid then return fail(why) end
        local ok, applied, detail = call(env.apply, item.payload, role)
        if not ok or applied ~= true then return fail(detail or "应用预设失败") end
        return true
    end
    function api.export(id, role)
        local r, reason = ready(); if not r then return false, reason end
        local _, item = find(id); item=item or find_builtin(id,role); if not item then return fail("找不到该预设") end
        local valid, why = validate_payload(item.payload); if not valid then return fail(why) end
        local data = FILE_MAGIC .. tostring(#item.name) .. "\n" .. tostring(#item.payload) .. "\n" .. item.name .. item.payload
        local filename = "preset-" .. item.id .. ".autochat"
        local ok, wrote, detail, path = call(env.export_file, filename, data)
        if not ok or wrote ~= true then return fail(detail or "导出预设失败") end
        return true, nil, path or detail
    end
    function api.import(path, role)
        local r, reason = ready(); if not r then return false, reason end
        role=role or "host"
        if not valid_role(role) then return fail("请选择主机或客机预设池") end
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
        if duplicate_name(name,role) then return fail("此角色的预设名称已存在，请先重命名现有预设") end
        local valid, vwhy = validate_payload(payload); if not valid then return fail(vwhy) end
        if serial >= MAX_SERIAL then return fail("预设编号已用尽") end
        local next_serial = serial + 1
        local next_entries = {}; for i = 1, #entries do next_entries[i] = entries[i] end
        local id = string.format("P%08.0f", next_serial)
        next_entries[#next_entries + 1] = {id = id, role=role, name = name, payload = payload}
        local saved, savewhy = persist(next_entries, next_serial); if not saved then return fail(savewhy) end
        return true, nil, id
    end
    return api
end
-- END PRESET LIBRARY

M.game_language_reader = M.build_game_language_reader({ffi=ffi})
M.language = M.build_language({read_game=function() return M.game_language_reader.read() end})
M.ui_preview_language = nil -- UI_PREVIEW_LOCALE: build-time preview override; default UI follows game language.
function M.panel_locale()
    local locale=M.ui_preview_language
    if locale~='zh' and locale~='en' then locale=M.language.current() end
    return locale
end
function M.panel_text(chinese, english)
    return M.language.text(chinese, english, M.panel_locale())
end
function M.panel_status(value)
    return M.language.status(value, M.panel_locale())
end
function M.panel_is_chinese()
    return M.language.is_chinese(M.panel_locale())
end
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
    category_label = function(category,locale) return M.language.phrase('category.' .. tostring(category),locale) end,
    phrase = function(key,locale) return M.language.phrase(key,locale) end,
    stock_template = function(value,locale) return M.language.stock_template(value,locale) end,
    diagnostic = function(...) return M.record_event_diagnostic(...) end,
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
M.builtin_presets = (function()
    local stock=M.language.stock_templates()
    local chinese={welcome_message='欢迎加入小队！',ping_message='标记了{目标}',
        summon_message='{玩家名}召唤了{目标}',task_stratagem_message='{玩家名}正在开始{目标}',
        quick_timer_message='自动聊天测试消息'}
    local english={}
    for key,value in pairs(chinese) do english[key]=stock[value] or value end
    local result={host={},client={}}
    for _,role in ipairs({'host','client'}) do
        local cn=automation.export_default_profile(role,'zh',chinese)
        local en=automation.export_default_profile(role,'en',english)
        assert(type(cn)=='string' and type(en)=='string','failed to construct built-in default presets')
        result[role][1]={id='builtin-'..role..'-en',name='English Default Preset',payload=en}
        result[role][2]={id='builtin-'..role..'-zh',name='中文默认预设',payload=cn}
    end
    return result
end)()
preset_library = build_preset_library({
    read_file = function()
        return preset_read(PRESET_LIBRARY_PATH, 16 * 1024 * 1024 + 1, true)
    end,
    write_file = function(data) return preset_atomic_write(PRESET_LIBRARY_PATH, data) end,
    capture = function(role, old_payload)
        local previous={}
        if type(old_payload)=='string' then
            local valid,parsed=automation.validate_profile(old_payload)
            if valid and type(parsed.plugins)=='table' then previous=parsed.plugins end
        end
        local blobs=previous
        if REGISTRY and type(REGISTRY.capture_presets)=='function' then
            local captured,why=REGISTRY.capture_presets(role,previous)
            if type(captured)~='table' then return nil,why or '无法捕获插件预设' end
            blobs=captured
        end
        return automation.export_profile(role,M.profile_tasks(role),blobs)
    end,
    validate = function(payload) return automation.validate_profile(payload) end,
    builtins = M.builtin_presets,
    apply = function(payload, role) return apply_preset_snapshot(payload, role) end,
    diagnostic = function(category, action, stable_id, result, output)
        note('event flow category='..tostring(category)..' action='..tostring(action)
            ..' rule='..tostring(stable_id)..' result='..tostring(result)..' output='..tostring(output))
    end,
    export_file = function(filename, data)
        if type(filename) ~= 'string'
            or not filename:match('^preset%-P%d%d%d%d%d%d%d%d+%.autochat$')
                and not filename:match('^preset%-builtin%-%a[%w%-]*%.autochat$')
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

-- BEGIN STRATAGEM NAMES ZH
-- Curated Simplified Chinese display names keyed by stable StratagemInfo ID.
-- The catalog uses these labels only for display; native identities remain English and unchanged.
local STRATAGEM_NAMES_ZH = {
    [5185868] = "AX/TX-13 腐息",
    [12688472] = "MD-6 反步兵雷区",
    [14345846] = "M-105 盟友",
    [45875024] = "B-100 便捷式地狱火炸弹",
    [65564476] = "未知战备",
    [73468749] = "LIFT-860 悬浮背包",
    [101457192] = "装填高爆弹",
    [115737856] = "未知战备",
    [153819019] = "GL-52 缓和使者",
    [255298804] = "未知战备",
    [272480476] = "SH-51 定向护盾",
    [295629711] = "EXO-45 “爱国者”外骨骼装甲",
    [336693041] = "S-11 矛枪",
    [458198946] = "MG-43 机枪",
    [460870572] = "TD-110 风暴漩涡",
    [474724029] = "A/FLAM-40 火焰喷射哨戒炮",
    [485866824] = "AX/AR-23 护卫犬",
    [509712523] = "未知战备",
    [512147393] = "GL-28 弹链式榴弹发射器",
    [533318241] = "MG-206 重机枪",
    [563851843] = "破门型战斗机甲",
    [599201298] = "超级地球旗帜",
    [623391597] = "A/G-16 加特林哨戒炮",
    [644090457] = "MD-8 毒气地雷",
    [650447969] = "未知战备",
    [681028671] = "未知战备",
    [685210453] = "未知战备",
    [705279885] = "便携式通信中继站",
    [716088572] = "未知战备",
    [716273285] = "未知战备",
    [717707279] = "A/MLS-4X 火箭哨戒炮",
    [762584056] = "E/AT-12 反坦克炮台",
    [774795224] = "未知战备",
    [854563507] = "A/AC-8 自动哨戒炮",
    [863373678] = "未知战备",
    [867876502] = "重新补给",
    [871315230] = "撤离信标",
    [875551083] = "AC-8 机炮",
    [890972990] = "StA-X3 W.A.S.P.发射器",
    [905054095] = "未知战备",
    [913592461] = "未知战备",
    [929878807] = "未知战备",
    [951988742] = "AX/LAS-5 漫游车",
    [960389145] = "A/LAS-98 激光哨戒炮",
    [970450596] = "轨道激光炮",
    [992079466] = "ARC-3 电弧发射器",
    [1005987791] = "未知战备",
    [1042447730] = "未知战备",
    [1053576110] = "B-100 便捷式地狱火炸弹",
    [1063322614] = "轨道120MM高爆弹火力网",
    [1091253198] = "未知战备",
    [1125307795] = "AX/FLAM-75 热狗",
    [1232978203] = "未知战备",
    [1238358532] = "“飞鹰”空袭",
    [1280711447] = "轨道电磁冲击波攻击",
    [1290499887] = "EXO-49 “解放者”外骨骼装甲",
    [1295431756] = "未知战备",
    [1298599997] = "GR-8 无后坐力炮",
    [1337271929] = "MS-11 单兵导弹发射井",
    [1426041086] = "未知战备",
    [1432571981] = "FLAM-40 火焰喷射器",
    [1449420233] = "未知战备",
    [1503060624] = "未知战备",
    [1560416221] = "轨道空爆攻击",
    [1567517764] = "未知战备",
    [1582497738] = "A/M-12 迫击哨戒炮",
    [1606251952] = "未知战备",
    [1685231450] = "“飞鹰”烟雾攻击",
    [1692135420] = "AX/ARC-3 K-9",
    [1695682779] = "未知战备",
    [1753436707] = "LIFT-850 喷射背包",
    [1813634375] = "EAT-700 消耗性凝固汽油弹",
    [1824787072] = "未知战备",
    [1907808218] = "B-1 补给背包",
    [1979913877] = "“飞鹰”110MM火箭巢",
    [2002187052] = "TD-220 堡垒MK XVI",
    [2007887745] = "RL-77 空爆火箭弹发射器",
    [2040137691] = "“飞鹰”凝固汽油弹空袭",
    [2084654169] = "轨道加特林火力网",
    [2185045091] = "LIFT-182 传送背包",
    [2186648412] = "战术摄像机",
    [2207713849] = "APW-1 反器材步枪",
    [2229216190] = "未知战备",
    [2230051894] = "未知战备",
    [2232989803] = "MLS-4X 突击兵",
    [2239174926] = "MD-17 反坦克地雷",
    [2265180087] = "CQC-1 唯一真旗",
    [2266266587] = "未知战备",
    [2271469939] = "B/FLAM-80 焚燃者",
    [2281932031] = "FX-12 防护罩生成中继器",
    [2319566343] = "未知战备",
    [2402590523] = "A/ARC-3 特斯拉塔",
    [2480128092] = "E/GL-21 掷弹兵防卫墙",
    [2587901119] = "未知战备",
    [2625074523] = "LAS-99 类星体加农炮",
    [2636699686] = "M-103 补给型快速侦察载具",
    [2663642538] = "未知战备",
    [2670122272] = "未知战备",
    [2720892179] = "未知战备",
    [2742141597] = "MD-I4 燃烧地雷",
    [2744472229] = "轨道炮攻击",
    [2808191861] = "“飞鹰”空袭支援",
    [2822568285] = "LAS-98 激光大炮",
    [2846457047] = "M-104 炽灼型快速侦察载具",
    [2902516083] = "轨道凝固汽油弹火力网",
    [2919842659] = "E/MG-101 重机枪部署支架",
    [2934950455] = "EAT-411 荡平者",
    [2985177386] = "未知战备",
    [3001049275] = "未知战备",
    [3078242205] = "RS-422 磁轨炮",
    [3085503322] = "A/M-23 电磁冲击波迫击哨戒炮",
    [3086305673] = "EXO-51 “伐木者”外骨骼装甲",
    [3108516875] = "轨道380MM高爆弹火力网",
    [3183339606] = "A/GM-17 瓦斯迫击哨戒炮",
    [3193297673] = "轨道毒气攻击",
    [3193487269] = "未知战备",
    [3275255096] = "未知战备",
    [3279813377] = "轨道游走火力网",
    [3288352984] = "M-1000 重装机枪",
    [3300666223] = "上传数据",
    [3316399568] = "未知战备",
    [3330450692] = "CQC-20 破门锤",
    [3343676429] = "GL-21 榴弹发射器",
    [3353508219] = "SH-20 防弹护盾背包",
    [3413606544] = "EAT-17 消耗性反坦克武器",
    [3455841218] = "M-1000 重装机枪",
    [3523620028] = "轨道精准攻击",
    [3572024208] = "CQC-9 除叶工具",
    [3656370131] = "“飞鹰”集束炸弹",
    [3702563421] = "装填反坦克弹",
    [3713568312] = "轨道烟雾攻击",
    [3722314010] = "超级地球旗帜",
    [3748434442] = "B/MD C4背包",
    [3753216434] = "EAT-17 消耗性反坦克武器",
    [3796132384] = "未知战备",
    [3837064536] = "未知战备",
    [3843705076] = "SH-32 防护罩生成包",
    [3868299561] = "未知战备",
    [3923676543] = "FAF-14 飞矛",
    [3928947721] = "未知战备",
    [3935317067] = "M-102 炮手快速侦察载具",
    [3989310204] = "地狱火炸弹",
    [4119049995] = "“飞鹰”500KG炸弹",
    [4152191751] = "TX-41 灭菌器",
    [4177070437] = "未知战备",
    [4196275240] = "“飞鹰”毒气空袭",
    [4239785897] = "A/MG-43 哨戒机枪",
    [4261593827] = "PLAS-45 纪元",
    [4264661046] = "装填霰弹",
}
-- Inline this fragment before build_stratagem_catalog and pass STRATAGEM_NAMES_ZH as env.names_zh.
-- END STRATAGEM NAMES ZH
-- BEGIN STRATAGEM NAMES EN
-- Readable English labels for the current 149 stable StratagemInfo IDs.
-- Curated against the local ID/debug-name snapshot and Chinese display map.
-- This is not an exported official English localization table. Several mission,
-- tutorial, reward, and unused records need in-game/native-string confirmation.
M.STRATAGEM_NAMES_EN = {
    [5185868] = 'AX/TX-13 Dog Breath',
    [12688472] = 'MD-6 Anti-Personnel Minefield',
    [14345846] = 'M-105 Stalwart',
    [45875024] = 'B-100 Portable Hellbomb',
    [65564476] = 'Unknown stratagem',
    [73468749] = 'LIFT-860 Hover Pack',
    [101457192] = 'Load High-Explosive Shells',
    [115737856] = 'Unknown stratagem',
    [153819019] = 'GL-52 De-Escalator',
    [255298804] = 'Unknown stratagem',
    [272480476] = 'SH-51 Directional Shield',
    [295629711] = 'EXO-45 Patriot Exosuit',
    [336693041] = 'S-11 Speargun',
    [458198946] = 'MG-43 Machine Gun',
    [460870572] = 'TD-110 Maelstrom',
    [474724029] = 'A/FLAM-40 Flame Sentry',
    [485866824] = 'AX/AR-23 Guard Dog',
    [509712523] = 'Unknown stratagem',
    [512147393] = 'GL-28 Belt-Fed Grenade Launcher',
    [533318241] = 'MG-206 Heavy Machine Gun',
    [563851843] = 'EXO-84 Breacher Exosuit',
    [599201298] = 'Super Earth Flag',
    [623391597] = 'A/G-16 Gatling Sentry',
    [644090457] = 'MD-8 Gas Mines',
    [650447969] = 'Seismic Probe',
    [681028671] = 'Unknown stratagem',
    [685210453] = 'Prospecting Drill',
    [705279885] = 'Portable Comms Relay',
    [716088572] = 'Unknown stratagem',
    [716273285] = 'Unknown stratagem',
    [717707279] = 'A/MLS-4X Rocket Sentry',
    [762584056] = 'E/AT-12 Anti-Tank Emplacement',
    [774795224] = 'Unknown stratagem',
    [854563507] = 'A/AC-8 Autocannon Sentry',
    [863373678] = 'Unknown stratagem',
    [867876502] = 'Resupply',
    [871315230] = 'Unknown stratagem',
    [875551083] = 'AC-8 Autocannon',
    [890972990] = 'StA-X3 W.A.S.P. Launcher',
    [905054095] = 'Unknown stratagem',
    [913592461] = 'Unknown stratagem',
    [929878807] = 'Unknown stratagem',
    [951988742] = 'AX/LAS-5 Rover',
    [960389145] = 'A/LAS-98 Laser Sentry',
    [970450596] = 'Orbital Laser',
    [992079466] = 'ARC-3 Arc Thrower',
    [1005987791] = 'Unknown stratagem',
    [1042447730] = 'Unknown stratagem',
    [1053576110] = 'B-100 Portable Hellbomb',
    [1063322614] = 'Orbital 120mm HE Barrage',
    [1091253198] = 'Unknown stratagem',
    [1125307795] = 'AX/FLAM-75 Hot Dog',
    [1232978203] = 'Unknown stratagem',
    [1238358532] = 'Eagle Airstrike',
    [1280711447] = 'Orbital EMS Strike',
    [1290499887] = 'EXO-49 Emancipator Exosuit',
    [1295431756] = 'Unknown stratagem',
    [1298599997] = 'GR-8 Recoilless Rifle',
    [1337271929] = 'MS-11 Solo Silo',
    [1426041086] = 'Unknown stratagem',
    [1432571981] = 'FLAM-40 Flamethrower',
    [1449420233] = 'Unknown stratagem',
    [1503060624] = 'Unknown stratagem',
    [1560416221] = 'Orbital Airburst Strike',
    [1567517764] = 'Unknown stratagem',
    [1582497738] = 'A/M-12 Mortar Sentry',
    [1606251952] = 'Cargo Container',
    [1685231450] = 'Eagle Smoke Strike',
    [1692135420] = 'AX/ARC-3 K-9',
    [1695682779] = 'Orbital Illumination Flare',
    [1753436707] = 'LIFT-850 Jump Pack',
    [1813634375] = 'EAT-700 Expendable Napalm',
    [1824787072] = 'Unknown stratagem',
    [1907808218] = 'B-1 Supply Pack',
    [1979913877] = 'Eagle 110mm Rocket Pods',
    [2002187052] = 'TD-220 Bastion MK XVI',
    [2007887745] = 'RL-77 Airburst Rocket Launcher',
    [2040137691] = 'Eagle Napalm Airstrike',
    [2084654169] = 'Orbital Gatling Barrage',
    [2185045091] = 'LIFT-182 Warp Pack',
    [2186648412] = 'Tactical Video Camera',
    [2207713849] = 'APW-1 Anti-Materiel Rifle',
    [2229216190] = 'Unknown stratagem',
    [2230051894] = 'Unknown stratagem',
    [2232989803] = 'MLS-4X Commando',
    [2239174926] = 'MD-17 Anti-Tank Mines',
    [2265180087] = 'CQC-1 One True Flag',
    [2266266587] = 'Unknown stratagem',
    [2271469939] = 'B/FLAM-80 Cremator',
    [2281932031] = 'FX-12 Shield Generator Relay',
    [2319566343] = 'SSSD Delivery',
    [2402590523] = 'A/ARC-3 Tesla Tower',
    [2480128092] = 'E/GL-21 Grenadier Battlement',
    [2587901119] = 'Unknown stratagem',
    [2625074523] = 'LAS-99 Quasar Cannon',
    [2636699686] = 'M-103 Supply FRV',
    [2663642538] = 'Unknown stratagem',
    [2670122272] = 'Cargo Container',
    [2720892179] = 'Unknown stratagem',
    [2742141597] = 'MD-I4 Incendiary Mines',
    [2744472229] = 'Orbital Railcannon Strike',
    [2808191861] = 'Eagle Air Support',
    [2822568285] = 'LAS-98 Laser Cannon',
    [2846457047] = 'M-104 Incinerator FRV',
    [2902516083] = 'Orbital Napalm Barrage',
    [2919842659] = 'E/MG-101 HMG Emplacement',
    [2934950455] = 'EAT-411 Leveller',
    [2985177386] = 'SEAF Artillery',
    [3001049275] = 'Unknown stratagem',
    [3078242205] = 'RS-422 Railgun',
    [3085503322] = 'A/M-23 EMS Mortar Sentry',
    [3086305673] = 'EXO-51 Lumberer Exosuit',
    [3108516875] = 'Orbital 380mm HE Barrage',
    [3183339606] = 'A/GM-17 Gas Mortar Sentry',
    [3193297673] = 'Orbital Gas Strike',
    [3193487269] = 'SoS Beacon',
    [3275255096] = 'Unknown stratagem',
    [3279813377] = 'Orbital Walking Barrage',
    [3288352984] = 'M-1000 Maxigun',
    [3300666223] = 'Upload Data',
    [3316399568] = 'Unknown stratagem',
    [3330450692] = 'CQC-20 Breaching Hammer',
    [3343676429] = 'GL-21 Grenade Launcher',
    [3353508219] = 'SH-20 Ballistic Shield Backpack',
    [3413606544] = 'EAT-17 Expendable Anti-Tank',
    [3455841218] = 'M-1000 Maxigun',
    [3523620028] = 'Orbital Precision Strike',
    [3572024208] = 'CQC-9 Defoliation Tool',
    [3656370131] = 'Eagle Cluster Bomb',
    [3702563421] = 'Load Anti-Tank Shells',
    [3713568312] = 'Orbital Smoke Strike',
    [3722314010] = 'Super Earth Flag',
    [3748434442] = 'B/MD C4 Pack',
    [3753216434] = 'EAT-17 Expendable Anti-Tank',
    [3796132384] = 'Smoke-Enhanced Walking Barrage',
    [3837064536] = 'Eagle Rearm',
    [3843705076] = 'SH-32 Shield Generator Pack',
    [3868299561] = 'Unknown stratagem',
    [3923676543] = 'FAF-14 Spear',
    [3928947721] = 'SSSD Delivery',
    [3935317067] = 'M-102 Gunner FRV',
    [3989310204] = 'Unknown stratagem',
    [4119049995] = 'Eagle 500kg Bomb',
    [4152191751] = 'TX-41 Sterilizer',
    [4177070437] = 'Call in Super Destroyer',
    [4196275240] = 'Eagle Gas Airstrike',
    [4239785897] = 'A/MG-43 Machine Gun Sentry',
    [4261593827] = 'PLAS-45 Epoch',
    [4264661046] = 'Load Shotgun Shells',
}

-- END STRATAGEM NAMES EN
-- BEGIN STRATAGEM CATALOG
-- Read-only StratagemInfo discovery for Steam build 25480438.
-- env.base() must enforce the supported game.dll fingerprint. Extra pins prove
-- the row/name/icon consumers. Layout facts and provenance: docs/STRATAGEM-REFERENCE-0.8.0.md.
-- No game calls, writes, asset loading, or static native-type identity mapping.
local function build_stratagem_catalog(env)
    local names_zh=type(env.names_zh)=='table' and env.names_zh or {}
    local names_en=type(env.names_en)=='table' and env.names_en or {}
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
                    local name_zh=names_zh[id]
                    if type(name_zh)~='string' or name_zh=='' then name_zh='未知战备' end
                    local name_en=names_en[id]
                    if type(name_en)~='string' or name_en=='' then name_en='Unknown stratagem' end
                    local display_name=names_zh[id]
                    if type(display_name)~='string' or display_name=='' then display_name='战备 #'..tostring(id) end
                    local display_name_en=names_en[id]
                    if type(display_name_en)~='string' or display_name_en=='' then display_name_en='Stratagem #'..tostring(id) end
                    local row={id=id,type=kind,name_key=name_key,name_upper_key=upper_key,name=debug_name,
                        display_name=display_name,display_name_en=display_name_en,
                        target_names={zh=name_zh,en=name_en},
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

local stratagem_catalog=build_stratagem_catalog({base=supported_game_base,read=read_at,names_zh=STRATAGEM_NAMES_ZH,names_en=M.STRATAGEM_NAMES_EN})
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
        local native=type(event.target_names)=='table' and event.target_names.native_name or nil
        local names=type(row.target_names)=='table' and {zh=row.target_names.zh,en=row.target_names.en}
            or {zh=row.display_name,en=row.display_name_en}
        if type(native)=='string' and native~='' then
            local lower=native:lower():match('^%s*(.-)%s*$')
            local generic=lower=='特殊地点' or lower=='special location'
                or lower=='敌方单位' or lower=='enemy unit' or lower=='任务交互物'
                or lower=='objective terminal' or lower=='任务终端' or lower=='mission terminal'
                or lower=='战略配备' or lower=='strategic asset' or lower=='stratagem'
                or lower=='普通物资' or lower=='supplies'
            local native_is_han=false
            local native_is_ascii=true
            local i=1
            while i<=#native do
                local a=native:byte(i)
                if a>=0x80 then native_is_ascii=false end
                if a>=0xE0 and a<=0xEF and i+2<=#native then
                    local b,c=native:byte(i+1,i+2)
                    if b>=0x80 and b<=0xBF and c>=0x80 and c<=0xBF then
                        local code=(a-0xE0)*4096+(b-0x80)*64+(c-0x80)
                        if (code>=0x3400 and code<=0x4DBF) or (code>=0x4E00 and code<=0x9FFF) then
                            native_is_han=true
                        end
                        i=i+3
                    else i=i+1 end
                elseif a>=0xC2 and a<=0xDF and i+1<=#native then i=i+2
                elseif a>=0xF0 and a<=0xF4 and i+3<=#native then i=i+4
                else i=i+1 end
            end
            if not generic and native_is_han then names.zh=native
            elseif not generic and native_is_ascii then names.en=native end
        end
        event.target_names=names
        event.display_name=M.language.is_chinese() and row.display_name or row.display_name_en
    else
        local rule=stratagem_catalog.resolve_rule_resource(event.resource)
            or stratagem_catalog.resolve_rule_name_key(event.localization_key)
        if rule then event.stratagem_rule_id=rule.id;event.stratagem_group=rule.group;event.stratagem_ambiguous=true end
    end
end
function M.debug_enrich_stratagem_event(event,now)enrich_stratagem_event(event,now)end
M._published_ping_events=setmetatable({}, {__mode='k'})
function M.debug_emit_ping_event(event,now)
    enrich_stratagem_event(event,now)
    if type(event)=='table' and type(event.target_names)~='table' and type(event.resource)=='string' then
        local row=M.special_targets and M.special_targets.resolve(event.resource)
        if row then event.target_names={zh=row.name_zh,en=row.name_en} end
    end
    event.type='ping'
    local accepted,disposition=automation.push_ping(event,now)
    local published_ping_events=M._published_ping_events
    local notified=published_ping_events[event]
    if notified==nil then
        -- Set before invoking plugin code so a reentrant publish cannot duplicate it.
        published_ping_events[event]=0
        notified=REGISTRY and REGISTRY.publish(event) or 0
        published_ping_events[event]=notified
    end
    if disposition=='retry' then return false,'retry' end
    return accepted==true or notified>0
end

-- BEGIN SPECIAL TARGETS
-- Verified target-name enrichment for special resources.
-- The six shell IDs are Spottable + ObjectiveShell entries in current RawData
-- EntityComponentMap (game version 1.007.100). They remain ordinary building
-- events and do not introduce a separate user-facing category or rule system.
M.build_special_targets = function()
    local rows = {
        {resource='DC19126D15692D04', name_zh='大炮 炸弹', name_en='Explosive (SEAF)'},
        {resource='6B7EE87FB2EC6455', name_zh='大炮 高爆弹', name_en='High-Yield Explosive (SEAF)'},
        {resource='E09FCB5A280ACB1D', name_zh='大炮 迷你核弹', name_en='Mini Nuke (SEAF)'},
        {resource='E4BE3FDF0C857B7F', name_zh='大炮 凝固汽油弹', name_en='Napalm (SEAF)'},
        {resource='F598598C47617605', name_zh='大炮 烟雾弹', name_en='Smoke (SEAF)'},
        {resource='C02C2623B6359BB3', name_zh='大炮 静电场', name_en='Static Field (SEAF)'},
        -- Exact-hash fallback for a user-confirmed live direct-target event:
        -- sanitized capture was kind=10, target present, resource=0ABED3586E397289,
        -- generic location key=3585962803, identity_link=true. The immediately
        -- preceding user action was the Salute drop pod mark. Static asset path:
        -- work/eagle-stingray-research/stingray-archive-list.txt:93034-93035
        -- (super_earth_cache.physics/.unit); this is a contextual fallback, not
        -- an official localized label and must not be generalized to other caches.
        {resource='0ABED3586E397289', name_zh='坠落舱', name_en='Super Earth cache'},
    }
    local by_resource = {}
    for _, row in ipairs(rows) do
        assert(row.resource:match('^[0-9A-F][0-9A-F]+$') and #row.resource == 16,
            'invalid special target resource')
        assert(not by_resource[row.resource], 'duplicate special target resource')
        by_resource[row.resource] = row
    end
    return {
        list = function() return rows end,
        resolve = function(resource)
            if type(resource) ~= 'string' then return nil end
            return by_resource[resource:upper()]
        end,
    }
end

-- END SPECIAL TARGETS
M.special_targets = M.build_special_targets()
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
-- Resource pickups are classified separately so the main policy can keep them
-- behind its supplies switch rather than mislabeling them as buildings.
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
    ['019F988FA225DD1C'] = {'building', '逃生舱', 0, 'Escape Pod'},
    ['01A88312C8889D5F'] = {'building', '炮塔控制终端', 0, 'Turret Control Terminal'},
    ['051DA4B57216A005'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['06D3C4720E642FC1'] = {'building', '虫卵群', 0, 'Egg Cluster'},
    ['0722B3A72ADE6CB1'] = {'building', 'TCS 主塔', 0, 'TCS Main Tower'},
    ['073270650F859DD0'] = {'building', '装有化学武器的背包', 3054644200, 'Chemical Weapons Backpack'},
    ['0801B6B3C5D12EBC'] = {'building', '地面全地形采集钻机', 3023900891, 'Ground-Based All-Terrain Excavator'},
    ['095686275A113614'] = {'building', '尖啸虫巢穴', 3496786382, 'Shrieker Nest'},
    ['0A12D5A29CDF2D40'] = {'building', '撤离信标', 0, 'Extraction Beacon'},
    ['0DC9084E50C051F3'] = {'building', '铂金条', 2492072473, 'Platinum Bar'},
    ['0DF874E208040D2F'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['0E88F182E83A4275'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['0F1A0189B327C5CB'] = {'building', '超级固态硬盘', 714952129, 'SSSD'},
    ['10E44156F08786EF'] = {'building', '生物处理器', 0, 'Bio-Processor'},
    ['1262CD07B196AAC3'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['1312B769F47256D9'] = {'building', 'SEAF 防空导弹阵地', 1563965062, 'SEAF Anti-Air Missile Site'},
    ['142637570A721CB9'] = {'building', '轨道炮弹药供给装置', 0, 'Orbital Cannon Ammo Supply'},
    ['15031543894C3F3C'] = {'building', 'TCS 孢子喷涌体', 3139947901, 'TCS Spore Spewer'},
    ['1556FE9780D5D52D'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['15E2A2B11BA78C5A'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['162256BD224F6265'] = {'building', '加注站终端', 0, 'Refueling Station Terminal'},
    ['16D7BA33ED511664'] = {'building', '控制塔终端', 0, 'Control Tower Terminal'},
    ['1A3B52A4D3F166F7'] = {'building', '光能者城市巨炮终端', 0, 'Illuminate City Cannon Terminal'},
    ['1B633762874A709A'] = {'building', '首都防御设施', 0, 'Capital Defense Facility'},
    ['1C2360811101BCCE'] = {'building', '冷却管道', 0, 'Cooling Pipe'},
    ['1D72EBD1A6916E67'] = {'building', '装配设施曲柄', 0, 'Assembly Facility Crank'},
    ['22CC0ED4CEB9CB68'] = {'building', '机器人制造厂', 3794527478, 'Automaton Fabricator'},
    ['23C85E970FB46685'] = {'building', '战备干扰器', 0, 'Stratagem Jammer'},
    ['245F7D8792CD23E5'] = {'building', '军事通信交付点', 0, 'Military Communications Delivery Point'},
    ['24ACA2B4D15D2E2F'] = {'building', '发电机组', 0, 'Generator Unit'},
    ['25C5B9818EF934E3'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['2670E0047B2EB409'] = {'building', '探测塔', 0, 'Detector Tower'},
    ['2778F620A6E414AF'] = {'building', '光能者气象装置核心', 0, 'Illuminate Weather Device Core'},
    ['2862C5AFC2E837BA'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['29D0A1DFB5FD811F'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['2B581BBB45DA1225'] = {'building', '燃料提取终端', 0, 'Fuel Extraction Terminal'},
    ['2B5D3186EE3A4A84'] = {'building', '变异虫卵', 555942570, 'Mutated Eggs'},
    ['2D3BC1683A54298D'] = {'building', '情报包裹', 3717706265, 'Intelligence Package'},
    ['317B2C0E4D10E293'] = {'building', '炮塔控制数据交付点', 0, 'Turret Control Data Drop-off'},
    ['319388D1D8ACB8F3'] = {'building', 'TCS 任务终端', 0, 'TCS Mission Terminal'},
    ['3231BD912357A9E1'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['33F2BCDAE3A12592'] = {'building', '超级固态硬盘', 714952129, 'SSSD'},
    ['346C42FD9C915904'] = {'building', '轨道炮终端', 0, 'Orbital Cannon Terminal'},
    ['36C5E772F8A3B9D3'] = {'building', '超级固态硬盘', 714952129, 'SSSD'},
    ['36CC8EAD2BB18D78'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['372481E910C05A76'] = {'building', '战术摄像机', 2071327434, 'Tactical Camera'},
    ['37EB67CB7ACE7410'] = {'building', '能量核心站', 0, 'Energy Core Station'},
    ['3A28A51BAA029E1A'] = {'building', '抽油任务钻机', 3477736393, 'Oil Extraction Drill'},
    ['3A2CEF12ED32A088'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['3CE56937E0BD28BD'] = {'building', '工厂区域大门', 0, 'Factory Sector Gate'},
    ['3DE2415EA33B6897'] = {'building', '黑匣子', 4046999266, 'Black Box'},
    ['3E099DDF97ACF85F'] = {'building', '样本箱', 1332022394, 'Sample Box'},
    ['3E993C23A25E6B88'] = {'building', '机器人任务数据', 714952129, 'Automaton Mission Data'},
    ['3F2C34C69CFC94B2'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['3F70E3503A3293F9'] = {'building', '鹈鹕燃料运输机', 0, 'Pelican Fuel Transport'},
    ['3F8734AEC15B82AD'] = {'building', '鹈鹕飞船', 0, 'Pelican'},
    ['4012166966A9E6E9'] = {'building', 'SEAF 火炮弹药', 3660636186, 'SEAF Artillery Shells'},
    ['4232EE48E2CFD24E'] = {'building', '机器人制造厂', 644365486, 'Automaton Fabricator'},
    ['423FF97D57AB04F5'] = {'building', '地面全地形采集钻机', 3023900891, 'Ground-Based All-Terrain Excavator'},
    ['424036E9F7DE9A1E'] = {'building', '冷却阀门', 0, 'Cooling Valve'},
    ['42786DC1DD1EACAD'] = {'building', '核导弹', 4280970126, 'Nuclear Missile'},
    ['43EC60F66E7E046B'] = {'building', '装有化学武器的背包', 3054644200, 'Chemical Weapons Backpack'},
    ['44748FFC63F78A72'] = {'building', '“虫窝破裂者”钻机', 1998289914, 'Hive Breaker Drill'},
    ['459DD5EB8C68C63F'] = {'building', '工厂区域入口', 0, 'Factory Sector Entrance'},
    ['460576BBDCF770D0'] = {'building', '军械库发电机', 0, 'Armory Generator'},
    ['46918A7483D70F3E'] = {'building', '任务交互物', 2851008997, 'Mission Item'},
    ['4747668D063EEC06'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['4776A1CF3F19A13B'] = {'building', '潜行虫巢穴', 3277626454, 'Stalker Nest'},
    ['480445A33039CE5E'] = {'building', '虫卵群', 0, 'Egg Cluster'},
    ['4A3E722B5A865E38'] = {'building', '黑匣子', 3346432464, 'Black Box'},
    ['4C182656063F121A'] = {'building', '控制塔数据交付点', 0, 'Control Tower Data Drop-off'},
    ['4FB8EB356AC8553E'] = {'building', '机器人制造厂', 3794527478, 'Automaton Fabricator'},
    ['5158E582FBEB26BD'] = {'building', '机器人制造厂', 3794527478, 'Automaton Fabricator'},
    ['516E4FA1D2AE46AE'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['52D52230745B66A0'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['534000F7801EA508'] = {'building', '数据收集交付点', 0, 'Data Collection Drop-off'},
    ['542A14BA4D755F4E'] = {'building', '雷达站终端', 0, 'Radar Station Terminal'},
    ['54B66A0D35FDF785'] = {'building', '有机物提取终端', 0, 'Organic Matter Extraction Terminal'},
    ['5684D928C9AB00D1'] = {'building', '发射代码', 767789391, 'Launch Codes'},
    ['5726276FED2241B3'] = {'building', '轨道炮弹药', 2928771667, 'Orbital Cannon Ammunition'},
    ['57DB57121F3E7ED2'] = {'building', '非法广播塔', 0, 'Illegal Broadcast Tower'},
    ['5852B7D2F865966C'] = {'building', '采油机', 0, 'Oil Extractor'},
    ['5A14BF4098BF4259'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['5CF84155E60C6E4D'] = {'building', '机械虫洞', 3277626454, 'Mechanical Wormhole'},
    ['60544E51EE260967'] = {'building', '光能者城市巨炮', 0, 'Illuminate City Cannon'},
    ['62D2C45A8B9703CC'] = {'building', '中继塔', 1549126177, 'Relay Tower'},
    ['646F5AEBDFF603CB'] = {'building', '黑匣子交付点', 0, 'Black Box Drop-off'},
    ['68053EAE33FFA084'] = {'building', '光能者科技枢纽中枢', 0, 'Illuminate Tech Hub Core'},
    ['682871578A4E98EB'] = {'building', '空军基地控制塔', 0, 'Airbase Control Tower'},
    ['6838D8C197CC9C78'] = {'building', '轨道炮', 0, 'Orbital Cannon'},
    ['6845B56D77E61B9F'] = {'building', '军事通信终端', 0, 'Military Communications Terminal'},
    ['688949109126ECE4'] = {'building', '机械虫洞', 3277626454, 'Mechanical Wormhole'},
    ['68BFAC3C8A03BB83'] = {'building', '战备干扰器终端', 0, 'Stratagem Jammer Terminal'},
    ['6B7EE87FB2EC6455'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['6C62E2E25E084083'] = {'building', 'SEAF 火炮弹药', 0, 'SEAF Artillery Shells'},
    ['6DB870D59730EE07'] = {'building', '中型冷却管道', 0, 'Medium Cooling Pipe'},
    ['6DC9F65AF69783BD'] = {'building', '采油阀门', 0, 'Oil Valve'},
    ['6E499C5C95B019FC'] = {'building', '指挥碉堡', 245997106, 'Command Bunker'},
    ['6FDCD0D7F8EAF267'] = {'building', 'TCS 支柱', 0, 'TCS Pylon'},
    ['705B0136A9A9D73A'] = {'building', '任务弹头', 3660636186, 'Mission Warhead'},
    ['75BE82ED8592A6B3'] = {'building', '鹈鹕运输机', 0, 'Pelican Transport'},
    ['766E7B3BDF79452F'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['7B0F8449CA9D2DA0'] = {'building', '鹈鹕运输机', 0, 'Pelican Transport'},
    ['7BDAA1BB44C3EE1C'] = {'building', '虫族战备干扰器', 0, 'Terminid Stratagem Jammer'},
    ['7C81DE10F0023D08'] = {'building', '旗帜', 2728206271, 'Flag'},
    ['7CA1B74B22C2EB9C'] = {'building', '任务交互物', 3660636186, 'Mission Item'},
    ['7E4876D0DBF9C981'] = {'building', '中继塔终端', 0, 'Relay Tower Terminal'},
    ['7E4C6B45BCC45C3F'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['867FFD3B4EA22E05'] = {'building', '装配设施冷却管道', 0, 'Assembly Facility Cooling Pipe'},
    ['888536AE851DCA05'] = {'building', '数据上传交互装置', 0, 'Data Upload Device'},
    ['888EAAFD58C03C75'] = {'building', '任务货运车', 581608860, 'Mission Cargo Truck'},
    ['8901F188DB366B4B'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['8A50B60B22186B9B'] = {'building', '巢穴世界采油阀门', 0, 'Hive World Oil Valve'},
    ['8AD7A3118BD48D1C'] = {'building', '黑匣子', 4046999266, 'Black Box'},
    ['8C31B749759CBD61'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['8F7D4D9C196018C8'] = {'building', '旗帜', 2728206271, 'Flag'},
    ['90001FEAC563D6A1'] = {'building', '公文包', 4194145910, 'Briefcase'},
    ['91209E5AF7A9660B'] = {'building', '有机物提取软管接口', 0, 'Organic Matter Extraction Hose'},
    ['913B7D337E61EE4C'] = {'building', '生物处理器终端', 0, 'Bio-Processor Terminal'},
    ['925158186B8FD952'] = {'building', '中继塔对准开关', 0, 'Relay Tower Alignment Switch'},
    ['95D717E4AA9ED443'] = {'building', '光能者城市巨炮曲柄', 0, 'Illuminate City Cannon Crank'},
    ['973A2984F0CA6A30'] = {'building', '机器人通信终端', 0, 'Automaton Communications Terminal'},
    ['97DD3178E9F0AB70'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['9A0D640BF4ABB03B'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['9A1F728716DA05B5'] = {'building', '超级地球旗杆', 0, 'Super Earth Flagpole'},
    ['9A6A60CF4BAD9FA5'] = {'building', '防御任务终端', 0, 'Defense Mission Terminal'},
    ['9B58C95349D051F9'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['9B75A86003C2A1F4'] = {'building', '采油任务终端', 0, 'Oil Extraction Mission Terminal'},
    ['9BFC8FCD68B09F28'] = {'building', 'SEAF 火炮', 0, 'SEAF Artillery'},
    ['9D3A7E11095E3355'] = {'building', '任务旗帜', 2728206271, 'Mission Flag'},
    ['9D8632A79C2D9789'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['9E0E5E86A44C62A1'] = {'building', '机器人任务数据', 714952129, 'Automaton Mission Data'},
    ['9EA89CEEA6F8E766'] = {'building', '幼虫储存器', 1492050893, 'Larva Storage'},
    ['A09A19371FECD6A3'] = {'building', 'TCS 任务终端', 0, 'TCS Mission Terminal'},
    ['A0EA22BD370D4D72'] = {'building', '平民撤离门', 0, 'Civilian Evacuation Gate'},
    ['A1A7B76B29088843'] = {'building', '机器人制造厂', 3794527478, 'Automaton Fabricator'},
    ['A1BDB3A13E3633DD'] = {'building', 'SEAF 防空导弹阵地', 1563965062, 'SEAF Anti-Air Missile Site'},
    ['A1E90D748B3D8AAA'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['A21F08920052C27E'] = {'building', '发电站', 0, 'Power Station'},
    ['A3D5F183F8A2B768'] = {'building', 'SEAF 火炮装填架', 0, 'SEAF Artillery Loader'},
    ['A531053415EB57DA'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['A7381B87F3A3B455'] = {'building', '超级固态硬盘', 714952129, 'SSSD'},
    ['A8AE6952B375EF6C'] = {'building', '武装运输舰制造厂', 3794527478, 'Gunship Fabricator'},
    ['A8B999A49716BF41'] = {'building', '光能者传送门', 0, 'Illuminate Portal'},
    ['AA28CAF964D05500'] = {'building', '孢子喷涌体', 3139947901, 'Spore Spewer'},
    ['AC6E5FA7DB7FE621'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['ACC611541CD839DB'] = {'building', '撤离信标', 0, 'Extraction Beacon'},
    ['AEAEF7A1851E6C9D'] = {'building', '机器人防空炮阵地', 4042981686, 'Automaton Anti-Air Site'},
    ['AFC719AF96F10DC3'] = {'building', '受感染高塔', 3896690221, 'Infested Tower'},
    ['B127552416CE512E'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['B19C942FFD41C4A5'] = {'building', '防御任务发射井', 0, 'Defense Mission Silo'},
    ['B1D938C07E30C5DB'] = {'building', '洲际导弹发射井', 0, 'ICBM Silo'},
    ['B27FE88BC708A680'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['B31073E494A0643A'] = {'building', '含水层钻机', 1436471677, 'Aquifer Drill'},
    ['B44F8D33E16202FB'] = {'building', '精炼厂终端', 0, 'Refinery Terminal'},
    ['B50DBC63A02C0D3B'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['B663751EB459D242'] = {'building', '光能者古物', 3335887011, 'Illuminate Artifact'},
    ['B6A181ADCF547AEB'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['B6FE4BD12C248286'] = {'building', '装配设施夹具', 0, 'Assembly Facility Clamp'},
    ['B7C9C0D0C39AA349'] = {'building', '黑匣子回收终端', 0, 'Black Box Recovery Terminal'},
    ['B8A49F22D83D52CF'] = {'building', '洲际导弹发射井锁', 0, 'ICBM Silo Lock'},
    ['BA80E8D1331D8489'] = {'building', '电力恢复终端', 0, 'Power Restoration Terminal'},
    ['BADBA9174CAEE9FF'] = {'building', '洲际导弹发射终端', 0, 'ICBM Launch Terminal'},
    ['BAF9DBD86B22270A'] = {'building', '统御舰', 4134104203, 'Overseer Ship'},
    ['BB2570AFA4C767D8'] = {'building', '数据上传交付点', 0, 'Data Upload Drop-off'},
    ['BB2984B9B83EBFD1'] = {'building', '光能者收割设施', 0, 'Illuminate Harvesting Facility'},
    ['BC2AF8548C6D5E06'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['BD20741E0225BD33'] = {'building', '有机装配设施终端', 0, 'Organic Assembly Facility Terminal'},
    ['BF908A82B8E787AC'] = {'building', 'TCS 支撑建筑', 0, 'TCS Support Structure'},
    ['C02C2623B6359BB3'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['C066DCFAA61E740C'] = {'building', '数据收集终端', 0, 'Data Collection Terminal'},
    ['C2F0CC038E724374'] = {'building', 'SEAF 火炮终端', 0, 'SEAF Artillery Terminal'},
    ['C3D9B291BD97B935'] = {'building', 'TCS 支撑建筑', 0, 'TCS Support Structure'},
    ['C71C0C7B2E688B9B'] = {'building', '机密数据', 3839214628, 'Classified Data'},
    ['C8F9A2233048B836'] = {'building', '任务交互物', 354671336, 'Mission Item'},
    ['CB036409F28330E7'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['D0444F56A7D86E2B'] = {'building', '发电机', 0, 'Generator'},
    ['D3CEB59066593FBD'] = {'building', '工厂任务终端', 0, 'Factory Mission Terminal'},
    ['D4A349DAAE850283'] = {'building', '光能者城市巨炮锁', 0, 'Illuminate City Cannon Lock'},
    ['D564F4E9E3A98599'] = {'building', '燃料补给终端', 0, 'Fuel Refill Terminal'},
    ['D666AA61D804D311'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['D6A1019CF530FA1D'] = {'building', '中继塔控制终端', 0, 'Relay Tower Control Terminal'},
    ['D84FFC32A6E640A8'] = {'building', '机器人运输舰', 1485224906, 'Automaton Transport Ship'},
    ['D86B3F92DD4AAEDC'] = {'building', '平民撤离主终端', 0, 'Civilian Evacuation Main Terminal'},
    ['D88547FF02B212E8'] = {'building', '机器人工厂', 0, 'Automaton Factory'},
    ['D888E2EC286A4B0D'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['D8A28BFB827392BE'] = {'building', '聚变电池', 280534572, 'Fusion Battery'},
    ['DB59777F0ABAF6AF'] = {'building', '任务货运集装箱', 0, 'Mission Cargo Container'},
    ['DC19126D15692D04'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['DC901B71A3A73B9A'] = {'building', '孢肺', 989829386, 'Spore Lung'},
    ['DEF983C174B8E083'] = {'building', '巢穴世界燃料提取终端', 0, 'Hive World Fuel Extraction Terminal'},
    ['DF3C4F91E298BFA4'] = {'building', '任务钻机', 1998289914, 'Mission Drill'},
    ['DF657367D712CD8E'] = {'building', '洲际导弹发射井', 0, 'ICBM Silo'},
    ['DFA99372CEFBF84D'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['E02E6BD34B606A85'] = {'building', '孢子喷涌体', 3139947901, 'Spore Spewer'},
    ['E05784031312C43F'] = {'building', '巢穴世界燃料提取阀门', 0, 'Hive World Fuel Extraction Valve'},
    ['E09FCB5A280ACB1D'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['E2E6E77DCC99A1CB'] = {'building', '生物处理器', 0, 'Bio-Processor'},
    ['E41334ADBEAF0D12'] = {'building', '雷达任务终端', 0, 'Radar Mission Terminal'},
    ['E48C901A7175F638'] = {'building', '科研站数据上传设施', 0, 'Research Station Data Uplink'},
    ['E4BE3FDF0C857B7F'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['E73F6B5A100B7230'] = {'building', '移动雷达', 0, 'Mobile Radar'},
    ['E98D623E013A113B'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['E9929CB8800E1C8F'] = {'building', '巢穴世界管道疏通阀门', 0, 'Hive World Pipe Purge Valve'},
    ['EAE962D85C0C2D4A'] = {'building', '抽油任务钻机', 3477736393, 'Oil Extraction Drill'},
    ['EECB5C13AE48637B'] = {'building', '数据上传主终端', 0, 'Data Upload Main Terminal'},
    ['EF3A4136B21592CB'] = {'building', '鹈鹕飞船', 0, 'Pelican'},
    ['F08AE61266335A40'] = {'building', '非法科研站', 0, 'Illegal Research Station'},
    ['F0B98FB953B13960'] = {'building', '机器人制造厂', 3794527478, 'Automaton Fabricator'},
    ['F1ADE19F87015997'] = {'building', '任务终端', 0, 'Mission Terminal'},
    ['F1C4856CC0EAF603'] = {'building', '防空导弹发射终端', 0, 'Anti-Air Missile Launch Terminal'},
    ['F41432892465C5FD'] = {'building', '超级固态硬盘', 714952129, 'SSSD'},
    ['F45D1A033E848901'] = {'building', '大型冷却管道', 0, 'Large Cooling Pipe'},
    ['F598598C47617605'] = {'building', '任务交互物', 0, 'Mission Item'},
    ['F78BF0FF5C62140D'] = {'building', '虫穴', 3277626454, 'Bug Hole'},
    ['F8E53685C00D926A'] = {'building', '任务交付点', 0, 'Mission Delivery Point'},
    ['FB0AF9C18AAEFEF2'] = {'building', '坠毁的收割者', 0, 'Crashed Harvester'},
    ['FBD932EAC8E28E0B'] = {'building', '主发电站', 0, 'Main Power Station'},
    ['FF5CC825B9571052'] = {'building', '机器人迫击炮阵地', 2649067399, 'Automaton Mortar Site'},
    ['FF660C3FD24531A0'] = {'building', '燃料提取软管接口', 0, 'Fuel Extraction Hose'},
}
-- END MISSION TARGET CATALOG

-- BEGIN ENEMY TARGET CATALOG
-- Generated offline by tools/generate_enemy_catalog.py from docs/enemy-catalog.json.
-- Game 1.007.100, 2026-09-22; hostile + Spottable only; flight before size.
local ENEMY_TARGETS = {
    ['0002BA767DF856F3'] = {'small_enemy', '劫掠者', 2454424572, 'Marauder'},
    ['0883366204E1CCC5'] = {'medium_enemy', '凝视者', 1661895142, 'Gazer'},
    ['089833D2880D9E06'] = {'small_enemy', '机枪奇袭者（炽灼部队）', 586021653, 'Incendiary MG Raider'},
    ['08E6FFC2474287BD'] = {'medium_enemy', '监视者 MK2', 3363066353, 'Overseer MK2'},
    ['09DFB04B2E578BC3'] = {'small_enemy', '激光装甲兵', 4039692928, 'Incendiary Rocket Trooper'},
    ['09FE0BE51A23396C'] = {'medium_enemy', '惑乱者（女）', 1371180916, 'Female Agiator'},
    ['0AB7B92B131C228C'] = {'large_enemy', '爆裂强袭虫', 3903153972, 'Rupture Charger'},
    ['0ADC9F9173AD8E1D'] = {'small_enemy', '无票者（中型）', 4211847317, 'Voteless Medium'},
    ['10081ACEF6163EF6'] = {'medium_enemy', '酸液武斗虫', 3365898186, 'Bile Warrior'},
    ['137988CEA16458F7'] = {'large_enemy', '巨型碾压者', 613980508, 'Hulk Bruiser'},
    ['1448D494665D01A0'] = {'small_enemy', '凝视者 MK2', 2259733865, 'Gazer MK2'},
    ['1897BDD32105D2DC'] = {'large_enemy', '巨型炙焰者 MK2（炽灼部队）', 1775662925, 'Hulk Scorcher MK2'},
    ['19E18B46EC55D94A'] = {'flying_enemy', '刺魟', 4160806915, 'Stingray'},
    ['1A7FCDFF98C664B0'] = {'large_enemy', '强袭虫', 1299714559, 'Charger'},
    ['1B5B9AC4F96B36E5'] = {'small_enemy', '机械统帅（炽灼部队）', 621159586, 'Incendiary Commissar'},
    ['1E66EE1F6F7FD00E'] = {'large_enemy', '巨型抹煞者', 1560770730, 'Hulk Obliterator'},
    ['1F0A91729C0004E0'] = {'small_enemy', '孢裂追猎虫', 1210082392, 'Spore Burst Hunter'},
    ['20B9C7734DAEAD65'] = {'large_enemy', '证真者', 3776682558, 'Veracitor'},
    ['215CE160A17BE4CD'] = {'small_enemy', '喷气机械统帅', 621159586, 'Jet Brigade Commissar'},
    ['257D805CAA7E10C0'] = {'small_enemy', '装甲兵 霰弹（废案）', 4039692928, 'Shotgun Trooper'},
    ['262351741C53FF0C'] = {'small_enemy', '凝视者 尖塔', 2259733865, 'Gazer Spire'},
    ['282EB766C1FFA6A1'] = {'flying_enemy', '炮艇', 1932062202, 'Gunship'},
    ['2A12104F2853AE16'] = {'small_enemy', '火箭奇袭者', 3112705780, 'Rocket Raider'},
    ['2AD2E055DAD21F6E'] = {'flying_enemy', '入侵的穿梭舰', 3579113113, 'Warp Ship Invasion'},
    ['2CF3488C4845F8BD'] = {'large_enemy', '机器人 加农炮塔', 478200978, 'Cannon Turret'},
    ['30CF04B2EC8C9BD4'] = {'small_enemy', '侦察奇袭者', 2319746535, 'Scout Raider'},
    ['30F2DEE2333F227A'] = {'giant_enemy', '移动工厂 带干扰塔', 1153658728, 'Jammer Factory Strider'},
    ['31BAE74D2F064D8D'] = {'large_enemy', '湮灭坦克 MK2', 3455009224, 'Annihilator Tank MK2'},
    ['32541FC4EC7C9CDC'] = {'medium_enemy', '武斗虫 MK3', 3564923972, 'Warrior MK3'},
    ['32CDEADA234FB8DF'] = {'large_enemy', '喷气巨型碾压者', 613980508, 'Jet Brigade Hulk Bruiser'},
    ['34DFD23365472E9E'] = {'flying_enemy', '突入者', 3621116014, 'Obtruder'},
    ['36AA99CCE5E60146'] = {'medium_enemy', '胆汁喷涌虫', 717622970, 'Bile Spewer'},
    ['3AFF5FD7D5450B99'] = {'large_enemy', '巨兽级强袭虫', 1076678822, 'Charger Behemoth'},
    ['3D0E03E2D574E1CA'] = {'small_enemy', '追猎虫 MK2', 3330362068, 'Hunter MK2'},
    ['3E0537D606438FEA'] = {'large_enemy', '巨型炙焰者', 1775662925, 'Hulk Scorcher'},
    ['4019623142351CB6'] = {'small_enemy', '装甲兵 MK3', 4039692928, 'Trooper MK3'},
    ['44458A2C52B002FB'] = {'small_enemy', '无票者（重型）', 4211847317, 'Voteless Heavy'},
    ['453FE22C634EB30F'] = {'large_enemy', '御门者', 1870840792, 'Gatekeeper'},
    ['4E97FB073BDC7A4B'] = {'medium_enemy', '武斗虫 MK2（俘虏）', 3564923972, 'Warrior MK2 (Captive)'},
    ['51EEA86BF6997E4E'] = {'small_enemy', '食腐虫 MK2', 4212839382, 'Scavenger MK2'},
    ['52018DEB9AB6827E'] = {'small_enemy', '喷气装甲兵（崩溃）', 4039692928, 'Jet Brigade Trooper'},
    ['53D8919D7B8ABD67'] = {'large_enemy', '湮灭坦克', 3455009224, 'Annihilator Tank'},
    ['54E107DACF6929CB'] = {'medium_enemy', '狂暴者 MK2', 3201222154, 'Berserker MK2'},
    ['57EED0EAC346CD9D'] = {'medium_enemy', '蹂躏者 MK3（炽灼部队）', 1649987991, 'Incendiary Devastator'},
    ['58B2B86C11369241'] = {'medium_enemy', '燃烧机枪蹂躏者', 75849082, 'Incendiary MG Devastator'},
    ['5CA832447445C0BA'] = {'small_enemy', '追猎虫 MK3', 3330362068, 'Hunter MK3'},
    ['6021E22338333D88'] = {'medium_enemy', '抚育喷涌虫', 487985459, 'Nursing Spewer'},
    ['604A794EC45BB820'] = {'flying_enemy', '崇高监视者', 2745056259, 'Elevated Overseer'},
    ['611BA777783B08A2'] = {'large_enemy', '噪轰引擎 速射加农炮', 4066406510, 'Vox Engine Cannon Turret'},
    ['63DF3D07B7424588'] = {'large_enemy', '铁幕坦克', 3921592399, 'Barrager Tank'},
    ['64090088502435DD'] = {'flying_enemy', '尖啸虫', 793026793, 'Shrieker'},
    ['64BA5F030B114EC1'] = {'small_enemy', '奇袭者', 2000862158, 'Raider'},
    ['672F7DA17F3BA34A'] = {'small_enemy', '穿刺虫触手', 1046000873, 'Tentacle'},
    ['67DC32DCA4F02D33'] = {'large_enemy', '肉瘤体', 2880434041, 'Fleshmob'},
    ['6B202392F4AB605E'] = {'large_enemy', '孢子强袭虫', 1939105083, 'Spore Charger'},
    ['6DAB2EADF5D8B692'] = {'large_enemy', '巨型烈焰轰炸者', 2090691137, 'Hulk Firebomber'},
    ['728421351D440EBC'] = {'medium_enemy', '孢裂武斗虫', 2115960485, 'Spore Burst Warrior'},
    ['72A83E49CED6DB3D'] = {'small_enemy', '胆汁吐沫虫', 444529084, 'Bile Spitter'},
    ['746A7F3BEDA32699'] = {'medium_enemy', '激进先锋（男）', 23741406, 'Male Radical'},
    ['74E2285C01DA4F71'] = {'flying_enemy', '增援穿梭舰', 3579113113, 'Warp Ship'},
    ['78E1497571012C47'] = {'small_enemy', '无票者（轻型）', 4211847317, 'Voteless Light'},
    ['7B48CACDBACB3881'] = {'small_enemy', '装甲兵 MK2', 4039692928, 'Trooper MK2'},
    ['7ECE5304F868F6B3'] = {'small_enemy', '装甲兵（无包裹）', 4039692928, 'Trooper'},
    ['82A87AD8D595B2BA'] = {'small_enemy', '炙焰装甲兵', 2861014363, 'Pyro Trooper'},
    ['843D18D4B5512B63'] = {'large_enemy', '移动工厂 连发加农炮', 478200978, 'Factory Strider Cannon Turret'},
    ['856E9710E45E760F'] = {'small_enemy', '特攻奇袭者', 1467464627, 'Jet Brigade Raider'},
    ['883401AF2A98A5F6'] = {'small_enemy', '掠食追猎虫', 3029738043, 'Predator Hunter'},
    ['8FF0A839830A7692'] = {'small_enemy', '食腐虫', 4212839382, 'Scavenger'},
    ['905809A4C28D8A45'] = {'large_enemy', '粉碎者', 3922421925, 'Crusher'},
    ['9076EEED17FCEE35'] = {'large_enemy', '强化侦察纵步者', 1871700431, 'Reinforced Scout Strider'},
    ['91EBD77931110AFC'] = {'medium_enemy', '重型蹂躏者 MK3', 1649987991, 'Heavy Devastator MK3'},
    ['960B48A421A3FAAA'] = {'flying_enemy', '蟑龙', 1378841226, 'Dragonroach'},
    ['96110F9D6B010E02'] = {'large_enemy', '敌方单位', 478200978, 'Enemy unit'},
    ['9647B00CC3A9D36F'] = {'medium_enemy', '火箭蹂躏者', 2365630221, 'Rocket Devastator'},
    ['965EAE5A51ACDD4A'] = {'large_enemy', '猎杀器', 1405979473, 'Harvester'},
    ['96BA14C9EBB49CE1'] = {'large_enemy', '巨型者', 790541304, 'Hulk'},
    ['98152772A72F7838'] = {'flying_enemy', '运输船', 554367013, 'Dropship'},
    ['9926876B2375A1BB'] = {'medium_enemy', '机器人 碉堡炮塔', 3921936527, 'Bunker Turret'},
    ['9A8A3AAE287B230C'] = {'small_enemy', '食腐虫 MK3', 4212839382, 'Scavenger MK3'},
    ['9D8827FED763650E'] = {'medium_enemy', '惑乱者（男）', 1371180916, 'Male Agitator'},
    ['9E2E17F2CCCCAFDD'] = {'giant_enemy', '吐酸泰坦', 2514244534, 'Bile Titan'},
    ['9F57782F00E6ED20'] = {'small_enemy', '装甲兵（炽灼部队）', 4039692928, 'Incendiary Trooper'},
    ['A05BD1EC67B3AC4C'] = {'large_enemy', '巨兽级强袭虫 MK2', 1076678822, 'Charger Behemoth MK2'},
    ['A1F37BF2A40FBDE4'] = {'medium_enemy', '虫窝护卫', 626718113, 'Hive Guard'},
    ['A35207C6F2150806'] = {'medium_enemy', '爆裂武斗虫', 953392591, 'Rupture Warrior'},
    ['A381A11C07D3EB94'] = {'medium_enemy', '爆裂喷涌虫', 2270698456, 'Rupture Spewer'},
    ['A4552F97033392F4'] = {'small_enemy', '喷气机枪奇袭者', 586021653, 'Jet Brigade MG Raider'},
    ['A6A68D8AF177F3A1'] = {'medium_enemy', '狂暴者', 3201222154, 'Berserker'},
    ['A71AAFD82C6EBC92'] = {'small_enemy', '机械统帅', 621159586, 'Commissar'},
    ['AAB438596F5E8FD9'] = {'small_enemy', '猛扑虫', 908216632, 'Pouncer'},
    ['ABDB2E2A0479D8CA'] = {'large_enemy', '机器人 加农炮塔 MK2', 478200978, 'Cannon Turret MK2'},
    ['AC60E78435098C9D'] = {'flying_enemy', '守望者', 886803190, 'Watcher'},
    ['AE57FCDB49F74E98'] = {'small_enemy', '装甲兵 MK2（机枪版）', 4039692928, 'Trooper MK2 MG'},
    ['AE63E525853D7044'] = {'medium_enemy', '蹂躏者 MK3', 1649987991, 'Devastator MK3'},
    ['AF0F9B3A163787A5'] = {'small_enemy', '喷气装甲兵', 4039692928, 'Jet Brigade Trooper'},
    ['B056F8FC74ABA02D'] = {'small_enemy', '激光炮装甲兵（废案）', 4039692928, 'Cannon Trooper'},
    ['B2A6FA1E4284C7E6'] = {'medium_enemy', '狂暴武斗虫', 3564923972, 'Warrior'},
    ['B4ED319B39F5457B'] = {'small_enemy', '机枪奇袭者', 586021653, 'MG Raider'},
    ['B5DBC0C240C921AD'] = {'medium_enemy', '狂暴者 MK3（炽灼部队）', 3201222154, 'Incendiary Berserker'},
    ['B92435FBF60F0748'] = {'medium_enemy', '重型蹂躏者 MK2', 398976798, 'Heavy Devastator MK2'},
    ['BC242702FB46B7E7'] = {'large_enemy', '噪轰引擎', 4066406510, 'Vox Engine'},
    ['BE39E313A1E46BB9'] = {'medium_enemy', '武斗虫 MK2', 3564923972, 'Warrior MK2'},
    ['BE743B2FAA3A6E26'] = {'medium_enemy', '喷气蹂躏者', 1649987991, 'Jet Brigade Devastator'},
    ['C626D2BB495A202D'] = {'medium_enemy', '蹂躏者', 1649987991, 'Devastator'},
    ['C6449FFD9EA3779C'] = {'large_enemy', '碎裂坦克', 2577770154, 'Shredder Tank'},
    ['C9BCCCB0A54A82A4'] = {'medium_enemy', '火箭蹂躏者 MK3 （炽灼部队）', 2365630221, 'Incendiary Rocket Devastator'},
    ['CBB1BA3366009C3A'] = {'medium_enemy', '激进先锋（女）', 23741406, 'Female Radical'},
    ['CC188F0C80505C6C'] = {'medium_enemy', '悲怜体', 2118086817, 'Wretch'},
    ['CC7022FDD172089B'] = {'medium_enemy', '抚育喷涌虫 MK2', 487985459, 'Nursing Spewer MK2'},
    ['CCAE5264ACD591B7'] = {'medium_enemy', '胆汁喷涌虫 MK2', 717622970, 'Bile Spewer MK2'},
    ['CD28A27A79BE53D5'] = {'medium_enemy', '指挥碉堡 碉堡重机枪', 3921936527, 'Command Bunker HMG'},
    ['D1E990BAF22D5A52'] = {'large_enemy', '掠食追踪虫', 4106686024, 'Predator Stalker'},
    ['D37E8D120D2836E3'] = {'giant_enemy', '移动工厂', 1153658728, 'Factory Strider'},
    ['D465D9C7F77A07CB'] = {'giant_enemy', '霸王虫', 3929716830, 'Hivelord'},
    ['D522FD4748D443A5'] = {'large_enemy', '虫族指挥官', 3077749065, 'Brood Commander'},
    ['D5792F6856B06BA4'] = {'medium_enemy', '喷气狂暴者', 3201222154, 'Jet Brigade Berserker'},
    ['D63FCBFF0851B7AF'] = {'large_enemy', '猎杀器 MK2', 1405979473, 'Harvester MK2'},
    ['D8CBC4A807A6D035'] = {'small_enemy', '乱斗者', 1974334302, 'Brawler'},
    ['D9511E9F6BD62E3F'] = {'small_enemy', '追猎虫', 3330362068, 'Hunter'},
    ['DA40BB347C7447F2'] = {'medium_enemy', '监视者', 1899936906, 'Overseer'},
    ['DB90077E76FAA025'] = {'flying_enemy', '敌方单位', 554367013, 'Enemy unit'},
    ['DB964631BE1CF501'] = {'small_enemy', '孢裂食腐虫', 2842755544, 'Spore Burst Scavenger'},
    ['DCF8E74212FBEE3B'] = {'large_enemy', '穿刺虫', 1046000873, 'Impaler'},
    ['DFBACBD977A948DC'] = {'small_enemy', '食腐虫 MK2（俘虏）', 4212839382, 'Scavenger MK2 (Captive)'},
    ['E0353177F1329573'] = {'medium_enemy', '烈火蹂躏者', 3498181594, 'Conflagration Devastator'},
    ['E44EC9F9B3FE1D2A'] = {'large_enemy', '喷气巨型炙焰者', 1775662925, 'Jet Brigade Hulk Scorcher'},
    ['E683D2CA5618D74A'] = {'small_enemy', '奇袭者（炽灼部队）', 2000862158, 'Incendiary Raider'},
    ['E8F19A0AA958E46D'] = {'medium_enemy', '新月监视者', 3877563222, 'Crescent Overseer'},
    ['EACEE39FA017B495'] = {'medium_enemy', '武斗虫', 3564923972, 'Warrior'},
    ['EF04CB84D097A497'] = {'giant_enemy', '孢裂泰坦', 2514244534, 'Spore Burst Bile Titan'},
    ['EF570293245A17C2'] = {'large_enemy', '战争纵步者', 523260929, 'War Strider'},
    ['F0B26FA9258128D3'] = {'flying_enemy', '敌方单位', 793026793, 'Enemy unit'},
    ['F1610AC48CDC5240'] = {'medium_enemy', '监视者（无包裹模型）', 1899936906, 'Overseer'},
    ['F22D027B37BEF107'] = {'giant_enemy', '利维坦', 3097344451, 'Leviathan'},
    ['F540CA9D9D4A422E'] = {'large_enemy', '追踪虫', 2387277009, 'Stalker'},
    ['F66D0BAD8693779A'] = {'medium_enemy', '火箭蹂躏者 MK2', 2365630221, 'Rocket Devastator MK2'},
    ['F79CD8BB654397DF'] = {'large_enemy', '阿尔法指挥官', 570845236, 'Alpha Commander'},
    ['F8131632AA867107'] = {'large_enemy', '侦察纵步者', 20706814, 'Scout Strider'},
    ['F8B5A81A86D5D4EB'] = {'medium_enemy', '重型蹂躏者', 398976798, 'Heavy Devastator'},
    ['FB9937035D652C43'] = {'small_enemy', '装甲兵', 4039692928, 'Trooper'},
    ['FC8DEC78BE8AB47D'] = {'medium_enemy', '蹂躏者 MK2 移动工厂生产', 1649987991, 'Devastator MK2 Spawn'},
    ['FD5247653C897803'] = {'large_enemy', '敌方单位', 1076678822, 'Enemy unit'},
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
-- Current data confirms these are ObjectiveShell entities, but not their shell
-- variant. Never turn their generic catalogue fallback into a claimed type.
local function build_ping_events(env)
    local ffi = require('ffi')
    local classification = {
        supply_targets = {
            ['79CCFFD281E3F3A9'] = {name_zh='弹药盒', name_en='Ammo box'},
            ['B4CA4C5B922F7965'] = {name_zh='针剂盒', name_en='Stim box'},
            ['97AF34FBF093409C'] = {name_zh='手雷包', name_en='Grenade pack'},
        },
        ambiguous_shells = {['6C62E2E25E084083']=true, ['C8F9A2233048B836']=true},
        generic_native_names = {['特殊地点']=true, ['special location']=true,
            ['敌方单位']=true, ['enemy unit']=true, ['任务交互物']=true, ['objective terminal']=true,
            ['任务终端']=true, ['mission terminal']=true,
            ['战略配备']=true, ['strategic asset']=true, ['stratagem']=true,
            ['普通物资']=true, ['supplies']=true},
        exact_supply_names = {
            ['弹药']=true, ['弹药盒']=true, ['针剂']=true, ['针剂盒']=true,
            ['手雷']=true, ['手雷包']=true, ['手雷盒']=true,
            ['样本']=true, ['样本瓶']=true, ['普通样本']=true, ['稀有样本']=true, ['超级样本']=true,
            ['普通样本瓶']=true, ['稀有样本瓶']=true, ['超级样本瓶']=true,
            ['ammo']=true, ['ammunition']=true, ['ammo box']=true, ['ammo canister']=true,
            ['stim']=true, ['stims']=true, ['stim box']=true, ['stim case']=true,
            ['grenade']=true, ['grenades']=true, ['grenade box']=true, ['grenade case']=true,
            ['grenade pack']=true, ['sample']=true, ['samples']=true, ['common sample']=true,
            ['rare sample']=true, ['super sample']=true, ['sample vial']=true,
        },
    }
    local state = {scene = nil, seen = {}, generation = 0, serial = 0, status = '等待标记数据'}
    local api = {state = state, supported = {small_enemy = true, flying_enemy = true,
        medium_enemy = true, large_enemy = true,
        giant_enemy = true, building = true, supplies = true, stratagem = true, map = true}}
    local function selected_name(row)
        local language
        if env.language then
            local okay, value = pcall(env.language)
            if okay then language = value end
        end
        if type(language) == 'string' and language:lower():match('^en') then
            return row.name_en or row.name_zh
        end
        return row.name_zh or row.name_en
    end
    local function has_cjk(value)
        if type(value)~='string' then return false end
        for i=1,#value-2 do
            local a,b,c=value:byte(i,i+2)
            if a and b and c and a>=0xE0 and a<=0xEF and b>=0x80 and b<=0xBF
                and c>=0x80 and c<=0xBF then
                local code=(a-0xE0)*4096+(b-0x80)*64+(c-0x80)
                if (code>=0x3400 and code<=0x4DBF) or (code>=0x4E00 and code<=0x9FFF) then
                    return true
                end
            end
        end
        return false
    end
    local function ascii_name(value)
        return type(value)=='string' and value~='' and not value:find('[\128-\255]')
    end
    local function target_names(info,native,zh_fallback,en_fallback)
        local zh=info and info[2] or zh_fallback
        local en=info and info[4] or nil
        if not en and info and ascii_name(info[2]) then en=info[2] end
        if type(en)~='string' or en=='' then en=en_fallback end
        if has_cjk(native) then zh=native
        elseif ascii_name(native) then en=native end
        return {zh=zh or zh_fallback,en=en or en_fallback,native_name=native}
    end
    local function merge_native(names,native)
        names=type(names)=='table' and names or {}
        if has_cjk(native) then names.zh=native
        elseif ascii_name(native) then names.en=native end
        names.native_name=native
        return names
    end
    local supply_names={}
    for _,row in pairs(classification.supply_targets) do
        supply_names[row.name_zh]=row;supply_names[row.name_en:lower()]=row
    end
    local function report_drop(reason, entry, resource)
        if not env.diagnostic then return end
        pcall(env.diagnostic, reason, entry.kind, entry.map_type,
            entry.target_id ~= 0 and entry.target_id ~= 0xffffffff,
            entry.localization_key, resource)
    end
    local function generic_name(name, key)
        if type(name) == 'string' then
            name = name:match('^%s*(.-)%s*$')
            local lower = name:lower()
            return GENERIC_MISSION_NAMES[key]
                or classification.generic_native_names[name]
                or classification.generic_native_names[lower] or false
        end
        return GENERIC_MISSION_NAMES[key] or false
    end
    local function exact_supply_name(name)
        if type(name) ~= 'string' then return false end
        name = name:match('^%s*(.-)%s*$')
        return classification.exact_supply_names[name]
            or classification.exact_supply_names[name:lower()] or false
    end
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
                .. bytes:sub(53,56)
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
                local map_name=localized_name(entry.localization_key) or '地图标记'
                local event = {category='map',target=map_name,
                    target_names=target_names(nil,map_name,'地图标记','Map marker'),position=entry.position,
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    source='tactical_map',localization_key=entry.localization_key}
                -- Captured replicated MapMarkerType 6 is the extraction pin.
                if entry.map_type == 6 then
                    event.target='撤离区';event.target_names={zh='撤离区',en='Extraction zone'}
                end
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
                    local target_resource=hex64(identity,0)
                    local mission_target=MISSION_TARGETS[target_resource]
                    local enemy_target=ENEMY_TARGETS[target_resource]
                    local known_target=mission_target or enemy_target
                    if known_target then
                        local native=objective.objective_name
                        if not native or generic_name(native,objective.localization_key) then
                            native=localized_name(known_target[3])
                            if generic_name(native,known_target[3]) then native=nil end
                        end
                        event.target_names=target_names(known_target,native,
                            mission_target and '任务目标' or '敌方单位',
                            mission_target and 'Mission objective' or 'Enemy unit')
                        event.objective_names=event.target_names
                    else
                        event.target_names=target_names(nil,objective.objective_name,'任务目标','Mission objective')
                        event.objective_names=event.target_names
                    end
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
            if native_category == 'building' and (entry.target_id==0 or entry.target_id==0xffffffff)
                and exact_supply_name(localized) then
                local known_supply=supply_names[localized] or supply_names[localized:lower()]
                local names=known_supply and {zh=known_supply.name_zh,en=known_supply.name_en}
                    or {zh='普通物资',en='Supplies'}
                return {category='supplies',target=localized,position=entry.position,
                    target_names=merge_native(names,localized),
                    creator_id=entry.creator_id,kind=entry.kind,slot=entry.slot,
                    localization_key=entry.localization_key,action=action,source='native_marker'}
            end
            if native_category and (entry.target_id==0 or entry.target_id==0xffffffff) then
                if not localized and entry.localization_key > 0 then return nil, 'retry' end
                if not localized or generic_name(localized, entry.localization_key) then
                    report_drop('missing_target_or_generic_name', entry)
                    return nil
                end
                local zh_fallback=native_category=='stratagem' and '未知战备' or '未知目标'
                local en_fallback=native_category=='stratagem' and 'Unknown stratagem' or 'Unknown target'
                return {category=native_category,target=localized,
                    target_names=target_names(nil,localized,zh_fallback,en_fallback),position=entry.position,
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
            local mission = MISSION_TARGETS[resource]
            if not mission and exact_supply_name(localized) then
                if read(address, 24) ~= identity then return nil, 'retry' end
                local known_supply=classification.supply_targets[resource]
                return {category='supplies',target=localized,target_id=entry.target_id,
                    target_names=known_supply and merge_native({zh=known_supply.name_zh,en=known_supply.name_en},localized)
                        or target_names(nil,localized,'普通物资','Supplies'),
                    creator_id=entry.creator_id,resource=resource,kind=entry.kind,slot=entry.slot,
                    localization_key=entry.localization_key,position=entry.position,action=action,
                    source=summoned and 'stratagem_call' or 'target'}
            end
            if EXCLUDED_SUPPLIES[resource] then
                local supply = classification.supply_targets[resource]
                local label = supply and selected_name(supply)
                    or (localized and not generic_name(localized, entry.localization_key) and localized)
                if not label then
                    report_drop('supply_without_specific_name', entry, resource)
                    return nil
                end
                if read(address, 24) ~= identity then return nil, 'retry' end
                return {category='supplies',target=label,target_id=entry.target_id,
                    target_names=supply and merge_native({zh=supply.name_zh,en=supply.name_en},localized)
                        or target_names(nil,localized,'普通物资','Supplies'),
                    creator_id=entry.creator_id,resource=resource,kind=entry.kind,slot=entry.slot,
                    localization_key=entry.localization_key,position=entry.position,action=action,
                    source=summoned and 'stratagem_call' or 'target'}
            end
            if classification.ambiguous_shells[resource] and (not localized
                or generic_name(localized, entry.localization_key)) then
                report_drop('ambiguous_shell_without_specific_name', entry, resource)
                return nil
            end
            -- A ground-style marker is meaningful only when its actual target
            -- identity is a reviewed task resource. Empty terrain still exits
            -- above, and arbitrary objects/enemies do not become locations.
            if entry.kind == 0 and not mission then return nil end
            local enemy = ENEMY_TARGETS[resource]
            local special = env.special_targets and env.special_targets.resolve(resource,
                entry.localization_key) or nil
            local info = mission or enemy or PING_TARGETS[resource]
            if special then
                if read(address, 24) ~= identity then return nil, 'retry' end
                local native=localized and not generic_name(localized, entry.localization_key)
                    and localized or nil
                local target = native or selected_name(special)
                local special_names=target_names({[2]=special.name_zh,[4]=special.name_en},native,
                    '特殊目标','Special target')
                return {category='building',target=target,target_id=entry.target_id,
                    target_names=special_names,
                    creator_id=entry.creator_id,resource=resource,kind=entry.kind,slot=entry.slot,
                    localization_key=entry.localization_key,position=entry.position,action=action,
                    source=summoned and 'stratagem_call' or 'target'}
            end
            if not info and (not native_category or not localized
                or generic_name(localized, entry.localization_key)) then
                report_drop('unknown_target_or_generic_name', entry, resource)
                return nil
            end
            if read(address, 24) ~= identity then return nil, 'retry' end
            local label = localized or info and info[2]
            -- Mission sites and enemies can share generic marker keys. Resolve
            -- the catalog's actual Encyclopedia name before its reviewed fallback;
            -- keep specific native marker text when it is available.
            if (mission or enemy) and (not localized or generic_name(localized,entry.localization_key)) then
                local encyclopedia_name=localized_name(info[3])
                label=encyclopedia_name and not generic_name(encyclopedia_name,info[3])
                    and encyclopedia_name or info[2]
            end
            if info and native_category and not mission and not enemy
                and generic_name(localized, entry.localization_key) then
                label = info[2]
            end
            if info and info[2]:match('^TCS') and localized and not localized:find('TCS',1,true)
                and not GENERIC_MISSION_NAMES[entry.localization_key] then
                label = info[2] .. ' / ' .. localized
            end
            local native_name=localized and not generic_name(localized,entry.localization_key)
                and localized or nil
            if not native_name and (mission or enemy) then
                local encyclopedia_name=localized_name(info[3])
                if encyclopedia_name and not generic_name(encyclopedia_name,info[3]) then
                    native_name=encyclopedia_name
                end
            end
            local zh_fallback=native_category=='stratagem' and '未知战备' or '任务目标'
            local en_fallback=native_category=='stratagem' and 'Unknown stratagem'
                or mission and 'Mission objective' or enemy and 'Enemy unit' or 'Mission target'
            local target_names=target_names(info,native_name,zh_fallback,en_fallback)
            return {category = info and info[1] or native_category,
                target = label, target_id = entry.target_id,
                target_names=target_names,objective_names=mission and target_names or nil,
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
            local token_changed = not previous or previous.token ~= entry.token
            local age_reset = previous and entry.age < previous.age
            local fresh = token_changed or age_reset or previous.pending or previous.pending_emit
            next_seen[entry.slot] = {token = entry.token, age = entry.age}
            if not first and not (entry.map_source and first_map) and fresh then
                local event, reason
                local reusable = not token_changed and not age_reset and previous.pending_emit
                    and type(previous.event) == 'table'
                if reusable then
                    event = previous.event
                else
                    local good
                    good, event, reason = pcall(snapshot.target, entry)
                    if not good or reason == 'retry' then
                        -- A target can finish streaming after its ping arrives. Preserve
                        -- freshness until it resolves or the native mark expires.
                        next_seen[entry.slot] = {token=entry.token, age=entry.age, pending=true}
                        event = nil
                    end
                end
                if event then
                    if not reusable then
                        state.serial = state.serial+1
                        -- Every legitimate renewal gets a distinct key even for the same
                        -- target and slot; the caller's queue can dedupe repeated polls.
                        event.key = snapshot.scene..':'..state.generation..':'..state.serial
                        event.id = event.key
                    end
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
            local success, accepted, disposition = pcall(env.emit, event, now)
            if success and accepted == true then emitted = emitted+1 end
            if success and accepted == false and disposition == 'retry' then
                local pending = state.seen[event.slot]
                if pending and pending.token then
                    state.seen[event.slot] = {token=pending.token, age=pending.age,
                        pending_emit=true, event=event}
                end
            end
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
    special_targets = M.special_targets,
    language = function() return M.language.current() end,
    diagnostic = function(...) return M.record_ping_drop(...) end,
    emit = M.debug_emit_ping_event,
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
    local state = {status='等待任务战备数据', previous={}, seen={}, pending={}}
    local api = {state=state}
    function api.reset()
        state.scene,state.clock,state.previous,state.seen,state.pending,state.last_poll=nil,nil,{},{},{},nil
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
        if baseline then state.seen,state.pending={},{};state.status='任务战备读取就绪';return 0,state.status end
        for key,expiry in pairs(state.seen) do if now>expiry then state.seen[key]=nil end end
        local emitted=0
        if next(state.pending) then
            for key,pending in pairs(state.pending) do
                local item=snapshot.entries[key]
                local token=item and item.id..':'..string.format('%.0f',item.activation) or nil
                if not item or token~=pending.token or now>pending.expires then
                    state.pending[key]=nil
                else
                    local valid=pcall(snapshot.validate)
                    if not valid then api.reset();state.status='任务战备数据切换中';return emitted,state.status end
                    local delivered,accepted,disposition=pcall(env.emit,pending.event,now)
                    if delivered and accepted==true then
                        state.pending[key]=nil;emitted=emitted+1
                    elseif not (delivered and accepted==false and disposition=='retry') then
                        state.pending[key]=nil
                    end
                end
            end
        end
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
                local delivered,accepted,disposition=pcall(env.emit,event,now)
                if delivered and accepted==true then emitted=emitted+1
                elseif delivered and accepted==false and disposition=='retry' then
                    state.pending[key]={token=token,event=event,expires=now+15}
                end
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
    emit = M.debug_emit_ping_event,
})
function M.debug_stratagem_events() return stratagem_events end
M.task_stratagem_status = '等待任务战备数据'


-- Tasks are data, never executable Lua. Percent escaping preserves UTF-8 and delimiters.
M.tasks = {}
local task_serial, task_revision = 0, 0
M.MAX_TASK_ID = 9007199254740991 -- exact-integer ceiling for LuaJIT's number representation
M.task_profile_cache = {}
function M.profile_tasks(role)
    local result = {}
    for _, task in ipairs(M.tasks) do
        if (task.profile or 'host') == role then result[#result+1] = task end
    end
    return result
end
function M.profile_task_view(role)
    if role~='host' and role~='client' then return {} end
    local cached=M.task_profile_cache[role]
    if cached and cached.revision==task_revision then return cached.items end
    local items={}
    for _,task in ipairs(M.tasks) do
        if (task.profile or 'host')==role then items[#items+1]=task end
    end
    M.task_profile_cache[role]={revision=task_revision,items=items}
    return items
end
M.TASK_FILE_LIMIT = 16 * 1024 * 1024
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
    if type(data) ~= 'string' then return false, '任务文件格式无效' end
    if #data > M.TASK_FILE_LIMIT then return false, '任务文件超过 16 MiB；原内容未加载' end
    local first, list, ids, serial = true, {}, {}, 0
    for line in data:gmatch('[^\r\n]+') do
        if first then
            if line ~= 'AutoChatTasks1' then return false end
            first = false
        else
            local f = {}
            for v in (line .. '\t'):gmatch('(.-)\t') do f[#f + 1] = unescape_field(v) end
            if #f ~= 9 and #f ~= 10 then return false, '任务记录格式无效' end
            if f[10] and f[10] ~= 'host' and f[10] ~= 'client' then return false end
            local t = task_validate(f[8], f[2], f[3], f[9])
            local id, due = tonumber(f[1]), tonumber(f[6])
            if not t or not id or id < 1 or id > M.MAX_TASK_ID or id ~= math.floor(id)
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
    local serialized = serialize_tasks()
    if #serialized > M.TASK_FILE_LIMIT then return false, '任务文件超过 16 MiB' end
    local handle = io.open(temporary, 'w')
    if not handle then return false end
    local ok, result = pcall(function()
        local written, err = handle:write(serialized)
        if not written then error(err or 'write failed') end
        local closed, close_err = handle:close()
        if closed == nil and close_err then error(close_err) end
        if kernel.MoveFileExA(temporary, TASK_FILE, 9) == 0 then error('file replacement failed') end
        return true
    end)
    if not ok then pcall(function() handle:close() end) note('task save failed: ' .. tostring(result)); return false, '保存失败：'..tostring(result) end
    return ok
end
M.quick_migrated_task_name = '旧版快捷定时'
function M.quick_task_definition_exists(definitions, interval, message)
    for _, definition in ipairs(definitions or {}) do
        if tostring(definition.name):match('^' .. M.quick_migrated_task_name)
            and definition.mode == 'repeat' and tostring(definition.time) == tostring(interval)
            and definition.message == message then return true end
    end
    return false
end
function M.append_quick_task_definition(definitions, interval, message)
    definitions = definitions or {}
    if M.quick_task_definition_exists(definitions, interval, message) then return definitions end
    local occupied, name = {}, M.quick_migrated_task_name
    for _, definition in ipairs(definitions) do
        if tostring(definition.name):match('^' .. M.quick_migrated_task_name) then occupied[definition.name] = true end
    end
    local suffix = 2
    while occupied[name] do name = M.quick_migrated_task_name .. ' ' .. suffix; suffix = suffix + 1 end
    definitions[#definitions + 1] = {name=name,mode='repeat',time=tostring(interval),message=message,enabled=true}
    return definitions
end
apply_host_preset_snapshot = function(payload, role)
    local valid, parsed = automation.validate_profile(payload)
    if not valid then return false, parsed end
    local old_tasks, old_serial, old_revision
    local migrate_quick = parsed.values.quick_timer_enabled == true
    if parsed.tasks ~= nil or migrate_quick then
        if role ~= 'host' and role ~= 'client' then return false, '未知预设' end
        local candidate, count = {}, 0
        for _, task in ipairs(M.tasks) do
            if parsed.tasks == nil or (task.profile or 'host') ~= role then
                count = count + 1; candidate[count] = task
            end
        end
        local definitions = parsed.tasks
        if migrate_quick then
            definitions = M.append_quick_task_definition(definitions, parsed.values.quick_timer_interval,
                parsed.values.quick_timer_message)
        end
        old_tasks, old_serial, old_revision = {}, task_serial, task_revision
        for i, task in ipairs(M.tasks) do old_tasks[i] = task end
        local now = os.time()
        local next_serial = task_serial
        for _, definition in ipairs(definitions or {}) do
            local task, why = task_validate(definition.name, definition.mode, definition.time, definition.message)
            if not task then return false, why end
            if next_serial >= M.MAX_TASK_ID then return false, '任务编号超过可精确保存的范围' end
            next_serial = next_serial + 1
            task.id, task.profile = next_serial, role
            task.enabled = definition.enabled == true
            task.done = false
            task.due = now + (task.seconds or 0)
            if task.mode=='daily' then
                local c=os.date('*t',now)
                if type(c)=='table' and c.hour*60+c.min>=task.minute then
                    task.last_day=string.format('%04d-%02d-%02d',c.year,c.month,c.day)
                end
            end
            count = count + 1; candidate[count] = task
        end
        for i = #M.tasks, 1, -1 do M.tasks[i] = nil end
        for i, task in ipairs(candidate) do M.tasks[i] = task end
        task_serial = next_serial
        local tasks_saved, tasks_save_why = save_tasks()
        if not tasks_saved then
            for i = #M.tasks, 1, -1 do M.tasks[i] = nil end
            for i, task in ipairs(old_tasks) do M.tasks[i] = task end
            task_serial = old_serial
            return false, '保存定时任务失败；原任务已恢复' .. (tasks_save_why and ('：'..tostring(tasks_save_why)) or '')
        end
        task_revision = old_revision + 1
    end
    local import_payload = payload
    if migrate_quick then
        local count
        import_payload, count = payload:gsub('(quick_timer_enabled=)true\n', '%1false\n', 1)
        if count ~= 1 then
            if old_tasks then
                for i = #M.tasks, 1, -1 do M.tasks[i] = nil end
                for i, task in ipairs(old_tasks) do M.tasks[i] = task end
                task_serial, task_revision = old_serial, old_revision
                if not save_tasks() then
                    note('preset task rollback failed after quick timer conversion error')
                    return false, '快捷定时迁移失败；任务文件回滚失败；预设未应用'
                end
            end
            return false, '快捷定时迁移失败；预设未应用'
        end
    end
    local applied, why = automation.import_profile(import_payload, role)
    if applied then return true, why end
    if old_tasks then
        for i = #M.tasks, 1, -1 do M.tasks[i] = nil end
        for i, task in ipairs(old_tasks) do M.tasks[i] = task end
        task_serial, task_revision = old_serial, old_revision
        if not save_tasks() then
            note('preset task rollback failed after settings write failure')
            return false, tostring(why or '预设设置写入失败')..'；任务文件回滚失败'
        end
    end
    return false, why
end
apply_preset_snapshot = function(payload,role)
    local valid,parsed=automation.validate_profile(payload)
    if not valid then return false,parsed end
    local tx
    if type(parsed.plugins)=='table' and next(parsed.plugins)~=nil then
        if not REGISTRY or type(REGISTRY.prepare_presets)~='function' then
            return false,'插件预设恢复接口不可用；未应用预设'
        end
        local why
        tx,why=REGISTRY.prepare_presets(parsed.plugins,role)
        if not tx then return false,why or '插件预设验证失败；未应用预设' end
        local committed,commit_why=tx.commit()
        if committed~=true then
            local rolled,rollback_why=tx.rollback()
            if rolled~=true then
                return false,tostring(commit_why or '插件预设应用失败')..'；插件回滚失败：'..tostring(rollback_why)
            end
            return false,commit_why or '插件预设应用失败；插件状态已回滚'
        end
    end
    local applied,why=apply_host_preset_snapshot(payload,role)
    if applied then return true,why end
    if tx then
        local rolled,rollback_why=tx.rollback()
        if rolled~=true then return false,tostring(why or '预设应用失败')..'；插件回滚失败：'..tostring(rollback_why) end
    end
    return false,why
end
local function load_tasks()
    local handle = io.open(TASK_FILE, 'r')
    if not handle then return end
    local data = handle:read(M.TASK_FILE_LIMIT + 1)
    handle:close()
    local ok, why = restore_tasks(data)
    if not ok then note('tasks: ' .. tostring(why or 'invalid file') .. '; not loaded') end
end
function M.add_task(name, mode, time, message, now, profile)
    profile = profile or automation.sync() or 'host'
    if profile ~= 'host' and profile ~= 'client' then return nil, '未知预设' end
    local t, why = task_validate(name, mode, time, message)
    if not t then return nil, why end
    if task_serial >= M.MAX_TASK_ID then return nil, '任务编号超过可精确保存的范围' end
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
    local saved, save_why = save_tasks()
    if not saved then table.remove(M.tasks) return nil, save_why or '保存失败，请检查配置目录' end
    task_revision = task_revision + 1
    return t
end
function M.migrate_quick_timer(role)
    if role ~= 'host' and role ~= 'client' then return false, '未知身份' end
    local profile = automation.profile(role)
    if not profile or profile.quick_timer_enabled ~= true then return true, '无需迁移' end
    local definitions = {}
    for _, task in ipairs(M.profile_tasks(role)) do
        definitions[#definitions + 1] = {name=task.name,mode=task.mode,time=task.time,message=task.message}
    end
    if not M.quick_task_definition_exists(definitions, profile.quick_timer_interval, profile.quick_timer_message) then
        local name = M.quick_migrated_task_name
        local occupied = {}
        for _, task in ipairs(M.profile_tasks(role)) do
            if tostring(task.name):match('^' .. M.quick_migrated_task_name) then occupied[task.name] = true end
        end
        local suffix=2
        while occupied[name] do name=M.quick_migrated_task_name .. ' ' .. suffix;suffix=suffix+1 end
        local added, why=M.add_task(name,'repeat',tostring(profile.quick_timer_interval),profile.quick_timer_message,nil,role)
        if not added then return false, why end
    end
    local ok, why=automation.set('quick_timer_enabled',false,role)
    if not ok then return false, why end
    return true, '已迁移为定时任务'
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
                local allowed, why = automation.check(now, reason, nil, true)
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
                local task_role=t.profile or 'host'
                local task_profile=automation.profile(task_role)
                local ok, why = automation.send(automation.format(t.message,nil,nil,false,
                    task_profile and task_profile.ping_sender_color==true,
                    task_profile and task_profile.message_language), task_role)
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

-- BEGIN UNICODE TEXT INPUT
-- Convert the native window-procedure event queue into ordered editor actions.
-- No Win32 callbacks live here; callers pass only records copied by the thunk.
local function build_text_input(capacity)
    capacity = math.max(1, math.floor(tonumber(capacity) or 128))
    local MAX_CHAR_REPEAT = 32
    local state = { composing = false, pending_high = nil, overflow = false, pressed = {},
                    bytes = 0 }
    local self = {}

    local function utf8(codepoint)
        if codepoint < 0x80 then
            return string.char(codepoint)
        elseif codepoint < 0x800 then
            return string.char(0xC0 + math.floor(codepoint / 64), 0x80 + codepoint % 64)
        elseif codepoint < 0x10000 then
            return string.char(0xE0 + math.floor(codepoint / 4096),
                               0x80 + math.floor(codepoint / 64) % 64,
                               0x80 + codepoint % 64)
        end
        return string.char(0xF0 + math.floor(codepoint / 262144),
                           0x80 + math.floor(codepoint / 4096) % 64,
                           0x80 + math.floor(codepoint / 64) % 64,
                           0x80 + codepoint % 64)
    end

    local function append(out, codepoint)
        if codepoint < 0x20 or codepoint == 0x7F or codepoint > 0x10FFFF
                or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then return end
        local value = utf8(codepoint)
        state.bytes = state.bytes + #value
        out[#out + 1] = { kind = 'text', value = value }
    end

    local function char_unit(out, unit)
        if unit >= 0xD800 and unit <= 0xDBFF then
            state.pending_high = unit
            return
        end
        if unit >= 0xDC00 and unit <= 0xDFFF then
            if state.pending_high then
                append(out, 0x10000 + (state.pending_high - 0xD800) * 0x400 + unit - 0xDC00)
            end
            state.pending_high = nil
            return
        end
        state.pending_high = nil
        append(out, unit)
    end

    local function action(out, kind)
        out[#out + 1] = { kind = kind }
    end

    function self.consume(events, overflow)
        local out = {}
        local has_overflow = overflow or (events and #events > capacity)
        if has_overflow then
            state.pending_high, state.composing = nil, false
            state.pressed, state.bytes, state.overflow = {}, 0, true
            out[1] = { kind = 'reset' }
            return out
        end
        state.overflow = false
        for i = 1, #(events or {}) do
            local event = events[i]
            local message = tonumber(event.message)
            local wp, lp = tonumber(event.wparam) or 0, tonumber(event.lparam) or 0
            if message == 0x010D then
                state.composing = true
                action(out, 'ime_start')
            elseif message == 0x010E then
                state.composing = false
                action(out, 'ime_end')
            elseif message == 0x0102 then
                local repeats = lp % 0x10000
                if repeats == 0 then repeats = 1 end
                repeats = math.min(repeats, MAX_CHAR_REPEAT)
                for _ = 1, repeats do
                    if wp == 0x08 then
                        if not state.composing then
                            state.pending_high = nil
                            action(out, 'backspace')
                        end
                    elseif wp == 0x0D or wp == 0x1B then
                        -- Enter and Escape are handled on keydown only.
                    elseif wp == 0x16 then
                        action(out, 'paste')
                    elseif wp == 0x01 then
                        action(out, 'select_all')
                    elseif wp == 0x18 then
                        action(out, 'cut')
                    elseif wp == 0x03 then
                        action(out, 'copy')
                    elseif wp ~= 0x09 and wp ~= 0x0A then
                        char_unit(out, wp)
                    end
                end
            elseif message == 0x0109 then
                state.pending_high = nil
                if wp ~= 0xFFFF then append(out, wp) end -- UNICODE_NOCHAR is a probe.
            elseif message == 0x0100 or message == 0x0104 then
                local repeated = math.floor(lp / 0x40000000) % 2 == 1
                if not repeated and not state.pressed[wp] then
                    state.pressed[wp] = true
                    if wp == 0x0D and not state.composing then action(out, 'submit') end
                    if wp == 0x1B and not state.composing then action(out, 'cancel') end
                end
            elseif message == 0x0101 or message == 0x0105 then
                state.pressed[wp] = nil
            end
        end
        return out
    end

    function self.reset()
        state.composing, state.pending_high, state.bytes, state.overflow = false, nil, 0, false
        state.pressed = {}
    end

    function self.status()
        return { composing = state.composing, pending_high = state.pending_high,
                 overflow = state.overflow, bytes = state.bytes }
    end

    return self
end
-- END UNICODE TEXT INPUT
-- BEGIN ARMORY INPUT
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
    local debug_wheel = nil
    local function consume_wheel(f)
        local current = tonumber(f.u[1]) or 0
        local previous = f.wheel_seen
        if previous == nil then previous = current end
        local delta = (current - previous) % 4294967296
        if delta >= 2147483648 then delta = delta - 4294967296 end
        f.wheel_seen = current
        local remainder = (f.wheel_rest or 0) + delta
        local notches = remainder >= 0 and math.floor(remainder / 120)
            or math.ceil(remainder / 120)
        f.wheel_rest = remainder - notches * 120
        return notches
    end
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
        for _, f in ipairs(filters) do
            if not f.debug then
                if on and f.u[0] == 0 then
                    f.wheel_seen = tonumber(f.u[1]) or 0
                    f.wheel_rest = 0
                end
                f.u[0] = on and 1 or 0
            end
        end
    end
    -- The native window hook consumes WM_MOUSEWHEEL while filtering is active,
    -- so the engine axis is not a reliable source in that state. Read its signed
    -- counter, handle uint32 wrap, and retain sub-notch deltas like Armory does.
    function input.filter_wheel()
        local filtered, total = false, 0
        for _, f in ipairs(filters) do
            if f.u[0] ~= 0 then
                filtered = true
                total = total + consume_wheel(f)
            end
        end
        if debug_wheel and debug_wheel.active then
            filtered = true
            total = total + consume_wheel(debug_wheel)
        end
        if filtered then return total end
        return nil
    end
    -- Tests cannot install a real HWND thunk; this seeds the same uint32_t
    -- counter reader without changing the production native bridge.
    function input.debug_set_wheel_counter(value, active)
        value = tonumber(value) or 0
        if not debug_wheel or (active and not debug_wheel.active) then
            debug_wheel = {u={[0]=active and 1 or 0, [1]=value},
                wheel_seen=value, wheel_rest=0, active=not not active}
        else
            if debug_wheel.active ~= not not active then
                debug_wheel.wheel_seen, debug_wheel.wheel_rest = value, 0
            end
            debug_wheel.u[0], debug_wheel.u[1] = active and 1 or 0, value
            debug_wheel.active = not not active
        end
    end
    function self.filter_wheel() return input.filter_wheel() end
    function self.debug_set_wheel_counter(value, active)
        return input.debug_set_wheel_counter(value, active)
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
-- END ARMORY INPUT
local panel_input = build_panel_input(ffi, user, kernel, note)
local text_input = build_text_input(64)

-- ---------------------------------------------------------------- 11. panel
-- Staged construction: create_screen_gui must not run before the ship world
-- exists, and each stage advances only on success so a failure names the exact
-- engine call that broke instead of dying invisibly.
local PANEL = {world = nil, gui = nil, draw_guis = nil, open = false, hover = -1,
    scroll_offsets = {},
               lfail = 0, version = 0,
               rw = 0, rh = 0}
PANEL.context_worlds, PANEL.context_main = nil, nil
PANEL.context_settled_at, PANEL.next_context_sample = nil, 0
PANEL.context_is_settled = false
PANEL.chat_view_cache, PANEL.chat_poll_frame = nil, 0
PANEL.context_status = 'not checked'
PANEL.loaded_plugin_icon = PANEL.loaded_plugin_icon or function()
    local cache = PANEL.plugin_icon_cache
    if not cache then
        cache = {open=false, session=nil, generation=nil, icon=nil,
            next_scan=0, next_session_check=0}
        PANEL.plugin_icon_cache = cache
    end
    local now = os.time()
    local generation = stratagem_catalog.state.generation or 0
    local known_session = automation.state.limit_session
    local function reset(token)
        cache.session, cache.generation, cache.icon = token, generation, nil
        cache.next_scan, cache.next_session_check = 0, now + 5
    end
    if not cache.open then
        cache.open = true
        reset(known_session or session_token())
    elseif known_session and cache.session ~= known_session then
        reset(known_session)
    elseif now >= cache.next_session_check then
        cache.next_session_check = now + 5
        local token = session_token()
        if token and token ~= cache.session then reset(token) end
    end
    if cache.generation ~= generation then reset(cache.session) end
    if cache.icon or now < cache.next_scan then return cache.icon end
    cache.next_scan = now + 2
    for _, row in ipairs(stratagem_catalog.list()) do
        local icon = row.icon
        if type(icon) == 'string' and #icon == 16 and icon:match('^%x+$')
            and resource_loaded('material', icon) then
            cache.icon = icon:upper()
            break
        end
    end
    return cache.icon
end
M.language.set_dirty(function()
    PANEL.version = (PANEL.version or 0) + 1
    PANEL.sig = nil
end)
local function stop_text_input()
    local status = panel_input.status()
    local window = status.window
    if not window and user then pcall(function() window = user.GetForegroundWindow() end) end
    if PANEL.input_edit_field and window then pcall(panel_input.editing, false, window) end
    pcall(panel_input.clear)
    text_input.reset()
    PANEL.input_edit_field, PANEL.edit_select_all = nil, nil
end
PANEL.preset_selected_by_role = PANEL.preset_selected_by_role or {}
PANEL.preset_page_by_role = PANEL.preset_page_by_role or {}
local PRESET_SELECTION_FILE = HOME .. 'AutoChat/preset-selection.txt'
local function load_preset_selection()
    local file=io.open(PRESET_SELECTION_FILE,'rb')
    if not file then return end
    local content=file:read(256);file:close()
    if type(content)~='string' then return end
    for role,id in content:gmatch('([%a]+)=(P%d+)') do
        if (role=='host' or role=='client') and id:match('^P%d%d%d%d%d%d%d%d$') then
            PANEL.preset_selected_by_role[role]=id
        end
    end
end
local function save_preset_selection()
    local temporary=PRESET_SELECTION_FILE..'.tmp'
    local file=io.open(temporary,'wb')
    if not file then note('preset selection save failed: cannot create file');return false end
    local data='host='..tostring(PANEL.preset_selected_by_role.host or '')..'\nclient='
        ..tostring(PANEL.preset_selected_by_role.client or '')..'\n'
    local ok,written=pcall(function()
        local result=file:write(data)
        if not result then file:close();return false end
        if not file:close() then return false end
        return kernel.MoveFileExA(temporary,PRESET_SELECTION_FILE,9)~=0
    end)
    if not ok then pcall(file.close,file) end
    if not ok or written~=true then note('preset selection save failed: atomic replace refused');return false end
    return true
end
load_preset_selection()
local draft = {name = '', mode = 'repeat', time = '30', message = ''}
M.batch_rule_ids = function(locale)
    local ids,seen={},{}
    if locale~='zh' and locale~='en' then locale=M.language.current() end
    local filter=PANEL.rule_filter or 'all'
    local query=tostring(PANEL.rule_search or ''):lower()
    for _,row in ipairs(stratagem_catalog.list_rules and stratagem_catalog.list_rules() or stratagem_catalog.list()) do
        local matches_filter=filter=='all' or (filter=='mission' and row.family=='mission')
            or (filter=='other' and row.group=='other' and row.family~='mission')
            or (filter~='mission' and filter~='other' and row.group==filter)
        local display=M.language.is_chinese(locale) and (row.display_name or ('战备 #'..tostring(row.id)))
            or (row.display_name_en or ('Stratagem #'..tostring(row.id)))
        if matches_filter and (query=='' or tostring(display or ''):lower():find(query,1,true)
            or tostring(row.id):find(query,1,true)
            or tostring(row.debug_name or row.name or ''):lower():find(query,1,true)) then
            local key=tostring(row.id)
            if not seen[key] then seen[key]=true;ids[#ids+1]=row.id end
        end
    end
    return ids
end
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
M.panel_mouse_wheel_delta = function()
    local filtered_wheel = panel_input and panel_input.filter_wheel()
    if filtered_wheel ~= nil then return filtered_wheel end
    local mouse = sr and sr.Mouse
    if type(mouse) ~= 'table' then return 0 end
    local id
    for _, name in ipairs({'axis_id', 'axis_index'}) do
        local get_id = rawget(mouse, name)
        if type(get_id) == 'function' then
            local ok, value = pcall(get_id, 'wheel')
            if ok and value ~= nil then id = value; break end
        end
    end
    local axis = rawget(mouse, 'axis')
    if id == nil or type(axis) ~= 'function' then return 0 end
    local ok, value = pcall(axis, id)
    if not ok or value == nil then return 0 end
    local got, dy = pcall(sr.Vector3.y, value)
    if not got or type(dy) ~= 'number' then dy = type(value) == 'table' and value[2] or 0 end
    return tonumber(dy) or 0
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

local function utf8_to_clipboard_utf16(text)
    local out, i = {}, 1
    while i <= #text do
        local a, cp, width = text:byte(i), nil, nil
        if a < 0x80 then cp, width = a, 1
        elseif a >= 0xC2 and a <= 0xDF then
            local b=text:byte(i+1);if not b or b<0x80 or b>0xBF then return nil end
            cp,width=(a-0xC0)*64+b-0x80,2
        elseif a >= 0xE0 and a <= 0xEF then
            local b,c=text:byte(i+1),text:byte(i+2)
            if not b or not c or b<0x80 or b>0xBF or c<0x80 or c>0xBF
                or (a==0xE0 and b<0xA0) or (a==0xED and b>=0xA0) then return nil end
            cp,width=(a-0xE0)*4096+(b-0x80)*64+c-0x80,3
        elseif a >= 0xF0 and a <= 0xF4 then
            local b,c,d=text:byte(i+1),text:byte(i+2),text:byte(i+3)
            if not b or not c or not d or b<0x80 or b>0xBF or c<0x80 or c>0xBF or d<0x80 or d>0xBF
                or (a==0xF0 and b<0x90) or (a==0xF4 and b>0x8F) then return nil end
            cp,width=(a-0xF0)*262144+(b-0x80)*4096+(c-0x80)*64+d-0x80,4
        else return nil end
        if cp < 0x10000 then
            out[#out+1]=string.char(cp%256,math.floor(cp/256))
        else
            cp=cp-0x10000
            local high=0xD800+math.floor(cp/1024)
            local low=0xDC00+cp%1024
            out[#out+1]=string.char(high%256,math.floor(high/256),low%256,math.floor(low/256))
        end
        i=i+width
    end
    out[#out+1]='\0\0'
    return table.concat(out)
end

-- Clipboard ownership transfers to Windows only after SetClipboardData succeeds.
-- Every earlier failure unlocks/frees our allocation and still closes the clipboard.
local function clipboard_set_text(text)
    if not user or not kernel then return false end
    local bytes=utf8_to_clipboard_utf16(text)
    if not bytes then return false end
    local memory,locked,transferred
    local allocated,alloc_result=pcall(function()
        memory=kernel.GlobalAlloc(0x0002,#bytes) -- GMEM_MOVEABLE
        if memory==nil or memory==ffi.NULL then return false end
        locked=kernel.GlobalLock(memory)
        if locked==nil or locked==ffi.NULL then return false end
        ffi.copy(locked,bytes,#bytes)
        kernel.GlobalUnlock(memory)
        locked=nil
        return true
    end)
    if not allocated or alloc_result~=true then
        if locked and memory then pcall(function() kernel.GlobalUnlock(memory) end) end
        if memory and memory~=ffi.NULL then pcall(function() kernel.GlobalFree(memory) end) end
        return false
    end
    local status=panel_input and panel_input.status() or {}
    local owner=status.window
    if not owner or owner==ffi.NULL then owner=user.GetForegroundWindow() end
    if not owner or owner==ffi.NULL then pcall(function() kernel.GlobalFree(memory) end);return false end
    local owner_pid=ffi.new('uint32_t[1]')
    local owner_ok,owner_thread=pcall(function() return user.GetWindowThreadProcessId(owner,ffi.cast('void *',owner_pid)) end)
    if not owner_ok or not owner_thread or owner_thread==0
        or tonumber(owner_pid[0])~=tonumber(kernel.GetCurrentProcessId()) then
        pcall(function() kernel.GlobalFree(memory) end);return false
    end
    local ok_open,opened=pcall(function() return user.OpenClipboard(owner) end)
    if not ok_open or not opened or opened==0 then
        pcall(function() kernel.GlobalFree(memory) end)
        return false
    end
    local ok,result=pcall(function()
        if user.EmptyClipboard()==0 then return false end
        local accepted=user.SetClipboardData(13,memory) -- CF_UNICODETEXT
        if accepted==nil or accepted==ffi.NULL then return false end
        transferred=true
        return true
    end)
    if locked and memory then pcall(function() kernel.GlobalUnlock(memory) end) end
    if memory and not transferred then pcall(function() kernel.GlobalFree(memory) end) end
    pcall(function() user.CloseClipboard() end)
    return ok and result==true
end

-- Returns the edited text, or nil to keep the current one. Pure enough to test offline:
-- it takes `now` and reads keys through key_down, which the harness controls.
local function edit_text(now, raw_events, overflow)
    local text = PANEL.edit_text
    if text == nil then text = PANEL.edit_field and draft[PANEL.edit_field] or cfg.message or '' end
    local limit = PANEL.edit_field == 'preset:name' and 96
        or PANEL.edit_field == 'preset:path' and 1024 or MAX_MESSAGE

    if raw_events ~= nil then
        for _, event in ipairs(text_input.consume(raw_events, overflow)) do
            if event.kind == 'reset' then
                PANEL.edit_text, PANEL.edit_select_all = nil, nil
                return nil, 'reset'
            elseif event.kind == 'submit' then
                PANEL.edit_text = nil
                return text, 'commit'
            elseif event.kind == 'cancel' then
                PANEL.edit_text, PANEL.edit_select_all = nil, nil
                return nil, 'cancel'
            elseif event.kind == 'select_all' then
                PANEL.edit_select_all = true
            elseif event.kind == 'text' then
                if PANEL.edit_select_all then text, PANEL.edit_select_all = '', nil end
                text = text .. cut_utf8(event.value or '', math.max(0, limit - #text))
            elseif event.kind == 'backspace' then
                if PANEL.edit_select_all then text, PANEL.edit_select_all = '', nil
                else
                    local trimmed = text:gsub('[\194-\244][\128-\191]*$', '')
                    if #trimmed == #text then trimmed = text:sub(1, -2) end
                    text = trimmed
                end
            elseif event.kind == 'copy' then
                if PANEL.edit_select_all then clipboard_set_text(text) end
            elseif event.kind == 'cut' then
                if PANEL.edit_select_all and clipboard_set_text(text) then text, PANEL.edit_select_all = '', nil end
            elseif event.kind == 'paste' then
                local pasted = clipboard_text()
                if pasted then
                    if PANEL.edit_select_all then text, PANEL.edit_select_all = '', nil end
                    text = text .. cut_utf8(pasted, math.max(0, limit - #text))
                end
            end
        end
        PANEL.edit_text = text
        return text, 'typing'
    end

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
function M.debug_edit_text(now, events, overflow) return edit_text(now or 0, events, overflow) end
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
    if not sr then return false, false, 'world_unavailable' end
    local ok, world = pcall(sr.Application.main_world)
    if not ok or world == nil then return false, false, 'world_unavailable' end
    local okr, rw, rh = pcall(Gui.resolution)
    if not okr or type(rw) ~= 'number' or rw < 640 or rh < 480 then
        return false, false, 'resolution_unavailable'
    end
    -- A new world means every gui made for the old one is stale, and the geometry
    -- must be recomputed. Teardown here (rather than only in the frame body) is what
    -- makes a world change safe: the panel is rebuilt from scratch for the new world.
    local changed_world = PANEL.world ~= nil and world ~= PANEL.world
    if changed_world then
        -- The old native world may already have been destroyed by the engine.
        -- Drop our stale GUI handle instead of passing it to destroy_gui.
        panel_clear(true)
    end
    PANEL.world = world
    PANEL.rw, PANEL.rh = rw, rh
    return true, changed_world
end

-- Armory's installed payload snapshots Application.worlds() and main_world(), then
-- waits for 1.5 seconds without identity changes before drawing. AutoChat applies
-- that same stability condition to opening and closes if either identity changes.
-- We sample at 12-frame intervals while idle/open and take a fresh sample per open
-- request, avoiding a world-list scan on most frames while the panel is closed.
local panel_context_guard = (function()
local WORLD_SETTLE_SECONDS, WORLD_SAMPLE_FRAMES = 1.5, 12
local function invalidate_world_context(reason)
    PANEL.context_worlds, PANEL.context_main = nil, nil
    PANEL.context_settled_at, PANEL.context_is_settled = nil, false
    PANEL.chat_view_cache = nil
    PANEL.next_context_sample = M.frames + WORLD_SAMPLE_FRAMES
    PANEL.context_status = tostring(reason)
    M.panel_context = PANEL.context_status
    return false, reason
end
local function same_world_list(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function world_context_sample(force)
    if not force and M.frames < PANEL.next_context_sample then
        if not PANEL.context_worlds then return false, PANEL.context_status or 'world_unavailable' end
        return true, PANEL.context_is_settled and 'stable' or 'settling'
    end
    local now = monotonic_now()
    if not now then return invalidate_world_context('clock_unavailable') end
    PANEL.next_context_sample = M.frames + WORLD_SAMPLE_FRAMES
    refresh_engine()
    if not sr or not sr.Application or type(sr.Application.main_world) ~= 'function' then
        return invalidate_world_context('world_unavailable')
    end
    local ok_main, main = pcall(sr.Application.main_world)
    if not ok_main or main == nil then
        return invalidate_world_context('world_unavailable')
    end
    if type(sr.Application.worlds) ~= 'function' then
        return invalidate_world_context('world_list_unavailable')
    end
    local ok_worlds, worlds = pcall(sr.Application.worlds)
    if not ok_worlds or type(worlds) ~= 'table' then
        return invalidate_world_context('world_list_unavailable')
    end
    local count = #worlds
    -- The engine's world list is a small runtime set. Refuse malformed/unbounded
    -- arrays instead of allocating/copying arbitrary Lua-controlled lengths.
    if count < 1 or count > 256 then return invalidate_world_context('world_list_invalid') end
    local copy = {}
    local main_found, overlay_found = false, false
    for i = 1, count do
        if worlds[i] == nil then return invalidate_world_context('world_list_invalid') end
        copy[i] = worlds[i]
        if worlds[i] == main then main_found = true end
        if worlds[i] ~= main then overlay_found = true end
    end
    if not main_found then return invalidate_world_context('main_world_not_listed') end
    -- Armory draws only after it can find a non-main overlay world. AutoChat keeps
    -- its GUI owned by main_world, but uses the same overlay availability gate.
    if not overlay_found then return invalidate_world_context('overlay_world_unavailable') end
    local had_snapshot = PANEL.context_worlds ~= nil
    local main_changed = PANEL.context_main ~= nil and PANEL.context_main ~= main
    local changed = PANEL.context_worlds == nil or main_changed
                  or not same_world_list(copy, PANEL.context_worlds)
    if changed then
        PANEL.context_worlds, PANEL.context_main = copy, main
        PANEL.context_settled_at = now + WORLD_SETTLE_SECONDS
        PANEL.context_is_settled = false
        PANEL.chat_view_cache = nil
        PANEL.context_status = 'worlds changed; settling'
        M.panel_context = PANEL.context_status
        if PANEL.open and had_snapshot then set_panel_open(false, main_changed) end
        note('panel context changed; waiting 1.5 seconds for worlds to settle')
        write_status('panel context: world identity changed; settling')
        return true, 'settling'
    end
    local was_settled = PANEL.context_is_settled
    PANEL.context_is_settled = now >= (PANEL.context_settled_at or math.huge)
    if PANEL.context_is_settled and not was_settled then
        PANEL.context_status, M.panel_context = 'worlds stable', 'worlds stable'
        note('panel context stable')
        write_status('panel context: worlds stable; checking native chat on request')
    end
    return true, PANEL.context_is_settled and 'stable' or 'settling'
end

-- Native UI-context reader. Its two byte fingerprints intentionally live outside
-- M.CODE: a UI-only mismatch closes/blocks the panel without disabling the sender.
local CHAT_UI_ROOT_PTR_RVA = 0x3326E68
local CHAT_UI_ROOT_SIGNATURE_RVA = 0x1437DD9
local CHAT_UI_ROOT_BYTES = '\72\139\45\136\240\238\1'
local CHAT_UI_FIELD_RVA = 0x185F566
local CHAT_UI_FIELD_BYTES = '\64\136\187\184\57\1\0'
local CHAT_UI_COUNT_OFFSET, CHAT_UI_SLOTS_OFFSET = 0x2be8, 0x2bf0
local CHAT_UI_SLOT_STRIDE, CHAT_UI_TAG, CHAT_UI_FIELD_OFFSET = 16, 0xc3, 0x139b8
local CHAT_UI_MAX_COUNT = 4096
local function u64_off(bytes, offset)
    local lo, hi = u32_off(bytes, offset), u32_off(bytes, offset + 4)
    if not lo or not hi then return nil end
    return lo + hi * 4294967296
end
local function chat_view_state(fresh)
    local base = supported_game_base()
    if not base then return nil, 'native build gate unavailable' end
    if read_at(base + CHAT_UI_ROOT_SIGNATURE_RVA, #CHAT_UI_ROOT_BYTES) ~= CHAT_UI_ROOT_BYTES then
        return nil, 'chat registry fingerprint mismatch'
    end
    if read_at(base + CHAT_UI_FIELD_RVA, #CHAT_UI_FIELD_BYTES) ~= CHAT_UI_FIELD_BYTES then
        return nil, 'chat field fingerprint mismatch'
    end
    local registry = u64(base + CHAT_UI_ROOT_PTR_RVA)
    if not sane_ptr(registry) then return nil, 'chat UI registry unavailable' end
    local count = u32(registry + CHAT_UI_COUNT_OFFSET)
    if not count or count > CHAT_UI_MAX_COUNT then return nil, 'chat UI registry count invalid' end
    local cache = PANEL.chat_view_cache
    if fresh or not cache or cache.registry ~= registry then
        local slots = count > 0 and read_at(registry + CHAT_UI_SLOTS_OFFSET,
                                             count * CHAT_UI_SLOT_STRIDE) or nil
        if not slots then return nil, 'chat UI registry unreadable' end
        local found_index, found_object
        for i = 0, count - 1 do
            local at = i * CHAT_UI_SLOT_STRIDE
            if u32_off(slots, at + 8) == CHAT_UI_TAG then
                local object = u64_off(slots, at)
                if not sane_ptr(object) or found_index then
                    return nil, 'chat view identity ambiguous'
                end
                found_index, found_object = i, object
            end
        end
        if not found_index then return nil, 'chat view is not registered' end
        cache = {registry = registry, count = count, index = found_index, object = found_object}
        PANEL.chat_view_cache = cache
    end
    if cache.registry ~= registry or cache.count ~= count or cache.index >= count then
        PANEL.chat_view_cache = nil
        return nil, 'chat view identity changed'
    end
    local slot = registry + CHAT_UI_SLOTS_OFFSET + cache.index * CHAT_UI_SLOT_STRIDE
    if u32(slot + 8) ~= CHAT_UI_TAG or u64(slot) ~= cache.object then
        PANEL.chat_view_cache = nil
        return nil, 'chat view identity changed'
    end
    local raw = read_at(cache.object + CHAT_UI_FIELD_OFFSET, 1)
    if not raw then return nil, 'chat view state unreadable' end
    local value = raw:byte(1)
    if value ~= 0 and value ~= 1 then return nil, 'chat view state invalid' end
    return value == 1, value == 1 and 'game chat open' or 'game chat closed'
end

local function panel_context_report(state, reason)
    local key = tostring(state) .. ':' .. tostring(reason)
    if PANEL.context_status == key then return end
    PANEL.context_status = key
    M.panel_context = key
    if state == 'blocked' or state == 'unknown' then
        PANEL.guard_hint = M.panel_text(
            '面板暂不可用：' .. tostring(reason),
            'Panel unavailable: ' .. tostring(reason))
        PANEL.hint = PANEL.guard_hint
    elseif PANEL.hint == PANEL.guard_hint then
        PANEL.hint, PANEL.guard_hint = nil, nil
    end
    note('panel context ' .. key)
    write_status('panel context: ' .. key)
end

local function request_panel_open()
    if PANEL.open then return true end
    if not focused() then
        panel_context_report('blocked', 'game window is not focused')
        return false
    end
    if M.frames < 600 then panel_context_report('blocked', 'startup') return false end
    local available, world_state = world_context_sample(true)
    if not available then
        panel_context_report('unknown', world_state)
        return false
    end
    if world_state ~= 'stable' then
        panel_context_report('blocked', world_state)
        return false
    end
    local chat_open, chat_reason = chat_view_state(true)
    if chat_open == nil then
        panel_context_report('unknown', chat_reason)
        return false
    end
    if chat_open then
        panel_context_report('blocked', chat_reason)
        return false
    end
    panel_context_report('ready', chat_reason)
    set_panel_open(true)
    return true
end
return {world_sample=world_context_sample, chat_state=chat_view_state,
        report=panel_context_report, request_open=request_panel_open}
end)()

-- ---------------------------------------------------------------- dest / rebuild
-- The screen GUI is DESTROYED, not left in place. A retained GUI keeps rendering
-- whatever was drawn into it, so the panel would stay on screen after closing and
-- block the HUD underneath. Destroying it also clears the signature, so the next open
-- rebuilds rather than reusing a destroyed handle.
--
-- Assigned to the forward-declared local (see above the cursor table), NOT declared
-- here with `local function`: world_ready above calls it, and a `local` introduced
-- after its reader leaves the reader holding nil.
panel_clear = function(discard_world_gui)
    if sr and PANEL.gui and PANEL.world then
        local owner_live = false
        local ok, owner = false, nil
        if sr.Application and type(sr.Application.main_world) == 'function' then
            ok, owner = pcall(sr.Application.main_world)
        end
        if ok and owner == PANEL.world then
            owner_live = true
        elseif sr.Application and type(sr.Application.worlds) == 'function' then
            -- During a scene transition, the old main world can remain live as a
            -- non-main world. Match Armory's membership check before destroying;
            -- if the owner has left the live set, discard without native access.
            local worlds_ok, worlds = pcall(sr.Application.worlds)
            if worlds_ok and type(worlds) == 'table' then
                local count = #worlds
                if count > 0 and count <= 256 then
                    for i = 1, count do
                        if worlds[i] == PANEL.world then owner_live = true; break end
                    end
                end
            end
        end
        if owner_live then pcall(sr.World.destroy_gui, PANEL.world, PANEL.gui) end
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
    registry.version, registry.api_version, registry.api_revision = 2, 2, 4
    registry.capabilities = {independent_send=true, settings=true, plugin_ui=true, plugin_presets=true}
    local independent_state, context_token = {}, nil
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
    local function current_context()
        local value = context()
        if value ~= context_token then independent_state, context_token = {}, value end
        return value
    end
    local function snapshot_copy(source)
        local seen, remaining, failure = {}, 16384, nil
        local function clone(value, depth)
            local kind = type(value)
            if kind == 'string' or kind == 'boolean' then return value end
            if kind == 'number' then
                return value == value and value ~= math.huge and value ~= -math.huge and value or nil
            end
            if kind ~= 'table' or seen[value] then return nil end
            if depth > 8 then failure = 'settings snapshot too large'; return nil end
            local result = {}; seen[value] = true
            for key, item in next, value do
                if remaining <= 0 then failure = 'settings snapshot too large'; break end
                if type(key) == 'string' and #key <= 128 or type(key) == 'number' then
                    remaining = remaining - 1
                    local copied = clone(item, depth + 1)
                    if copied ~= nil then result[key] = copied end
                end
            end
            seen[value] = nil
            return result
        end
        local result = clone(source, 0)
        if failure then return nil, failure end
        return result
    end
    local function normalize_options(value)
        if value == nil then return {policy='inherit'} end
        if type(value) ~= 'table' then return nil, 'invalid options' end
        local allowed = {policy=true,enabled=true,cooldown=true,cooldown_key=true,allow_solo=true,output=true}
        local count = 0
        for key in pairs(value) do
            if not allowed[key] then return nil, 'unknown send option' end
            count = count + 1
        end
        local policy = value.policy
        if policy == nil then
            if count == 0 then return {policy='inherit'} end
            return nil, 'policy required for send options'
        end
        if policy == 'inherit' then
            if count > 1 then return nil, 'inherit policy does not accept overrides' end
            return {policy='inherit'}
        end
        if policy ~= 'independent' then return nil, 'invalid send policy' end
        local enabled = value.enabled
        if enabled == nil then enabled = true end
        if type(enabled) ~= 'boolean' then return nil, 'invalid enabled option' end
        local allow_solo = value.allow_solo
        if allow_solo == nil then allow_solo = true end
        if type(allow_solo) ~= 'boolean' then return nil, 'invalid allow_solo option' end
        local cooldown = value.cooldown
        if cooldown == nil then cooldown = 0 end
        if type(cooldown) ~= 'number' or cooldown ~= cooldown or cooldown == math.huge
            or cooldown == -math.huge or cooldown < 0 then return nil, 'invalid cooldown option' end
        local cooldown_key = value.cooldown_key
        if cooldown_key == nil then cooldown_key = 'default' end
        if type(cooldown_key) ~= 'string' or #cooldown_key == 0 or #cooldown_key > 64
            or cooldown_key:find('[%c]') then return nil, 'invalid cooldown_key option' end
        local output = value.output
        if output == nil then output = 'inherit' end
        if output ~= 'inherit' and output ~= 'local' and output ~= 'public' then
            return nil, 'invalid output option'
        end
        return {policy='independent',enabled=enabled,cooldown=cooldown,
            cooldown_key=cooldown_key,allow_solo=allow_solo,output=output}
    end
    local function bucket_key(creator_id, cooldown_key)
        local creator = creator_id or '@self'
        if type(env.creator_key) == 'function' then
            local ok, canonical = pcall(env.creator_key, creator_id)
            if not ok or type(canonical) ~= 'string' or canonical == '' then return nil end
            creator = canonical
        end
        return #creator .. ':' .. creator .. ':' .. #cooldown_key .. ':' .. cooldown_key
    end
    local function now()
        local value
        if type(env.now) == 'function' then
            local ok; ok, value = pcall(env.now)
            if not ok then return nil end
        else value = os.time() end
        if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
            return nil
        end
        return value
    end
    local function fault(entry, callback, why)
        entry.faults = entry.faults + 1
        entry.last_error = callback .. ': ' .. tostring(why)
        if entry.faults <= 3 then note(entry.id .. ' ' .. entry.last_error)
        elseif entry.faults == 4 then note(entry.id .. ' further callback faults suppressed') end
    end
    local function valid_plugin_id(id)
        return text(id,64) and id:match('^[%w_.%-]+$')~=nil
    end
    local function copy_preset_blobs(source)
        if source==nil then return {} end
        if type(source)~='table' then return nil,'plugin preset payload map must be a table' end
        local result,total={},0
        for id,data in next,source do
            if not valid_plugin_id(id) then return nil,'invalid plugin preset id' end
            if type(data)~='string' then return nil,'plugin '..id..' preset data must be a string' end
            total=total+#id+#data
            if total>1024*1024 then return nil,'plugin preset data exceeds 1 MiB' end
            result[id]=data
        end
        return result
    end
    local function preset_error(entry,operation,why)
        local message='plugin '..entry.id..' preset '..operation..' failed'
        if why~=nil and tostring(why)~='' then message=message..': '..tostring(why) end
        note(message)
        return message
    end
    local function preset_callback(entry,operation,...)
        local hook=entry._preset and entry._preset[operation]
        local values={pcall(hook,...)}
        if not values[1] then return false,nil,preset_error(entry,operation,values[2]) end
        return true,values[2],values[3]
    end
    function registry.capture_presets(role,previous_blobs)
        if role~='host' and role~='client' then return nil,'invalid plugin preset role' end
        local result,why=copy_preset_blobs(previous_blobs)
        if not result then return nil,why end
        local plugins={};for i,entry in ipairs(registry.plugins) do plugins[i]=entry end
        table.sort(plugins,function(a,b)return a.id<b.id end)
        for _,entry in ipairs(plugins) do
            if registry.by_id[entry.id]==entry and entry._preset then
                local called,data,detail=preset_callback(entry,'capture',role)
                if not called then return nil,detail end
                if type(data)~='string' then
                    return nil,preset_error(entry,'capture',detail or 'expected byte string')
                end
                if #data+#entry.id>1024*1024 then
                    return nil,preset_error(entry,'capture','data exceeds 1 MiB')
                end
                local valid,accepted,validate_why=preset_callback(entry,'validate',data,role)
                if not valid then return nil,validate_why end
                if accepted~=true then return nil,preset_error(entry,'validate',validate_why or 'data rejected') end
                result[entry.id]=data
            end
        end
        local total=0
        for id,data in next,result do
            total=total+#id+#data
            if total>1024*1024 then return nil,'plugin preset data exceeds 1 MiB' end
        end
        return result
    end
    function registry.prepare_presets(blobs,role)
        if role~='host' and role~='client' then return nil,'invalid plugin preset role' end
        local payloads,why=copy_preset_blobs(blobs)
        if not payloads then return nil,why end
        local ids,entries={},{}
        for id in next,payloads do
            local entry=registry.by_id[id]
            if entry and entry._preset then ids[#ids+1]=id;entries[id]=entry end
        end
        table.sort(ids)
        -- Validate every target before asking any plugin for rollback state.
        for _,id in ipairs(ids) do
            local entry=entries[id]
            if registry.by_id[id]~=entry then
                return nil,preset_error(entry,'validate','plugin registration changed')
            end
            local called,accepted,detail=preset_callback(entry,'validate',payloads[id],role)
            if not called then return nil,detail end
            if registry.by_id[id]~=entry then
                return nil,preset_error(entry,'validate','plugin registration changed')
            end
            if accepted~=true then return nil,preset_error(entry,'validate',detail or 'data rejected') end
        end
        local participants={}
        for _,id in ipairs(ids) do
            local entry=entries[id]
            if registry.by_id[id]~=entry then
                return nil,preset_error(entry,'capture','plugin registration changed')
            end
            local called,old_data,detail=preset_callback(entry,'capture',role)
            if not called then return nil,detail end
            if registry.by_id[id]~=entry then
                return nil,preset_error(entry,'capture','plugin registration changed')
            end
            if type(old_data)~='string' then
                return nil,preset_error(entry,'capture',detail or 'expected byte string')
            end
            if #old_data+#id>1024*1024 then
                return nil,preset_error(entry,'capture','rollback data exceeds 1 MiB')
            end
            local valid,accepted,validate_why=preset_callback(entry,'validate',old_data,role)
            if not valid then return nil,validate_why end
            if registry.by_id[id]~=entry then
                return nil,preset_error(entry,'validate','plugin registration changed')
            end
            if accepted~=true then return nil,preset_error(entry,'validate','rollback data rejected: '..tostring(validate_why or '')) end
            participants[#participants+1]={id=id,entry=entry,data=payloads[id],old_data=old_data}
        end
        for _,item in ipairs(participants) do
            if registry.by_id[item.id]~=item.entry then
                return nil,preset_error(item.entry,'prepare','plugin registration changed')
            end
        end
        local tx={state='prepared',attempted={}}
        function tx.commit()
            if tx.state~='prepared' then return false,'plugin preset transaction is not prepared' end
            tx.state='committing'
            for _,item in ipairs(participants) do
                tx.attempted[#tx.attempted+1]=item -- apply may fail after changing plugin state
                if registry.by_id[item.id]~=item.entry then
                    tx.failure=preset_error(item.entry,'apply','plugin registration changed')
                    tx.state='failed'
                    return false,tx.failure
                end
                local called,accepted,detail=preset_callback(item.entry,'apply',item.data,role)
                if not called then
                    tx.failure=detail;tx.state='failed';return false,detail
                end
                if accepted~=true then
                    tx.failure=preset_error(item.entry,'apply',detail or 'data rejected')
                    tx.state='failed';return false,tx.failure
                end
            end
            tx.state='committed'
            return true
        end
        function tx.rollback()
            if tx.state~='failed' and tx.state~='committed' then
                return false,'plugin preset transaction cannot be rolled back in this state'
            end
            tx.state='rolling_back'
            local failures={}
            for i=#tx.attempted,1,-1 do
                local item=tx.attempted[i]
                local called,restored,detail=preset_callback(item.entry,'restore',item.old_data,role)
                if not called then failures[#failures+1]=item.id..' ('..tostring(detail)..')'
                elseif restored~=true then
                    local message=preset_error(item.entry,'restore',detail or 'rollback rejected')
                    failures[#failures+1]=item.id..' ('..message..')'
                end
            end
            tx.state='rolled_back'
            if #failures>0 then return false,'plugin preset rollback failed: '..table.concat(failures,', ') end
            return true
        end
        return tx
    end
    local function api_for(entry)
        local token = context()
        local api = {version = 2, api_version = 2, api_revision = 4,
            capabilities = registry.capabilities, id = entry.id,
            context = context,
            send = function(value, creator_id, options)
                if registry.by_id[entry.id] ~= entry then return false, 'plugin unregistered' end
                if context() ~= token then return false, 'session changed' end
                return registry.send(entry.id, value, creator_id, options)
            end,
            settings = function()
                if registry.by_id[entry.id] ~= entry then return nil, 'plugin unregistered' end
                if context() ~= token then return nil, 'session changed' end
                return registry.settings(entry.id)
            end}
        return api
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
        local name_en = rawget(spec, 'name_en')
        if not text(id, 64) or not id:match('^[%w_.%-]+$') then return nil, 'invalid plugin id' end
        if not text(title, 96) then return nil, 'invalid plugin name' end
        if name_en ~= nil and not text(name_en, 96) then return nil, 'invalid English plugin name' end
        if registry.by_id[id] then return nil, 'plugin id already registered' end
        if #registry.plugins >= 16 then return nil, 'maximum 16 plugins' end
        if type(rawget(spec, 'draw')) ~= 'function' then return nil, 'draw callback required' end
        for _, name in ipairs({'on_click', 'revision', 'on_event'}) do
            if rawget(spec, name) ~= nil and type(rawget(spec, name)) ~= 'function' then
                return nil, 'invalid ' .. name .. ' callback'
            end
        end
        local preset=rawget(spec,'preset')
        if preset~=nil then
            if type(preset)~='table' then return nil,'invalid preset hooks' end
            for _,name in ipairs({'capture','validate','apply','restore'}) do
                if type(rawget(preset,name))~='function' then return nil,'incomplete preset hooks: '..name end
            end
        end
        local entry = {id = id, title = title, name = title, name_en = name_en, faults = 0,
            _draw = rawget(spec, '_draw') or rawget(spec, 'draw'),
            _on_click = rawget(spec, '_on_click') or rawget(spec, 'on_click'),
            _revision = rawget(spec, '_revision') or rawget(spec, 'revision'),
            _on_event = rawget(spec, '_on_event') or rawget(spec, 'on_event'),
            _preset = preset and {capture=rawget(preset,'capture'),validate=rawget(preset,'validate'),
                apply=rawget(preset,'apply'),restore=rawget(preset,'restore')} or nil}
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
        registry.by_id[id], independent_state[id], registry.serial = nil, nil, registry.serial + 1
        note('unregistered ' .. id)
        return true
    end
    function registry.settings(id)
        if type(id) ~= 'string' or not registry.by_id[id] then return nil, 'plugin unregistered' end
        current_context()
        if type(env.settings) ~= 'function' then return nil, 'settings unavailable' end
        local ok, value, why = pcall(env.settings, id)
        if not ok then note(id .. ' settings failed: ' .. tostring(value)); return nil, 'settings unavailable' end
        if type(value) ~= 'table' then return nil, why or 'role unavailable' end
        local snapshot, copy_error = snapshot_copy(value)
        if type(snapshot) ~= 'table' then return nil, copy_error or 'settings unavailable' end
        return snapshot
    end
    function registry.send(id, value, creator_id, options)
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
        local normalized, option_error = normalize_options(options)
        if not normalized then return false, option_error end
        local token = current_context()
        local stamp
        local bucket
        if normalized.policy == 'independent' then
            if not normalized.enabled then return false, 'independent send disabled' end
            stamp = now()
            if stamp == nil then return false, 'clock unavailable' end
            local ledger = independent_state[id]
            if not ledger then ledger = {}; independent_state[id] = ledger end
            bucket = bucket_key(creator_id, normalized.cooldown_key)
            if not bucket then return false, 'trigger player unavailable' end
            for key, record in pairs(ledger) do
                if stamp >= record.expires or record.context ~= token then ledger[key] = nil end
            end
            local existing = normalized.cooldown > 0 and ledger[bucket] or nil
            if existing and stamp < existing.expires then return false, 'independent cooldown' end
            if normalized.cooldown > 0 and not existing then
                local count = 0; for _ in pairs(ledger) do count = count + 1 end
                if count >= 128 then return false, 'independent cooldown capacity reached' end
            end
        end
        local ok, sent, why = pcall(env.send, value, id, creator_id, normalized)
        if not ok then
            note(id .. ' sender failed: ' .. tostring(sent))
            return false, 'sender failed'
        end
        if sent == true and normalized.policy == 'independent' and normalized.cooldown > 0 then
            local ledger = independent_state[id] or {}; independent_state[id] = ledger
            ledger[bucket] = {expires=stamp + normalized.cooldown, context=token}
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
    now = function() return os.time() end,
    creator_key = function(peer) return automation.canonical_peer(peer) end,
    settings = function()
        local role = automation.sync()
        if not role then return nil, 'role unavailable' end
        local snapshot, why = automation.settings()
        if not snapshot then return nil, why end
        local tasks = M.profile_tasks(role)
        snapshot.language = M.language.current()
        snapshot.tasks = {}
        for i, task in ipairs(tasks) do
            snapshot.tasks[i] = {name=task.name,mode=task.mode,time=task.time,
                message=task.message,enabled=task.enabled == true}
        end
        return snapshot
    end,
    send = function(text, id, creator_id, options)
        options = type(options) == 'table' and options or {policy='inherit'}
        local role = automation.sync()
        if not role then return false, 'role unavailable' end
        local now = os.time()
        if creator_id and not automation.has_peer(creator_id) then return false, 'trigger player unavailable' end
        local independent = options.policy == 'independent'
        local allow_solo = independent and options.allow_solo or true
        if independent and options.allow_solo == false then allow_solo = false end
        local chat, others = send_context(allow_solo)
        if not chat then return false, others end
        if not independent then
            local allowed, why = automation.check(now, others, creator_id)
            if not allowed then return false, why end
        end
        local profile = automation.profile(role)
        local output = options.output or 'inherit'
        if output == 'inherit' then output = profile.output end
        if output == 'public' then output = 'squad' end
        if output ~= 'local' and output ~= 'squad' then return false, 'invalid output policy' end
        local sent, reason = automation.send(automation.format(text,creator_id,nil,false,false,profile.message_language), role, output)
        if sent and not independent then automation.record(now,creator_id) end
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
-- BEGIN PLUGIN UI
-- Build a bounded drawing facade for one registered plugin body.
-- UX and image callbacks close over the host GUI; none of those native objects
-- are returned to plugin code.
M.build_plugin_ui = function(env)
    env = type(env) == 'table' and env or {}
    local UX = type(env.UX) == 'table' and env.UX or {}
    local ctx = type(env.context) == 'table' and env.context or {}
    local dx, dy = ctx.ox or 0, ctx.oy or 0
    local content_w = ctx.content_w or ((ctx.w or 1000) - 44)
    local content_h = ctx.content_h or ((ctx.h or 990) - dy - 22)
    local palette = UX.palette or {}
    local MAX_LINE_SEGMENTS = 512

    local function finite(value)
        return type(value) == 'number' and value == value
            and value < math.huge and value > -math.huge
    end

    local function area(x, y, w, h)
        if not finite(x) or not finite(y) or not finite(w) or not finite(h)
            or w <= 0 or h <= 0 then
            return false, 'invalid_geometry'
        end
        if x < 0 or y < 0 or x + w > content_w or y + h > content_h then
            return false, 'out_of_bounds'
        end
        return true
    end

    local function z_value(z, fallback)
        if z == nil then return fallback end
        return finite(z) and z or nil
    end

    local function forwarded(ok, reason, fn, ...)
        if not ok then return false, reason end
        if type(fn) ~= 'function' then return false, 'drawing_unavailable' end
        local result, detail = fn(...)
        if result == nil then return true end
        if detail == nil then return result end
        return result, detail
    end

    local function utf8_length(value)
        local count = 0
        for i = 1, #value do
            local byte = value:byte(i)
            if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
        end
        return count
    end

    local api = {
        w = ctx.w, h = ctx.h, content_w = content_w, content_h = content_h,
        body_y = dy, scale = ctx.scale or UX.s,
        colour = UX.colour, palette = palette,
        loaded_icon = ctx.loaded_icon,
        language = ctx.language,
        version = env.version,
    }

    api.text = function(value, x, y, size, colour, limit, align)
        if value == nil or value == '' then return 0 end
        local ok, string_value = pcall(tostring, value)
        if not ok then return false, 'invalid_text' end
        size = size == nil and 14 or size
        if not finite(x) or not finite(y) or not finite(size) or size <= 0
            or (limit ~= nil and (not finite(limit) or limit <= 0)) then
            return false, 'invalid_geometry'
        end
        local draw_limit = limit
        if draw_limit == nil then
            if align == 'right' then
                draw_limit = x
            elseif align == 'center' then
                draw_limit = 2 * math.min(x, content_w - x)
            else
                draw_limit = content_w - x
            end
        end
        local estimated_width = limit or (utf8_length(string_value) * size * 0.62)
        local left = x
        if align == 'right' then left = x - estimated_width
        elseif align == 'center' then left = x - estimated_width / 2 end
        local valid, reason = area(left, y, estimated_width, size)
        if not valid then return false, reason end
        if align == nil then
            return forwarded(true, nil, UX.text, string_value, x + dx, y + dy,
                size, colour, draw_limit)
        end
        return forwarded(true, nil, UX.text, string_value, x + dx, y + dy,
            size, colour, draw_limit, align)
    end

    api.rect = function(x, y, w, h, colour, z)
        local valid, reason = area(x, y, w, h)
        if not valid then return false, reason end
        z = z_value(z, 951)
        if not z then return false, 'invalid_geometry' end
        return forwarded(true, nil, UX.rect, x + dx, y + dy, w, h, colour, z)
    end

    api.border = function(x, y, w, h, colour, z)
        local valid, reason = area(x, y, w, h)
        if not valid then return false, reason end
        z = z_value(z, 952)
        if not z then return false, 'invalid_geometry' end
        return forwarded(true, nil, UX.border, x + dx, y + dy, w, h, colour, z)
    end

    api.region = function(key, x, y, w, h)
        local valid, reason = area(x, y, w, h)
        if not valid then return false, reason end
        if type(UX.region) ~= 'function' then return false, 'drawing_unavailable' end
        UX.region('plugin:' .. tostring(ctx.id or '') .. ':' .. tostring(key),
            x + dx, y + dy, w, h)
        return true
    end

    api.button = function(key, value, x, y, w, h, enabled, active)
        local valid, reason = area(x, y, w, h)
        if not valid then return false, reason end
        local full = 'plugin:' .. tostring(ctx.id or '') .. ':' .. tostring(key)
        local hovered = ctx.hover == full
        local fill = active and palette.YELLOW or hovered and palette.ROW_HI or palette.PANEL
        local border = active and palette.YELLOW or hovered and palette.TEXT or palette.LINE2
        UX.rect(x + dx, y + dy, w, h, fill, 951)
        UX.border(x + dx, y + dy, w, h, border, 952)
        if w > 16 and h > 16 then
            api.text(tostring(value), x + 8, y + 8, 14,
                active and palette.INK or enabled == false and palette.DIM or palette.TEXT,
                w - 16)
        end
        if enabled ~= false then
            UX.region(full, x + dx, y + dy, w, h)
        end
        return true
    end

    api.line = function(x1, y1, x2, y2, colour, z, width)
        width = width == nil and 1 or width
        z = z_value(z, 953)
        if not finite(x1) or not finite(y1) or not finite(x2) or not finite(y2)
            or not finite(width) or width <= 0 or not z then
            return false, 'invalid_geometry'
        end
        local dx_line, dy_line = x2 - x1, y2 - y1
        local major = math.max(math.abs(dx_line), math.abs(dy_line))
        if major == 0 then
            local valid, reason = area(x1 - width / 2, y1 - width / 2, width, width)
            if not valid then return false, reason end
            if type(UX.rect) ~= 'function' then return false, 'drawing_unavailable' end
            UX.rect(x1 + dx - width / 2, y1 + dy - width / 2,
                width, width, colour or palette.TEXT, z)
            return true
        end
        if dy_line == 0 then
            local valid, reason = area(math.min(x1, x2), y1 - width / 2,
                math.max(major, width), width)
            if not valid then return false, reason end
            if type(UX.rect) ~= 'function' then return false, 'drawing_unavailable' end
            UX.rect(math.min(x1, x2) + dx, y1 + dy - width / 2,
                math.max(major, width), width, colour or palette.TEXT, z)
            return true
        elseif dx_line == 0 then
            local valid, reason = area(x1 - width / 2, math.min(y1, y2),
                width, math.max(major, width))
            if not valid then return false, reason end
            if type(UX.rect) ~= 'function' then return false, 'drawing_unavailable' end
            UX.rect(x1 + dx - width / 2, math.min(y1, y2) + dy,
                width, math.max(major, width), colour or palette.TEXT, z)
            return true
        end
        local steps = math.max(1, math.ceil(major / 2))
        if steps > MAX_LINE_SEGMENTS then return false, 'line_too_long' end
        local interval = major / steps
        local stamp = math.max(width, interval + 0.25)
        local left, right = math.min(x1, x2) - stamp / 2, math.max(x1, x2) + stamp / 2
        local top, bottom = math.min(y1, y2) - stamp / 2, math.max(y1, y2) + stamp / 2
        if left < 0 or top < 0 or right > content_w or bottom > content_h then
            return false, 'out_of_bounds'
        end
        if type(UX.rect) ~= 'function' then return false, 'drawing_unavailable' end
        for i = 0, steps do
            local t = i / steps
            local x, y = x1 + dx_line * t, y1 + dy_line * t
            UX.rect(x + dx - stamp / 2, y + dy - stamp / 2,
                stamp, stamp, colour or palette.TEXT, z)
        end
        return true
    end

    api.image = function(resource, x, y, w, h, colour, z)
        if type(resource) ~= 'string' or #resource ~= 16 or not resource:match('^%x+$') then
            return false, 'invalid_resource'
        end
        local valid, reason = area(x, y, w, h)
        if not valid then return false, reason end
        z = z_value(z, 953)
        if not z then return false, 'invalid_geometry' end
        if type(env.draw_image) ~= 'function' then return false, 'image_unavailable' end
        local ok, result, why = pcall(env.draw_image, resource, x + dx, y + dy,
            w, h, colour or palette.TEXT, z)
        if not ok then return false, 'image_draw_failed' end
        if result == true then return true end
        return false, why or 'material_unavailable'
    end

    api.icon = function(resource, x, y, size, colour, z)
        if not finite(size) or size <= 0 then return false, 'invalid_geometry' end
        return api.image(resource, x, y, size, size, colour, z)
    end

    api.note = type(env.note) == 'function' and env.note or function() end
    return api
end

-- END PLUGIN UI

local function plugin_api(ctx)
    return M.build_plugin_ui({UX=UX, context=ctx, note=plugin_note, version=M.version,
        draw_image=function(...)
            if type(UX.image) ~= 'function' then return false,'image_unavailable' end
            return UX.image(...)
        end})
end


PANEL._signature_cache = PANEL._signature_cache or {frames={},depth=0}
PANEL._signature_cache.collect = function(frame)
    local opts = automation.profile(PANEL.profile or 'host')
    local s, ox, oy = PANEL.ui_s, PANEL.ui_ox, PANEL.ui_oy
    local initial = frame.signature == nil
    frame.changed = initial
    do local value = PANEL.rw
        if initial or frame.raw[1] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[1]~=1/value) then
            frame.raw[1] = value
            frame.parts[1] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.rh
        if initial or frame.raw[2] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[2]~=1/value) then
            frame.raw[2] = value
            frame.parts[2] = tostring(value); frame.changed = true
        end end
    do local value = s or 0
        if initial or frame.raw[3] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[3]~=1/value) then
            frame.raw[3] = value
            local text = string.format('%.3f', value)
            if frame.parts[3] ~= text then frame.parts[3] = text; frame.changed = true end
        end end
    do local value = ox or 0
        if initial or frame.raw[4] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[4]~=1/value) then
            frame.raw[4] = value
            frame.parts[4] = tostring(value); frame.changed = true
        end end
    do local value = oy or 0
        if initial or frame.raw[5] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[5]~=1/value) then
            frame.raw[5] = value
            frame.parts[5] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.hover
        if initial or frame.raw[6] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[6]~=1/value) then
            frame.raw[6] = value
            frame.parts[6] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.editing
        if initial or frame.raw[7] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[7]~=1/value) then
            frame.raw[7] = value
            frame.parts[7] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.hint
        if initial or frame.raw[8] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[8]~=1/value) then
            frame.raw[8] = value
            frame.parts[8] = tostring(value); frame.changed = true
        end end
    do local value = M.language.current()
        if initial or frame.raw[9] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[9]~=1/value) then
            frame.raw[9] = value
            frame.parts[9] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.edit_text
        if initial or frame.raw[10] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[10]~=1/value) then
            frame.raw[10] = value
            frame.parts[10] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.edit_field
        if initial or frame.raw[11] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[11]~=1/value) then
            frame.raw[11] = value
            frame.parts[11] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.pos and PANEL.pos.fx or '-'
        if initial or frame.raw[12] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[12]~=1/value) then
            frame.raw[12] = value
            frame.parts[12] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.pos and PANEL.pos.fy or '-'
        if initial or frame.raw[13] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[13]~=1/value) then
            frame.raw[13] = value
            frame.parts[13] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.ui_scale or 1
        if initial or frame.raw[14] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[14]~=1/value) then
            frame.raw[14] = value
            frame.parts[14] = tostring(value); frame.changed = true
        end end
    do local value = draft.name
        if initial or frame.raw[15] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[15]~=1/value) then
            frame.raw[15] = value
            frame.parts[15] = tostring(value); frame.changed = true
        end end
    do local value = draft.mode
        if initial or frame.raw[16] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[16]~=1/value) then
            frame.raw[16] = value
            frame.parts[16] = tostring(value); frame.changed = true
        end end
    do local value = draft.time
        if initial or frame.raw[17] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[17]~=1/value) then
            frame.raw[17] = value
            frame.parts[17] = tostring(value); frame.changed = true
        end end
    do local value = draft.message
        if initial or frame.raw[18] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[18]~=1/value) then
            frame.raw[18] = value
            frame.parts[18] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.profile or 'host'
        if initial or frame.raw[19] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[19]~=1/value) then
            frame.raw[19] = value
            frame.parts[19] = tostring(value); frame.changed = true
        end end
    do local value = automation.state.active_role or '-'
        if initial or frame.raw[20] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[20]~=1/value) then
            frame.raw[20] = value
            frame.parts[20] = tostring(value); frame.changed = true
        end end
    do local value = opts.output
        if initial or frame.raw[21] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[21]~=1/value) then
            frame.raw[21] = value
            frame.parts[21] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.settings_view
        if initial or frame.raw[22] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[22]~=1/value) then
            frame.raw[22] = value
            frame.parts[22] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.enabled) or '-'
        if initial or frame.raw[23] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[23]~=1/value) then
            frame.raw[23] = value
            frame.parts[23] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.rule_view
        if initial or frame.raw[24] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[24]~=1/value) then
            frame.raw[24] = value
            frame.parts[24] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.rule_selected
        if initial or frame.raw[25] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[25]~=1/value) then
            frame.raw[25] = value
            frame.parts[25] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.rule_page
        if initial or frame.raw[26] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[26]~=1/value) then
            frame.raw[26] = value
            frame.parts[26] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.rule_filter
        if initial or frame.raw[27] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[27]~=1/value) then
            frame.raw[27] = value
            frame.parts[27] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.rule_search
        if initial or frame.raw[28] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[28]~=1/value) then
            frame.raw[28] = value
            frame.parts[28] = tostring(value); frame.changed = true
        end end
    do local value = automation.state.rule_revision
        if initial or frame.raw[29] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[29]~=1/value) then
            frame.raw[29] = value
            frame.parts[29] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.preset_view
        if initial or frame.raw[30] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[30]~=1/value) then
            frame.raw[30] = value
            frame.parts[30] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.preset_selected_by_role and PANEL.preset_selected_by_role[PANEL.profile or 'host']
        if initial or frame.raw[31] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[31]~=1/value) then
            frame.raw[31] = value
            frame.parts[31] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.preset_page_by_role and PANEL.preset_page_by_role[PANEL.profile or 'host']
        if initial or frame.raw[32] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[32]~=1/value) then
            frame.raw[32] = value
            frame.parts[32] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.preset_name
        if initial or frame.raw[33] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[33]~=1/value) then
            frame.raw[33] = value
            frame.parts[33] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.preset_path
        if initial or frame.raw[34] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[34]~=1/value) then
            frame.raw[34] = value
            frame.parts[34] = tostring(value); frame.changed = true
        end end
    do local value = preset_library.state.revision
        if initial or frame.raw[35] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[35]~=1/value) then
            frame.raw[35] = value
            frame.parts[35] = tostring(value); frame.changed = true
        end end
    do local value = preset_library.state.error
        if initial or frame.raw[36] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[36]~=1/value) then
            frame.raw[36] = value
            frame.parts[36] = tostring(value); frame.changed = true
        end end
    do local value = stratagem_catalog.state.generation
        if initial or frame.raw[37] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[37]~=1/value) then
            frame.raw[37] = value
            frame.parts[37] = tostring(value); frame.changed = true
        end end
    do local value = stratagem_catalog.state.status
        if initial or frame.raw[38] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[38]~=1/value) then
            frame.raw[38] = value
            frame.parts[38] = tostring(value); frame.changed = true
        end end
    do local value = opts.ping_small_enemy
        if initial or frame.raw[39] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[39]~=1/value) then
            frame.raw[39] = value
            frame.parts[39] = tostring(value); frame.changed = true
        end end
    do local value = opts.ping_flying_enemy
        if initial or frame.raw[40] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[40]~=1/value) then
            frame.raw[40] = value
            frame.parts[40] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.allow_solo) or '-'
        if initial or frame.raw[41] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[41]~=1/value) then
            frame.raw[41] = value
            frame.parts[41] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.welcome) or '-'
        if initial or frame.raw[42] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[42]~=1/value) then
            frame.raw[42] = value
            frame.parts[42] = tostring(value); frame.changed = true
        end end
    do local value = opts and opts.welcome_message or '-'
        if initial or frame.raw[43] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[43]~=1/value) then
            frame.raw[43] = value
            frame.parts[43] = tostring(value); frame.changed = true
        end end
    do local value = opts and opts.cooldown or '-'
        if initial or frame.raw[44] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[44]~=1/value) then
            frame.raw[44] = value
            frame.parts[44] = tostring(value); frame.changed = true
        end end
    do local value = opts and opts.welcome_delay or '-'
        if initial or frame.raw[45] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[45]~=1/value) then
            frame.raw[45] = value
            frame.parts[45] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping) or '-'
        if initial or frame.raw[46] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[46]~=1/value) then
            frame.raw[46] = value
            frame.parts[46] = tostring(value); frame.changed = true
        end end
    do local value = opts and opts.ping_message or '-'
        if initial or frame.raw[47] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[47]~=1/value) then
            frame.raw[47] = value
            frame.parts[47] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_summon) or '-'
        if initial or frame.raw[48] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[48]~=1/value) then
            frame.raw[48] = value
            frame.parts[48] = tostring(value); frame.changed = true
        end end
    do local value = opts and opts.summon_message or '-'
        if initial or frame.raw[49] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[49]~=1/value) then
            frame.raw[49] = value
            frame.parts[49] = tostring(value); frame.changed = true
        end end
    do local value = opts and opts.task_stratagem_message or '-'
        if initial or frame.raw[50] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[50]~=1/value) then
            frame.raw[50] = value
            frame.parts[50] = tostring(value); frame.changed = true
        end end
    do local value = M.task_stratagem_status
        if initial or frame.raw[51] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[51]~=1/value) then
            frame.raw[51] = value
            frame.parts[51] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_building) or '-'
        if initial or frame.raw[52] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[52]~=1/value) then
            frame.raw[52] = value
            frame.parts[52] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_stratagem) or '-'
        if initial or frame.raw[53] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[53]~=1/value) then
            frame.raw[53] = value
            frame.parts[53] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_medium_enemy) or '-'
        if initial or frame.raw[54] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[54]~=1/value) then
            frame.raw[54] = value
            frame.parts[54] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_large_enemy) or '-'
        if initial or frame.raw[55] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[55]~=1/value) then
            frame.raw[55] = value
            frame.parts[55] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_giant_enemy) or '-'
        if initial or frame.raw[56] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[56]~=1/value) then
            frame.raw[56] = value
            frame.parts[56] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_map) or '-'
        if initial or frame.raw[57] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[57]~=1/value) then
            frame.raw[57] = value
            frame.parts[57] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_sender_prefix) or '-'
        if initial or frame.raw[58] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[58]~=1/value) then
            frame.raw[58] = value
            frame.parts[58] = tostring(value); frame.changed = true
        end end
    do local value = opts and tostring(opts.ping_sender_color) or '-'
        if initial or frame.raw[59] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[59]~=1/value) then
            frame.raw[59] = value
            frame.parts[59] = tostring(value); frame.changed = true
        end end
    do local value = M.ping_status
        if initial or frame.raw[60] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[60]~=1/value) then
            frame.raw[60] = value
            frame.parts[60] = tostring(value); frame.changed = true
        end end
    do local value = task_revision
        if initial or frame.raw[61] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[61]~=1/value) then
            frame.raw[61] = value
            frame.parts[61] = tostring(value); frame.changed = true
        end end
    -- Keep the legacy signature position stable; scroll offsets have dedicated slots.
    do local value = 1
        if initial or frame.raw[62] ~= value then
            frame.raw[62] = value
            frame.parts[62] = tostring(value); frame.changed = true
        end end
    do local value = cfg.timer_on and 'on' or 'off'
        if initial or frame.raw[63] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[63]~=1/value) then
            frame.raw[63] = value
            frame.parts[63] = tostring(value); frame.changed = true
        end end
    do local value = cfg.interval
        if initial or frame.raw[64] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[64]~=1/value) then
            frame.raw[64] = value
            frame.parts[64] = tostring(value); frame.changed = true
        end end
    do local value = cfg.elapsed
        if initial or frame.raw[65] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[65]~=1/value) then
            frame.raw[65] = value
            local text = string.format('%.0f', value)
            if frame.parts[65] ~= text then frame.parts[65] = text; frame.changed = true end
        end end
    do local value = cfg.message
        if initial or frame.raw[66] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[66]~=1/value) then
            frame.raw[66] = value
            frame.parts[66] = tostring(value); frame.changed = true
        end end
    do local value = M.sent or 0
        if initial or frame.raw[67] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[67]~=1/value) then
            frame.raw[67] = value
            frame.parts[67] = tostring(value); frame.changed = true
        end end
    do local value = M.last_peers or '-'
        if initial or frame.raw[68] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[68]~=1/value) then
            frame.raw[68] = value
            frame.parts[68] = tostring(value); frame.changed = true
        end end
    do local value = M.version
        if initial or frame.raw[69] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[69]~=1/value) then
            frame.raw[69] = value
            frame.parts[69] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.version
        if initial or frame.raw[70] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[70]~=1/value) then
            frame.raw[70] = value
            frame.parts[70] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.active_plugin
        if initial or frame.raw[71] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[71]~=1/value) then
            frame.raw[71] = value
            frame.parts[71] = tostring(value); frame.changed = true
        end end
    do local value = REGISTRY.signature()
        if initial or frame.raw[72] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[72]~=1/value) then
            frame.raw[72] = value
            frame.parts[72] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.tab_page or 1
        if initial or frame.raw[73] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[73]~=1/value) then
            frame.raw[73] = value
            frame.parts[73] = tostring(value); frame.changed = true
        end end
    do local value = M.last_send and ((M.last_send.ok and 'ok:' or 'no:') .. tostring(M.last_send.why)) or '-'
        if initial or frame.raw[74] ~= value or (type(value)=='number' and value==0 and 1/frame.raw[74]~=1/value) then
            frame.raw[74] = value
            frame.parts[74] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.scroll_offsets and PANEL.scroll_offsets.pings or 0
        if initial or frame.raw[75] ~= value then
            frame.raw[75] = value; frame.parts[75] = tostring(value); frame.changed = true
        end end
    do local value = PANEL.scroll_offsets and PANEL.scroll_offsets.tasks or 0
        if initial or frame.raw[76] ~= value then
            frame.raw[76] = value; frame.parts[76] = tostring(value); frame.changed = true
        end end
    do local value = M.panel_locale and M.panel_locale() or M.language.current()
        if initial or frame.raw[77] ~= value then
            frame.raw[77] = value; frame.parts[77] = tostring(value); frame.changed = true
        end end
    if frame.changed then
        frame.epoch = (frame.epoch or 0) + 1
        frame.signature = table.concat(frame.parts, '|')
    end
    return frame.signature
end
local function panel_signature()
    local cache = PANEL._signature_cache
    cache.depth = cache.depth + 1
    local depth = cache.depth
    local frame = cache.frames[depth]
    if not frame then frame = {raw={},parts={}}; cache.frames[depth] = frame end
    local ok, result = pcall(cache.collect, frame)
    cache.depth = depth - 1
    if not ok then error(result, 0) end
    return result
end

-- The plugin selected in the tab strip; nil means the default settings.
PANEL.active_plugin = PANEL.active_plugin

-- BEGIN ALERT PANEL
-- Dedicated configuration views using the existing Armory frame/input owner.
-- No native reads here; catalog rows and safely bound icons come from the host.
local function draw_alert_panel(canvas,p,a,catalog,chinese,version,status_text)
    local C=canvas.palette
    local function say(cn,en) return chinese and cn or en end
    local function text(v,x,y,size,c,w) canvas.text(v,x,y,size or 14,c or C.TEXT,w) end
    local function row_name(row)
        if chinese then return row.display_name or row.name or row.debug_name or tostring(row.id) end
        return row.display_name_en or row.name_en or row.debug_name or row.name or row.display_name or tostring(row.id)
    end
    local function button(key,value,x,y,w,on,disabled)
        canvas.rect(x,y,w,32,disabled and C.FIELD or on and C.YELLOW or p.hover==key and C.ROW_HI or C.PANEL,951)
        canvas.border(x,y,w,32,disabled and C.LINE2 or on and C.YELLOW or C.LINE2,952)
        text(value,x+9,y+8,13,disabled and C.DIM or on and C.INK or C.TEXT,w-18)
        if not disabled then canvas.region(key,x,y,w,32) end
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
        local groups={{'red','红战备','RED'}, {'blue','蓝战备','BLUE'}, {'green','绿战备','GREEN'},
            {'mission','任务战备','MISSION STRATAGEMS'}}
        for i,v in ipairs(groups) do
            local y=237+(i-1)*38
            local total,enabled_count=0,0
            for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
                if (v[1]=='mission' and row.family=='mission') or (v[1]~='mission' and row.group==v[1]) then
                    total=total+1
                    if a.rule('stratagem',row.id,role).enabled~=false then enabled_count=enabled_count+1 end
                end
            end
            text(say(v[2],v[3])..' '..enabled_count..'/'..total,22,y+9,14,C.TEXT,104)
            button('rules:bulk:'..v[1]..':on',say('全部启用','ENABLE ALL'),130,y,128,false)
            button('rules:bulk:'..v[1]..':off',say('全部关闭','DISABLE ALL'),266,y,112,false)
        end
        local x=22
        for _,v in ipairs({{'all','全部','ALL'},{'red','红','RED'},{'blue','蓝','BLUE'},
            {'green','绿','GREEN'},{'mission','任务','MISSION'}}) do
            button('rules:filter:'..v[1],say(v[2],v[3]),x,390,80,(p.rule_filter or 'all')==v[1]);x=x+86
        end
        canvas.rect(22,432,424,32,C.FIELD,951);canvas.border(22,432,424,32,C.LINE2,952)
        local search=p.edit_field=='rules:search' and p.edit_text or p.rule_search or ''
        text(search~='' and search or say('搜索名称或 ID（点击输入）','SEARCH NAME / ID'),30,440,14,C.MUTED,408)
        canvas.region('rules:search',22,432,424,32)
        local query=(p.rule_search or ''):lower()
        for _,row in ipairs(catalog.list_rules and catalog.list_rules() or catalog.list()) do
            local filter=p.rule_filter or 'all'
            local matches_filter=filter=='all' or (filter=='mission' and row.family=='mission')
                or (filter=='other' and row.group=='other' and row.family~='mission')
                or (filter~='mission' and filter~='other' and row.group==filter)
            if matches_filter
                and (query=='' or row_name(row):lower():find(query,1,true)
                    or tostring(row.id):find(query,1,true)
                    or (row.debug_name or row.name or ''):lower():find(query,1,true)) then rows[#rows+1]=row end
        end
        text(status_text and status_text(catalog.state.status) or catalog.state.status,22,472,12,C.MUTED,424)
    end
    local selected
    for _,row in ipairs(rows) do if tostring(row.id)==tostring(p.rule_selected) then selected=row end end
    selected=selected or rows[1];p.rule_selected=selected and selected.id or nil
    local batch_fields={{'mark_message',say('标记消息','MARK MESSAGE')},
        {'call_message',say('召唤 / 执行消息','CALL / TASK MESSAGE')},
        {'cooldown',say('独立冷却（秒）：空 = 默认；0 合法','RULE COOLDOWN: BLANK = DEFAULT; 0 IS VALID')}}
    local function batch_toggle()
        local key=p.rule_batch_edit and 'rules:batch:close' or 'rules:batch:open'
        button(key,p.rule_batch_edit and say('返回单项编辑','BACK TO SINGLE RULE')
            or say('批量编辑筛选 ('..#rows..')','BULK EDIT FILTER ('..#rows..')'),724,334,236,false)
    end
    local function draw_batch_fields()
        text(say('对当前筛选的全部匹配项应用；包含其他分页。','APPLIES TO ALL FILTER MATCHES, INCLUDING OTHER PAGES.'),486,378,13,C.YELLOW,474)
        p.rule_batch_drafts=p.rule_batch_drafts or {}
        p.rule_batch_drafts[role]=p.rule_batch_drafts[role] or {}
        local drafts=p.rule_batch_drafts[role]
        for i,item in ipairs(batch_fields) do
            local field,title=item[1],item[2];local y=408+(i-1)*108
            local key='rules:batch:edit:'..field
            local editing=p.edit_field==key and p.editing
            local value=editing and (p.edit_text or '') or drafts[field] or ''
            text(title,486,y,12,C.YELLOW,474)
            canvas.rect(486,y+18,474,34,editing and C.ROW_HI or C.FIELD,951)
            canvas.border(486,y+18,474,34,editing and C.YELLOW or C.LINE2,952)
            text(value~='' and tostring(value)..(editing and '_' or '')
                or say('点击输入本字段批量值','CLICK TO ENTER A VALUE FOR THIS FIELD'),494,y+27,13,editing and C.TEXT or C.MUTED,458)
            canvas.region(key,486,y+18,474,34)
            local count=#rows
            button('rules:batch:apply:'..field,say('应用到筛选 ('..count..')','APPLY TO FILTER ('..count..')'),486,y+58,260,false,count==0)
            button('rules:batch:reset:'..field,say('恢复默认 ('..count..')','RESET DEFAULT ('..count..')'),754,y+58,206,false,count==0)
        end
        if p.hint then text(status_text and status_text(p.hint) or p.hint,486,750,12,C.YELLOW,474) end
    end
    local page_size=enemy and 5 or 9
    local pages=math.max(1,math.ceil(#rows/page_size))
    p.rule_page=math.max(1,math.min(pages,p.rule_page or 1))
    local top=enemy and 356 or 480
    for i=(p.rule_page-1)*page_size+1,math.min(#rows,p.rule_page*page_size) do
        local row=rows[i];local y=top+(i-(p.rule_page-1)*page_size-1)*40
        local rule=a.rule(enemy and 'enemy' or 'stratagem',row.id,role)
        local enabled=enemy and opts['ping_'..row.id] or not enemy and rule.enabled~=false
        local key='rules:select:'..row.id
        canvas.rect(22,y,424,36,row==selected and C.ROW_HI or C.PANEL,951)
        canvas.border(22,y,424,36,row==selected and C.YELLOW or C.LINE,952)
        if not enemy and canvas.icon then canvas.icon(row.icon,27,y+4,28) end
        text(row_name(row),enemy and 32 or 62,y+9,14,C.TEXT,enemy and 328 or 298)
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
        if not enemy then
            batch_toggle()
            if p.rule_batch_edit then draw_batch_fields() end
        end
        return
    end
    local kind=enemy and 'enemy' or 'stratagem';local rule=a.rule(kind,selected.id,role)
    text(row_name(selected),486,262,20,C.TEXT,474)
    if not enemy then
        text(say('规则ID ','RULE ID ')..selected.id..'  · '..selected.group..'  · '..say('游戏冷却 ','GAME CD ')..string.format('%.0f',selected.cooldown)..'s',486,296,12,C.MUTED,474)
        if selected.variant_ids and #selected.variant_ids>1 then
            text(say('同名 '..#selected.variant_ids..' 个变体共用此规则','SHARED BY '..#selected.variant_ids..' SAME-NAME VARIANTS'),735,343,12,C.MUTED,225)
        end
    end
    local enabled=enemy and opts['ping_'..selected.id] or not enemy and rule.enabled~=false
    button('rules:enabled',say('此类提醒 ','THIS ALERT ')..(enabled and 'ON' or 'OFF'),486,334,230,enabled)
    if not enemy then
        batch_toggle()
        if p.rule_batch_edit then draw_batch_fields();return end
    end
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
    text('{玩家名}/{player_name}',486,689,12,C.TEXT,474)
    text('{缩写}/{abbr}  ·  {编号}/{slot}',486,707,12,C.TEXT,474)
    text('{目标}/{target}',486,725,12,C.TEXT,474)
    text('{战备}/{stratagem}',486,743,12,C.TEXT,474)
    text('{类别}/{category}',486,761,12,C.TEXT,474)
    text('{动作}/{action}',486,779,12,C.TEXT,474)
    text('{任务名}/{objective}',486,797,12,C.TEXT,474)
    text('{任务类型}/{objective_type}',486,815,12,C.TEXT,474)
    text('{位置}/{position}',486,833,12,C.TEXT,474)
    text(say('Enter 保存 · Esc 取消 · Ctrl+V 粘贴','ENTER SAVE · ESC CANCEL · CTRL+V PASTE'),486,850,12,C.MUTED,474)
    button('rules:inherit',say('恢复消息与冷却为默认','RESTORE MESSAGE / COOLDOWN DEFAULTS'),486,870,474,false)
    if p.hint then text(status_text and status_text(p.hint) or p.hint,486,919,12,C.YELLOW,474) end
end
-- END ALERT PANEL

-- BEGIN PRESET PANEL
-- Named automation preset page. The frame and hit testing belong to auto_chat.lua;
-- this renderer only records ordinary panel regions through UX.
local function draw_preset_panel(UX, PANEL, automation, preset_library, font_ok, status_text)
    local C, W, H = UX.palette, 1000, 990
    local text, rect, border, region = UX.text, UX.rect, UX.border, UX.region
    local role = PANEL.profile or 'host'
    local options = automation.profile(role)
    local function say(cn, en) return font_ok and cn or en end
    local function button(key, title, x, y, w, h, active, disabled)
        local hovered = PANEL.hover == key
        rect(x, y, w, h, disabled and C.FIELD or active and C.YELLOW or hovered and C.ROW_HI or C.PANEL, 951)
        border(x, y, w, h, disabled and C.LINE2 or active and C.YELLOW or hovered and C.TEXT or C.LINE2, 952)
        text(title, x+w/2, y+(h-13)/2, 13, disabled and C.DIM or active and C.INK or C.TEXT, w-12, 'center')
        if not disabled then region(key, x, y, w, h) end
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
    PANEL.preset_selected_by_role=PANEL.preset_selected_by_role or {}
    PANEL.preset_page_by_role=PANEL.preset_page_by_role or {}
    PANEL.preset_index_cache_by_role=PANEL.preset_index_cache_by_role or {}
    local selected_id=PANEL.preset_selected_by_role[role]
    local entries=(preset_library._list_view or preset_library.list)(role)
    local revision=preset_library.state and preset_library.state.revision or 0
    local index_cache=PANEL.preset_index_cache_by_role[role]
    if not index_cache or index_cache.revision~=revision or index_cache.entries~=entries then
        local by_id={}
        for _,entry in ipairs(entries) do by_id[entry.id]=entry end
        index_cache={revision=revision,entries=entries,by_id=by_id}
        PANEL.preset_index_cache_by_role[role]=index_cache
    end
    if selected_id then
        if not index_cache.by_id[selected_id] then selected_id=nil;PANEL.preset_selected_by_role[role]=nil end
    end
    if not selected_id then
        local english_id='builtin-'..role..'-en'
        local english=index_cache.by_id[english_id]
        if english and english.builtin==true then
            selected_id=english_id
            PANEL.preset_selected_by_role[role]=english_id
        end
    end
    local selected=selected_id and index_cache.by_id[selected_id] or nil
    text(say('共 '..#entries..' 个预设',#entries..' PRESETS'),346,184,12,C.MUTED,nil,'right')
    if preset_library.state.error then
        text(say('预设库读取失败，已锁定写入：','LIBRARY ERROR; WRITES DISABLED:'),40,218,12,C.BAD,300)
        text(preset_library.state.error,40,240,11,C.BAD,300)
    elseif #entries==0 then text(say('暂无已保存预设','NO SAVED PRESETS'),40,224,14,C.DIM,300) end
    local pages=math.max(1,math.ceil(#entries/16))
    local page=PANEL.preset_page_by_role[role] or 1
    page=math.max(1,math.min(pages,page));PANEL.preset_page_by_role[role]=page
    local first=(page-1)*16+1
    for i=first,math.min(#entries,first+15) do
        local entry=entries[i];local y=266+(i-first)*36
        local chosen=entry.id==selected_id
        rect(38,y,308,30,chosen and C.ROW_HI or C.ROW,951)
        border(38,y,308,30,chosen and C.YELLOW or C.LINE2,952)
        text(entry.name,48,y+8,13,chosen and C.YELLOW or C.TEXT,244)
        region('preset:select:'..entry.id,38,y,308,30)
    end
    button('preset:prev','<',38,H-132,40,26,page>1)
    text(page..' / '..pages,94,H-126,12,C.MUTED)
    button('preset:next','>',142,H-132,40,26,page<pages)
    button('preset:save',say('保存当前配置','SAVE CURRENT'),38,H-94,146,32,false)
    button('preset:replace',say('替换所选','REPLACE'),194,H-94,152,32,false,selected and selected.builtin==true)

    text(say('编辑目标：','EDITING:')..say(role=='host' and '主机' or '客机',role:upper()),390,178,13,C.YELLOW,270)
    text(say('当前：','ACTIVE: ')..(automation.state.active_role=='host' and say('主机','HOST') or automation.state.active_role=='client' and say('客机','CLIENT') or say('等待','WAITING')),682,178,12,C.MUTED,130)
    button('preset:back',say('返回设置','BACK TO SETTINGS'),822,168,136,30,false)
    text(say('当前配置输出：','CURRENT OUTPUT: ')..(options.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),390,201,12,C.MUTED,568)
    field('preset:name',say('预设名称','PRESET NAME'),PANEL.preset_name or '',230)
    text(selected and (say('已选：','SELECTED: ')..selected.name) or say('请选择预设','SELECT A PRESET'),390,348,13,selected and C.TEXT or C.DIM,420)
    button('preset:rename',say('改名','RENAME'),822,340,136,30,false,selected and selected.builtin==true)
    local valid,parsed
    if selected then
        local cached=index_cache.validation
        if not cached or cached.id~=selected.id or cached.payload~=selected.payload then
            local ok,profile=automation.validate_profile(selected.payload)
            cached={id=selected.id,payload=selected.payload,valid=ok,parsed=profile}
            index_cache.validation=cached
        end
        valid,parsed=cached.valid,cached.parsed
    end
    local saved=valid and parsed and parsed.values
    if saved then
        text(say('将载入：','WILL LOAD: ')..(saved.output=='local' and say('仅自己可见','ONLY ME') or say('小队公屏','SQUAD CHAT')),390,376,12,C.YELLOW,568)
        text(say('自动消息：','AUTO SEND: ')..(saved.enabled and 'ON' or 'OFF')..'    '..say('标记：','PING: ')..(saved.ping and 'ON' or 'OFF'),390,394,12,C.MUTED,568)
    else text(say('无法预览所选预设内容','SELECTED PRESET CANNOT BE PREVIEWED'),390,376,12,C.BAD,568) end
    if selected then
        local count=0;for _ in selected.payload:gmatch('\nrule_[^=]+=[^\n]*') do count=count+1 end
        text(say('包含自动消息设置、模板和细粒度规则；规则字段：','AUTOMATION OPTIONS, TEMPLATES AND FINE GRAIN RULES; RULE FIELDS: ')..tostring(count),390,412,12,C.MUTED,568)
    end
    button('preset:apply',say(role=='host' and '应用到主机配置' or '应用到客机配置',
        role=='host' and 'APPLY TO HOST CONFIG' or 'APPLY TO CLIENT CONFIG'),390,432,210,34,false)
    button('preset:export',say('导出文件','EXPORT FILE'),612,432,160,34,false)
    button('preset:delete',say('删除','DELETE'),784,432,174,34,false,selected and selected.builtin==true)
    field('preset:path',say('导入文件路径','IMPORT FILE PATH'),PANEL.preset_path or '',488)
    button('preset:import',say('导入路径中的文件','IMPORT FILE FROM PATH'),390,556,276,34,false)
    text(PANEL.hint and status_text and status_text(PANEL.hint) or PANEL.hint
        or say('选择主机或客机配置后，点击应用按钮写入该角色。','Select a host or client configuration, then apply the preset to that role.'),390,606,12,PANEL.hint and C.YELLOW or C.MUTED,568)
    if PANEL.preset_export_path then text(say('导出位置：','EXPORTED: ')..PANEL.preset_export_path,390,638,11,C.GOOD,568) end
end
-- END PRESET PANEL

local function draw_panel()
    local function panel_text(chinese, english)
        return M.panel_text(chinese, english)
    end
    local function panel_status(value)
        return M.panel_status(value)
    end
    local function panel_is_chinese()
        return M.panel_is_chinese()
    end
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
    local active_viewport
    PANEL.scroll_offsets = PANEL.scroll_offsets or {}
    PANEL.viewports = {}

    local function viewport_y(y)
        return active_viewport and y - active_viewport.offset or y
    end

    local function rect(x, y, w, h, c, z)
        y = viewport_y(y)
        if active_viewport then
            local clip = active_viewport
            local x1, y1 = math.min(x + w, clip.x + clip.w), math.min(y + h, clip.y + clip.h)
            x, y = math.max(x, clip.x), math.max(y, clip.y)
            w, h = x1 - x, y1 - y
            if w <= 0 or h <= 0 then return end
        end
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
        y = viewport_y(y)
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
        if active_viewport and (top < active_viewport.y or top + sz / s > active_viewport.y + active_viewport.h
            or tx < active_viewport.x or tx + w > active_viewport.x + active_viewport.w) then return w end
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
        y = viewport_y(y)
        if active_viewport then
            local clip = active_viewport
            local x1, y1 = math.min(x + w, clip.x + clip.w), math.min(y + h, clip.y + clip.h)
            x, y = math.max(x, clip.x), math.max(y, clip.y)
            w, h = x1 - x, y1 - y
            if w <= 0 or h <= 0 then return end
        end
        regions[#regions + 1] = {
            key = key,
            x = px(ox + x * s), y = px(height - oy - (y + h) * s),
            w = px(w * s), h = px(h * s),
        }
    end

    local function begin_viewport(id, x, y, w, h, content_h, row_h)
        local max_offset = math.max(0, content_h - h)
        local offset = math.max(0, math.min(max_offset, tonumber(PANEL.scroll_offsets[id]) or 0))
        PANEL.scroll_offsets[id] = offset
        local view = {id=id, x=x, y=y, w=w-14, h=h, offset=offset, max=max_offset,
                      row_h=row_h or 36}
        PANEL.viewports[id] = view
        if max_offset > 0 then
            local tx, tw = x + w - 10, 8
            local thumb_h = math.max(24, h * h / content_h)
            local thumb_y = y + (h - thumb_h) * offset / max_offset
            local previous = active_viewport
            active_viewport = nil
            rect(tx, y, tw, h, C.FIELD, 951)
            rect(tx, thumb_y, tw, thumb_h, C.LINE2, 953)
            region('scroll:'..id..':track', tx-3, y, tw+6, h)
            region('scroll:'..id..':thumb', tx-3, thumb_y, tw+6, thumb_h)
            active_viewport = previous
            view.track_x, view.track_y, view.track_h = px(ox + (tx-3)*s),
                px(height - oy - (y+h)*s), px(h*s)
            view.thumb_y, view.thumb_h = px(thumb_y*s), px(thumb_h*s)
            view.travel_px = math.max(1, px((h-thumb_h)*s))
            view.fit = math.max(1, math.floor(h / view.row_h))
        else
            view.fit = math.max(1, math.floor(h / view.row_h))
        end
        view.screen_x, view.screen_y = px(ox + x*s), px(height - oy - (y+h)*s)
        view.screen_w, view.screen_h = px(w*s), px(h*s)
        active_viewport = view
        return view
    end

    local function end_viewport()
        active_viewport = nil
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
    UX.image=function(hash,x,y,w,h,tint,z)
        if type(hash)~='string' or #hash~=16 or not hash:match('^%x+$')
            or not sr.IdString64 or type(sr.IdString64.from_hex)~='function'
            or type(Gui.bitmap_uv)~='function' or not resource_loaded('material',hash) then
            return false,'material_unavailable'
        end
        local ok,id=pcall(sr.IdString64.from_hex,hash)
        if not ok or not id then return false,'material_unavailable' end
        local drawn,why=pcall(Gui.bitmap_uv,gui,id,Vector2(0,0),Vector2(1,1),
            Vector3(px(ox+x*s),px(height-oy-(y+h)*s),z or 953),
            Vector2(px(w*s),px(h*s)),tint or color(255,255,255,255))
        if not drawn then return false,'image_draw_failed' end
        return true
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
    text(PANEL.hover == 'drag'
         and panel_text('拖动移动窗口 / Ctrl+0 复位', 'Drag to move / Ctrl+0 to reset')
         or 'AUTOMATIC SQUAD CHAT',
         PAD + mx + 12, 12, 11, C.TEXT)
    text('v' .. M.version, W - PAD, 12, 11, C.DIM, nil, 'right')
    rect(0, 32, W, 1, C.LINE, 951)
    border(22, 44, 50, 50, C.TEXT, 952)
    rect(33, 54, 28, 20, C.YELLOW, 952); rect(36, 74, 22, 4, C.YELLOW, 952)
    rect(40, 78, 14, 4, C.YELLOW, 952); rect(44, 82, 6, 3, C.YELLOW, 952)
    rect(38, 59, 18, 4, C.INK, 953); rect(42, 63, 10, 4, C.INK, 953)
    local tw = text('AUTO', 86, 50, 34, C.TEXT)
    text('CHAT', 86 + tw + 12, 50, 34, C.YELLOW)
    text(panel_text('自定义定时事件，自动发送小队消息。','Schedule your squad messages.'),
         88, 84, 12, C.MUTED, 420)
    text('X', W - PAD - 14, 48, 18, PANEL.hover == 'close' and C.YELLOW or C.MUTED)
    region('close', W - PAD - 28, 38, 28, 30)
    rect(470, 48, 130, 30, PANEL.preset_view and C.YELLOW or PANEL.hover == 'presets:open' and C.ROW_HI or C.PANEL, 951)
    border(470, 48, 130, 30, PANEL.preset_view and C.YELLOW or C.LINE2, 952)
    text(panel_text('命名预设','PRESETS'), 535, 56, 13,
         PANEL.preset_view and C.INK or C.TEXT, 118, 'center')
    region('presets:open', 470, 48, 130, 30)
    if PANEL.preset_view then
        for _, item in ipairs({{'host', 614}, {'client', 768}}) do
            local role_key, role_x = item[1], item[2]
            local chosen = (PANEL.profile or 'host') == role_key
            local role_label = role_key == 'host' and 'HOST PRESET' or 'CLIENT PRESET'
            rect(role_x, 48, 146, 30, chosen and C.YELLOW or PANEL.hover == 'profile:' .. role_key and C.ROW_HI or C.PANEL, 951)
            border(role_x, 48, 146, 30, chosen and C.YELLOW or C.LINE2, 952)
            text(panel_is_chinese() and (role_key == 'host' and '主机预设' or '客机预设') or role_label,
                 role_x + 73, 56, 13, chosen and C.INK or C.TEXT, 134, 'center')
            region('profile:' .. role_key, role_x, 48, 146, 30)
        end
        local current_role = automation.sync()
        text(panel_is_chinese() and ('当前身份：' .. (current_role == 'host' and '主机' or current_role == 'client' and '客机' or '等待确认'))
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
    local tabs = {{key = 'tab:default', title = panel_text('设置','SETTINGS'), id = nil}}
    for i = 1, #M.PLUGINS do
        tabs[#tabs + 1] = {key = 'tab:' .. M.PLUGINS[i].id,
                           title = M.panel_locale() == 'en'
                               and (M.PLUGINS[i].name_en or M.PLUGINS[i].title)
                               or M.PLUGINS[i].title,
                           id = M.PLUGINS[i].id}
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
        local plugin_context = {
            id = active.id, w = W_PANEL, h = H_PANEL,
            ox = PAD, oy = body_y + 10,
            content_w = W_PANEL - 2 * PAD, content_h = H_PANEL - (body_y + 10) - PAD,
            panel_w = W_PANEL, panel_h = H_PANEL, body_y = body_y, scale = s,
            language = M.language.current(),
            loaded_icon = PANEL.loaded_plugin_icon(),
        }
        local ok, result, err = pcall(active.draw, plugin_api(plugin_context), plugin_context)
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
    if PANEL.plugin_icon_cache then
        PANEL.plugin_icon_cache.open = false
        PANEL.plugin_icon_cache.icon = nil
        PANEL.plugin_icon_cache.next_scan = 0
    end

    -- ---------------------------------------------------------- settings body
    if PANEL.rule_view then
        stratagem_catalog.scan(os.time())
        draw_alert_panel(UX,PANEL,automation,stratagem_catalog,panel_is_chinese(),M.version,panel_status)
        PANEL.ui_s,PANEL.ui_ox,PANEL.ui_oy=s,ox,oy
        return
    end
    if PANEL.preset_view then
        draw_preset_panel(UX, PANEL, automation, preset_library, panel_is_chinese(),panel_status)
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

    local function caption(cn, en) return panel_text(cn,en) end
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
    if PANEL.settings_view == 'quick' then PANEL.settings_view = 'tasks' end
    local navw = (IW - 12) / 3
    button('view:tasks', caption('定时任务', 'TASKS'), IX, y, navw, 30, true,
           PANEL.settings_view ~= 'automation' and PANEL.settings_view ~= 'pings')
    button('view:automation', caption('自动消息', 'AUTO SEND'), IX + navw + 6,
           y, navw, 30, true, PANEL.settings_view == 'automation')
    button('view:pings', caption('标记消息', 'PING'), IX + 2 * (navw + 6),
           y, navw, 30, true, PANEL.settings_view == 'pings')
    y = y + 44
    if PANEL.settings_view == 'pings' and M.options then
        local pings_top = y
        -- Content is eight 34px options, two 34px links, three fields with their
        -- current spacing, and ten 18px help rows plus the optional status line.
        local pings_content_h = 8*34 + 2*34 + 64 + 58 + 58 + 230 + 14
        local pings_view = begin_viewport('pings', IX, pings_top, IW,
            math.max(1, BOT - 8 - pings_top), pings_content_h, 34)
        IW = pings_view.w
        local opts = automation.profile(PANEL.profile or 'host')
        for _, item in ipairs({{'ping','玩家标记自动消息','ENABLE PING MESSAGES'},
            {'ping_building','任务建筑','MISSION BUILDINGS'}, {'ping_stratagem','战备物品标记','STRATAGEM EQUIPMENT'},
            {'ping_supplies','普通物资','ORDINARY SUPPLIES'},
            {'ping_summon','战备召唤 / 任务执行','CALL-INS / TASK ACTIONS'},
            {'ping_map','地图任务 / 撤离区','MAP OBJECTIVES / EXTRACTION'},
            {'ping_sender_prefix','显示触发者缩写','TRIGGER PLAYER PREFIX'},
            {'ping_sender_color','玩家名称与缩写使用队员颜色','PLAYER NAME AND PREFIX COLOR'}}) do
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
        text(panel_status(M.ping_status or '等待标记数据'), IX, y + 22, 12, C.MUTED, IW)
        text(panel_status(M.task_stratagem_status or '等待任务战备数据'), IX, y + 40, 12, C.MUTED, IW)
        text('{玩家名}/{player_name}', IX, y + 62, 12, C.MUTED, IW)
        text('{缩写}/{abbr}  ·  {编号}/{slot}', IX, y + 80, 12, C.MUTED, IW)
        text('{目标}/{target}', IX, y + 98, 12, C.MUTED, IW)
        text('{战备}/{stratagem}', IX, y + 116, 12, C.MUTED, IW)
        text('{类别}/{category}', IX, y + 134, 12, C.MUTED, IW)
        text('{动作}/{action}', IX, y + 152, 12, C.MUTED, IW)
        text('{任务名}/{objective}', IX, y + 170, 12, C.MUTED, IW)
        text('{任务类型}/{objective_type}', IX, y + 188, 12, C.MUTED, IW)
        text('{位置}/{position}', IX, y + 206, 12, C.MUTED, IW)
        if PANEL.hint then text(panel_status(PANEL.hint), IX, y + 230, 11, C.YELLOW, IW) end
        end_viewport()
    elseif PANEL.settings_view == 'automation' and M.options then
        local opts = automation.profile(PANEL.profile or 'host')
        local function toggle(key, zh, en)
            button('opt:' .. key, caption(zh, en) .. (opts[key] and ' [ON]' or ' [OFF]'),
                   IX, y, IW, 30, true, opts[key])
            y = y + 40
        end
        toggle('enabled', '自动发送总开关', 'ENABLE AUTO SEND')
        label(caption('消息输出方式', 'MESSAGE OUTPUT'), IX, y)
        y = y + 18
        button('output:squad', caption('小队公屏', 'SQUAD CHAT'), IX, y, (IW - 8)/2, 30, true, opts.output == 'squad')
        button('output:local', caption('仅自己可见', 'ONLY ME'), IX + (IW + 8)/2, y, (IW - 8)/2, 30, true, opts.output == 'local')
        y = y + 40
        toggle('allow_solo', '无人房间也发送', 'ALLOW SOLO SEND')
        field('option:cooldown', caption('标记/召唤提醒间隔（秒）', 'PING / CALL INTERVAL (SECONDS)'), tostring(opts.cooldown), y)
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
        text(PANEL.hint and panel_status(PANEL.hint) or caption('修改后自动保存；Enter 确认，Esc 取消', 'AUTO SAVED / ENTER CONFIRMS / ESC CANCELS'),
             IX, y, 12, PANEL.hint and C.YELLOW or C.MUTED, IW)
        text('{玩家名}/{player_name}', IX, y + 38, 12, C.DIM, IW)
        text('{缩写}/{abbr}  ·  {编号}/{slot}', IX, y + 58, 12, C.DIM, IW)
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
    text(PANEL.hint and panel_status(PANEL.hint) or caption('点击输入框填写；Enter 确认', 'CLICK TO TYPE; ENTER CONFIRMS'),
         IX, y, 12, PANEL.hint and C.YELLOW or C.DIM, IW)
        text(caption('Esc 取消', 'ESC CANCELS'), IX, y + 17, 12, PANEL.hint and C.YELLOW or C.DIM, IW)
        text(caption('填写完成后点击“添加任务”，任务才会保存并进入预设',
                     'CLICK “ADD TASK” TO SAVE THE DRAFT AND INCLUDE IT IN PRESETS'), IX, y + 38, 11, C.MUTED, IW)
        text(caption('重复 / 倒计时：5 秒至 24 小时', 'REPEAT / COUNTDOWN: 5 S TO 24 H'), IX, y + 58, 12, C.MUTED, IW)
        text(caption('每天定时：使用本机时间', 'DAILY: LOCAL SYSTEM TIME'), IX, y + 78, 12, C.MUTED, IW)
        text('{玩家名}/{player_name}', IX, y + 98, 12, C.DIM, IW)
        text('{缩写}/{abbr}  ·  {编号}/{slot}', IX, y + 116, 12, C.DIM, IW)
    end
    -- The right column uses the same row controls as the settings form.
    IX, IW = RX, RIW
    y = TOP + 14
    head(IX, y, caption('设置', 'SETTINGS'), (PANEL.profile or 'host') == 'host'
         and caption('主机定时任务', 'HOST TASKS') or caption('客机定时任务', 'CLIENT TASKS'))
    local visible_tasks = M.profile_task_view(PANEL.profile or 'host')
    text(panel_is_chinese() and ('共 '..#visible_tasks..' 个任务') or (#visible_tasks..' TASKS'), IX + IW, y + 20, 12, C.MUTED, nil, 'right')
    y = y + 58
    local list_top = y
    local list_bottom = BOT - 52
    local list_height = math.max(1, list_bottom - list_top)
    local task_view = begin_viewport('tasks', IX, list_top, IW, list_height,
        math.max(list_height, #visible_tasks * 76), 76)
    IW = task_view.w
    local start = math.floor(task_view.offset / 76) + 1
    local stop = math.min(#visible_tasks, math.ceil((task_view.offset + list_height) / 76))
    if #visible_tasks == 0 then
        text(caption('暂无任务，填写上方表单即可添加', 'NO TASKS. FILL THE FORM ABOVE.'), IX, y + 12, 13, C.DIM, IW)
    end
    for i = start, stop do
        local t = visible_tasks[i]
        local row_y = list_top + (i - 1) * 76
        rect(IX, row_y, IW, 68, C.ROW, 951)
        local state = t.done and caption('已执行', 'DONE')
                      or t.enabled and caption('运行中', 'ON') or caption('暂停', 'PAUSED')
        text(cut(t.name, 14, IW - 160), IX + 8, row_y + 7, 14, C.TEXT, IW - 160)
        text(t.mode:upper() .. ' / ' .. t.time .. (t.mode == 'daily' and '' or ' S') .. ' / ' .. state,
             IX + 8, row_y + 27, 11, t.enabled and C.GOOD or C.DIM, IW - 140)
        text(cut(t.result and panel_status(t.result) or t.message, 11, IW - 16), IX + 8, row_y + 48, 11, C.MUTED, IW - 16)
        button('toggle:' .. t.id, t.done and caption('重启', 'RESTART') or t.enabled
               and caption('暂停', 'PAUSE') or caption('启用', 'ENABLE'),
               IX + IW - 136, row_y + 7, 72, 28, true)
        button('delete:' .. t.id, caption('删除', 'DEL'), IX + IW - 58, row_y + 7, 50, 28, true)
    end
    end_viewport()
    -- Fixed footer keeps pagination reachable on both empty and full pages.
    y = BOT - 40
    button('page:prev', '<', IX, y, 34, 26, task_view.offset > 0)
    local first_item = #visible_tasks == 0 and 0 or math.min(#visible_tasks, start)
    local last_item = #visible_tasks == 0 and 0 or math.min(#visible_tasks, stop)
    local range_label = panel_is_chinese()
        and ('第'..first_item..'-'..last_item..'条 / 共'..#visible_tasks..'条')
        or (first_item..'-'..last_item..' / '..#visible_tasks..' TASKS')
    text(range_label, IX + IW / 2, y + 6, 12, C.MUTED, IW - 84, 'center')
    button('page:next', '>', IX + IW - 34, y, 34, 26, task_view.offset < task_view.max)
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
set_panel_open = function(open, discard_world_gui)
    open = open and true or false
    if open == PANEL.open then return PANEL.open end
    PANEL.open = open
    M.panel_open = open
    PANEL.version = (PANEL.version or 0) + 1
    if open then
        PANEL.profile = PANEL.profile or automation.sync() or 'host'
        PANEL.armed, mouse_was_down = nil, nil
        PANEL.chat_poll_frame = M.frames
        take_cursor()
    else
        PANEL.scrollbar_drag = nil
        if PANEL.plugin_icon_cache then
            PANEL.plugin_icon_cache.open, PANEL.plugin_icon_cache.icon = false, nil
            PANEL.plugin_icon_cache.next_scan = 0
        end
        -- The message editor previews typing directly in cfg.message. Forced closes
        -- must cancel that draft so loading/chat guards never apply an unconfirmed edit.
        if PANEL.editing and not PANEL.edit_field and PANEL.edit_backup ~= nil then
            cfg.message = PANEL.edit_backup
        end
        PANEL.edit_backup = nil
        stop_text_input()
        panel_input.release()
        if PANEL.drag then PANEL.drag = nil; pcall(save_position) end
        PANEL.armed, mouse_was_down = nil, nil
        PANEL.editing, PANEL.edit_field, PANEL.edit_text = nil, nil, nil
        release_cursor()
        panel_clear(discard_world_gui)
    end
    return PANEL.open
end

local function panel_frame()
    -- Sample K even while the panel is unavailable. A key held across startup or a
    -- world transition must not become a fresh toggle when the gate opens.
    local toggle = key_pressed(0x4B)
    local is_focused = focused()
    if not is_focused then
        PANEL.scrollbar_drag = nil
        if PANEL.open then set_panel_open(false)
        else panel_input.release(); release_cursor() end
        return
    end
    local world_context_ok, world_context_state = panel_context_guard.world_sample(false)
    if not world_context_ok then
        panel_context_guard.report('unknown', world_context_state)
        if PANEL.open then set_panel_open(false, world_context_state == 'world_unavailable') end
    end
    -- Not before the world exists: creating a screen GUI too early faults at native
    -- level, and pcall does not catch native faults.
    if M.frames < 600 then return end
    local available, changed_world, unavailable_reason = world_ready()
    if not available or changed_world then
        if changed_world then panel_context_guard.world_sample(true) end
        if PANEL.open then set_panel_open(false, unavailable_reason == 'world_unavailable')
        else panel_input.release(); release_cursor() end
        return
    end

    -- hotkey K (0x4B)
    if toggle and not PANEL.editing then
        if PANEL.open then set_panel_open(false) else panel_context_guard.request_open() end
        note('panel ' .. (PANEL.open and 'opened' or 'closed'))
        write_status()
    end

    if not PANEL.open then
        panel_input.release()
        release_cursor()
        return
    end
    if M.frames - (PANEL.chat_poll_frame or 0) >= 6 then
        PANEL.chat_poll_frame = M.frames
        local chat_open, chat_reason = panel_context_guard.chat_state(false)
        if chat_open == nil then
            panel_context_guard.report('unknown', chat_reason)
            set_panel_open(false)
            return
        elseif chat_open then
            panel_context_guard.report('blocked', chat_reason)
            set_panel_open(false)
            return
        elseif PANEL.context_status:find('^blocked:game chat open$')
           or PANEL.context_status:find('^unknown:') then
            panel_context_guard.report('ready', chat_reason)
        end
    end
    if PANEL.lfail >= 3 then
        -- Three refusals from the engine. Stop calling into it every frame; the panel
        -- stays off for the rest of the session. lfail resets on any success, so an
        -- isolated refusal does not count toward the three.
        panel_input.release()
        release_cursor()
        return
    end

    local queued_edit_action
    if PANEL.editing and PANEL.input_edit_field then
        local pending, overflow = panel_input.drain()
        if panel_input.status().broken then pending = nil end
        local value, action = edit_text((M.frames or 0) / 120, pending, overflow)
        if action == 'typing' then PANEL.edit_text = value
        elseif action == 'commit' then PANEL.edit_text, queued_edit_action = value, 'commit'
        elseif action == 'cancel' or action == 'reset' then queued_edit_action = action end
    end
    if is_focused and PANEL.pending_edit_action then
        queued_edit_action = PANEL.pending_edit_action
        PANEL.pending_edit_action = nil
    elseif not is_focused and queued_edit_action then
        PANEL.pending_edit_action = queued_edit_action
        queued_edit_action = nil
    end
    panel_input.hold(os.clock(), is_focused and user.GetForegroundWindow() or nil, key_down(0x4B))
    M.input_state = panel_input.status().state
    keep_cursor()
    local gx, gy = mouse_state()
    -- Read the captured wheel counter once on every open frame. Messages outside
    -- a scroll viewport are intentionally consumed and discarded here.
    local wheel_delta = M.panel_mouse_wheel_delta()
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
        -- Later regions are drawn on top (notably the thumb over its track), so
        -- hit testing follows the same painter order as the visible controls.
        for i = #regions, 1, -1 do
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
        PANEL.scrollbar_drag = nil
        if PANEL.drag then PANEL.drag = nil; pcall(save_position) end
        PANEL.armed, mouse_was_down = nil, nil
        return
    end
    local scroll_drag = PANEL.scrollbar_drag
    if scroll_drag then
        if down and gy then
            local view = PANEL.viewports and PANEL.viewports[scroll_drag.id]
            if view then
                local value = scroll_drag.offset - (gy - scroll_drag.y) / scroll_drag.travel * view.max
                PANEL.scroll_offsets[scroll_drag.id] = math.max(0, math.min(view.max, value))
            else
                PANEL.scrollbar_drag = nil
            end
        else
            PANEL.scrollbar_drag = nil
        end
        PANEL.armed = nil
    elseif pressed and type(hovered) == 'string' then
        local id = hovered:match('^scroll:(%w+):thumb$')
        local view = id and PANEL.viewports and PANEL.viewports[id]
        if view and view.max > 0 then
            PANEL.scrollbar_drag = {id=id, y=gy, offset=view.offset, travel=view.travel_px}
            PANEL.armed = nil
        end
    end
    if gx and gy and PANEL.viewports then
        for id, view in pairs(PANEL.viewports) do
            if gx >= view.screen_x and gx <= view.screen_x + view.screen_w
                and gy >= view.screen_y and gy <= view.screen_y + view.screen_h then
                if wheel_delta ~= 0 and view.max > 0 then
                    local step = view.id == 'tasks' and 76 or 34
                    local direction = wheel_delta > 0 and -1 or 1
                    PANEL.scroll_offsets[id] = math.max(0, math.min(view.max,
                        view.offset + direction * step * 3 * math.max(1, math.abs(wheel_delta))))
                end
                break
            end
        end
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
        if PANEL.editing and PANEL.input_edit_field then
            local pending, overflow = panel_input.drain()
            if panel_input.status().broken then pending = nil end
            local value, action = edit_text((M.frames or 0) / 120, pending, overflow)
            if action == 'typing' then PANEL.edit_text = value
            elseif action == 'commit' then PANEL.edit_text, commit = value, true
            elseif action == 'cancel' or action == 'reset' then commit = false end
        end
        if commit and PANEL.edit_field then
            local option = PANEL.edit_field:match('^option:(.+)$')
            local kind,id,rule_field=PANEL.edit_field:match('^rule:([^:]+):([^:]+):([^:]+)$')
            local batch_field=PANEL.edit_field:match('^rules:batch:edit:([%a_]+)$')
            if batch_field~='mark_message' and batch_field~='call_message' and batch_field~='cooldown' then batch_field=nil end
            if kind then
                local value=PANEL.edit_text or ''
                if rule_field=='cooldown' and value~='' then value=tonumber(value) or false end
                local ok,why=automation.set_rule(kind,id,rule_field,value,PANEL.profile or 'host')
                PANEL.hint=why;if not ok then return false end
            elseif PANEL.edit_field=='rules:search' then
                PANEL.rule_search=PANEL.edit_text or '';PANEL.rule_page=1
            elseif batch_field then
                local role=PANEL.profile or 'host'
                PANEL.rule_batch_drafts=PANEL.rule_batch_drafts or {}
                PANEL.rule_batch_drafts[role]=PANEL.rule_batch_drafts[role] or {}
                PANEL.rule_batch_drafts[role][batch_field]=PANEL.edit_text or ''
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
        stop_text_input()
        PANEL.editing, PANEL.edit_field, PANEL.edit_text = nil, nil, nil
        M.key_held = key_held
        for k in pairs(key_held) do key_held[k] = nil end
        return true
    end
    if queued_edit_action and PANEL.editing then
        if queued_edit_action == 'commit' then
            if finish_edit(true) then PANEL.hint = '输入已确认；点击对应按钮执行操作' end
        else
            finish_edit(false)
            PANEL.hint = queued_edit_action == 'cancel' and '已取消本次输入'
                or '输入队列溢出，已取消并保留原值'
        end
        clicked = false
    end
    if clicked and hovered then
        local scroll_track = hovered:match('^scroll:(%w+):track$')
        if scroll_track then
            local view = PANEL.viewports and PANEL.viewports[scroll_track]
            if view and view.max > 0 then
                local from_top = math.max(0, math.min(1,
                    (view.screen_y + view.screen_h - gy) / view.screen_h))
                PANEL.scroll_offsets[scroll_track] = from_top * view.max
                PANEL.version = (PANEL.version or 0) + 1
            end
        end
        local field = hovered:match('^task:(name)$') or hovered:match('^task:(time)$')
                      or hovered:match('^task:(message)$')
        local option = hovered:match('^option:(.+)$')
        local preset_field = hovered == 'preset:name' or hovered == 'preset:path'
        local opt_toggle = hovered:match('^opt:(.+)$')
        local mode = hovered:match('^mode:(%a+)$')
        local toggle_id = hovered:match('^toggle:(%d+)$')
        local delete_id = hovered:match('^delete:(%d+)$')
        local keys = PANEL.tab_keys
        if clicked and hovered ~= 'close' and not finish_edit(true) then
            clicked = false
        elseif hovered:match('^rules:batch:edit:') then
            local field=hovered:match('^rules:batch:edit:(.+)$')
            if field=='cooldown' or field=='mark_message' or field=='call_message' then
                local role=PANEL.profile or 'host'
                PANEL.rule_batch_drafts=PANEL.rule_batch_drafts or {}
                PANEL.rule_batch_drafts[role]=PANEL.rule_batch_drafts[role] or {}
                PANEL.editing,PANEL.edit_field,PANEL.edit_text=true,hovered,PANEL.rule_batch_drafts[role][field] or ''
                PANEL.hint=M.panel_text('输入后点“应用到筛选”或“恢复默认”','Type, then choose Apply to Filter or Reset Default')
            end
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
        elseif hovered=='rules:batch:open' then PANEL.rule_batch_edit=true;PANEL.hint=nil
        elseif hovered=='rules:batch:close' then PANEL.rule_batch_edit=nil;PANEL.hint=nil
        elseif hovered:match('^rules:batch:apply:') or hovered:match('^rules:batch:reset:') then
            local action,field=hovered:match('^rules:batch:([%a_]+):(.+)$')
            local reset=action=='reset'
            if field=='cooldown' or field=='mark_message' or field=='call_message' then
                local ids=M.batch_rule_ids(M.panel_locale())
                if #ids==0 then
                    PANEL.hint=M.panel_text('当前筛选没有可修改条目','No matching entries in the current filter')
                else
                    local role=PANEL.profile or 'host'
                    local value
                    if not reset then
                        PANEL.rule_batch_drafts=PANEL.rule_batch_drafts or {}
                        PANEL.rule_batch_drafts[role]=PANEL.rule_batch_drafts[role] or {}
                        value=PANEL.rule_batch_drafts[role][field] or ''
                        if field=='cooldown' and value~='' then value=tonumber(value) or false end
                    end
                    local ok,why=automation.set_rule_field_batch('stratagem',ids,field,value,role)
                    PANEL.hint=ok and M.panel_text('已更新 '..#ids..' 个战备规则','Updated '..#ids..' stratagem rules') or why
                end
            end
        elseif hovered:match('^rules:select:') then
            PANEL.rule_selected=hovered:match('^rules:select:(.+)$');PANEL.hint=nil
        elseif hovered:match('^rules:filter:') then
            PANEL.rule_filter=hovered:match('^rules:filter:(.+)$');PANEL.rule_page=1;PANEL.rule_selected=nil
        elseif hovered=='rules:prev' or hovered=='rules:next' then
            PANEL.rule_page=math.max(1,(PANEL.rule_page or 1)+(hovered=='rules:next' and 1 or -1))
        elseif hovered:match('^rules:bulk:') then
            local group,value=hovered:match('^rules:bulk:([^:]+):([^:]+)$');local ids={}
            for _,row in ipairs(stratagem_catalog.list_rules()) do
                if (group=='mission' and row.family=='mission') or (group~='mission' and row.group==group) then
                    ids[#ids+1]=row.id
                end
            end
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
            local role=PANEL.profile or 'host'
            PANEL.preset_selected_by_role[role] = hovered:match('^preset:select:(.+)$')
            save_preset_selection()
            PANEL.hint = nil
        elseif hovered == 'preset:prev' or hovered == 'preset:next' then
            local role=PANEL.profile or 'host'
            local pages = math.max(1, math.ceil(#preset_library._list_view(role)/16))
            PANEL.preset_page_by_role[role] = math.max(1, math.min(pages, (PANEL.preset_page_by_role[role] or 1)
                + (hovered == 'preset:next' and 1 or -1)))
        elseif preset_field then
            local key = hovered == 'preset:name' and 'preset_name' or 'preset_path'
            PANEL.editing, PANEL.edit_field, PANEL.edit_text = true, hovered, PANEL[key] or ''
            PANEL.hint = 'Enter 确认输入 / Esc 取消'
        elseif hovered == 'preset:save' then
            local role=PANEL.profile or 'host'
            local ok, why, id = preset_library.save(PANEL.preset_name or '', role)
            PANEL.hint = ok and '已保存当前自动消息配置' or why
            if ok then
                PANEL.preset_selected_by_role[role] = id
                PANEL.preset_page_by_role[role] = math.ceil(#preset_library._list_view(role)/16)
                save_preset_selection()
            end
        elseif hovered == 'preset:replace' then
            local role=PANEL.profile or 'host';local selected=PANEL.preset_selected_by_role[role]
            if not selected then PANEL.hint = '请先选择预设'
            else
                local builtin=false
                for _,item in ipairs(preset_library._list_view(role)) do if item.id==selected then builtin=item.builtin==true;break end end
                if builtin then PANEL.hint=M.panel_text('内置预设不可覆盖','Built-in presets cannot be replaced')
                else
                    local ok, why = preset_library.replace(selected, role)
                    PANEL.hint = ok and '已替换所选预设内容' or why
                end
            end
        elseif hovered == 'preset:rename' then
            local role=PANEL.profile or 'host';local selected=PANEL.preset_selected_by_role[role]
            if not selected then PANEL.hint = '请先选择预设'
            else
                local builtin=false
                for _,item in ipairs(preset_library._list_view(role)) do if item.id==selected then builtin=item.builtin==true;break end end
                if builtin then PANEL.hint=M.panel_text('内置预设不可重命名','Built-in presets cannot be renamed')
                else
                    local ok, why = preset_library.rename(selected, PANEL.preset_name or '')
                    PANEL.hint = ok and '预设名称已更新' or why
                end
            end
        elseif hovered == 'preset:apply' then
            local role=PANEL.profile or 'host'
            local selected=PANEL.preset_selected_by_role[role]
            if not selected then PANEL.hint = M.panel_text('请先选择预设','Select a preset first.')
            else
                local entry
                for _,item in ipairs(preset_library._list_view(role)) do if item.id==selected then entry=item;break end end
                local legacy_without_tasks=false
                if entry then
                    local valid,parsed=automation.validate_profile(entry.payload)
                    legacy_without_tasks=valid and parsed.tasks==nil
                end
                local ok, why = preset_library.apply(selected, role)
                if ok then
                    -- The cached role starts as host before a session is known.
                    -- Only report a match after a fresh session sync confirms it.
                    local active=automation.sync()
                    local role_name=role=='host' and '主机' or '客机'
                    local active_name=active=='host' and '主机' or active=='client' and '客机' or nil
                    local applied=M.panel_text('已应用到'..role_name..'配置','Applied to '..role:upper()..' configuration')
                    if active_name then
                        applied=applied..M.panel_text(active==role and '；当前身份匹配' or '；当前身份为'..active_name..'，切换到'..role_name..'身份后生效',
                            active==role and '; active role matches.' or '; active role is '..active:upper()..'. It takes effect in a '..role:upper()..' session.')
                    else
                        applied=applied..M.panel_text('；当前身份尚未确认，检测到'..role_name..'身份后生效',
                            '; session role is not confirmed. It will take effect in a '..role:upper()..' session.')
                    end
                    if legacy_without_tasks then
                        applied=applied..M.panel_text('；旧版预设未保存定时任务，已保留当前'..role_name..'任务',
                            '; this legacy preset has no task snapshot, so current '..role:upper()..' tasks were kept.')
                    end
                    PANEL.hint=applied
                else PANEL.hint=M.panel_text('预设应用失败：'..tostring(why),
                    'Preset apply failed: '..M.panel_status(tostring(why))) end
            end
        elseif hovered == 'preset:export' then
            local selected=PANEL.preset_selected_by_role[PANEL.profile or 'host']
            if not selected then PANEL.hint = '请先选择预设'
            else
                local ok, why, path = preset_library.export(selected,PANEL.profile or 'host')
                PANEL.hint = ok and '预设已导出' or why
                PANEL.preset_export_path = ok and path or nil
            end
        elseif hovered == 'preset:delete' then
            local role=PANEL.profile or 'host';local selected=PANEL.preset_selected_by_role[role]
            if not selected then PANEL.hint = '请先选择预设'
            else
                local builtin=false
                for _,item in ipairs(preset_library._list_view(role)) do if item.id==selected then builtin=item.builtin==true;break end end
                if builtin then PANEL.hint=M.panel_text('内置预设不可删除','Built-in presets cannot be deleted')
                else
                    local ok, why = preset_library.remove(selected)
                    PANEL.hint = ok and '预设已删除' or why
                    if ok then PANEL.preset_selected_by_role[role] = nil; PANEL.preset_export_path = nil;save_preset_selection() end
                end
            end
        elseif hovered == 'preset:import' then
            local role=PANEL.profile or 'host'
            local ok, why, id = preset_library.import(PANEL.preset_path or '',role)
            PANEL.hint = ok and '预设已导入，请选择后加载' or why
            if ok then
                PANEL.preset_selected_by_role[role] = id
                PANEL.preset_page_by_role[role] = math.ceil(#preset_library._list_view(role)/16)
                save_preset_selection()
            end
        elseif option then
            PANEL.editing, PANEL.edit_field, PANEL.edit_text = true, hovered, tostring(automation.profile(PANEL.profile or 'host')[option])
            PANEL.hint = 'Enter 保存 / Esc 取消 / Ctrl+V 粘贴'
        elseif opt_toggle then
            local ok, why = automation.set(opt_toggle, not automation.profile(PANEL.profile or 'host')[opt_toggle], PANEL.profile or 'host')
            PANEL.hint = ok and '设置已保存' or why
        elseif hovered:match('^profile:') then
            PANEL.profile = hovered:match('^profile:(.+)$')
            PANEL.scrollbar_drag = nil
            PANEL.scroll_offsets.tasks = 0
            PANEL.hint = M.panel_text(
                '正在编辑' .. (PANEL.profile == 'host' and '主机' or '客机') .. '预设；根据身份自动启用',
                'Editing ' .. (PANEL.profile or 'host') .. ' preset; enabled according to identity')
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
            PANEL.scrollbar_drag = nil
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
                local tasks=M.profile_task_view(PANEL.profile or 'host')
                PANEL.scroll_offsets.tasks = math.max(0, (#tasks - 1) * 76)
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
            local view=PANEL.viewports and PANEL.viewports.tasks
            if view then
                local delta=hovered=='page:next' and 7*76 or -7*76
                PANEL.scroll_offsets.tasks=math.max(0,math.min(view.max,view.offset+delta))
            end
        elseif hovered == 'close' then
            if PANEL.editing and not finish_edit(true) then
                clicked=false -- validation failed; preserve the field and leave the panel open
            else set_panel_open(false) end
        elseif keys and keys[hovered] ~= nil or (keys and hovered == 'tab:default') then
            finish_edit(true)
            -- Resolved through the map the tab strip built while drawing, so a click can
            -- only select a tab that was actually drawn.
            PANEL.active_plugin = keys[hovered] or nil
            PANEL.rule_view,PANEL.preset_view=nil,nil
            PANEL.version = (PANEL.version or 0) + 1
            note('panel: tab -> ' .. tostring(PANEL.active_plugin or 'default'))
        end
        PANEL.version = (PANEL.version or 0) + 1
        write_status()
    end
    if not PANEL.open then return end

    -- Message editing. While the field has focus the editor owns the keyboard, so the
    -- K hotkey cannot fire mid-word.
    if PANEL.editing then
        if not PANEL.edit_field and PANEL.edit_backup == nil then PANEL.edit_backup = cfg.message end
        local now = (M.frames or 0) / 120
        local input_field = PANEL.edit_field or '__message__'
        if PANEL.input_edit_field ~= input_field then
            if PANEL.input_edit_field then stop_text_input() end
            text_input.reset(); panel_input.clear()
            PANEL.input_edit_field = input_field
        end
        if is_focused then
            local window = user.GetForegroundWindow()
            local status = panel_input.status()
            if window and status.editing and not status.ime_ready and not status.ime_pending then
                local why='game window IME context is unavailable'
                if M.input_ime_error ~= why then M.input_ime_error=why;note('panel text input unavailable: '..why) end
                PANEL.hint='中文输入不可用：窗口 IME 上下文未就绪'
            elseif status.ime_ready and M.input_ime_error=='game window IME context is unavailable' then
                M.input_ime_error=nil
                if PANEL.hint=='中文输入不可用：窗口 IME 上下文未就绪' then PANEL.hint=nil end
            end
            if window and not status.editing and not status.ime_pending then
                local ok, why = panel_input.editing(true, window)
                if not ok and M.input_ime_error ~= why then
                    M.input_ime_error = why
                    note('panel text input unavailable: ' .. tostring(why))
                elseif ok then M.input_ime_error = nil end
            end
        end
        local events, overflow = panel_input.drain()
        -- Keep the existing ASCII key path as a degraded fallback when the
        -- native Unicode bridge could not initialize. A live bridge always
        -- owns text input through its ordered Win32 event queue.
        if panel_input.status().broken then events = nil end
        local value, what = edit_text(now, events, overflow)
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
            elseif what == 'reset' then
                finish_edit(false)
                PANEL.hint = '输入队列溢出，已取消并保留原值'
            end
        elseif what == 'commit' then
            cfg.message = value or cfg.message
            config_save()
            PANEL.editing = nil
            PANEL.edit_backup = nil
            stop_text_input()
            PANEL.hint = 'MESSAGE SAVED'
            note('panel: message set to: ' .. tostring(cfg.message))
        elseif what == 'cancel' then
            cfg.message = PANEL.edit_backup or cfg.message
            PANEL.editing = nil
            PANEL.edit_backup = nil
            stop_text_input()
            PANEL.hint = 'EDIT CANCELLED'
            note('panel: message edit cancelled')
        elseif what == 'reset' then
            cfg.message = PANEL.edit_backup or cfg.message
            PANEL.editing = nil
            PANEL.edit_backup = nil
            stop_text_input()
            PANEL.hint = '输入队列溢出，已取消并保留原值'
            note('panel text input overflow; edit cancelled')
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
local function handle_config_command(body)
    if not tostring(body):match('^timed%s+') then return false end
    note('timed: quick timer was retired; use the scheduled task settings')
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
        if not PANEL.open and M.frames >= 600 then
            panel_context_guard.request_open()
        end
        note(PANEL.open and 'trigger: panel opened' or 'trigger: panel request unavailable in this context')
        if PANEL.open then write_status() end
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
function M.debug_panel_input() return panel_input end
function M.debug_save_preset_selection() return save_preset_selection() end
function M.debug_font() return {resolved = FONT.resolved, ok = FONT.ok, why = FONT.why, kind = FONT.kind} end
function M.debug_panel_signature() return panel_signature() end
function M.debug_cfg() return cfg end
function M.debug_language() return M.language end
function M.debug_last_send() return M.last_send end
function M.debug_timed_send(dt) return false end
function M.debug_migrate_quick_timer(role) return M.migrate_quick_timer(role) end
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
function M.debug_request_open() return panel_context_guard.request_open() end

local function tick()
    M.frames = M.frames + 1
    if not verified then return end
    M.language.update('auto', M.frames)
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
note(string.format('AutoChat v%s starting (build %s; send + panel)', M.version, M.build_id))
note('user32 declarations: added[' .. tostring(M.user32_added)
     .. '] reused[' .. tostring(M.user32_reused) .. ']')
config_load()
load_tasks()
-- The retired quick timer is converted to an ordinary role-scoped repeat task.
-- Never leave an enabled hidden sender behind when saving the task fails.
;(function()
    local has_legacy_timer_task=false
    for _,task in ipairs(M.tasks) do
        if task.profile=='host' and task.name=='旧版定时发送' and task.mode=='repeat'
            and tostring(task.time)==tostring(cfg.interval) and task.message==cut_utf8(cfg.message,200) then
            has_legacy_timer_task=true;break
        end
    end
    if automation.state.legacy_quick_timer_missing then
        local migration_ok=true
        if cfg.timer_on and not has_legacy_timer_task then
            local task,why=M.add_task('旧版定时发送','repeat',tostring(cfg.interval),cut_utf8(cfg.message,200),nil,'host')
            if not task then migration_ok=false;PANEL.hint=M.panel_text('旧版定时迁移失败，原设置保留但不会发送：'..tostring(why),'Legacy timer migration failed; old settings were kept, and no hidden sender will run: '..tostring(why));note('legacy timer task migration failed: '..tostring(why)) end
        end
        if migration_ok then
            local ok,why=automation.migrate_legacy_quick_timer(false,cfg.interval,cut_utf8(cfg.message,200))
            if ok then
                if cfg.timer_on then cfg.timer_on=false;config_save() end
                note('legacy timer migrated to scheduled task: '..tostring(why))
            else PANEL.hint=M.panel_text('旧版定时设置迁移失败，原设置保留：'..tostring(why),'Legacy timer settings migration failed; old settings were kept: '..tostring(why));note('legacy timer profile migration failed: '..tostring(why)) end
        end
    else
        for _,role in ipairs({'host','client'}) do
            local ok,why=M.migrate_quick_timer(role)
            if not ok then PANEL.hint=M.panel_text('旧版定时迁移失败，原设置保留但不会发送：'..tostring(why),'Legacy timer migration failed; old settings were kept, and no hidden sender will run: '..tostring(why));note('quick timer task migration failed ('..role..'): '..tostring(why)) end
        end
    end
end)()
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

--[===[AutoChat / 自动聊天  v1.0.0 candidate  —— SETTINGS + PLAYER TEMPLATES + ADDON API

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

Panel redraw signatures cache their raw values and rebuild only when displayed
content changes. Ping and stratagem events rejected only for transient readiness
or queue capacity are retried while their native marker remains valid; accepted
messages are never evicted to make room. Plugin event notifications are sent once.

Custom alert rules and Unicode input (0.8.3)
Settings > Ping > Stratagem rules / Enemy rules opens the dedicated editors.
Each stratagem has an enable switch, separate mark/call templates and cooldown.
Blank messages inherit defaults; blank cooldown uses the global player timer.
Explicit rule cooldown is independent per trigger player + rule; 0 bypasses
global cooldown and prioritizes new events, while master/dedup still apply.
No zero-cooldown rules are seeded; configure individual rules when needed.
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
The catalog editor displays validated Simplified Chinese names for the current
149 stratagem rows and falls back to internal English debug names for unknown IDs.
Scanning never calls native localization in bulk. Event messages prefer the
event-time localized name, then the mapped display name. In-game IME input is
handled through queued window-thread messages; physical in-game entry still needs
verification for this candidate.
One user-sampled Super Earth cache resource uses the exact-hash fallback label "坠落舱" when its native name is generic; this is not official localization and does not cover other cache resources. The tower-top marker follows its existing path; the user confirmed the tower-base generic point should remain unsupported.
中文：设置→标记消息→战备细分设置 / 敌人体型与飞行提醒。
空消息沿用默认；冷却留空使用全局，独立秒数按触发者+规则计时，0绕过全局。
默认不预置零冷却规则；需要时可逐项配置。
战备可搜索、逐项开关、分别设置召唤/落地标记模板，红蓝绿一键开关。
图标只显示游戏已加载材质；同名且呼叫方式一致的奖励等变体共用规则。
界面语言按游戏设置切换；战备消息名称按预设的消息语言选择，与界面语言相互独立。当前稳定目录149个战备ID具有双语映射，未核实名称使用通用可读fallback；未知运行时ID的消息不暴露内部代码。扫描不批量调用游戏本地化函数。六种已核实的SEAF炮弹走现有任务建筑提醒。一个经用户实机样本核对的Super Earth cache资源在泛名称时回退显示“坠落舱”；这不是官方本地化，也不覆盖其他cache资源。广播塔顶端标记沿用既有路径；用户确认塔底泛型点不需适配。游戏内IME输入仍待实机验收。
不能确定具体变体时不冒认ID；连同名规则也无法确定时使用默认提醒。
飞行优先于体型；小型默认关闭；当前142条可标记敌对资源，12条飞行。
新增战备在兼容布局下自动发现；新敌人及游戏二进制更新仍需校验。

Role presets and private output (0.8.3)
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
another role is active. Presets and tasks have no fixed entry-count cap; local
storage remains bounded by the documented per-file and per-preset size limits.
Named preset v5 files save task definitions, all behavior settings and optional
opaque addon preset data.
Older presets without task definitions preserve the destination role's current
tasks. Old quick-timer values are read only for one-time conversion to ordinary
repeat tasks; there is no separate quick-timer sender or settings page.
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
  - click fields to type, including Windows IME; ENTER confirms, ESC cancels,
    CTRL+V pastes Unicode. The 0.8.3 IME path has offline native tests; in-game
    physical input remains unverified.
  - click ADD TASK to save tasks; the task file has a 16 MiB size limit

Timed send
----------
Role-specific tasks run while the game is running, using real elapsed time
independent of FPS. Scheduled tasks keep the selected local/squad output and
normal send cooldown.
Repeat/countdown accept 5-86400 seconds. Daily tasks run at most once per local day.
Countdown deadlines persist across restarts; overdue tasks attempt once on launch.
Unavailable chat, unknown role and cooldown leave tasks pending with a reason.
An enabled pre-profile timer migrates once into a host repeat task. An 0.8.1
timer already converted to a task remains that task. Oldest deadlines get priority
so short repeat tasks cannot starve countdowns. The AUTO MESSAGES section has a master
switch, separate host/client profiles selected from session identity, allow-solo switch, per-player cooldown, newcomer
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
HD2AutoChatAPI keeps the v2 handshake and adds revision 3 capabilities for independent
sends, detached role settings snapshots, and bounded drawing helpers. The separately
packaged Interface Demo registers a manual example tab; it does not subscribe to live
events or send on load. The release ZIP includes plugin-author guides under Docs/.
Settings persist in:

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
  - 中文可在字段内使用系统输入法直输，也可 Ctrl+V 粘贴；Enter 确认，Esc 取消
  - 填写完成后还须点击“添加任务”，任务才会保存并进入命名预设
  - 可添加任意数量的任务；单项字段和任务文件仍受明确大小限制

任务按真实时间计时，仅在游戏运行时执行。倒计时保存截止时刻；重启后到期任务尝试一次。
聊天未就绪、身份未知或角色条件不满足时，任务保持等待，不会直接消耗一次倒计时；任务不受事件冷却限制。
最早到期的任务优先，避免短周期任务一直占用发送机会。
自动消息：总开关、主机/客机独立配置并按当前会话身份启用、无人房间允许发送、标记/召唤提醒间隔、新人欢迎及自定义欢迎语/延迟；输出仍可选小队公屏或仅自己可见。旧快捷定时只在升级时转为普通重复任务，不再单独显示或发送。
默认允许主客机及单人发送，冷却5秒，新人欢迎关闭，欢迎延迟2秒；启用时不欢迎已有队友。
标记消息：任务建筑、战备提示、中型/大型/巨型敌人、地图标记分别开关；不再提示普通弹药、针剂、手雷、样本。
静态资源包含 TCS、LAS-98激光大炮、堡垒坦克、重新补给和M-103补给车；特殊标记优先读取游戏本地化名称（需校验当前DLL）。
本人和队友的新标记均可触发；本人标记使用本人的事件间隔，定时任务不受该间隔限制。
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
标记、召唤和执行事件间隔按触发玩家分别计算：A不占用B/C；冷却中的新事件直接丢弃，不排队补发。默认5秒，0为不限制。
同时加入的新人各有独立欢迎队列，逐条发送；欢迎和定时任务忽略且不会延长事件间隔。不指定触发者的扩展发送使用本机玩家间隔。
欢迎、标记、定时任务与扩展消息支持 {玩家名}/{缩写}/{编号}；{名字}/{触发者}也是名字。
例如：欢迎 {玩家名}（{缩写}，{编号}号）加入小队！ 数据缺失时显示“队友/队友/?”，不猜编号。
其他模组可通过 HD2AutoChatAPI v2 注册显示名菜单、按钮与可选事件回调。revision 3
保留旧握手，并新增独立发送策略、当前角色设置副本和边界受限的绘图接口；独立发送仍由宿主检查会话、身份与原生发送入口。
独立接口示例包注册“接口示例”，提供手动发送；加载和绘制时不发送，也不订阅实时事件。
主包 ZIP 的 `Docs/` 目录包含插件 API 与接口示例指南。
设置保存在 `AutoChat\tasks.txt`；旧版已启用的单计时器迁移成可见任务。

按 K 呼出；退出输入后再按 K，或点右上角 X 关闭。
本版本尚未实机验收，离线布局预览不是游戏截图。
]===]
