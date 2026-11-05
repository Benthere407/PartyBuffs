--[[
* Party TP and target health numbers, from the tparty addon by atom0s (GPL-3.0).
*
* Party 1 (your party) moves with the buff list: its position is the list's offset (shift+drag,
* or the Position page) plus its own offset in settings.tp.layout.main, so its own offset only
* nudges the numbers against the buffs. The alliance parties and the target stay independent.
--]]

require('common');
local chat = require('chat');
local fonts = require('fonts');
local imgui = require('imgui');
local scaling = require('scaling');
local settingLib = require('settings');
local ffi = require('ffi');
local bit = require('bit');

local tpd = {
    test = false,        -- position test: a label on every slot and draggable boxes
    fx_try_until = 0,    -- Try it: the TP effect plays on every number until this time (os.clock)
};

-- Shift key detection (used for shift+click dragging)
pcall(ffi.cdef, [[ short GetAsyncKeyState(int vKey); ]]);
local function shift_down()
    local ok, r = pcall(function () return ffi.C.GetAsyncKeyState(0x10); end);
    return ok and r ~= nil and r < 0;
end

-- Default settings (settings.tp)
tpd.defaults = T{
    party = T{
        enabled = true,
        shift_drag = true,
        tp_ready_color = 0xFF00FF00,    -- TP 1000-2000 (below 1000 uses font.color).
        tp_max_color = 0xFFFFC840,      -- TP 2001 and up.
        border_size = 0,                -- Text border thickness in pixels (0 = off).
        border_color = 0xFF000000,
        in_front = true,                -- Draw party TP and target HP% in front of ImGui windows (YunaUI's frames).
        tp_fx = 'none',                 -- Effect when TP reaches 1000: none, blink, sparkle or both.
        tp_fx_mode = 'timed',           -- timed = for tp_fx_secs seconds, always = for as long as TP is 1000+.
        tp_fx_secs = 3,
        tp_fx_color = 0xFFFFF0B0,       -- Sparkle color.
        tp_fx_size = 100,               -- Sparkle size in percent.
        font = T{
            visible = true,
            locked = true,
            font_family = 'Arial',
            font_height = scaling.scale_f(8),
            bold = true,
            italic = true,
            right_justified = true,
            color = 0xFFFFFFFF,
        },
    },
    target = T{
        enabled = true,
        border_size = 0,
        border_color = 0xFF000000,
        font = T{
            visible = true,
            locked = true,
            font_family = 'Arial',
            font_height = scaling.scale_f(10),
            bold = true,
            italic = true,
            right_justified = true,
            color = 0xFFFFFFFF,
        },
    },
    -- Per-group layout. x/y are pixel offsets from the default position (+x = right, +y = down);
    -- spacing is the pixels between one row and the next.
    layout = T{
        main      = T{ enabled = true, x = 0, y = 0, size = 10, spacing = 20 }, -- Your party (slots 1-6).
        alliance1 = T{ enabled = true, x = 0, y = 0, size = 8, spacing = 16 }, -- Alliance party 2 (slots 7-12).
        alliance2 = T{ enabled = true, x = 0, y = 0, size = 8, spacing = 16 }, -- Alliance party 3 (slots 13-18).
        target    = T{ x = 0, y = 0, size = 10 }, -- Target HP percent.
    },
};

-- TParty Variables
local tparty = T{
    font_target = nil,
    font_party = T{ },
    border = { },       -- Border copies of each font: [0] = target, [1-18] = party slots.
};

-- Drag state
local ui = T{
    box_drag = nil,         -- Key of the test box currently being dragged.
    box_mx = 0, box_my = 0, -- Last mouse position while dragging a test box.
    last = T{ },            -- Last position set per slot (to detect dragging).
    last_target = nil,      -- Last position set for the target font.
    drag_unlocked = nil,    -- Current locked/unlocked state of the fonts.
    drag_dirty = false,     -- Slot offsets changed by dragging and not yet saved.
    tp_last = { },          -- Last TP seen per slot (to detect reaching 1000).
    fx_start = { },         -- When each slot reached 1000 TP (os.clock).
};

-- Ashita's font object has no border thickness setting, so the border is drawn as 8 copies of the
-- text in the border color, behind the main text.
local BORDER_DIRS = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } };

