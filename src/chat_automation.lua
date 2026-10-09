-- Automatic chat policy, inlined by the addon builder; no native offsets or writes.
-- Session API provenance: P2P-Ping 0.1.34 scope() / update_peer_labels().
local function build_chat_automation(env)
    local options = {enabled = true, scope = 'all', allow_solo = true,
        welcome = false, welcome_message = '欢迎加入小队！', cooldown = 5,
        welcome_delay = 2, ping = false, ping_building = true, ping_stratagem = true, ping_map = true,
        ping_sender_prefix = true, ping_sender_color = true, ping_medium_enemy = true,
        ping_large_enemy = true, ping_giant_enemy = true,
        ping_message = '标记了{目标}（{类别}）'}
    local keys = {'enabled', 'scope', 'allow_solo', 'welcome', 'welcome_message',
        'cooldown', 'welcome_delay', 'ping', 'ping_building', 'ping_stratagem', 'ping_map', 'ping_sender_prefix', 'ping_sender_color', 'ping_medium_enemy',
        'ping_large_enemy', 'ping_giant_enemy', 'ping_message'}
    local booleans = {enabled=true, allow_solo=true, welcome=true, ping=true,
        ping_building=true, ping_stratagem=true, ping_map=true,
        ping_sender_prefix=true, ping_sender_color=true, ping_medium_enemy=true, ping_large_enemy=true,
        ping_giant_enemy=true}
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
        elseif key == 'cooldown' or key == 'welcome_delay' then
            local limit = key == 'cooldown' and 3600 or 60
            if type(value) ~= 'number' or value ~= value or value < 0 or value > limit
                or value ~= math.floor(value) then
                return false, '请输入 0 到 ' .. limit .. ' 之间的整数秒数'
            end
        elseif key == 'welcome_message' or key == 'ping_message' then
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
    local function serialize(candidate)
        local lines = {'# AutoChat automation settings v2'}
        for _, key in ipairs(keys) do lines[#lines + 1] = key .. '=' .. escape(tostring(candidate[key])) end
        return table.concat(lines, '\n') .. '\n'
    end
    local saved_keys, legacy = {}, {}
    local saved = attempt(env.read_file)
    if type(saved) == 'string' then
        for line in saved:gmatch('[^\r\n]+') do
            local key, raw = line:match('^([%w_]+)=(.*)$')
            if key then
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
                elseif validate(key, value) then options[key] = value; saved_keys[key] = true end
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

    local categories = {building='任务建筑', stratagem='战备提示', map='地图标记',
        medium_enemy='中型敌人', large_enemy='大型敌人', giant_enemy='巨型敌人'}
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

    function api.format(template, peer, extra)
        if type(template) ~= 'string' then return '' end
        if peer == nil then local s=api.snapshot();peer=s and s.mine end
        local identity = identity_for(peer)
        local name = identity and plain(identity.name,96) or '队友'
        local short = identity and plain(identity.short,16) or '队友'
        if name=='' then name='队友' end
        if short=='' then short='队友' end
        local slot = identity and identity.color_index
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
            state.limit_session, state.last_by_peer, state.last_send = token, {}, nil
        end
        if snapshot then
            local present = {}
            for _,key in ipairs(snapshot.peers) do present[bucket(key,snapshot)]=true end
            for key in pairs(state.last_by_peer) do
                if not present[key] then state.last_by_peer[key]=nil end
            end
        end
    end
    local function policy(now, others, snapshot, peer)
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
        local last = state.last_by_peer[bucket(peer,snapshot)]
        if last and now - last < options.cooldown then
            return false, '等待：该玩家的自动消息间隔中'
        end
        return true, '可以自动发送'
    end
    function api.check(now, others, peer)
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
    function api.set(key, value)
        local ok, why = validate(key, value)
        if not ok then return false, why end
        if options[key] == value then return true, '设置未变化' end
        local candidate = {}
        for _, name in ipairs(keys) do candidate[name] = options[name] end
        candidate[key] = value
        -- The environment writes a temporary file and renames it atomically.
        -- Commit options only after that succeeds; queue/baseline also survive failure.
        if attempt(env.write_file, serialize(candidate)) ~= true then return false, '设置保存失败，已保留原设置' end
        options[key] = value
        if key == 'enabled' or key == 'welcome' or key == 'scope' then reset() end
        if key == 'enabled' or key == 'scope' or key == 'ping' then state.pings = {} end
        state.status = '设置已保存'
        return true, state.status
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
        local sent, send_why = attempt(env.send, api.format(options.welcome_message,candidate))
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
    function api.push_ping(event, now)
        if type(event) ~= 'table' or not categories[event.category] or type(event.key) ~= 'string'
            or #event.key > 128 or type(now) ~= 'number' or now ~= now
            or now == math.huge or now == -math.huge then return false end
        if not options.enabled or not options.ping or not options['ping_' .. event.category] then return false end
        for key, expires in pairs(state.ping_seen) do if now > expires then state.ping_seen[key] = nil end end
        if state.ping_seen[event.key] or #state.pings >= 16 then return false end
        local snapshot = api.snapshot()
        if options.scope == 'host' and (not snapshot or snapshot.is_host ~= true) then return false end
        if not creator_present(event.creator_id, snapshot) then return false end
        local label = categories[event.category]
        local target = type(event.target) == 'string' and plain(event.target,200) or label
        local identity = identity_for(event.creator_id)
        local short = identity and plain(identity.short, 16) or '队友'
        if short == '' then short = '队友' end
        local objective_types = {primary='主线任务', prerequisite='主线前置任务',
            optional='支线任务', tactical='战术任务', unknown='任务'}
        local replacements = {['{类别}']=label, ['{目标}']=plain(target, 200),
            ['{任务名}']=plain(type(event.objective_name)=='string' and event.objective_name or target,200),
            ['{任务类型}']=objective_types[event.objective_kind] or label,
            ['{位置}']=position_text(event)}
        local text = api.format(options.ping_message,event.creator_id,replacements)
        local prefix = ''
        if options.ping_sender_prefix and type(event.creator_id) == 'string' then
            prefix = '[' .. short .. ']'
            if options.ping_sender_color and identity and type(identity.color) == 'string'
                and (#identity.color==6 or #identity.color==8) and identity.color:match('^%x+$') then
                prefix = attempt(env.colorize, prefix, identity.color) or prefix
            end
            prefix = prefix .. ' '
        end
        text = prefix .. clipped(text, math.max(0, 512 - #prefix))
        state.pings[#state.pings+1] = {key=event.key, category=event.category, text=text, expires=now+15, retry=now,
            context=attempt(env.context), session=snapshot and snapshot.session, mine=snapshot and snapshot.mine,
            host=snapshot and snapshot.host, creator_id=event.creator_id, known_identity=identity ~= nil}
        state.ping_seen[event.key] = now + 30
        return true
    end
    local function poll_ping(now)
        if not options.enabled or not options.ping then state.pings = {}; return false end
        if type(now) ~= 'number' or now ~= now then return false end
        local snapshot = api.snapshot()
        local context = attempt(env.context)
        for i=#state.pings,1,-1 do
            local p = state.pings[i]
            if now > p.expires or not creator_present(p.creator_id, snapshot)
                or not options['ping_' .. p.category]
                or p.context ~= context or p.session ~= (snapshot and snapshot.session)
                or p.mine ~= (snapshot and snapshot.mine) or p.host ~= (snapshot and snapshot.host) then
                table.remove(state.pings,i)
            end
        end
        local pending, index
        for i,p in ipairs(state.pings) do
            if now>=p.retry then
                local allowed,why=policy(now,snapshot and #snapshot.remote or nil,snapshot,p.creator_id)
                if allowed then pending,index=p,i;break end
                state.status=why
            end
        end
        if not pending then return false end
        local sent = attempt(env.send, pending.text)
        if sent == true then
            table.remove(state.pings,index); api.record(now,pending.creator_id)
            state.status='已发送玩家标记提示'; return true, state.status
        end
        pending.retry=now+5
        state.status='等待：标记提示暂未发送（5秒后重试）'
        return false, state.status
    end
    function api.poll(now)
        local sent, why = poll_welcome(now)
        if sent then return sent, why end
        local ping_sent, ping_why = poll_ping(now)
        return ping_sent, ping_why or why
    end
    return api
end
