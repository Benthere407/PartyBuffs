--[[
* The TP and target pages of the menu, from the tparty addon's menu.
*
* Usage (from conf_ui.lua):
*   local pages = require('conf_tp')(mark_dirty);
*   pages.display(), pages.layout(), pages.style(), pages.help()
--]]

require('common');
local imgui = require('imgui');
local bit   = require('bit');
local vc    = require('vcmenu');
local tpd   = require('tpdisplay');

local C = vc.colors;

local mark_dirty;
local confirm_reset = false;

local SLIDER_W = 220;

local function tip(text)
    if text and imgui.IsItemHovered() then
        imgui.SetTooltip(text);
    end
end

-- Switches tbl[key]. Returns true when clicked
local function switch(id, label, tbl, key, help)
    local nv = vc.switch_row(id, label, tbl[key] == true);
    tip(help);
    if (nv == nil) then return false; end
    tbl[key] = nv;
    mark_dirty();
    return true;
end

-- Slides tbl[key], with - and + buttons to nudge it by 1. Returns true when changed
local function slider(id, label, tbl, key, lo, hi, fmt, help)
    vc.label_row(label, SLIDER_W + 64 + 60);
    local v, nv = tbl[key], nil;
    if imgui.Button('-##nm_' .. id, { vc.z(24), 0 }) then nv = v - 1; end
    tip('1 less');
    imgui.SameLine(0, vc.z(4));
    if imgui.Button('+##np_' .. id, { vc.z(24), 0 }) then nv = v + 1; end
    tip('1 more');
    imgui.SameLine(0, vc.z(8));
    local s = vc.slider(id, v, lo, hi, 1, fmt, SLIDER_W);
    tip(help);
    if (s ~= nil) then nv = math.floor(s + 0.5); end
    if (nv == nil) then return false; end
    tbl[key] = math.max(lo, math.min(hi, nv));
    mark_dirty();
    return true;
end

-- 0xAARRGGBB <-> { r, g, b, a } floats
local function argb_to_v4(c)
    c = c or 0xFFFFFFFF;
    return {
        bit.band(bit.rshift(c, 16), 0xFF) / 255,
        bit.band(bit.rshift(c, 8), 0xFF) / 255,
        bit.band(c, 0xFF) / 255,
        bit.band(bit.rshift(c, 24), 0xFF) / 255,
    };
end

local function v4_to_argb(v)
    local function ch(x) return math.max(0, math.min(255, math.floor((x * 255) + 0.5))); end
    local n = bit.bor(bit.lshift(ch(v[4]), 24), bit.lshift(ch(v[1]), 16), bit.lshift(ch(v[2]), 8), ch(v[3]));
    if (n < 0) then n = n + 4294967296; end
    return n;
end

local COLOR_FLAGS = bit.bor(ImGuiColorEditFlags_NoInputs or 0, ImGuiColorEditFlags_AlphaBar or 0,
                            ImGuiColorEditFlags_AlphaPreviewHalf or 0);

-- A color picker for tbl[key] (0xAARRGGBB). Returns true when changed
local function color_row(id, label, tbl, key, help)
    vc.label_row(label, 24);
    local c = argb_to_v4(tbl[key]);
    local changed = imgui.ColorEdit4('##col_' .. id, c, COLOR_FLAGS);
    tip(help);
    if (not changed) then return false; end
    tbl[key] = v4_to_argb(c);
    mark_dirty();
    return true;
end

-- Text width at 100% (vcmenu scales the widths it is given)
local function text_w(s) return (vc.xy(imgui.CalcTextSize(s))) / vc.scale(); end

local function seg_row(id, label, opts, cur, help)
    local w = 2;
    for _, o in ipairs(opts) do w = w + text_w(o[2]) + 12; end
    vc.label_row(label, w);
    local pick = vc.seg(id, opts, cur);
    tip(help);
    return pick;
end

