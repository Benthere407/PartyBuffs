--[[
* Draws the timer rings around buff icons (and the shift+drag outline) through a full screen,
* click-through imgui window, drawn on top of the sprite icons.
*
* A ring starts full and shrinks counter-clockwise back to 12 o'clock as the buff runs out.
* The moving end of the ring can twinkle (a glow, a flickering star and a few drifting sparks),
* show a plain dot, or nothing.
--]]

local imgui = require('imgui');
local scaling = require('scaling');
local yunaFont = require('yunafont');

local overlay = {};

local TWO_PI   = math.pi * 2;
local TOP      = -math.pi / 2;
local SEGMENTS = 64;   -- segments in a full circle

local WINDOW_FLAGS = bit.bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_NoInputs, ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoBringToFrontOnFocus, ImGuiWindowFlags_NoNav);

local function opt(name, default)
    local v = settings[name];
    if (v == nil) then
        return default;
    end
    return v;
end

-- 0xAARRGGBB -> { r, g, b, a } floats
local function argb_to_v4(c)
    return {
        bit.band(bit.rshift(c, 16), 0xFF) / 255,
        bit.band(bit.rshift(c, 8), 0xFF) / 255,
        bit.band(c, 0xFF) / 255,
        bit.band(bit.rshift(c, 24), 0xFF) / 255,
    };
end

local function lerp_v4(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t };
end

local function with_alpha(c, alpha)
    return imgui.GetColorU32({ c[1], c[2], c[3], c[4] * alpha });
end

-- Arc from angle a1 to a2 (radians, clockwise on screen) as line segments
local function draw_arc(draw, cx, cy, r, a1, a2, col, thickness)
    local count = math.max(2, math.ceil(SEGMENTS * (a2 - a1) / TWO_PI));
    local step = (a2 - a1) / count;
    local px, py = cx + math.cos(a1) * r, cy + math.sin(a1) * r;
    for i = 1,count do
        local a = a1 + step * i;
        local nx, ny = cx + math.cos(a) * r, cy + math.sin(a) * r;
        draw:AddLine({ px, py }, { nx, ny }, col, thickness);
        px, py = nx, ny;
    end
end

local function draw_sparkle(draw, cx, cy, r, tip, color, thickness, seed, t)
    local tx, ty = cx + math.cos(tip) * r, cy + math.sin(tip) * r;
    local white = { 1, 1, 1, 1 };
    local flicker = 0.65 + 0.35 * math.sin((t * 13) + seed * 7);

    -- Soft glow and a bright core
    draw:AddCircleFilled({ tx, ty }, thickness * 2.2, with_alpha(color, 0.30 * flicker), 12);
    draw:AddCircleFilled({ tx, ty }, math.max(1, thickness * 0.9), with_alpha(white, 0.9 * flicker), 8);

    -- Twinkling 4 point star, slowly turning
    local len = thickness * (1.6 + 1.4 * flicker);
    local spin = (t * 2) + seed;
    for k = 0,1 do
        local a = spin + k * (math.pi / 2);
        local dx, dy = math.cos(a) * len, math.sin(a) * len;
        draw:AddLine({ tx - dx, ty - dy }, { tx + dx, ty + dy }, with_alpha(white, 0.8 * flicker), 1);
    end

    -- Sparks drifting off behind the moving end
    for i = 0,3 do
        local p = ((t * 1.3) + (i / 4) + seed) % 1;           -- 0 = just spawned, 1 = faded out
        local a = tip - (p * 0.6);                            -- trail back along the ring
        local wobble = math.sin((t * 9) + (i * 2.1) + seed) * thickness;
        local sr = r + (p * thickness * 3) + wobble;          -- drift outward
        local sx, sy = cx + math.cos(a) * sr, cy + math.sin(a) * sr;
        local col = (i % 2 == 0) and white or color;
        draw:AddCircleFilled({ sx, sy }, math.max(0.6, (1 - p) * thickness * 0.8), with_alpha(col, (1 - p) * 0.9), 6);
    end