-- Font objects draw behind ImGui windows (YunaUI's frames are ImGui windows). In front mode the text is drawn
-- on ImGui's foreground list instead, which needs VanaCore's ImGui 1.92 (fonts at any size).
local can_front = rawget(_G, 'vana') ~= nil;
local front_faces = { };                -- Arial faces loaded into ImGui, by file name.
local FRONT_HANDLE = 0x00FFFFFF;        -- See-through color for the font objects, which stay as the shift+drag handles.
local FRONT_PX = 4 / 3;                 -- ImGui pixels per font object height.

-- The 1000 TP effect
local BLINK_SPEED = 2;                  -- Blinks per second.
local BLINK_LOW = 0.2;                  -- Alpha at the dim end of a blink.
local SPARKLES = 6;                     -- Stars around each number.
local SPARKLE_SECS = 0.9;               -- How long one star lasts.

--[[
* Converts an 0xAARRGGBB number to an ImGui color.
--]]
local function u32(c)
    return imgui.GetColorU32({
        bit.band(bit.rshift(c, 16), 0xFF) / 255,
        bit.band(bit.rshift(c, 8), 0xFF) / 255,
        bit.band(c, 0xFF) / 255,
        bit.band(bit.rshift(c, 24), 0xFF) / 255,
    });
end

--[[
* Returns the layout group (main party / alliance 2 / alliance 3) that a slot belongs to.
--]]
local function group_of(x)
    local L = settings.tp.layout;
    if (x <= 6) then
        return L.main;
    elseif (x <= 12) then
        return L.alliance1;
    end
    return L.alliance2;
end

--[[
* Returns the unscaled base position for a party slot (includes the group offset).
--]]
local function slot_base(x, members)
    local L = settings.tp.layout;
    if (x <= 6) then
        -- Party 1 moves with the buff list
        return -95 + L.main.x + (settings.list_offset_x or 0),
            -34 - L.main.spacing * (6 - x) + L.main.spacing * (6 - members) + L.main.y + (settings.list_offset_y or 0);
    elseif (x <= 12) then
        return -100 + L.alliance1.x, -388 + L.alliance1.spacing * ((x - 1) % 6) + L.alliance1.y;
    end
    return -100 + L.alliance2.x, -287 + L.alliance2.spacing * ((x - 1) % 6) + L.alliance2.y;
end

--[[
* Returns an 0xAARRGGBB color with its alpha multiplied by k (0-1).
--]]
local function fade(c, k)
    return math.floor((math.floor(c / 0x1000000) % 256) * k) * 0x1000000 + c % 0x1000000;
end

--[[
* Returns the color for a TP amount.
--]]
local function tp_color(tp)
    local p = settings.tp.party;
    if (tp >= 2001) then
        return p.tp_max_color;
    elseif (tp >= 1000) then
        return p.tp_ready_color;
    end
    return p.font.color;
end

--[[
* Creates the border copies for a font. Call before creating the font itself so they are drawn underneath it.
*
* @param {number} key - The font's key in tparty.border.
* @param {table} font - The font settings.
--]]
local function border_new(key, font)
    local b = { shown = false };
    for i = 1, #BORDER_DIRS do
        b[i] = fonts.new(font);
    end
    tparty.border[key] = b;
end

--[[
* Applies font settings to a font's border copies. They never take the mouse, so only the real text can be dragged.
*
* @param {number} key - The font's key in tparty.border.
* @param {table} font - The font settings.
--]]
local function border_apply(key, font)
    local b = tparty.border[key];
    if (b == nil) then
        return;
    end
    for i = 1, #BORDER_DIRS do
        b[i]:apply(font);
        b[i].can_focus = false;
        b[i].locked = true;
        b[i].visible = false;
    end
    b.shown = false;
end

--[[
* Shows or hides a font's border copies around its text.
*
* @param {number} key - The font's key in tparty.border.
* @param {boolean} shown - Flag if the font's text is showing.
* @param {string} text - The font's text.
* @param {number} x - The font's x position.
* @param {number} y - The font's y position.
* @param {table} block - The settings table holding border_size and border_color.
* @param {number} alpha - The blink's alpha (0-1).
--]]
local function border_update(key, shown, text, x, y, block, alpha)
    local b = tparty.border[key];
    if (b == nil) then
        return;
    end

    local size = block.border_size;
    if (not shown or size <= 0 or text == '') then
        if (b.shown) then
            b.shown = false;
            for i = 1, #BORDER_DIRS do
                b[i].visible = false;
            end
        end
        return;
    end

    b.shown = true;
    for i, d in ipairs(BORDER_DIRS) do
        local o = b[i];
        o.color = fade(block.border_color, alpha);
        o.text = text;
        o.position_x = x + d[1] * size;
        o.position_y = y + d[2] * size;
        o.visible = true;
    end
end

--[[
* Applies the text sizes to all font objects.
--]]
function tpd.ApplyLayout()
    local L = settings.tp.layout;

    local function set_height(key, f, size)
        local h = scaling.scale_f(size);
        if (f ~= nil) then
            f.font_height = h;
        end
        local b = tparty.border[key];
        if (b ~= nil) then
            for i = 1, #BORDER_DIRS do
                b[i].font_height = h;
            end
        end
    end

    set_height(0, tparty.font_target, L.target.size);

    -- Sizes only; positions are set every frame in d3d_present (so shift+drag can be detected).
    for x = 1, 18 do
        local g = (x <= 6) and L.main or ((x <= 12) and L.alliance1 or L.alliance2);
        set_height(x, tparty.font_party[x], g.size);
    end
end

--[[
* Applies the font style and the sizes to all font objects.
--]]
function tpd.ApplyFonts()
    if (tparty.font_target ~= nil) then
        tparty.font_target:apply(settings.tp.target.font);
    end
    border_apply(0, settings.tp.target.font);

    tparty.font_party:each(function (v, _)
        if (v ~= nil) then
            v:apply(settings.tp.party.font);
        end
    end);
    for x = 1, 18 do
        border_apply(x, settings.tp.party.font);
    end

    tpd.ApplyLayout();
    ui.drag_unlocked = nil;
end


--[[
* Position test: label and color for each slot (P1-P6 = your party, B1-B6 = alliance 2, C1-C6 = alliance 3).
--]]
local test_colors = { 0xFF4FCCAE, 0xFFF2D161, 0xFFFF8080 };
local function test_label(x)
    local g = math.floor((x - 1) / 6) + 1;
    return string.format('%s%d', ({ 'P', 'B', 'C' })[g], ((x - 1) % 6) + 1), test_colors[g];
end

--[[
* Normalizes imgui calls that return either two numbers or a table into x, y.
--]]
local function pair(a, b)
    if (type(a) == 'number') then
        return a, tonumber(b) or 0;
    end
    if (a ~= nil) then
        -- Tables or userdata (ImVec2): try .x/.y then [1]/[2]..
        local ok, x, y = pcall(function ()
            local px = a.x; if (px == nil) then px = a[1]; end
            local py = a.y; if (py == nil) then py = a[2]; end
            return px, py;
        end);
        if (ok and tonumber(x) ~= nil) then
            return tonumber(x), tonumber(y) or 0;
        end
    end
    return 0, tonumber(b) or 0;
end

--[[
* Returns the screen size in pixels.
--]]
local function display_size()
    local ok, w, h = pcall(function () return pair(imgui.GetIO().DisplaySize); end);
    if (ok and type(w) == 'number' and w > 0 and type(h) == 'number' and h > 0) then
        return w, h;
    end
    ok, w, h = pcall(function () return scaling.window.w, scaling.window.h; end);
    if (ok and type(w) == 'number' and w > 0 and type(h) == 'number' and h > 0) then
        return w, h;
    end
    return 1920, 1080;
end

--[[
* Converts a font position to an on-screen position. Negative font positions are measured from the
* right / bottom edge of the screen, so they must be converted before drawing with imgui.
--]]
local function font_to_screen(x, y, sw, sh)
    return (x < 0) and (sw + x) or x, (y < 0) and (sh + y) or y;
end

--[[
* Draws one outline box (position test). When shift is held the box can be dragged; the drag delta is
* returned in unscaled-pixel-free screen pixels (dx, dy) so the caller can move the matching group.
--]]
local function draw_test_box(key, title, x1, y1, x2, y2, color, shift)
    local strip = 18; -- Room above the box for the title.
    local w, h = math.max(8, x2 - x1), math.max(8, y2 - y1) + strip;
    local dx, dy = 0, 0;

    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoBringToFrontOnFocus);
    if (not shift) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoInputs); -- Click-through unless shift is held.
    end

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    -- The window is a few pixels larger than the box so the border is not clipped..
    imgui.SetNextWindowPos({ x1 - 3, y1 - strip - 3 }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ w + 6, h + 6 }, ImGuiCond_Always);
    if (imgui.Begin('##pb_tp_box_' .. key, { true }, flags)) then
        local dl = imgui.GetForegroundDrawList();   -- Over YunaUI's frames, like the text.
        local solid = imgui.GetColorU32(color);
        local faint = imgui.GetColorU32({ color[1], color[2], color[3], 0.15 });
        local chipbg = imgui.GetColorU32({ 0.05, 0.06, 0.09, 0.85 });
        local tw = #title * 7 + 10;

        -- Faint fill..
        pcall(function () dl:AddRectFilled({ x1, y1 }, { x2, y2 }, faint, 3.0); end);

        -- Border (four lines; AddLine is the most dependable call)..
        pcall(function ()
            local t = 2.0;
            dl:AddLine({ x1, y1 }, { x2, y1 }, solid, t);
            dl:AddLine({ x2, y1 }, { x2, y2 }, solid, t);
            dl:AddLine({ x2, y2 }, { x1, y2 }, solid, t);
            dl:AddLine({ x1, y2 }, { x1, y1 }, solid, t);
        end);

        -- Title chip sitting on the top edge of the box so it is clear which party this is..
        pcall(function ()
            dl:AddRectFilled({ x1, y1 - strip }, { x1 + tw, y1 }, chipbg, 3.0);
            dl:AddLine({ x1, y1 - strip }, { x1 + tw, y1 - strip }, solid, 1.0);
        end);
        pcall(function () dl:AddText({ x1 + 5, y1 - strip + 1 }, solid, title); end);

        if (shift) then
            imgui.SetCursorPos({ 0, 0 });
            imgui.InvisibleButton('##drag_' .. key, { w + 6, h + 6 });
            if (imgui.IsItemActive()) then
                local ok, mx, my = pcall(function () return pair(imgui.GetMousePos()); end);
                if (ok) then
                    if (ui.box_drag == key) then
                        dx, dy = mx - ui.box_mx, my - ui.box_my;
                    end
                    ui.box_drag, ui.box_mx, ui.box_my = key, mx, my;
                end
            elseif (ui.box_drag == key) then
                ui.box_drag = nil;
            end
        elseif (ui.box_drag == key) then
            ui.box_drag = nil;
        end
    end
    imgui.End();
    imgui.PopStyleVar(2);

    return dx, dy;
