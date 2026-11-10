--[[
* PartyBuffs config UI
* A Vanacore-style menu from the vcmenu library (vcmenu.lua in this folder; master copy in
* Documents/vcmenu). Pages in a sidebar: About, the display pages (Icons, Position, Range Text,
* Timer Rings, Timer Text), the buff pages (Active, Filters, Priority, Profiles), and Test Mode.
*
* Usage (from partybuffs.lua):
*   confUI.is_open[1] = true
*   confUI.render_config_ui(settings, hooks)
*
* hooks = {
*     save               = function() end,        -- persist settings
*     rebuild            = function() end,        -- rebuild exclusion/priority lookups
*     apply_font         = function() end,        -- re-apply distance font settings
*     default_exclusions = T{ ... },              -- the "Default" exclusion list
*     get_active_buffs   = function() end,        -- { { index, name, buffs = { ids } }, ... }
*     get_icon_themes    = function() end,        -- { 'HD', 'HD2', ... } folder names under themes\
*     get_rings          = function() end,        -- timer rings drawn this frame { { fraction, remaining, ... }, ... }
*     current_job        = function() end,        -- main job abbreviation or nil
*     save_profile       = function(name) end,
*     load_profile       = function(name) end,
*     delete_profile     = function(name) end,
* }
--]]

require('common');
local imgui  = require('imgui');
local vc     = require('vcmenu');
local groups = require('buffgroups');
local savedThemes = require('savedthemes');
local tpd    = require('tpdisplay');

local C = vc.colors;

local win = vc.new_state('icons');

local ui = T{
    is_open   = win.open,  -- /pb and /partybuffs toggle this
    test_mode = { false, },   -- preview a full party with sample buffs (not saved; only while the window is open)
    dirty   = false,   -- settings changed, waiting for mouse release to save
    version = 0,       -- bumped whenever a filter/priority list changes (invalidates list cache)
};

local gSettings, gHooks;   -- set every frame by render_config_ui

-- Call after filters are changed from outside the UI (e.g. auto profile switching).
ui.invalidate = function()
    ui.version = ui.version + 1;
end

-- Opens the menu on the TP pages (/tparty)
ui.open_tp = function()
    win.open[1] = not win.open[1];
    win.page = 'tp_display';
end

local function mark_dirty()
    ui.dirty = true;
end

local tpPages = require('conf_tp')(mark_dirty);

----------------------------------------------------------------------------------------------------
-- Rows: a label on the left, its control lined up at the right
----------------------------------------------------------------------------------------------------
local SLIDER_W = 220;

local function tip(text)
    if text and imgui.IsItemHovered() then
        imgui.SetTooltip(text);
    end
end

-- Text width at 100% (vcmenu scales the widths it is given)
local function text_w(s) return (vc.xy(imgui.CalcTextSize(s))) / vc.scale(); end

-- Returns the new value when clicked, else nil
local function switch(id, label, v, help)
    local nv = vc.switch_row(id, label, v == true);
    tip(help);
    return nv;
end

-- Returns the new value while dragged, else nil
local function slider(id, label, v, lo, hi, step, fmt, help)
    vc.label_row(label, SLIDER_W + 64);
    local nv = vc.slider(id, v, lo, hi, step, fmt, SLIDER_W);
    tip(help);
    if (nv ~= nil) and step and (step >= 1) then nv = math.floor(nv + 0.5); end
    return nv;
end

-- A slider over a wide range, with - and + buttons to nudge it by 1. Returns the new value, else nil
local function offset_row(id, label, v, lo, hi, help)
    vc.label_row(label, SLIDER_W + 64 + 60);
    local nv = nil;
    if imgui.Button('-##nm_' .. id, { vc.z(24), 0 }) then nv = v - 1; end
    tip('1 pixel less');
    imgui.SameLine(0, vc.z(4));
    if imgui.Button('+##np_' .. id, { vc.z(24), 0 }) then nv = v + 1; end
    tip('1 pixel more');
    imgui.SameLine(0, vc.z(8));
    local s = vc.slider(id, v, lo, hi, 1, '%d px', SLIDER_W);
    tip(help);
    if (s ~= nil) then nv = math.floor(s + 0.5); end
    if (nv ~= nil) then nv = math.max(lo, math.min(hi, nv)); end
    return nv;
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

-- An ARGB colour. Returns the new colour when changed, else nil
local function color_row(id, label, u, help)
    vc.label_row(label, 24);
    local c = argb_to_v4(u);
    local changed = imgui.ColorEdit4('##col_' .. id, c, COLOR_FLAGS);
    tip(help);
    if changed then return v4_to_argb(c); end
    return nil;
end

local function seg_w(opts)
    local w = 0;
    for _, o in ipairs(opts) do w = w + text_w(o[2]) + 12; end
    return w + 2;
end

local function seg_row(id, label, opts, cur, help)
    vc.label_row(label, seg_w(opts));
    local pick = vc.seg(id, opts, cur);
    tip(help);
    return pick;
end

----------------------------------------------------------------------------------------------------
-- Buff catalog (id + name for every buff the game knows about). Built once.
----------------------------------------------------------------------------------------------------
local gCatalog = nil;
local gNames   = {};
local function get_catalog()
    if (gCatalog == nil) then
        gCatalog = {};
        local resMgr = AshitaCore:GetResourceManager();
        for i = 1, 1024 do
            local name = resMgr:GetString('buffs.names', i);
            if (name ~= nil) and (name ~= '') then
                table.insert(gCatalog, { id = i, name = name });
                gNames[i] = name;
            end
        end
        table.sort(gCatalog, function(a, b)
            local an, bn = a.name:lower(), b.name:lower();
            if (an == bn) then return a.id < b.id; end
            return an < bn;
        end);
        for _, entry in ipairs(gCatalog) do
            entry.ja  = groups.is_job_ability(entry.name);
            entry.mon = groups.is_monster_debuff(entry.name);
        end
    end
    return gCatalog;
end

local function buff_name(id)
    get_catalog();
    return gNames[id] or ('Unknown ' .. tostring(id));
end

local function list_index(list, id)
    for i, v in ipairs(list) do
        if (v == id) then return i; end
    end
    return nil;
end

local function list_set(list, id, present)
    local idx = list_index(list, id);
    if (present and idx == nil) then
        table.insert(list, id);
    elseif ((not present) and idx ~= nil) then
        table.remove(list, idx);
    end
end

local function clear_list(list)
    for i = #list, 1, -1 do table.remove(list, i); end
end

-- Shown = not in exclusions
local function buff_visible(id)
    return list_index(gSettings.exclusions, id) == nil;
end

local function buff_priority(id)
    return list_index(gSettings.priority, id) ~= nil;
end

local function lists_changed()
    ui.version = ui.version + 1;
    gHooks.rebuild();
    mark_dirty();
end

local function set_buff_visible(id, on)
    list_set(gSettings.exclusions, id, not on);
    lists_changed();
end

local function set_buff_priority(id, on)
    list_set(gSettings.priority, id, on);
    lists_changed();
end

