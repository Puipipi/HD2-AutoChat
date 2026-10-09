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