----------------------------------------------------------------------------------------------------
-- Help
----------------------------------------------------------------------------------------------------
local function page_help()
    vc.title('TP Help', 'moving things and commands');

    vc.section('MOVING THINGS');
    vc.note('Party 1 moves with the buffs. Shift+drag the buffs to move both together. '..
        'Shift+drag a Party 1 number to nudge the numbers against the buffs.');
    vc.note('Hold Shift and drag any other TP number to move that whole party, or the target HP% to move it. '..
        'A placeholder shows while Shift is held with no target. Changes save when you let go of Shift.');
    vc.note('The position test outlines each party. Shift+drag a box to move it. '..
        'Alliance lists and the target use fixed positions.');

    vc.section('COMMANDS');
    vc.stat('/tparty', 'Open these pages', nil, 190);
    vc.stat('/tparty help', 'List the commands', nil, 190);
    vc.stat('/tparty test', 'Toggle the position test', nil, 190);
    vc.stat('/tparty p1|p2|p3|target', 'Toggle that display', nil, 190);
    vc.stat('/tparty reload', 'Reload settings from disk', nil, 190);
    vc.stat('/tparty reset', 'Reset TP and target to default', nil, 190);

    vc.section('RESET');
    if (confirm_reset) then
        imgui.TextColored(C.bad, 'Reset the TP and target settings for this character?');
        imgui.SameLine();
        if vc.button('Yes, reset##tp_reset_yes', 'danger', 100) then
            confirm_reset = false;
            tpd.Reset();
        end
        imgui.SameLine();
        if vc.button('Cancel##tp_reset_no', nil, 80) then confirm_reset = false; end
    elseif vc.button('Reset TP##tp_reset', 'danger', 100) then
        confirm_reset = true;
    end

    vc.section('CREDITS');
    vc.note('From the tparty addon by atom0s (GPL-3.0).');
end

----------------------------------------------------------------------------------------------------
-- Display
----------------------------------------------------------------------------------------------------
local function page_display()
    local s = settings.tp;
    vc.title('TP Display', 'what is shown');

    vc.section('PARTY TP');
    switch('showparty', 'Show party TP', s.party, 'enabled', 'Turns off all three parties at once.');
    switch('showp1', 'Party 1 (your party)', s.layout.main, 'enabled');
    switch('showp2', 'Party 2 (alliance)', s.layout.alliance1, 'enabled');
    switch('showp3', 'Party 3 (alliance)', s.layout.alliance2, 'enabled');

    vc.section('TARGET');
    switch('showtarget', 'Show target HP%', s.target, 'enabled');

    vc.section('DRAWING');
    switch('infront', 'Draw in front of Party Frames', s.party, 'in_front',
        'Draws the numbers over the party and alliance frames, and every other window.');
    vc.note('Needs VanaCore. Off: the numbers are behind the party frames, and use Ashita\'s own text.');

    vc.section('MOVING');
    switch('shiftdrag', 'Shift+drag parties and target', s.party, 'shift_drag', 'Hold Shift and drag the numbers to move them.');
end

----------------------------------------------------------------------------------------------------
-- Position & Size
----------------------------------------------------------------------------------------------------
local GROUPS = {
    { 'PARTY 1 (MOVES WITH THE BUFFS)', 'main' },
    { 'ALLIANCE PARTY 2 (SLOTS 7-12)', 'alliance1' },
    { 'ALLIANCE PARTY 3 (SLOTS 13-18)', 'alliance2' },
    { 'TARGET HP%', 'target' },
};