----------------------------------------------------------------------------------------------------
-- About
----------------------------------------------------------------------------------------------------
local function page_about()
    vc.title('PartyBuffs', 'version ' .. tostring(addon.version));
    vc.section('PARTYBUFFS');
    vc.note('Shows your party\'s buffs next to the game\'s party list, with optional timer rings and timer text.');
    vc.section('COMMANDS');
    vc.stat('/partybuffs', 'Open or close this window (or /pb)', nil, 190);
    vc.stat('/pb profile <name>', 'Load a saved filter profile', nil, 190);
    vc.stat('/pb distance', 'Turn the range text on or off', nil, 190);
    vc.stat('/pb self', 'Show or hide your own buffs', nil, 190);
    vc.stat('/pb exclusion add <buff>', 'Hide a buff', nil, 190);
    vc.stat('/pb priority add <buff>', 'Draw a buff first', nil, 190);
    vc.stat('Shift + drag', 'Move the buffs on screen', nil, 190);
    vc.section('TEST MODE');
    vc.note('Test Mode (top of the menu) shows a full party with sample buffs while this window is open, so you can see the layout, rings and timer text.');
    vc.section('CREDITS');
    vc.note(('By %s. %s'):format(addon.author, addon.link));
    vc.note('Font: TeX Gyre Adventor, as used by YunaUI (GUST Font License, see fonts/).');
    vc.note('TP and target numbers from the tparty addon by atom0s.');
    vc.note('Icon themes from HXUI. The window uses the vcmenu library, inspired by the VanaCore menus by Vekien and Josh.Xero.');
end

----------------------------------------------------------------------------------------------------
-- Icons
----------------------------------------------------------------------------------------------------
local DEFAULT_THEME_LABEL = 'Default (game icons)';
local gThemes = nil;   -- theme folder names, scanned on first use / Refresh

local function theme_row(s)
    if (gThemes == nil) then
        gThemes = gHooks.get_icon_themes();
    end
    local current = s.icon_theme or '';
    local shown = (current == '') and DEFAULT_THEME_LABEL or current;

    vc.label_row('Icon theme', 220 + 88);
    imgui.PushItemWidth(vc.z(220));
    if imgui.BeginCombo('##pb_icon_theme', shown) then
        if imgui.Selectable(DEFAULT_THEME_LABEL, current == '') then
            s.icon_theme = ''; mark_dirty();
        end
        for _, name in ipairs(gThemes) do
            if imgui.Selectable(name, current == name) then
                s.icon_theme = name; mark_dirty();
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    tip('Icon set used for buffs. Themes are folders of <buff id>.png files under partybuffs\\themes\\. Buffs missing from a theme use the game icon.');
    imgui.SameLine(0, vc.z(8));
    if vc.button('Refresh##pb_theme_refresh', nil, 80) then
        gThemes = nil;
    end
    tip('Rescan the themes folder (after adding or removing a theme).');
end

local ZIGZAG_TEXT = { { 'below', 'Both below' }, { 'zig', 'Zig above' }, { 'zag', 'Zag above' } };
local ZIGZAG_FIRST = { { 'top', 'Top' }, { 'bottom', 'Bottom' } };
local LIST_GROW = { { 'up', 'Grow up' }, { 'down', 'Grow down' } };

local function page_icons()
    local s, n = gSettings, nil;
    vc.title('Icons', 'size, spacing and theme');

    vc.section('SHOW');
    n = seg_row('list_grow', 'Direction', LIST_GROW, s.list_grow or 'up',
        'Grow up: the last member stays put and the list adds upward, like the game\'s party list. Grow down: you stay put and members add below you. Party 1 TP numbers follow.');
    if (n ~= nil) then s.list_grow = n; mark_dirty(); end
    n = switch('test_mode', 'Test Mode', ui.test_mode[1],
        'While this window is open, show a full 6 member party with sample buffs so you can see the layout. Shift+drag it to move it.');
    if (n ~= nil) then ui.test_mode[1] = n; end
    n = slider('test_buff_count', 'Test Mode buffs', s.test_buff_count or 6, 1, 18, 1, '%d',
        'How many sample buffs each member shows in Test Mode.');
    if (n ~= nil) then s.test_buff_count = n; mark_dirty(); end
    n = slider('test_debuff_count', 'Test Mode debuffs', s.test_debuff_count or 0, 0, 4, 1, '%d',
        'How many sample debuffs each member shows in Test Mode, on top of the buffs. They start at the far end of the row; turn on Debuffs first to see them move to the front.');
    if (n ~= nil) then s.test_debuff_count = n; mark_dirty(); end
    n = switch('show_self', 'Show your own buffs', s.show_self, 'Show a row of buffs for yourself too.');
    if (n ~= nil) then s.show_self = n; mark_dirty(); end
    n = switch('debuffs_first', 'Debuffs first', s.debuffs_first == true,
        'Enfeebles and debuffs on a player go first in line, next to the party list. Debuffs hidden on the Filters page stay hidden.');
    if (n ~= nil) then s.debuffs_first = n; mark_dirty(); end
    n = switch('unique_buffs', 'Merge same-name buffs', s.unique_buffs == true,
        'Off: every buff gets its own icon and timer, so two Minuets show twice and Geo Haste shows beside Haste. On: buffs with the same name share one icon.');
    if (n ~= nil) then s.unique_buffs = n; mark_dirty(); end
    n = switch('lead_buffs', 'Haste, Phalanx, Refresh first', s.lead_buffs ~= false,
        'Group Haste, Phalanx and Refresh in that order next to the party list, behind any debuffs when Debuffs first is on. With zigzag icons, Phalanx always sits on the top row.');
    if (n ~= nil) then s.lead_buffs = n; mark_dirty(); end

    vc.section('ICONS', nil, function()
        s.size, s.icon_spacing, s.row_spacing = 16, 0, 20; mark_dirty();
    end);
    n = slider('size', 'Icon size', s.size or 16, 8, 64, 1, '%d px', 'Size of each buff icon.');
    if (n ~= nil) then s.size = n; mark_dirty(); end
    n = slider('icon_spacing', 'Icon spacing', s.icon_spacing or 0, -math.floor((s.size or 16) / 2), 40, 1, '%d px',
        'Extra space between icons, side to side. Handy for room around timer rings or wide timer text.\nBelow 0 the icons overlap (up to half an icon).');
    if (n ~= nil) then s.icon_spacing = n; mark_dirty(); end
    n = slider('row_spacing', 'Row spacing', s.row_spacing or 20, 8, 60, 1, '%d px', 'Distance between party members, top to bottom.');
    if (n ~= nil) then s.row_spacing = n; mark_dirty(); end

    vc.section('ZIGZAG', nil, function()
        s.icon_zigzag, s.icon_zigzag_offset, s.icon_zigzag_text, s.icon_zigzag_first = false, 8, 'below', 'top'; mark_dirty();
    end);
    n = switch('icon_zigzag', 'Zigzag icons', s.icon_zigzag == true,
        'Stagger every other icon up or down. Goes well with icon spacing below 0, so overlapping icons stay easy to tell apart.');
    if (n ~= nil) then s.icon_zigzag = n; mark_dirty(); end
    if s.icon_zigzag then
        local range = math.max(48, (s.size or 16) * 3);
        n = slider('icon_zigzag_offset', 'Zigzag height', s.icon_zigzag_offset or 8, -range, range, 1, '%d px',
            'How far every other icon moves: above 0 down, below 0 up. You may need more Row spacing to make room.');
        if (n ~= nil) then s.icon_zigzag_offset = n; mark_dirty(); end
        n = seg_row('icon_zigzag_first', 'First icon', ZIGZAG_FIRST, s.icon_zigzag_first or 'top',
            'Whether the first icon of each row, the one next to the party list, sits on the top or the bottom of the zigzag.');
        if (n ~= nil) then s.icon_zigzag_first = n; mark_dirty(); end
        n = seg_row('icon_zigzag_text', 'Timer text', ZIGZAG_TEXT, s.icon_zigzag_text or 'below',
            'Where the timer text goes. Zig = the icons left in line, Zag = the icons that move. '..
            'Putting one of them above the icon keeps the labels apart.');
        if (n ~= nil) then s.icon_zigzag_text = n; mark_dirty(); end
    end

    vc.section('THEME');
    theme_row(s);
