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
