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
