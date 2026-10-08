-- Addon resource: mods/codex/auto_chat_demo
-- Optional interface example. Loading/registering it never sends a message.
local existing = rawget(_G, 'HD2AutoChatPlugins')
if type(existing) == 'table' and type(existing.by_id) == 'table' and existing.by_id.auto_chat_demo then
    return existing.by_id.auto_chat_demo
end
local pending = rawget(_G, 'HD2AutoChatPending')
if type(pending) ~= 'table' then pending = {}; rawset(_G, 'HD2AutoChatPending', pending) end
if pending.auto_chat_demo then return pending.auto_chat_demo end
local state = {enabled = false, clicks = 0, pings = 0, revision = 0, result = '尚未发送'}
local spec = {id = 'auto_chat_demo', name = '接口示例'}
spec.draw = function(u)
    u.text('跨模组接口示例', 22, 18, 22)
    u.text('点击次数：' .. state.clicks .. ' / 收到标记事件：' .. state.pings, 22, 54, 14)
    u.button('toggle', state.enabled and '标记计数：开启' or '标记计数：关闭', 22, 90, 240, 32, true)
    u.button('send', '立即发送测试消息', 22, 136, 240, 32, true)
    u.text(state.result, 22, 184, 14)
end
spec.on_click = function(key, api)
    if key == 'toggle' then state.enabled = not state.enabled
    elseif key == 'send' then
        local ok, why = api.send('AutoChat 接口示例：测试消息')
        state.result = ok and '测试消息已发送' or ('发送等待：' .. tostring(why))
    else return false, 'unknown control' end
    state.clicks, state.revision = state.clicks + 1, state.revision + 1
    return true
end
spec.on_event = function(event)
    if state.enabled and event.type == 'ping' then
        state.pings, state.revision = state.pings + 1, state.revision + 1
    end
end
spec.revision = function() return state.revision end
if type(existing) == 'table' and type(existing.register) == 'function' then
    local entry = existing.register(spec)
    if entry then return entry end
end
pending[spec.id] = spec
return spec