end

--[[
* Returns the Arial face for a font style. A font added this frame is usable from the next, so ImGui's
* current font stands in until then.
--]]
local function front_face(font)
    local file = (font.bold and font.italic and 'arialbi') or (font.bold and 'arialbd') or (font.italic and 'ariali') or 'arial';
    local e = front_faces[file];
    if (e == nil) then
        local path = ('%s\\Fonts\\%s.ttf'):format(os.getenv('WINDIR') or 'C:\\Windows', file);
        local ok, f = pcall(imgui.AddFontFromFileTTF, path, 18);
        e = { font = ok and f or nil, frame = imgui.GetFrameCount() };
        front_faces[file] = e;
    end
    if (e.font ~= nil and imgui.GetFrameCount() > e.frame) then
        return e.font;
    end
    return imgui.GetFont();
end

--[[
* Draws text with its border on top of every window, where the font object would have put it.
*
* @param {userdata} dl - The foreground draw list.
* @param {string} text - The text.
* @param {number} color - The text color. (0xAARRGGBB)
* @param {number} x - The font's x position.
* @param {number} y - The font's y position.
* @param {number} height - The font's height.
* @param {table} font - The font settings.
* @param {table} block - The settings table holding border_size and border_color.
* @param {number} alpha - The blink's alpha (0-1).
--]]
local function draw_front(dl, text, color, x, y, height, font, block, alpha)
    if (text == nil or text == '') then
        return;
    end

    local face = front_face(font);
    local px = height * FRONT_PX;
    local sw, sh = display_size();
    x, y = font_to_screen(x, y, sw, sh);
    if (font.right_justified) then
        x = x - pair(face:CalcTextSizeA(px, 9999, 0, text));
    end

    if (block.border_size > 0) then
        local bc = u32(fade(block.border_color, alpha));
        for _, d in ipairs(BORDER_DIRS) do
            dl:AddText(face, px, { x + d[1] * block.border_size, y + d[2] * block.border_size }, bc, text);
        end
    end
    dl:AddText(face, px, { x, y }, u32(fade(color, alpha)), text);
