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