end

----------------------------------------------------------------------------------------------------
-- Saved themes (savedthemes.lua): the whole look saved as a file, loaded from a list
----------------------------------------------------------------------------------------------------
local gSaved = { names = nil, pick = nil, name = { '' }, confirm = nil, msg = '', ok = true };

local function saved_say(ok, msg) gSaved.ok, gSaved.msg = ok, msg; end

local function has_name(list, name)
    for _, v in ipairs(list) do
        if (v == name) then return true; end
    end
    return false;
end

local function saved_refresh()
    gSaved.names = savedThemes.list();
end

local function saved_write(name)
    local ok, res = savedThemes.save(name, gSettings);
    if ok then
        gSettings.saved_theme = res;
        gSaved.pick, gSaved.name[1], gSaved.confirm = res, '', nil;
        mark_dirty();
        saved_refresh();
        saved_say(true, ('Saved "%s".'):format(res));
    else
        saved_say(false, res);
    end
end

local function page_saved()
    local s = gSettings;
    if (gSaved.names == nil) then saved_refresh(); end
    local names = gSaved.names;
    if (gSaved.pick == nil) or (not has_name(names, gSaved.pick)) then
        gSaved.pick = has_name(names, s.saved_theme or '') and s.saved_theme or names[1];
    end

    vc.title('Saved Themes', 'save and load the whole look');
    vc.note('A saved theme holds the look: icon size, spacing and icon theme, timer rings, timer text, range text and the TP and target numbers. '..
        'Not where the buffs sit on screen, or your filters (those are Profiles). Themes are files in this addon\'s savedthemes folder, so every character can use them.');

    vc.section('OPEN', ('%d saved'):format(#names));
    vc.stat('Last loaded or saved', ((s.saved_theme or '') ~= '') and s.saved_theme or 'none',
        ((s.saved_theme or '') ~= '') and C.gold or C.mute);

    vc.label_row('Theme', 220 + 8 + 80 + 8 + 80);
    imgui.PushItemWidth(vc.z(220));
    if imgui.BeginCombo('##pb_saved_pick', gSaved.pick or 'No saved themes') then
        for _, name in ipairs(names) do
            if imgui.Selectable(name .. '##pb_saved_' .. name, name == gSaved.pick) then
                gSaved.pick, gSaved.confirm = name, nil;
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    tip('Pick a saved theme, then Load.');
    imgui.SameLine(0, vc.z(8));
    if vc.button('Load##pb_saved_load', 'primary', 80) and (gSaved.pick ~= nil) then
        local ok, err = savedThemes.load(gSaved.pick, s);
        if ok then
            s.saved_theme = gSaved.pick;
            gHooks.apply_font();
            gHooks.apply_tp();
            mark_dirty();
            saved_say(true, ('Loaded "%s".'):format(gSaved.pick));
        else
            saved_say(false, err);
        end
    end
    tip('Replace the current look with this theme.');
    imgui.SameLine(0, vc.z(8));
    if vc.button('Refresh##pb_saved_refresh', nil, 80) then
        saved_refresh();
    end
    tip('Read the savedthemes folder again (after copying a theme file in).');

    if (gSaved.pick ~= nil) then
        if (gSaved.confirm == 'delete') then
            imgui.TextColored(C.bad, ('Delete "%s"?'):format(gSaved.pick));
            imgui.SameLine();
            if vc.button('Yes, delete##pb_saved_del_yes', 'danger', 100) then
                local ok, err = savedThemes.delete(gSaved.pick);
                if ok then
                    saved_say(true, ('Deleted "%s".'):format(gSaved.pick));
                    if (s.saved_theme == gSaved.pick) then s.saved_theme = ''; mark_dirty(); end
                    gSaved.pick = nil;
                    saved_refresh();
                else
                    saved_say(false, err);
                end
                gSaved.confirm = nil;
            end
            imgui.SameLine();
            if vc.button('Cancel##pb_saved_del_no', nil, 80) then gSaved.confirm = nil; end
        else
            if vc.button(('Save over "%s"##pb_saved_over'):format(gSaved.pick), nil, nil) then
                saved_write(gSaved.pick);
            end
            tip('Save the current look into this theme.');
            imgui.SameLine();
            if vc.button('Delete##pb_saved_del', 'danger', 80) then gSaved.confirm = 'delete'; end
            tip('Delete this theme\'s file.');
        end
    end

    vc.section('SAVE AS');
    vc.label_row('New name', 220 + 8 + 80);
    imgui.PushItemWidth(vc.z(220));
    imgui.InputText('##pb_saved_name', gSaved.name, 48);
    imgui.PopItemWidth();
    tip('Letters, numbers, spaces and - _ . ( ) only.');
    imgui.SameLine(0, vc.z(8));
    local want = savedThemes.clean_name(gSaved.name[1]);
    if vc.button('Save##pb_saved_save', 'primary', 80) then
        if (want == '') then
            saved_say(false, 'Give the theme a name.');
        elseif savedThemes.exists(want) then
            gSaved.confirm = 'replace:' .. want;
        else
            saved_write(want);
        end
    end
    tip('Save the current look as a new theme file.');
    if (gSaved.confirm ~= nil) and (gSaved.confirm:sub(1, 8) == 'replace:') then
        local target = gSaved.confirm:sub(9);
        imgui.TextColored(C.gold, ('"%s" already exists. Replace it?'):format(target));
        imgui.SameLine();
        if vc.button('Replace##pb_saved_rep_yes', 'danger', 90) then saved_write(target); end
        imgui.SameLine();
        if vc.button('Cancel##pb_saved_rep_no', nil, 80) then gSaved.confirm = nil; end
    end

    vc.section('COPY TO MY OTHER CLIENTS');
    vc.note('Sends this client\'s current look to your other open clients, along with where the buffs sit, one icon per buff, debuffs first and your own row. '..
        'Filters, priority and profiles stay as they are.');
    if (gSaved.confirm == 'copy') then
        imgui.TextColored(C.bad, 'Are you sure? Their current setup can\'t be brought back.');
        imgui.SameLine();
        if vc.button('Yes, copy now##pb_saved_copy_yes', 'danger', 120) then
            gSaved.confirm = nil;
            local ok, err = gHooks.copy_setup();
            if not ok then saved_say(false, err); end
        end
        imgui.SameLine();
        if vc.button('Cancel##pb_saved_copy_stop', nil, 80) then gSaved.confirm = nil; end
    else
        if vc.button('Copy to other clients##pb_saved_copy', 'primary', nil) then gSaved.confirm = 'copy'; end
        tip('Send the current setup to your other open clients. Asks you to confirm first.');
    end
    local copied = gHooks.copy_status();
    if (copied ~= nil) then vc.note(copied); end

    if (gSaved.msg ~= '') then
        imgui.Dummy({ 1, vc.z(4) });
        imgui.TextColored(gSaved.ok and C.good or C.bad, gSaved.msg);
    end
end

----------------------------------------------------------------------------------------------------
-- Position
----------------------------------------------------------------------------------------------------
local function page_position()
    local s, n = gSettings, nil;
    vc.title('Position', 'where the buffs sit');

    vc.section('BUFF LIST', nil, function()
        s.list_offset_x, s.list_offset_y = 0, 0; mark_dirty();
    end);
    vc.note('Hold Shift and drag the buff icons on screen to move them. Turn on Test Mode to drag without a party.');
    n = offset_row('list_x', 'Left / right', s.list_offset_x or 0, -1000, 1000, 'Move the whole buff list sideways (negative = left).');
    if (n ~= nil) then s.list_offset_x = n; mark_dirty(); end
    n = offset_row('list_y', 'Up / down', s.list_offset_y or 0, -1000, 1000, 'Move the whole buff list up or down (negative = up).');
    if (n ~= nil) then s.list_offset_y = n; mark_dirty(); end
end

----------------------------------------------------------------------------------------------------
-- Draw in front
----------------------------------------------------------------------------------------------------
local function page_front()
    local s, n = gSettings, nil;
    vc.title('Draw In Front', 'over the party frames');

    vc.section('DRAW IN FRONT OF PARTY FRAMES');
    n = switch('front_icons', 'Icons', s.front_icons == true,
        'Draws the buff icons, their rings and their timer text over the party frames and every other window.');
    if (n ~= nil) then s.front_icons = n; mark_dirty(); end
    n = switch('front_tp', 'TP', s.tp.party.in_front == true, 'Draws the party and alliance TP numbers over the frames.');
    if (n ~= nil) then s.tp.party.in_front = n; mark_dirty(); end
    n = switch('front_distance', 'Distance', s.front_distance == true, 'Draws the range text over the frames.');
    if (n ~= nil) then s.front_distance = n; mark_dirty(); end
    n = switch('front_hp', 'HP', s.tp.target.in_front == true, 'Draws the target HP% over the frames.');
    if (n ~= nil) then s.tp.target.in_front = n; mark_dirty(); end
    vc.note('TP, Distance and HP need VanaCore. Off: they\'re behind the party frames and use Ashita\'s own text. In front, Distance uses Comic Sans or Arial.');
end

----------------------------------------------------------------------------------------------------
-- Range text
----------------------------------------------------------------------------------------------------
local DECIMALS = { { 0, '0' }, { 1, '0.0' }, { 2, '0.00' } };

local function page_range()
    local s, n = gSettings, nil;
    vc.title('Range Text', 'distance to each member');

    vc.section('RANGE TEXT');
    n = switch('show_distance', 'Show range', s.show_distance, 'Show the distance to each party member.');
    if (n ~= nil) then s.show_distance = n; mark_dirty(); end
    n = switch('show_self_distance', 'Show 0.0 for yourself', s.show_self_distance,
        'Also show a range (0.0) on your own row. Needs "Show your own buffs" on the Icons page.');
    if (n ~= nil) then s.show_self_distance = n; mark_dirty(); end
    n = seg_row('decimals', 'Decimals', DECIMALS, s.distance_decimals or 1, 'Decimal places in the distance.');
    if (n ~= nil) then s.distance_decimals = n; mark_dirty(); end
    n = switch('distance_fixed', 'Fixed position', s.distance_fixed,
        'Off: the text follows the left edge of each member\'s buffs (moves as buffs come and go). '..
        'On: the text stays at a fixed spot from the right edge of the buff row.');
    if (n ~= nil) then s.distance_fixed = n; mark_dirty(); end

    vc.section('OFFSET', nil, function()
        s.distance_offset_x, s.distance_offset_y = 0, 0; mark_dirty();
    end);
    n = offset_row('dist_x', 'Left / right', s.distance_offset_x or 0, -800, 800, 'Move the range text sideways (negative = left).');
    if (n ~= nil) then s.distance_offset_x = n; mark_dirty(); end
    n = offset_row('dist_y', 'Up / down', s.distance_offset_y or 0, -300, 300, 'Move the range text up or down (negative = up).');
    if (n ~= nil) then s.distance_offset_y = n; mark_dirty(); end
end

-- { family, label } for the range text's font list
local FONT_PICKS = {
    { 'TeX Gyre Adventor', 'YunaUI (TeX Gyre Adventor)' },
    { 'Arial',             'Arial' },
    { 'Segoe UI',          'Segoe UI' },
    { 'Century Gothic',    'Century Gothic' },
    { 'Verdana',           'Verdana' },
    { 'Consolas',          'Consolas' },
    { 'Comic Sans MS',     'Comic Sans MS' },
};

local function page_range_font()
    local s, n = gSettings, nil;
    local font = s.distance_object;
    vc.title('Range Text', 'font');

    vc.section('FONT');
    vc.label_row('Font', 200);
    imgui.PushItemWidth(vc.z(200));
    local current = tostring(font.font_family or '');
    local shown = 'Other (type it below)';
    for _, f in ipairs(FONT_PICKS) do
        if (f[1]:lower() == current:lower()) then shown = f[2]; end
    end
    if imgui.BeginCombo('##pb_font_pick', shown) then
        for _, f in ipairs(FONT_PICKS) do
            if imgui.Selectable(f[2], f[1]:lower() == current:lower()) then
                font.font_family = f[1];
                gHooks.apply_font();
                mark_dirty();
            end
        end
        imgui.EndCombo();
    end
    imgui.PopItemWidth();
    tip('YunaUI uses TeX Gyre Adventor, which ships with this addon (in its fonts folder), so it needs no install.');
    vc.label_row('Font family', 200);
    imgui.PushItemWidth(vc.z(200));
    local fam = { tostring(font.font_family or '') };
    if imgui.InputText('##pb_font_family', fam, 255) then
        font.font_family = (tostring(fam[1]):gsub('%z', ''));
        ui.font_pending = true;   -- applied on mouse release, not every keystroke
        mark_dirty();
    end
    imgui.PopItemWidth();
    tip('Name of an installed font (or TeX Gyre Adventor). Applies once you stop typing and move the mouse.');
    n = slider('font_height', 'Font size', font.font_height or 8, 4, 40, 1, '%d', 'Size of the range text.');
    if (n ~= nil) then font.font_height = n; gHooks.apply_font(); mark_dirty(); end
    n = switch('font_bold', 'Bold', font.bold, 'Bold text.');
    if (n ~= nil) then font.bold = n; gHooks.apply_font(); mark_dirty(); end
    n = switch('font_italic', 'Italic', font.italic, 'Italic text.');
    if (n ~= nil) then font.italic = n; gHooks.apply_font(); mark_dirty(); end
    n = color_row('font_color', 'Text colour', font.color, 'Colour of the range text.');
    if (n ~= nil) then font.color = n; gHooks.apply_font(); mark_dirty(); end
    n = color_row('font_outline', 'Outline colour', s.distance_outline_color or 0xFF000000, 'Outline colour of the range text. Keep its alpha above 0.');
    if (n ~= nil) then s.distance_outline_color = n; gHooks.apply_font(); mark_dirty(); end
    n = slider('outline_thickness', 'Outline thickness', s.distance_outline_thickness or 1, 0, 4, 1, '%d px', '0 turns the outline off.');
    if (n ~= nil) then s.distance_outline_thickness = n; mark_dirty(); end
end

----------------------------------------------------------------------------------------------------
-- Timer rings
----------------------------------------------------------------------------------------------------
local TIPS = { { 'sparkle', 'Sparkle' }, { 'dot', 'Dot' }, { 'none', 'None' } };

local function page_rings()
    local s, n = gSettings, nil;
    vc.title('Timer Rings', 'a ring that shrinks as the buff runs out');

    vc.section('RING');
    n = switch('show_rings', 'Show rings', s.show_rings, 'Draw a ring around each buff icon that shrinks as the buff runs out.');
    if (n ~= nil) then s.show_rings = n; mark_dirty(); end
    n = slider('ring_thickness', 'Thickness', s.ring_thickness or 2, 1, 6, 1, '%d px', 'Ring line thickness.');
    if (n ~= nil) then s.ring_thickness = n; mark_dirty(); end
    n = slider('ring_gap', 'Gap', s.ring_gap or 0, -8, 6, 1, '%d px',
        'Ring size against the icon. 0 = touches the icon\'s edges. Above 0 overlaps the next icon\'s ring.');
    if (n ~= nil) then s.ring_gap = n; mark_dirty(); end
    n = color_row('ring_color', 'Time left colour', s.ring_color or 0xFF66CCFF, 'Colour of the part of the ring for the time left.');
    if (n ~= nil) then s.ring_color = n; mark_dirty(); end
    n = color_row('ring_gone_color', 'Time gone colour', s.ring_gone_color or 0x2E66CCFF,
        'Colour of the used up part of the ring. Lower its alpha for a faint track, or 0 to hide it.');
    if (n ~= nil) then s.ring_gone_color = n; mark_dirty(); end
    n = switch('ring_show_unknown', 'Ring when time is unknown', s.ring_show_unknown ~= false,
        'Draw a dim full ring on buffs whose time left can\'t be worked out (see TIME LEFT below).');
    if (n ~= nil) then s.ring_show_unknown = n; mark_dirty(); end

    vc.section('DEBUFFS');
    n = switch('ring_debuff', 'Show debuff rings', s.ring_debuff == true,
        'Give enfeebles and debuffs their own plain ring instead of the timer ring: full, with no moving end or low warning.');
    if (n ~= nil) then s.ring_debuff = n; mark_dirty(); end
    n = slider('ring_debuff_thickness', 'Thickness', s.ring_debuff_thickness or 2, 1, 6, 1, '%d px', 'Debuff ring line thickness.');
    if (n ~= nil) then s.ring_debuff_thickness = n; mark_dirty(); end
    n = slider('ring_debuff_gap', 'Gap', s.ring_debuff_gap or 0, -8, 6, 1, '%d px',
        'Ring size against the icon. 0 = touches the icon\'s edges. Above 0 overlaps the next icon.');
    if (n ~= nil) then s.ring_debuff_gap = n; mark_dirty(); end
    n = color_row('ring_debuff_color', 'Colour', s.ring_debuff_color or 0xFFFF4040, 'Colour of the debuff ring.');
    if (n ~= nil) then s.ring_debuff_color = n; mark_dirty(); end

    vc.section('MOVING END');
    local tipStyle = s.ring_tip or ((s.ring_sparkle == false) and 'none' or 'sparkle');
    n = seg_row('ring_tip', 'Style', TIPS, tipStyle, 'What marks the moving end of the ring: a twinkling sparkle, a plain dot, or nothing.');
    if (n ~= nil) then s.ring_tip = n; mark_dirty(); end
    if (tipStyle == 'dot') then
        n = slider('ring_dot_size', 'Dot size', s.ring_dot_size or 3, 1, 12, 1, '%d px', 'Radius of the dot.');
        if (n ~= nil) then s.ring_dot_size = n; mark_dirty(); end
        n = switch('ring_dot_only_low', 'Dot only when low', s.ring_dot_only_low, 'Hide the dot until the buff is low, then show it blinking.');
        if (n ~= nil) then s.ring_dot_only_low = n; mark_dirty(); end
    end

    vc.section('LOW');
    n = slider('ring_low_percent', 'Low at', s.ring_low_percent or 25, 5, 75, 1, '%d%% left',
        'A buff counts as low once less than this much of its time is left. Used by the warning colour, the blinking dot and the "only when low" options.');
    if (n ~= nil) then s.ring_low_percent = n; mark_dirty(); end
    n = switch('ring_warn', 'Warn when low', s.ring_warn ~= false,
        'Blend to the low colour once the buff is low. With the Dot style, the dot also blinks (faster near the end).');
    if (n ~= nil) then s.ring_warn = n; mark_dirty(); end
    n = color_row('ring_low_color', 'Low colour', s.ring_low_color or 0xFFFF4040, 'Ring and timer text colour when the buff is about to wear off.');
    if (n ~= nil) then s.ring_low_color = n; mark_dirty(); end
    n = switch('ring_only_low', 'Ring only when low', s.ring_only_low,
        'Only draw rings on buffs that are low. Healthy, unknown and permanent buffs get no ring.');
    if (n ~= nil) then s.ring_only_low = n; mark_dirty(); end

    vc.section('TIME LEFT');
    vc.note('Your own buffs use the game\'s exact timers. Party members\' timers are not sent by the server, so they are estimated from when the buff landed (or was recast) and its duration. '..
        'Durations are measured per caster, job and spell when a cast lands on one of your characters, and shared by all your characters. Otherwise they are learned from watching buffs wear off. '..
        'Buffs already up when you first saw a member (after loading or zoning) show as unknown until recast.');
    n = switch('share_timers', 'Share with my other clients', s.share_timers == true,
        'Your clients on this PC send each other their exact timers, so those characters are exact instead of estimated. It needs to be on in each client. Nothing leaves your PC.');
    if (n ~= nil) then s.share_timers = n; mark_dirty(); end
    if s.share_timers then
        vc.stat('Sharing', gHooks.share_status());
        tip('Other clients show here once they have this on too and have logged in.');
    end
    local timed, unknown, permanent = 0, 0, 0;
    for _, ring in ipairs(gHooks.get_rings()) do
        if (ring.fraction == nil) then
            unknown = unknown + 1;
        elseif (ring.fraction == -1) then
            permanent = permanent + 1;
        else
            timed = timed + 1;
        end
    end
    vc.stat('On screen', ('%d timed, %d unknown, %d permanent'):format(timed, unknown, permanent));
    tip('Only timed buffs have a moving end and a time gone part. Unknown and permanent buffs draw a plain full ring.');
    local count = 0;
    for _ in pairs(s.learned_durations or {}) do count = count + 1; end
    vc.stat('Learned durations', tostring(count));
    imgui.SameLine(0, vc.z(16));
    if vc.button('Forget learned##pb_forget_durations', 'danger', 130) then
        s.learned_durations = T{};
        gHooks.forget_lengths();
        mark_dirty();
    end
    tip('Clear learned durations and go back to the built-in ones. This also clears the caster lengths shared by all your characters.');
    vc.stat('Caster lengths', tostring(gHooks.caster_lengths()));
    tip('Lengths measured per caster, job and spell, shared by all your characters.');
end

----------------------------------------------------------------------------------------------------
-- Timer text
----------------------------------------------------------------------------------------------------
local TEXT_FONTS = { { 'yuna', 'YunaUI' }, { 'default', 'ImGui' } };

local function page_timer_text()
    local s, n = gSettings, nil;
    vc.title('Timer Text', 'time left under each icon');

    vc.section('TEXT');
    n = switch('show_timer_text', 'Show timer text', s.show_timer_text,
        'Show the time left under each icon, like the game\'s status list (16m, 1m, 50). Works with or without rings.');
    if (n ~= nil) then s.show_timer_text = n; mark_dirty(); end
    n = switch('timer_text_known_only', 'Known durations only', s.timer_text_known_only,
        'Show text only on exact timers (you and your other clients) and casts with a length measured for that caster. Assumed or unknown lengths get no text. Rings stay on.');
    if (n ~= nil) then s.timer_text_known_only = n; mark_dirty(); end
    vc.note('You may need more Row spacing (Icons page) to make room under the icons.');
    n = seg_row('timer_text_font', 'Font', TEXT_FONTS, s.timer_text_font or 'yuna',
        'YunaUI: TeX Gyre Adventor, as in YunaUI (needs VanaCore; elsewhere the ImGui font shows). ImGui: the plain overlay font.');
    if (n ~= nil) then s.timer_text_font = n; mark_dirty(); end
    n = slider('timer_text_scale', 'Text size', s.timer_text_scale or 0.85, 0.5, 2.0, 0.05, '%.2fx', 'Size of the timer text.');
    if (n ~= nil) then s.timer_text_scale = n; mark_dirty(); end
    n = color_row('timer_text_color', 'Text colour', s.timer_text_color or 0xFFFFFFFF,
        'Colour of the timer text. It uses the Low colour (Timer Rings page) once the buff is low, when Warn when low is on.');
    if (n ~= nil) then s.timer_text_color = n; mark_dirty(); end
    n = color_row('timer_text_outline', 'Outline colour', s.timer_text_outline_color or 0xFF000000, 'Outline around the timer text.');
    if (n ~= nil) then s.timer_text_outline_color = n; mark_dirty(); end

    local cap = s.timer_text_cap_minutes or 5;
    vc.section('LONG BUFFS');
    n = switch('timer_text_cap', ('Show "%d+" over %d minutes'):format(cap, cap), s.timer_text_cap,
        ('While more than %d minutes are left, show "%d+" instead of the time. The countdown shows once it drops below.'):format(cap, cap));
    if (n ~= nil) then s.timer_text_cap = n; mark_dirty(); end
    if s.timer_text_cap then
        n = slider('timer_text_cap_minutes', 'Minutes', cap, 1, 60, 1, '%d min', 'Where the cap starts.');
        if (n ~= nil) then s.timer_text_cap_minutes = n; mark_dirty(); end
        n = switch('timer_text_cap_hide', ('Hide instead of "%d+"'):format(cap), s.timer_text_cap_hide,
            ('Show no text at all while more than %d minutes are left.'):format(cap));
        if (n ~= nil) then s.timer_text_cap_hide = n; mark_dirty(); end
    end

    vc.section('OFFSET', nil, function()
        s.timer_text_offset_x, s.timer_text_offset_y = 0, -2; mark_dirty();
    end);
    n = slider('timer_text_x', 'Left / right', s.timer_text_offset_x or 0, -40, 40, 1, '%d px', 'Move the timer text sideways.');
    if (n ~= nil) then s.timer_text_offset_x = n; mark_dirty(); end
    n = slider('timer_text_y', 'Up / down', s.timer_text_offset_y or -2, -60, 40, 1, '%d px', 'Move the timer text up or down (0 = just below the icon).');
    if (n ~= nil) then s.timer_text_offset_y = n; mark_dirty(); end
end

----------------------------------------------------------------------------------------------------
-- Active buffs
----------------------------------------------------------------------------------------------------
local function page_active()
    vc.title('Active Buffs', 'on you and your party now');
    vc.note('Shown: drawn in the list (off adds the buff to your filters). Priority: drawn first, closest to the party list.');

    local members = gHooks.get_active_buffs();
    if (#members == 0) then
        imgui.TextColored(C.mute, 'No party data available.');
    end

    for _, m in ipairs(members) do
        vc.section(m.name, ('%d buff%s'):format(#m.buffs, (#m.buffs == 1) and '' or 's'));
        if (#m.buffs == 0) then
            imgui.TextColored(C.mute, 'No active buffs.');
        end
        for i, id in ipairs(m.buffs) do
            local shown, prio = buff_visible(id), buff_priority(id);
            local key = ('%d_%d_%d'):format(m.index, i, id);
            vc.label_row(('%s (%d)'):format(buff_name(id), id), 34 + 10 + 48 + 20 + 34 + 10 + 56);
            local v = vc.switch('act_s_' .. key, 'Shown', shown);
            if (v ~= nil) then set_buff_visible(id, v); end
            imgui.SameLine(0, vc.z(20));
            v = vc.switch('act_p_' .. key, 'Priority', prio);
            if (v ~= nil) then set_buff_priority(id, v); end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Filters / Priority: every buff the game knows, in a scrolling list
----------------------------------------------------------------------------------------------------
local gSearch  = { filter = { '' }, priority = { '' } };
local gView    = { filter = 0, priority = 0 };
local gCache   = {};
local gMessage = '';

local VIEWS = {
    filter   = { { 0, 'All' }, { 1, 'Shown' }, { 2, 'Hidden' } },
    priority = { { 0, 'All' }, { 1, 'Priority' }, { 2, 'Not priority' } },
};

-- mode = 'filter'   : on => buff is SHOWN; off => buff is in settings.exclusions
-- mode = 'priority' : on => buff is in settings.priority (drawn first)
local function page_list(mode)
    local is_filter = (mode == 'filter');
    local list = is_filter and gSettings.exclusions or gSettings.priority;
    local function is_on(id)
        if is_filter then return buff_visible(id); end
        return buff_priority(id);
    end

    if is_filter then
        vc.title('Filters', 'which buffs are shown');
        vc.section('QUICK SET');
        if vc.button('Show all##pb_showall', nil, 90) then clear_list(list); lists_changed(); end
        tip('Clear all filters so every buff is shown.');
        imgui.SameLine();
        if vc.button('Hide all##pb_hideall', nil, 90) then
            clear_list(list);
            for _, entry in ipairs(get_catalog()) do table.insert(list, entry.id); end
            lists_changed();
        end
        tip('Hide every buff, then turn on the ones you want.');
        imgui.SameLine();
        if vc.button('Default##pb_default', nil, 90) then
            clear_list(list);
            for _, id in ipairs(gHooks.default_exclusions) do table.insert(list, id); end
            lists_changed();
        end
        tip('Back to the default filter list.');
        if vc.button('Hide job abilities##pb_hide_ja', nil, 150) then
            local count = 0;
            for _, entry in ipairs(get_catalog()) do
                if entry.ja and (list_index(list, entry.id) == nil) then
                    table.insert(list, entry.id);
                    count = count + 1;
                end
            end
            gMessage = ('Hid %d job ability buffs.'):format(count);
            lists_changed();
        end
        tip('Hide every job ability buff (2-hours, rolls, maneuvers, stances and so on). Other filters stay as they are.');
        imgui.SameLine();
        if vc.button('Monster debuffs only##pb_mon_only', nil, 170) then
            clear_list(list);
            local shown = 0;
            for _, entry in ipairs(get_catalog()) do
                if entry.mon then
                    shown = shown + 1;
                else
                    table.insert(list, entry.id);
                end
            end
            gMessage = ('Showing only %d debuffs monsters can inflict.'):format(shown);
            lists_changed();
        end
        tip('Replaces your filters: hides everything except debuffs monsters can inflict (Sleep, Poison, Paralysis, Slow, Bind, elemental DoTs, Downs and so on).');
        if (gMessage ~= '') then
            vc.note(gMessage);
        end
    else
        vc.title('Priority', 'buffs drawn first');
        vc.section('PRIORITY');
        vc.note('Priority buffs are drawn first, closest to the party list.');
        if vc.button('Clear##pb_clearprio', 'danger', 90) then clear_list(list); lists_changed(); end
        tip('Remove all priority buffs.');
    end

    local raw   = tostring(gSearch[mode][1] or ''):gsub('%z', '');
    local query = raw:lower();
    local view  = gView[mode];

    -- Rebuild the filtered list only when something affecting it changed
    local key = table.concat({ query, view, ui.version }, '|');
    local cache = gCache[mode];
    if (cache == nil) or (cache.key ~= key) then
        local entries = {};
        for _, entry in ipairs(get_catalog()) do
            local match = true;
            if (query ~= '') then
                match = (entry.name:lower():find(query, 1, true) ~= nil) or (tostring(entry.id) == query);
            end
            if match and (view ~= 0) then
                local on = is_on(entry.id);
                if (view == 1 and not on) or (view == 2 and on) then
                    match = false;
                end
            end
            if match then table.insert(entries, entry); end
        end
        cache = { key = key, entries = entries };
        gCache[mode] = cache;
    end
    local entries = cache.entries;

    vc.section('BUFFS', ('%d buff%s'):format(#entries, (#entries == 1) and '' or 's'));
    vc.search_box('##pb_search_' .. mode, gSearch[mode], 'Search name or ID', 220);
    vc.right(seg_w(VIEWS[mode]));
    local pick = vc.seg('view_' .. mode, VIEWS[mode], view);
    if (pick ~= nil) then gView[mode] = pick; end
    imgui.Dummy({ 1, 2 });

    vc.list('##pb_list_' .. mode, 4, function()
        local count = #entries;
        if (count == 0) then
            imgui.TextColored(C.mute, 'No buffs match.');
            return;
        end
        -- Only the rows in view are drawn; the rest are spacers
        local ROW_H = vc.row_height();
        local sy = 0;
        pcall(function() sy = imgui.GetScrollY(); end);
        local _, vh = vc.xy(imgui.GetWindowSize());
        local first = math.max(1, math.floor(sy / ROW_H) + 1);
        local last  = math.min(count, first + math.ceil(vh / ROW_H) + 1);
        if (first > 1) then imgui.Dummy({ 1, (first - 1) * ROW_H }); end
        for i = first, last do
            local entry = entries[i];
            local on = is_on(entry.id);
            local right, col;
            if is_filter then
                right, col = on and 'Shown' or 'Hidden', on and C.good or C.bad;
            else
                right, col = on and 'Priority' or '', C.gold;
            end
            if vc.row(('##pb_row_%s_%d'):format(mode, entry.id), { no_icon = true, name = ('%s  (%d)'):format(entry.name, entry.id),
                    dim = not on, right = right, right_col = col }) then
                if is_filter then
                    set_buff_visible(entry.id, not on);
                else
                    set_buff_priority(entry.id, not on);
                end
            end
        end
        if (last < count) then imgui.Dummy({ 1, (count - last) * ROW_H }); end
    end);
end

----------------------------------------------------------------------------------------------------
-- Profiles (saved filter sets, optionally loaded per job)
----------------------------------------------------------------------------------------------------
local gProfileName = { '' };

local function clean_profile_name(raw)
    raw = tostring(raw or ''):gsub('%z', '');
    raw = raw:gsub('[^%w _%-]', '');
    raw = raw:gsub('^%s+', ''):gsub('%s+$', '');
    return raw:sub(1, 32);
end

local function page_profiles()
    local s = gSettings;
    local job = gHooks.current_job();
    local active = s.active_profile or '';
    local hasActive = (active ~= '') and (s.profiles[active] ~= nil);

    vc.title('Profiles', 'saved filters per job');
    vc.note('A profile stores your Filters and Priority lists. Save one per job, then load it by hand or let it load when you change jobs.');

    vc.section('NOW');
    vc.stat('Active profile', hasActive and active or 'none', hasActive and C.good or C.mute);
    vc.stat('Current job', job or 'unknown');
    local n = switch('auto_profile', 'Load a profile when I change jobs', s.auto_profile,
        'When your main job changes, load the profile set for that job ("Use for" below).');
    if (n ~= nil) then s.auto_profile = n; mark_dirty(); end

    vc.section('SAVE');
    vc.label_row('Name', 200 + 8 + 80);
    imgui.PushItemWidth(vc.z(200));
    imgui.InputText('##pb_profile_name', gProfileName, 32);
    imgui.PopItemWidth();
    tip('Letters, numbers, spaces, _ and - only.');
    imgui.SameLine(0, vc.z(8));
    if vc.button('Save##pb_profile_save', 'primary', 80) then
        local name = clean_profile_name(gProfileName[1]);
        if (name ~= '') then
            gHooks.save_profile(name);
            gProfileName[1] = '';
        end
    end
    tip('Save your current Filters and Priority under this name (replaces a profile with the same name).');
    if hasActive then
        if vc.button(('Update "%s"##pb_profile_update'):format(active), nil, nil) then
            gHooks.save_profile(active);
        end
        tip('Save your current Filters and Priority into the active profile.');
    end

    local names = {};
    for name, _ in pairs(s.profiles) do
        table.insert(names, name);
    end
    table.sort(names, function(a, b) return a:lower() < b:lower(); end);

    vc.section('SAVED PROFILES', tostring(#names));
    if (#names == 0) then
        imgui.TextColored(C.mute, 'No profiles saved yet.');
    end
    for _, name in ipairs(names) do
        local jobs = {};
        for j, p in pairs(s.job_profiles) do
            if (p == name) then table.insert(jobs, j); end
        end
        table.sort(jobs);

        pcall(imgui.AlignTextToFramePadding);
        imgui.TextColored((name == active) and C.gold or C.text, name);
        if (#jobs > 0) then
            imgui.SameLine();
            imgui.TextColored(C.mute, '  ' .. table.concat(jobs, ', '));
        end
        vc.right((job ~= nil) and (70 + 8 + 120 + 8 + 70) or (70 + 8 + 70));
        if vc.button('Load##pb_pload_' .. name, 'primary', 70) then
            gHooks.load_profile(name);
        end
        if (job ~= nil) then
            imgui.SameLine();
            local assigned = (s.job_profiles[job] == name);
            if vc.button((assigned and ('Unset ' .. job) or ('Use for ' .. job)) .. '##pb_pjob_' .. name, nil, 120) then
                s.job_profiles[job] = (not assigned) and name or nil;
                mark_dirty();
            end
            tip('Load this profile when you change to ' .. job .. ' (needs "Load a profile when I change jobs").');
        end
        imgui.SameLine();
        if vc.button('Delete##pb_pdel_' .. name, 'danger', 70) then
            gHooks.delete_profile(name);
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------------------------------
local PAGES = {
    about    = page_about,
    icons    = page_icons,
    position = page_position,
    saved    = page_saved,
    range    = page_range,
    range_font = page_range_font,
    front    = page_front,
    rings    = page_rings,
    text     = page_timer_text,
    active   = page_active,
    filters  = function() page_list('filter'); end,
    priority = function() page_list('priority'); end,
    profiles = page_profiles,
    tp_display = tpPages.display,
    tp_layout = tpPages.layout,
    tp_style = tpPages.style,
    tp_help = tpPages.help,
};
local PAGE_NAME = {
    about = 'About', saved = 'Saved Themes', icons = 'Icons', position = 'Position', front = 'Draw In Front', range = 'Range Text', range_font = 'Range Text / Font', rings = 'Timer Rings',
    text = 'Timer Text', active = 'Active Buffs', filters = 'Filters', priority = 'Priority', profiles = 'Profiles',
    tp_display = 'TP / Display', tp_layout = 'TP / Position & Size', tp_style = 'TP / Text Style', tp_help = 'TP / Help',
};

local function sidebar(nav)
    if nav.head('test', ui.test_mode[1] and 'Stop test' or 'Test Mode', ui.test_mode[1], 'test') then
        ui.test_mode[1] = not ui.test_mode[1];
    end
    nav.tip('Show a full party with sample buffs while this window is open. Shift+drag to move it.');
    nav.gap();
    if nav.head('about', 'About', win.page == 'about') then win.page = 'about'; end

    nav.caption('DISPLAY');
    if nav.head('widget', 'Saved Themes', win.page == 'saved', 'saved') then win.page = 'saved'; end
    nav.tip('Save the whole look as a file, or load one');
    nav.gap();
    if nav.head('gear', 'Display', false, 'h_display') then win.page = 'icons'; end
    if nav.item('Icons', win.page == 'icons', 'icons') then win.page = 'icons'; end
    if nav.item('Position', win.page == 'position', 'position') then win.page = 'position'; end
    if nav.item('Draw In Front', win.page == 'front', 'front') then win.page = 'front'; end
    nav.gap();
    if nav.head('search', 'Range Text', false, 'h_range') then win.page = 'range'; end
    nav.tip('Distance to each party member');
    if nav.item('Show & Position', win.page == 'range', 'range') then win.page = 'range'; end
    if nav.item('Font', win.page == 'range_font', 'range_font') then win.page = 'range_font'; end
    nav.gap();
    if nav.head('refresh', 'Timers', false, 'h_timers') then win.page = 'rings'; end
    if nav.item('Timer Rings', win.page == 'rings', 'rings') then win.page = 'rings'; end
    if nav.item('Timer Text', win.page == 'text', 'text') then win.page = 'text'; end

    nav.gap();
    if nav.head('spark', 'TP & Target', false, 'h_tp') then win.page = 'tp_display'; end
    nav.tip('Party TP numbers and target HP%');
    if nav.item('Display', win.page == 'tp_display', 'tp_display') then win.page = 'tp_display'; end
    if nav.item('Position & Size', win.page == 'tp_layout', 'tp_layout') then win.page = 'tp_layout'; end
    if nav.item('Text Style', win.page == 'tp_style', 'tp_style') then win.page = 'tp_style'; end
    if nav.item('Help', win.page == 'tp_help', 'tp_help') then win.page = 'tp_help'; end

    nav.caption('BUFFS');
    if nav.head('star', 'Active Buffs', win.page == 'active', 'active') then win.page = 'active'; end
    nav.tip('Buffs on you and your party right now');
    if nav.head('list', 'Filters', win.page == 'filters', 'filters') then win.page = 'filters'; end
    nav.tip('Which buffs are shown');
    if nav.head('spark', 'Priority', win.page == 'priority', 'priority') then win.page = 'priority'; end
    nav.tip('Buffs drawn first');
    if nav.head('files', 'Profiles', win.page == 'profiles', 'profiles') then win.page = 'profiles'; end
    nav.tip('Save the filters per job');
end

local WINDOW = {
    id        = 'partybuffs',
    title     = 'PartyBuffs',
    size      = { 740, 580 },
    min       = { 620, 420 },
    pages     = PAGES,
    sidebar   = sidebar,
    sidebar_w = 190,
    scaler    = true,
    on_scale  = function(sc) gSettings.ui_scale = sc; mark_dirty(); end,
    subtitle  = function(page) return PAGE_NAME[page]; end,
    header_right = function()
        if ui.test_mode[1] or tpd.test then return 'Test Mode', C.gold; end
        return 'v' .. tostring(addon.version), C.mute;
    end,
};

ui.render_config_ui = function(settings, hooks)
    gSettings, gHooks = settings, hooks;

    -- Flush pending changes once the mouse is released (also runs after the window is closed)
    if ui.dirty and not imgui.IsMouseDown(0) then
        ui.dirty = false;
        if ui.font_pending then
            ui.font_pending = false;
            hooks.apply_font();
        end
        hooks.save();
    end

    if (not win.open[1]) then return; end

    win.scale = tonumber(settings.ui_scale) or 1;
    vc.window(win, WINDOW);
end

return ui;