end

--[[
* Draws twinkling four-point stars around a party font's text, on top of every window.
*
* @param {table} f - The font object.
* @param {number} x - The font's x position.
* @param {number} y - The font's y position.
* @param {number} now - The time now (os.clock).
* @param {number} seed - Keeps each slot's stars different.
* @param {number} color - The sparkle color. (0xAARRGGBB)
* @param {number} size - The sparkle size multiplier.
--]]
local function draw_sparkle(f, x, y, now, seed, color, size)
    local dl = imgui.GetForegroundDrawList();
    local w, h = f:get_text_size();
    local sw, sh = display_size();
    x, y = font_to_screen(x, y, sw, sh);
    if (settings.tp.party.font.right_justified) then
        x = x - w;
    end

    local function rnd(n)
        local v = math.sin(n * 12.9898) * 43758.5453;
        return v - math.floor(v);
    end

    for i = 1, SPARKLES do
        local t = now / SPARKLE_SECS + i / SPARKLES + seed * 0.37;
        local cycle = math.floor(t);
        local life = math.sin((t - cycle) * math.pi);       -- Grows and shrinks over its cycle.
        local cx = x - 2 + rnd(cycle + i * 13 + seed * 7) * (w + 4);
        local cy = y + rnd(cycle + i * 29 + seed * 11) * h;
        local long, thin = (2 + h * 0.3) * life * size, (0.6 + h * 0.05) * life * size;
        local col = u32(fade(color, life));
        dl:AddQuadFilled({ cx, cy - long }, { cx + thin, cy }, { cx, cy + long }, { cx - thin, cy }, col);
        dl:AddQuadFilled({ cx - long, cy }, { cx, cy - thin }, { cx + long, cy }, { cx, cy + thin }, col);
    end