local function page_layout()
    vc.title('TP Position & Size', 'where each list sits and how big it is');
    vc.note('Positive X moves right, positive Y moves down. Use - and + to nudge by one pixel.');
    vc.note('Party 1 adds its offset to the position of the buffs, so it moves with them.');

    vc.section('POSITION TEST');
    switch('tptest', 'Position test', tpd, 'test', 'A label on every slot, with a box around each party. Shift+drag a box to move it.');

    for _, grp in ipairs(GROUPS) do
        local key = grp[2];
        local g, d = settings.tp.layout[key], tpd.defaults.layout[key];
        vc.section(grp[1], nil, function ()
            g.x, g.y, g.size = 0, 0, d.size;
            if (d.spacing ~= nil) then g.spacing = d.spacing; end
            tpd.ApplyLayout();
            mark_dirty();
        end);
        slider(key .. 'x', 'X offset', g, 'x', -800, 800, '%d px');
        slider(key .. 'y', 'Y offset', g, 'y', -800, 800, '%d px');
        if slider(key .. 'z', 'Text size', g, 'size', 6, 40, '%d pt') then tpd.ApplyLayout(); end
        if (d.spacing ~= nil) then
            slider(key .. 's', 'Row spacing', g, 'spacing', 8, 60, '%d px', 'Pixels from one member\'s row to the next.');
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Text Style
----------------------------------------------------------------------------------------------------
local FX_OPTS   = { { 'none', 'None' }, { 'blink', 'Blink' }, { 'sparkle', 'Sparkle' }, { 'both', 'Both' } };
local FX_MODES  = { { 'timed', 'For a few seconds' }, { 'always', 'Continually' } };

local function style_block(id, block)
    if switch(id .. 'bold', 'Bold', block.font, 'bold') then tpd.ApplyFonts(); end
    if switch(id .. 'ital', 'Italic', block.font, 'italic') then tpd.ApplyFonts(); end
    slider(id .. 'bsize', 'Border thickness', block, 'border_size', 0, 4, '%d px', '0 turns the border off.');
    color_row(id .. 'bcol', 'Border color', block, 'border_color', 'Keep its alpha above 0.');
end

local function page_style()
    local s = settings.tp;
    vc.title('TP Text Style', 'colors, bold, italic, border and TP effects');

    vc.section('PARTY TP');
    style_block('p', s.party);

    vc.section('TP COLORS', nil, function ()
        s.party.font.color = tpd.defaults.party.font.color;
        s.party.tp_ready_color = tpd.defaults.party.tp_ready_color;
        s.party.tp_max_color = tpd.defaults.party.tp_max_color;
        mark_dirty();
    end);
    color_row('tplow', 'Below 1000', s.party.font, 'color', 'TP 0 to 999');
    color_row('tpmid', '1000 to 2000', s.party, 'tp_ready_color', 'TP 1000 to 2000');
    color_row('tphigh', '2001 and up', s.party, 'tp_max_color', 'TP 2001 to 3000');

    vc.section('WHEN TP REACHES 1000');
    local pick = seg_row('tpfx', 'Effect', FX_OPTS, s.party.tp_fx);
    if (pick ~= nil) then s.party.tp_fx = pick; mark_dirty(); end
    if (s.party.tp_fx ~= 'none') then
        pick = seg_row('tpfxmode', 'How long', FX_MODES, s.party.tp_fx_mode);
        if (pick ~= nil) then s.party.tp_fx_mode = pick; mark_dirty(); end
        if (s.party.tp_fx_mode == 'timed') then
            slider('tpfxsecs', 'Seconds', s.party, 'tp_fx_secs', 1, 10, '%d s');
        end
        if (s.party.tp_fx ~= 'blink') then
            color_row('tpfxcol', 'Sparkle color', s.party, 'tp_fx_color');
            slider('tpfxsize', 'Sparkle size', s.party, 'tp_fx_size', 25, 400, '%d%%');
        end
        if vc.button('Try it##tpfxtry', 'primary', 80) then
            tpd.fx_try_until = os.clock() + ((s.party.tp_fx_mode == 'timed') and s.party.tp_fx_secs or 3);
        end
        tip('Plays the effect on every number showing now.');
    end

    vc.section('TARGET HP%');
    style_block('t', s.target);
    color_row('tcol', 'Color', s.target.font, 'color');
end

return function (dirty)
    mark_dirty = dirty;
    return { display = page_display, layout = page_layout, style = page_style, help = page_help };
end
