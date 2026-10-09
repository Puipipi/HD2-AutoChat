-- Automatic chat policy, inlined by the addon builder; no native offsets or writes.
-- Session API provenance: P2P-Ping 0.1.34 scope() / update_peer_labels().
local function build_chat_automation(env)
    local options = {enabled = true, allow_solo = true,
        welcome = false, welcome_message = '欢迎加入小队！', cooldown = 5,
        welcome_delay = 2, ping = false, ping_building = true, ping_stratagem = true, ping_map = true,
        ping_supplies = false,
        ping_sender_prefix = true, ping_sender_color = true, ping_medium_enemy = true,
        ping_large_enemy = true, ping_giant_enemy = true, ping_summon = true,
        ping_small_enemy = false, ping_flying_enemy = true,
        ping_message = '标记了{目标}（{类别}）', summon_message = '{玩家名}召唤了{目标}',
        task_stratagem_message = '{玩家名}正在开始{目标}', output = 'squad',
        quick_timer_enabled = false, quick_timer_interval = 30,
        quick_timer_message = 'HELLO FROM AUTOCHAT'}
    local keys = {'enabled', 'allow_solo', 'welcome', 'welcome_message',
        'cooldown', 'welcome_delay', 'ping', 'ping_building', 'ping_stratagem', 'ping_map', 'ping_supplies', 'ping_sender_prefix', 'ping_sender_color', 'ping_medium_enemy',
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
        options.ping_message = '标记了{目标}（{类别}）'
    end
    profiles = {host=copy(options), client=copy(options)}
    profiles.client.welcome, profiles.client.output = false, 'local'
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
    function api.export_profile(role, tasks)
        local source=profiles[role]
        if not source then return nil,'未知预设' end
        local lines={'# AutoChat profile v4'}
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
        if #tasks>32 then return nil,'预设最多包含32个定时任务' end
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
        local payload=table.concat(lines,'\n')..'\n'
        if #payload>1048576 then return nil,'预设超过 1 MiB' end
        return payload
    end
    function api.validate_profile(payload)
        if type(payload)~='string' or #payload>1048576 then return false,'预设格式无效或超过 1 MiB' end
        if payload:sub(-1)~='\n' or payload:find('\r',1,true) then return false,'预设须以换行结束且使用 LF' end
        local lines={};for line in payload:gmatch('([^\n]*)\n') do lines[#lines+1]=line end
        local version=tonumber(lines[1]:match('^# AutoChat profile v(%d+)$'))
        if version~=1 and version~=2 and version~=3 and version~=4 then return false,'预设版本无效' end
        local values,rules,seen,tasks_by_id={}, {}, {}, {}
        local task_count
        local scalar_set={};for _,key in ipairs(keys) do scalar_set[key]=true end
        for i=2,#lines do
            local key,raw=lines[i]:match('^([%w_%.]+)=(.*)$')
            if not key or key=='' or seen[key] then return false,'预设包含空白、重复或无效行' end
            seen[key]=true
            local value=unescape(raw)
            if value==nil or escape(value)~=raw then return false,'预设转义无效' end
            if not valid_utf8(value) then return false,'预设包含无效 UTF-8' end
            local task_index,task_field=key:match('^task_(%d+)%.([%a_]+)$')
            if key=='task_count' then
                if version<2 or not value:match('^%d+$') then return false,'定时任务数量无效' end
                task_count=tonumber(value)
                if task_count>32 then return false,'预设最多包含32个定时任务' end
            elseif task_index then
                local fields={name=true,mode=true,time=true,message=true,enabled=true}
                if version<2 or not fields[task_field] then return false,'定时任务字段无效' end
                local index=tonumber(task_index)
                if not index or index<1 or index>32 or index%1~=0 then return false,'定时任务编号无效' end
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
        local count=0;for _ in pairs(rules) do count=count+1 end
        if count>512 then return false,'规则数量超过 512' end
        return true,{values=values,rules=rules,tasks=task_list,version=version}
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
        supplies='普通物资',
        small_enemy='小型敌人', flying_enemy='飞行敌人', medium_enemy='中型敌人', large_enemy='大型敌人', giant_enemy='巨型敌人'}
    function api.category_label(category)
        local ok,value=pcall(env.category_label or function() return nil end,category)
        if ok and type(value)=='string' and value~='' then return value end
        return categories[category] or '未知'
    end
    function api.phrase(key,fallback)
        local ok,value=pcall(env.phrase or function() return nil end,key)
        if ok and type(value)=='string' and value~='' and value~=key then return value end
        return fallback
    end
    function api.stock_template(value)
        local ok,result=pcall(env.stock_template or function() return value end,value)
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
                local allowed, reason = policy(now,#snapshot.remote,snapshot,key)
                if allowed and (not entry or pending.joined < entry.joined
                    or pending.joined == entry.joined and key < candidate) then candidate, entry = key, pending
                elseif not allowed then blocked=reason end
            end
        end
        if not candidate then state.status = blocked or '等待新人欢迎'; return false, state.status end
        local allowed, reason = policy(now, #snapshot.remote, snapshot, candidate)
        if not allowed then state.status = reason; return false, reason end
        local sent, send_why = api.send(api.format(api.stock_template(options.welcome_message),candidate), state.active_role)
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
        if not api.sync() then state.status='等待：主机身份尚未确认';event_diagnostic(event,nil,'role-unknown');return false end
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
        if not creator_present(event.creator_id, snapshot) then event_diagnostic(event,rule_id,'creator-not-in-roster');return false end
        if #state.pings>=16 then
            if rule.cooldown~=0 then event_diagnostic(event,rule_id,'queue-full');return false end
            local evict
            for i,pending in ipairs(state.pings) do if pending.cooldown~=0 then evict=i;break end end
            if not evict then event_diagnostic(event,rule_id,'queue-full-no-eviction');return false end
            table.remove(state.pings,evict)
        end
        local label = api.category_label(event.category)
        local raw_target=type(event.display_name)=='string' and event.display_name or event.target
        local target = type(raw_target) == 'string' and plain(raw_target,200) or label
        local identity = identity_for(event.creator_id)
        local short = identity and plain(identity.short, 16) or '队友'
        if short == '' then short = '队友' end
        local objective_types = {primary='主线任务', prerequisite='主线前置任务',
            optional='支线任务', tactical='战术任务', unknown='任务'}
        local objective_kind=tostring(event.objective_kind or 'unknown')
        local objective_type=api.phrase('objective.'..objective_kind,objective_types[objective_kind] or label)
        local summoned = event.action == 'summon'
        local executing = event.action == 'use'
        local replacements = {['{类别}']=label, ['{目标}']=plain(target, 200),
            ['{动作}']=summoned and api.phrase('action.summon','召唤') or executing and api.phrase('action.start','开始') or api.phrase('action.mark','标记'),
            ['{任务名}']=plain(type(event.objective_name)=='string' and event.objective_name or target,200),
            ['{任务类型}']=objective_type or label,
            ['{位置}']=position_text(event)}
        local template = executing and options.task_stratagem_message or summoned and options.summon_message or options.ping_message
        template=((summoned or executing) and rule.call_message or not (summoned or executing) and rule.mark_message) or template
        template=api.stock_template(template)
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