end

-- 'sparkle', 'dot' or 'none' (older settings only had the ring_sparkle on/off switch)
local function TipStyle()
    local style = settings.ring_tip;
    if (style == nil) then
        return (settings.ring_sparkle == false) and 'none' or 'sparkle';
    end
    return style;
end

-- Fraction of time left below which a buff counts as "low" (warn color, blinking, only-when-low)
local function LowPoint()
    return opt('ring_low_percent', 25) / 100;
end

local function IsLow(frac)
    return (frac ~= nil) and (frac >= 0) and (frac < LowPoint());
end

local function draw_ring(draw, ring, t)
    local frac = ring.fraction;
    if opt('ring_only_low', false) and (not IsLow(frac)) then
        return;   -- healthy, unknown and permanent buffs get no ring
    end

    local thickness = opt('ring_thickness', 2);
    -- Gap 0 = ring's outer edge touches the icon's edges (icons sit side by side, so larger gaps overlap neighbours)
    local r  = (ring.size / 2) + opt('ring_gap', 0) - (thickness / 2);
    local cx = ring.x + (ring.size / 2);
    local cy = ring.y + (ring.size / 2);

    local color = argb_to_v4(opt('ring_color', 0xFF66CCFF));

    if (frac == nil) or (frac == -1) then
        -- Unknown time left / permanent: plain full ring, no movement
        if (frac == -1) or opt('ring_show_unknown', true) then
            draw_arc(draw, cx, cy, r, TOP, TOP + TWO_PI, with_alpha(color, (frac == -1) and 1.0 or 0.45), thickness);
        end
        return;
    end

    -- Shift toward the warning color once low
    local low = LowPoint();
    if opt('ring_warn', true) and IsLow(frac) then
        color = lerp_v4(argb_to_v4(opt('ring_low_color', 0xFFFF4040)), color, frac / low);
    end

    local tip = TOP + (math.max(0, frac) * TWO_PI);

    -- Time gone: from the moving end round to 12 o'clock
    if (frac < 1) then
        draw_arc(draw, cx, cy, r, tip, TOP + TWO_PI, with_alpha(argb_to_v4(opt('ring_gone_color', 0x2E66CCFF)), 1.0), thickness);
    end

    if (frac <= 0) then
        return;
    end
    -- Time left: from 12 o'clock to the moving end
    draw_arc(draw, cx, cy, r, TOP, tip, with_alpha(color, 1.0), thickness);

    local style = TipStyle();
    if (style == 'sparkle') then
        draw_sparkle(draw, cx, cy, r, tip, color, thickness, ring.seed or 0, t);
    elseif (style == 'dot') and ((not opt('ring_dot_only_low', false)) or IsLow(frac)) then
        -- Blink while low (faster in the last 40% of the low window)
        local alpha = 1.0;
        if opt('ring_warn', true) and IsLow(frac) then
            local speed = (frac < low * 0.4) and 14 or 8;
            alpha = 0.15 + 0.85 * (0.5 + 0.5 * math.sin(t * speed + (ring.seed or 0)));
        end
        local tx, ty = cx + math.cos(tip) * r, cy + math.sin(tip) * r;
        local dot = opt('ring_dot_size', 3);
        draw:AddCircleFilled({ tx, ty }, dot, with_alpha(color, alpha), 16);
        draw:AddCircleFilled({ tx, ty }, math.max(1, dot * 0.57), with_alpha({ 1, 1, 1, 1 }, alpha), 12);
    end
end

-- Time left as shown under the icon: "16m", "1m", "50" (or "5+" / nothing while above the cap, if enabled)
local function format_time(seconds)
    if opt('timer_text_cap', false) then
        local cap = opt('timer_text_cap_minutes', 5);
        if (seconds > cap * 60) then
            if opt('timer_text_cap_hide', false) then
                return nil;
            end
            return ('%d+'):format(cap);
        end
    end
    if (seconds >= 3600) then
        return ('%dh'):format(math.floor(seconds / 3600));
    elseif (seconds >= 60) then
        return ('%dm'):format(math.floor(seconds / 60));
    end
    return ('%d'):format(math.ceil(seconds));