end

--[[
* Creates the font objects.
--]]
function tpd.Load()
    -- Border copies are created first so they are drawn underneath the text..
    border_new(0, settings.tp.target.font);
    tparty.font_target = fonts.new(settings.tp.target.font);
    for x = 1, 18 do
        border_new(x, settings.tp.party.font);
        tparty.font_party[x] = fonts.new(settings.tp.party.font);
    end
    tpd.ApplyFonts();
end

--[[
* Destroys the font objects.
--]]
function tpd.Unload()
    if (tparty.font_target ~= nil) then
        tparty.font_target:destroy();
        tparty.font_target = nil;
    end

    if (tparty.font_party ~= nil) then
        tparty.font_party:each(function (v, _)
            v:destroy();
        end);
        tparty.font_party = T{ };
    end

    for _, b in pairs(tparty.border) do
        for i = 1, #BORDER_DIRS do
            b[i]:destroy();
        end
    end
    tparty.border = { };
end

--[[
* Draws the numbers. Call every frame.
*
* @param {boolean} testMode - Flag if the buffs' Test Mode is on: every party and the target show sample numbers.
--]]
function tpd.Render(testMode)
    local s = settings.tp;
    local L = s.layout;
    local test = tpd.test;
    local party = AshitaCore:GetMemoryManager():GetParty();
    -- The party list layout depends on how many members you have. Test mode uses your REAL party size so the
    -- positions match what is actually drawn..
    local real_members = party:GetAlliancePartyMemberCount1();
    local members = real_members;
    if (test) then
        members = math.max(1, math.min(6, real_members));
    end
    if (testMode) then
        members = 6;   -- the buffs' Test Mode draws a full party
    end
    local shift = s.party.shift_drag and shift_down() or false;

    -- In front of other windows: the font objects stay (see-through) so shift+drag still works..
    local front = can_front and s.party.in_front;
    local front_dl = nil;
    if (front) then
        front_dl = imgui.GetForegroundDrawList();
    end

    -- Update the target font..
    if (tparty.font_target ~= nil) then
        local target = GetEntity(AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0));
        -- The target is a fixed spot on screen: it uses a full 6-member party as its baseline and never moves when
        -- party / alliance members join or leave (use the Y offset to fine tune)..
        local count = 6;

        -- Detect a drag (the font moved away from where we last put it)..
        local tsx, tsy = scaling.scale_w(1), scaling.scale_h(1);
        if (shift and not test and ui.last_target ~= nil and tsx ~= 0 and tsy ~= 0) then
            local dx = tparty.font_target.position_x - ui.last_target.x;
            local dy = tparty.font_target.position_y - ui.last_target.y;
            if (math.abs(dx) > 0.5 or math.abs(dy) > 0.5) then
                L.target.x = L.target.x + dx / tsx;
                L.target.y = L.target.y + dy / tsy;
                ui.drag_dirty = true;
            end
        end

        local tpx = scaling.scale_w(-102 + L.target.x);
        local tpy = scaling.scale_h(-50 - 20 * count + L.target.y);
        tparty.font_target.position_x = tpx;
        tparty.font_target.position_y = tpy;
        ui.last_target = { x = tpx, y = tpy };

        if (test) then
            tparty.font_target.text = 'TGT';
        elseif (testMode) then
            tparty.font_target.text = '75';   -- A sample, even if the target display is switched off.
        elseif (not s.target.enabled) then
            tparty.font_target.text = '';
        elseif (target ~= nil) then
            tparty.font_target.text = tostring(target.HPPercent);
        elseif (shift) then
            -- Placeholder so there is something to grab while shift is held..
            tparty.font_target.text = '100';
        else
            tparty.font_target.text = '';
        end
        tparty.font_target.color = front and FRONT_HANDLE or s.target.font.color;
        border_update(0, not front, tparty.font_target.text, tpx, tpy, s.target, 1);
        if (front) then
            draw_front(front_dl, tparty.font_target.text, s.target.font.color, tpx, tpy, tparty.font_target.font_height, s.target.font, s.target, 1);
        end
    end

    -- Obtain the main players zone id..
    local zone = party:GetMemberZone(0);

    -- Shift+click dragging: unlock the fonts while shift is held so they can be dragged..
    if (ui.drag_unlocked ~= shift) then
        ui.drag_unlocked = shift;
        tparty.font_party:each(function (f, _)
            if (f ~= nil) then
                f.locked = not shift;
            end
        end);
        if (tparty.font_target ~= nil) then
            tparty.font_target.locked = not shift;
        end

        -- Shift released: round the offsets and save what was dragged..
        if (not shift and ui.drag_dirty) then
            ui.drag_dirty = false;
            for _, g in ipairs({ s.layout.main, s.layout.alliance1, s.layout.alliance2, s.layout.target }) do
                g.x = math.floor(g.x + 0.5);
                g.y = math.floor(g.y + 0.5);
            end
            settingLib.save();
        end
    end

    local sx = scaling.scale_w(1);
    local sy = scaling.scale_h(1);

    -- Detect a drag on any slot: the font moved away from where we last put it.
    -- The movement is applied to that slot's whole group (your party / alliance 2 / alliance 3)..
    if (shift and not test and sx ~= 0 and sy ~= 0) then
        for x = 1, 18 do
            local f = tparty.font_party[x];
            local last = ui.last[x];
            if (f ~= nil and last ~= nil) then
                local dx = f.position_x - last.x;
                local dy = f.position_y - last.y;
                if (math.abs(dx) > 0.5 or math.abs(dy) > 0.5) then
                    local g = group_of(x);
                    g.x = g.x + dx / sx;
                    g.y = g.y + dy / sy;
                    ui.drag_dirty = true;
                    break;
                end
            end
        end
    end

    -- The 1000 TP effect..
    local now = os.clock();
    local fx = s.party.tp_fx;
    local fx_try = now < tpd.fx_try_until;
    local blink_alpha = 1;
    if (fx == 'blink' or fx == 'both') then
        blink_alpha = BLINK_LOW + (1 - BLINK_LOW) * (0.5 + 0.5 * math.cos(now * BLINK_SPEED * 2 * math.pi));
    end

    -- Update the party TP fonts..
    for x = 1, 18 do
        local f = tparty.font_party[x];
        if (f ~= nil) then
            -- Text / visibility..
            local col = s.party.font.color;
            local fx_on = fx_try;
            if (test and x <= 6 and x > members) then
                f.visible = false;
            elseif (test) then
                local label;
                label, col = test_label(x);
                f.visible = true;
                f.text = label;
            elseif (testMode) then
                -- Sample numbers for every party, even ones switched off, so they can all be placed..
                local sample = (((x - 1) % 6) + 1) * 500;
                f.visible = true;
                col = tp_color(sample);
                f.text = tostring(sample);
            elseif (not s.party.enabled or group_of(x).enabled == false) then
                f.visible = false;
            elseif (party:GetMemberIsActive(x - 1) == 0 or party:GetMemberZone(x - 1) ~= zone) then
                f.visible = false;
                ui.tp_last[x] = nil;
                ui.fx_start[x] = nil;
            else
                local tp = party:GetMemberTP(x - 1);
                f.visible = true;
                col = tp_color(tp);
                f.text = tostring(tp);

                -- Only a real climb past 1000 starts the effect, not loading in with TP already up..
                if (tp < 1000) then
                    ui.fx_start[x] = nil;
                elseif (ui.tp_last[x] ~= nil and ui.tp_last[x] < 1000) then
                    ui.fx_start[x] = now;
                end
                ui.tp_last[x] = tp;
                if (tp >= 1000 and fx ~= 'none') then
                    if (s.party.tp_fx_mode == 'always') then
                        fx_on = true;
                    elseif (ui.fx_start[x] ~= nil and now - ui.fx_start[x] < s.party.tp_fx_secs) then
                        fx_on = true;
                    end
                end
            end
            local alpha = fx_on and blink_alpha or 1;
            f.color = front and FRONT_HANDLE or fade(col, alpha);

            -- Position = default + group offset..
            local bx, by = slot_base(x, members);
            local px = scaling.scale_w(bx);
            local py = scaling.scale_h(by);
            f.position_x = px;
            f.position_y = py;
            ui.last[x] = { x = px, y = py };
            border_update(x, f.visible and not front, f.text, px, py, s.party, alpha);
            if (front and f.visible) then
                draw_front(front_dl, f.text, col, px, py, f.font_height, s.party.font, s.party, alpha);
            end
            if (fx_on and f.visible and (fx == 'sparkle' or fx == 'both')) then
                draw_sparkle(f, px, py, now, x, s.party.tp_fx_color, s.party.tp_fx_size / 100);
            end
        end
    end

    -- Position test: outline box around each party (and the target) that can be shift+dragged..
    if (test and sx ~= 0 and sy ~= 0) then
        local pad = 6;
        local sw, sh = display_size();
        local rj = s.party.font.right_justified;
        local boxes = {
            { 'main',      'PARTY 1 (P1-P6)',      L.main,      1,  6,  { 0.310, 0.800, 0.680, 1.0 } },
            { 'alliance1', 'PARTY 2 (B1-B6)', L.alliance1, 7,  12, { 0.950, 0.820, 0.380, 1.0 } },
            { 'alliance2', 'PARTY 3 (C1-C6)', L.alliance2, 13, 18, { 1.000, 0.500, 0.500, 1.0 } },
        };

        for _, b in ipairs(boxes) do
            local top, bot, px = math.huge, -math.huge, nil;
            local upper = (b[1] == 'main') and math.min(b[5], members) or b[5];
            for x = b[4], upper do
                local last = ui.last[x];
                if (last ~= nil) then
                    local lx, ly = font_to_screen(last.x, last.y, sw, sh);
                    top = math.min(top, ly);
                    bot = math.max(bot, ly);
                    px = lx;
                end
            end
            local fh = tparty.font_party[b[4]] and tparty.font_party[b[4]].font_height or 12;
            if (px ~= nil) then
                local tw = fh * 3.4;
                local x1 = rj and (px - tw - pad) or (px - pad);
                local x2 = rj and (px + pad) or (px + tw + pad);
                local dx, dy = draw_test_box(b[1], b[2], x1, top - pad, x2, bot + fh * 1.7 + pad, b[6], shift);
                if (dx ~= 0 or dy ~= 0) then
                    b[3].x = b[3].x + dx / sx;
                    b[3].y = b[3].y + dy / sy;
                    ui.drag_dirty = true;
                end
            end
        end

        -- Target HP% box..
        local ft = tparty.font_target;
        if (ft ~= nil and ui.last_target ~= nil) then
            local th = ft.font_height;
            local tw = th * 2.4;
            local tx, ty = font_to_screen(ui.last_target.x, ui.last_target.y, sw, sh);
            local x1 = s.target.font.right_justified and (tx - tw - pad) or (tx - pad);
            local x2 = s.target.font.right_justified and (tx + pad) or (tx + tw + pad);
            local dx, dy = draw_test_box('target', 'TARGET (TGT)', x1, ty - pad, x2, ty + th * 1.7 + pad, { 0.700, 0.700, 1.000, 1.0 }, shift);
            if (dx ~= 0 or dy ~= 0) then
                L.target.x = L.target.x + dx / sx;
                L.target.y = L.target.y + dy / sy;
                ui.drag_dirty = true;
            end
        end
    elseif (ui.box_drag ~= nil) then
        ui.box_drag = nil;
    end
