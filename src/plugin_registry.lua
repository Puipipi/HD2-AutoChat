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