end

local function text_size(text)
    local a, b = imgui.CalcTextSize(text);
    if (type(a) == 'table') then
        return a.x or a[1], a.y or a[2];
    end
    return a, b;
end

local OUTLINE_DIRS = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } };

local function draw_timer_text(draw, ring)
    local left = ring.remaining;
    if (left == nil) or (left <= 0) then
        return;   -- unknown, permanent (-1) or expired
    end
    local text = format_time(left);
    if (text == nil) then
        return;
    end
    local w, h = text_size(text);
    local x = ring.x + ((ring.size - w) / 2) + opt('timer_text_offset_x', 0);
    local y = ring.y + ring.size + opt('timer_text_offset_y', -2);
    if ring.above then
        y = ring.y - (h or 0) - opt('timer_text_offset_y', -2);   -- mirrored: same overlap, on top
    elseif ring.zig then
        y = y + (h or 0);   -- zigzag so labels under overlapping icons don't run together
    end

    local color = argb_to_v4(opt('timer_text_color', 0xFFFFFFFF));
    if opt('ring_warn', true) and IsLow(ring.fraction) then
        color = argb_to_v4(opt('ring_low_color', 0xFFFF4040));
    end

    local outline = imgui.GetColorU32(argb_to_v4(opt('timer_text_outline_color', 0xFF000000)));
    for _,d in ipairs(OUTLINE_DIRS) do
        draw:AddText({ x + d[1], y + d[2] }, outline, text);
    end
    draw:AddText({ x, y }, imgui.GetColorU32(color), text);
end

-- rings: { { x, y, size, fraction, remaining, seed }, ... }; outline: nil or { x1, y1, x2, y2, active }
function overlay.Draw(rings, outline)
    if (#rings == 0) and (outline == nil) then
        return;
    end

    imgui.SetNextWindowPos({ 0, 0 });
    imgui.SetNextWindowSize({ scaling.window.w, scaling.window.h });
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    if imgui.Begin('##partybuffs_overlay', true, WINDOW_FLAGS) then
        local draw = imgui.GetWindowDrawList();
        local t = os.clock();
        if opt('show_rings', false) then
            for _,ring in ipairs(rings) do
                draw_ring(draw, ring, t);
            end
        end
        if opt('show_timer_text', false) then
            -- Text size is relative to ImGui's own 13 px font
            local px = 13 * opt('timer_text_scale', 0.85);
            local pushed = false;
            if (opt('timer_text_font', 'yuna') == 'yuna') then
                pushed = yunaFont.push(px);
            else
                imgui.SetWindowFontScale(px / 13);
            end
            for _,ring in ipairs(rings) do
                draw_timer_text(draw, ring);
            end
            yunaFont.pop(pushed);
        end

        if (outline ~= nil) then
            local col = outline.active and imgui.GetColorU32({ 1.0, 0.75, 0.2, 1.0 }) or imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.5 });
            local pad = 2 + (opt('show_rings', false) and math.max(0, opt('ring_gap', 0)) or 0);
            local x1, y1, x2, y2 = outline.x1 - pad, outline.y1 - pad, outline.x2 + pad, outline.y2 + pad;
            draw:AddLine({ x1, y1 }, { x2, y1 }, col, 1.5);
            draw:AddLine({ x2, y1 }, { x2, y2 }, col, 1.5);
            draw:AddLine({ x2, y2 }, { x1, y2 }, col, 1.5);
            draw:AddLine({ x1, y2 }, { x1, y1 }, col, 1.5);
        end
    end
    imgui.End();
    imgui.PopStyleVar(2);
end

return overlay;