end

-- Copies src's values over dst, only where dst has that setting
local function copy_over(dst, src)
    for k, v in pairs(src) do
        if (type(v) == 'table') and (type(dst[k]) == 'table') then
            copy_over(dst[k], v);
        elseif (dst[k] ~= nil) and (type(v) == type(dst[k])) then
            dst[k] = v;
        end
    end
end

--[[
* Brings this character's settings over from the old tparty addon, once. Party 1's offset becomes
* relative to the buff list, so the numbers stay where they were on screen.
--]]
function tpd.Import()
    if settings.tp_imported or (not settingLib.logged_in) then
        return;
    end
    settings.tp_imported = true;

    local path = ('%s\\config\\addons\\tparty\\%s_%d\\settings.lua'):format(
        (AshitaCore:GetInstallPath():gsub('[\\/]+$', '')), settingLib.name, settingLib.server_id);
    local fn = loadfile(path);
    if (fn ~= nil) then
        setfenv(fn, { T = T, require = function () end });   -- (data only)
        local ok, old = pcall(fn);
        if ok and (type(old) == 'table') then
            copy_over(settings.tp, old);
            local main = settings.tp.layout.main;
            main.x = main.x - (settings.list_offset_x or 0);
            main.y = main.y - (settings.list_offset_y or 0);
            print(chat.header('PartyBuffs'):append(chat.message('Brought your tparty settings over.')));
        end
    end
    settingLib.save();
