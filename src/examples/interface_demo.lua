-- Standalone addon resource: mods/codex/auto_chat_demo
-- This example has no live event subscription and never sends while drawing.
local existing = rawget(_G, 'HD2AutoChatPlugins')
if type(existing) == 'table' and type(existing.by_id) == 'table' and existing.by_id.auto_chat_demo then
    return existing.by_id.auto_chat_demo
end

local pending = rawget(_G, 'HD2AutoChatPending')
if type(pending) ~= 'table' then
    pending = {}
    rawset(_G, 'HD2AutoChatPending', pending)
end
if pending.auto_chat_demo then return pending.auto_chat_demo end

local messages = {
    {zh = 'AutoChat 接口示例：自定义消息 Alpha', en = 'AutoChat API demo: custom message Alpha'},
    {zh = 'AutoChat 接口示例：自定义消息 Beta', en = 'AutoChat API demo: custom message Beta'},
}
local copy = {
    zh = {
        title = '跨模组发送接口示例（API v2 revision 4）',
        settings_unavailable = '主设置：当前接口不提供设置快照',
        settings_error = '主设置：暂不可用', settings_unknown = '未知',
        on = '开', off = '关', local_output = '仅自己', squad = '小队',
        client = '客机', host = '主机', role_unknown = '未确认',
        settings = '主设置：%s / 间隔 %s秒 / %s / %s',
        mode = '模式：%s；独立发送：%s；冷却：%d秒；输出：%s',
        inherit = '继承主设置', independent = '独立',
        preview = '消息预览：%s', mode_button = '发送模式：%s',
        enabled_button = '独立发送：%s', cooldown_button = '独立冷却：%d秒',
        output_button = '独立输出：%s', template_button = '切换自定义消息模板',
        send_button = '手动发送预览消息', sample_button = '本地示例事件并手动发送',
        sample_count = '本地示例事件次数：%d', icon_missing = '游戏图标当前未加载',
        icon_unavailable = '游戏图标当前不可用（宿主未提供已加载材质）',
        unsent = '尚未发送', disabled = '独立发送已关闭', sent_local = '已仅自己发送',
        sent = '已发送', failed = '未发送：%s',
        capability_missing = '当前 AutoChat 未提供独立发送扩展',
        mode_changed = '已切换发送模式', cooldown_changed = '已切换独立冷却',
        enabled_on = '独立发送已开启', output_changed = '已切换独立输出方式',
        template_changed = '已切换消息模板', sample_target = '地图标记',
        sample_message = 'AutoChat 接口示例：本地示例事件 #%d（%s）',
    },
    en = {
        title = 'Cross-mod send API demo (API v2 revision 4)',
        settings_unavailable = 'Host settings: settings snapshots unavailable in this API',
        settings_error = 'Host settings: temporarily unavailable', settings_unknown = 'unknown',
        on = 'on', off = 'off', local_output = 'local', squad = 'squad',
        client = 'client', host = 'host', role_unknown = 'unconfirmed',
        settings = 'Host settings: %s / cooldown %ss / %s / %s',
        mode = 'Mode: %s; independent send: %s; cooldown: %ds; output: %s',
        inherit = 'inherit host settings', independent = 'independent',
        preview = 'Message preview: %s', mode_button = 'Send mode: %s',
        enabled_button = 'Independent send: %s', cooldown_button = 'Independent cooldown: %ds',
        output_button = 'Independent output: %s', template_button = 'Switch message template',
        send_button = 'Send preview manually', sample_button = 'Send local sample event',
        sample_count = 'Local sample events: %d', icon_missing = 'Game icon is not currently loaded',
        icon_unavailable = 'Game icon unavailable (host supplied no loaded material)',
        unsent = 'Not sent yet', disabled = 'Independent sending is disabled',
        sent_local = 'Sent locally', sent = 'Sent', failed = 'Not sent: %s',
        capability_missing = 'This AutoChat host does not provide independent sending',
        mode_changed = 'Send mode changed', cooldown_changed = 'Independent cooldown changed',
        enabled_on = 'Independent sending enabled', output_changed = 'Independent output changed',
        template_changed = 'Message template changed', sample_target = 'Map marker',
        sample_message = 'AutoChat API demo: local sample event #%d (%s)',
    },
}

