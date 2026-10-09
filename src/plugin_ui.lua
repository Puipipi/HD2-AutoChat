-- Build a bounded drawing facade for one registered plugin body.
-- UX and image callbacks close over the host GUI; none of those native objects
-- are returned to plugin code.
local function build_plugin_ui(env)
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

return build_plugin_ui