end

--[[
* Sets every TP and target setting back to default.
--]]
function tpd.Reset()
    settings.tp = tpd.defaults:copy(true);
    tpd.ApplyFonts();
    settingLib.save();
end

local function print_help(isError)
    if (isError) then
        print(chat.header('PartyBuffs'):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/tparty')));
    else
        print(chat.header('PartyBuffs'):append(chat.message('Available commands:')));
    end

    local cmds = T{
        { '/tparty', 'Opens the TP pages of the menu.' },
        { '/tparty help', 'Displays this list.' },
        { '/tparty (p1 | p2 | p3 | target)', 'Toggles that party / the target display.' },
        { '/tparty test', 'Toggles the position test (labels + draggable boxes).' },
        { '/tparty (reload | rl)', 'Reloads the PartyBuffs settings from disk.' },
        { '/tparty reset', 'Resets the TP and target settings to default.' },
    };
    cmds:ieach(function (v)
        print(chat.header('PartyBuffs'):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

--[[
* Handles the old /tparty commands.
*
* @param {table} args - The words after /tparty.
* @param {function} open_menu - Opens the menu on the TP pages.
--]]
function tpd.Command(args, open_menu)
    local cmd = args[1] and args[1]:lower() or nil;
    if (cmd == nil) or (#args == 1 and cmd:any('config', 'menu', 'cfg')) then
        open_menu();
        return;
    end
    if (#args == 1 and cmd == 'help') then
        print_help(false);
        return;
    end

    -- /tparty toggle <p1|p2|p3|target> (or /tparty <p1|p2|p3|target>)
    local which = (#args == 2 and cmd == 'toggle') and args[2]:lower() or ((#args == 1) and cmd or nil);
    if (which ~= nil) then
        local s, L = settings.tp, settings.tp.layout;
        local map = {
            p1 = { 'Party 1', L.main },       party1 = { 'Party 1', L.main },
            p2 = { 'Party 2', L.alliance1 },  party2 = { 'Party 2', L.alliance1 },
            p3 = { 'Party 3', L.alliance2 },  party3 = { 'Party 3', L.alliance2 },
            target = { 'Target', s.target },  tgt = { 'Target', s.target },
        };
        local m = map[which];
        if (m ~= nil) then
            m[2].enabled = not (m[2].enabled ~= false);
            settingLib.save();
            print(chat.header('PartyBuffs'):append(chat.message(m[1] .. ' display ' .. (m[2].enabled and 'ON' or 'OFF') .. '.')));
            return;
        end
    end

    if (#args == 1 and cmd == 'test') then
        tpd.test = not tpd.test;
        print(chat.header('PartyBuffs'):append(chat.message('Position test ' .. (tpd.test and 'ON' or 'OFF') .. '.')));
        return;
    end
    if (#args == 1 and cmd:any('reload', 'rl')) then
        settingLib.reload();
        print(chat.header('PartyBuffs'):append(chat.message('Settings reloaded from disk.')));
        return;
    end
    if (#args == 1 and cmd == 'reset') then
        tpd.Reset();
        print(chat.header('PartyBuffs'):append(chat.message('TP and target settings reset to defaults.')));
        return;
    end

    print_help(true);
end

return tpd;