local state = {
    message_index = 1,
    sample_events = 0,
    revision = 0,
    result_kind = 'unsent',
    result_reason = nil,
    preview = messages[1].zh,
    preview_kind = 'stock',
    language = 'zh',
    settings_snapshot = nil,
    policy = 'inherit',
    independent_enabled = true,
    cooldown = 0,
    output = 'inherit',
    active_role = 'host',
}

local function default_preset_state()
    return {policy='inherit',independent_enabled=true,cooldown=0,output='inherit',message_index=1}
end
local profile_states = {host=default_preset_state(),client=default_preset_state()}

local function save_active_preset_state()
    local role=state.active_role
    if role~='host' and role~='client' then return end
    profile_states[role]={policy=state.policy,independent_enabled=state.independent_enabled,
        cooldown=state.cooldown,output=state.output,message_index=state.message_index}
end

local function load_preset_state(role)
    local saved=profile_states[role] or default_preset_state()
    state.active_role=role
    state.policy=saved.policy
    state.independent_enabled=saved.independent_enabled
    state.cooldown=saved.cooldown
    state.output=saved.output
    state.message_index=saved.message_index
    state.preview=messages[state.message_index][state.language]
    state.preview_kind='stock'
    state.result_kind='unsent'
    state.result_reason=nil
end

local function changed()
    state.revision = state.revision + 1
    save_active_preset_state()
end

local function activate_role(role)
    if (role~='host' and role~='client') or role==state.active_role then return end
    save_active_preset_state()
    load_preset_state(role)
    changed()
end

local function language(value)
    return value == 'en' and 'en' or 'zh'
end

local PRESET_MAGIC='AutoChatInterfaceDemoPreset1'
local function parse_preset_state(data,role)
    if role~='host' and role~='client' then return nil,'invalid preset role' end
    if type(data)~='string' or #data>256 or data:sub(-1)~='\n' then
        return nil,'invalid demo preset data'
    end
    local lines={}
    for line in data:gmatch('([^\n]*)\n') do lines[#lines+1]=line end
    if #lines~=6 or lines[1]~=PRESET_MAGIC then return nil,'invalid demo preset format' end
    local policy=lines[2]:match('^policy=(.*)$')
    local enabled=lines[3]:match('^enabled=(.*)$')
    local cooldown=lines[4]:match('^cooldown=(.*)$')
    local output=lines[5]:match('^output=(.*)$')
    local index=lines[6]:match('^message_index=(.*)$')
    if (policy~='inherit' and policy~='independent')
        or (enabled~='true' and enabled~='false')
        or (cooldown~='0' and cooldown~='5')
        or (output~='inherit' and output~='local')
        or (index~='1' and index~='2') then return nil,'invalid demo preset values' end
    return {policy=policy,independent_enabled=enabled=='true',cooldown=tonumber(cooldown),
        output=output,message_index=tonumber(index)}
end

local function encode_preset_state(values)
    return PRESET_MAGIC..'\npolicy='..values.policy
        ..'\nenabled='..tostring(values.independent_enabled)
        ..'\ncooldown='..tostring(values.cooldown)
        ..'\noutput='..values.output
        ..'\nmessage_index='..tostring(values.message_index)..'\n'
end

local function read_settings(api)
    if type(api) ~= 'table' or type(api.settings) ~= 'function' then return nil end
    local okay, settings = pcall(api.settings)
    if okay and type(settings) == 'table' then
        state.settings_snapshot = settings
        return settings
    end
    return nil
end

local function sync_language(value)
    value = language(value)
    if value == state.language then return end
    local old_language = state.language
    if state.preview_kind == 'stock'
        and state.preview == messages[state.message_index][old_language] then
        state.preview = messages[state.message_index][value]
    elseif state.preview_kind == 'sample' then
        state.preview = string.format(copy[value].sample_message,
            state.sample_events, copy[value].sample_target)
    end
    state.language = value
    changed()
end

local function current_language(api)
    local settings = read_settings(api)
    if settings then
        activate_role(settings.role)
        if settings.language then sync_language(settings.language) end
    end
    return state.language
end

local function result_text(locale)
    local words = copy[locale]
    if state.result_kind == 'failed' then
        return string.format(words.failed, tostring(state.result_reason))
    end
    if state.result_kind == 'disabled' then return words.disabled end
    if state.result_kind == 'sent_local' then return words.sent_local end
    if state.result_kind == 'sent' then return words.sent end
    if state.result_kind == 'capability_missing' then return words.capability_missing end
    if state.result_kind == 'mode_changed' then return words.mode_changed end
    if state.result_kind == 'cooldown_changed' then return words.cooldown_changed end
    if state.result_kind == 'enabled_changed' then
        return state.independent_enabled and words.enabled_on or words.disabled
    end
    if state.result_kind == 'output_changed' then return words.output_changed end
    if state.result_kind == 'template_changed' then return words.template_changed end
    return words.unsent
end

local function send_message(text, api)
    if state.policy == 'independent' and not state.independent_enabled then
        state.result_kind = 'disabled'
        state.result_reason = nil
        changed()
        return false, 'plugin disabled'
    end
    local ok, why
    if state.policy == 'independent' then
        ok, why = api.send(text, nil, {
            policy = 'independent', enabled = true,
            cooldown = state.cooldown, cooldown_key = 'interface_demo',
            allow_solo = true, output = state.output,
        })
    else
        -- Omit options in inherit mode to preserve the original API v2 call.
        ok, why = api.send(text)
    end
    state.result_kind = ok and (why == 'local' and 'sent_local' or 'sent') or 'failed'
    state.result_reason = not ok and why or nil
    changed()
    return ok, why
end

-- This local fixture demonstrates an addon-owned event handler. It never
-- publishes a fabricated event to AutoChat or to other plugins.
local function handle_sample_event(event, api, locale)
    state.sample_events = state.sample_events + 1
    local target = type(event.target) == 'string' and event.target or copy[locale].sample_target
    local message = string.format(copy[locale].sample_message, state.sample_events, target)
    state.preview = message
    state.preview_kind = 'sample'
    return send_message(message, api)
end

local function settings_summary(locale)
    local words = copy[locale]
    local settings = state.settings_snapshot
    if not settings then
        return words.settings_unavailable
    end
    local enabled = settings.enabled == true and words.on or words.off
    local interval = tonumber(settings.cooldown)
    local output = settings.output == 'local' and words.local_output or words.squad
    local role = settings.role == 'client' and words.client
        or settings.role == 'host' and words.host or words.role_unknown
    return string.format(words.settings, enabled,
        interval and tostring(interval) or words.settings_unknown, output, role)
end

local spec = {id = 'auto_chat_demo', name = '接口示例', name_en = 'API Demo'}
spec.preset = {
    capture = function(role)
        if role~='host' and role~='client' then return nil,'invalid preset role' end
        if role==state.active_role then save_active_preset_state() end
        return encode_preset_state(profile_states[role] or default_preset_state())
    end,
    validate = function(data,role)
        local parsed,why=parse_preset_state(data,role)
        return parsed~=nil,why
    end,
    apply = function(data,role)
        local parsed,why=parse_preset_state(data,role)
        if not parsed then return false,why end
        profile_states[role]=parsed
        if role==state.active_role then
            load_preset_state(role)
            changed()
        end
        return true
    end,
    restore = function(data,role)
        return spec.preset.apply(data,role)
    end,
}
spec.draw = function(u, ctx, api)
    ctx = type(ctx) == 'table' and ctx or {}
    local locale = language(ctx.language or (type(u) == 'table' and u.language))
    local settings = read_settings(api)
    if settings then activate_role(settings.role) end
    if settings and not ctx.language and not (type(u) == 'table' and u.language) then
        locale = language(settings.language)
    end
    sync_language(locale)
    local words = copy[locale]
    u.text(words.title, 22, 18, 22)
    u.text(settings_summary(locale), 22, 50, 14, nil, 700)
    u.text(string.format(words.mode,
        state.policy == 'independent' and words.independent or words.inherit,
        state.independent_enabled and words.on or words.off,
        state.cooldown,
        state.output == 'local' and words.local_output or words.inherit), 22, 76, 14, nil, 700)
    u.text(string.format(words.preview, state.preview), 22, 104, 14, nil, 700)

    local independent = state.policy == 'independent'
    local can_independent = type(api) == 'table' and type(api.capabilities) == 'table'
        and api.capabilities.independent_send == true
    u.button('mode', string.format(words.mode_button,
        independent and words.independent or words.inherit),
        22, 138, 200, 32, can_independent, independent)
    u.button('enabled', string.format(words.enabled_button,
        state.independent_enabled and words.on or words.off),
        230, 138, 190, 32, independent, state.independent_enabled)
    u.button('cooldown', string.format(words.cooldown_button, state.cooldown),
        428, 138, 190, 32, independent, state.cooldown == 5)
    u.button('output', string.format(words.output_button,
        state.output == 'local' and words.local_output or words.inherit),
        626, 138, 220, 32, independent, state.output == 'local')
    u.button('template', words.template_button, 22, 180, 270, 32, true)
    local send_enabled = state.policy ~= 'independent' or state.independent_enabled
    u.button('send', words.send_button, 302, 180, 270, 32, send_enabled)
    u.button('sample', words.sample_button, 582, 180, 290, 32, send_enabled)

    u.text(string.format(words.sample_count, state.sample_events), 22, 226, 14)
    u.text(result_text(locale), 22, 252, 14, nil, 700)
    if type(u.line) == 'function' then
        u.line(22, 286, 872, 286, u.palette and u.palette.LINE2 or nil, 953, 1)
    end
    local resource = u.loaded_icon or ctx.loaded_icon
    local icon = type(resource) == 'string'
        and #resource == 16 and resource:match('^%x+$') and resource or nil
    if icon and type(u.icon) == 'function' then
        local shown = u.icon(icon, 22, 304, 40)
        if shown == false then u.text(words.icon_missing, 72, 314, 13) end
    else
        u.text(words.icon_unavailable, 22, 314, 13)
    end
end

spec.on_click = function(key, api)
    local locale = current_language(api)
    local words = copy[locale]
    if key == 'mode' then
        if type(api) ~= 'table' or type(api.capabilities) ~= 'table'
            or api.capabilities.independent_send ~= true then
            state.result_kind = 'capability_missing'
            state.result_reason = nil
            changed()
            return false, 'independent send unavailable'
        end
        state.policy = state.policy == 'inherit' and 'independent' or 'inherit'
        state.result_kind = 'mode_changed'
        state.result_reason = nil
        changed()
        return true
    elseif key == 'cooldown' then
        if state.policy ~= 'independent' then return false, 'switch to independent mode first' end
        state.cooldown = state.cooldown == 0 and 5 or 0
        state.result_kind = 'cooldown_changed'
        state.result_reason = nil
        changed()
        return true
    elseif key == 'enabled' then
        if state.policy ~= 'independent' then return false, 'switch to independent mode first' end
        state.independent_enabled = not state.independent_enabled
        state.result_kind = 'enabled_changed'
        state.result_reason = nil
        changed()
        return true
    elseif key == 'output' then
        if state.policy ~= 'independent' then return false, 'switch to independent mode first' end
        state.output = state.output == 'inherit' and 'local' or 'inherit'
        state.result_kind = 'output_changed'
        state.result_reason = nil
        changed()
        return true
    elseif key == 'template' then
        state.message_index = state.message_index % #messages + 1
        state.preview = messages[state.message_index][locale]
        state.preview_kind = 'stock'
        state.result_kind = 'template_changed'
        state.result_reason = nil
        changed()
        return true
    elseif key == 'send' then
        return send_message(state.preview, api)
    elseif key == 'sample' then
        return handle_sample_event({
            type = 'ping', category = 'map', target = words.sample_target, source = 'local_demo_sample',
        }, api, locale)
    end
    return false, 'unknown control'
end

spec.revision = function() return state.revision end

if type(existing) == 'table' and type(existing.register) == 'function' then
    local entry = existing.register(spec)
    if entry then return entry end
end
pending[spec.id] = spec
return spec
