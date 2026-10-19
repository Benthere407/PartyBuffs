--[[
* PartyBuffs config UI
* Layout/behavior modeled on the Timers addon config UI (tabs, checkbox filter list
* with search / paging / view modes).
*
* Usage (from partybuffs.lua):
*   confUI.is_open[1] = true                -- open the window
*   confUI.render_config_ui(settings, hooks)
*
* hooks = {
*     save               = function() end,   -- persist settings
*     rebuild            = function() end,   -- rebuild exclusion/priority lookups
*     apply_font         = function() end,   -- re-apply distance font settings
*     default_exclusions = T{ ... },         -- the "Default" exclusion list
* }
--]]

require('common');
local imgui = require('imgui');

local gHeaderColor = { 1.0, 0.75, 0.55, 1.0 };

local ui = T{
    is_open = { false, },
    dirty   = false,   -- settings changed, waiting for mouse release to save
    version = 0,       -- bumped whenever a filter/priority list changes (invalidates list cache)
};

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------
local function show_help(text)
    if text and imgui.IsItemHovered() then
        imgui.SetTooltip(text);
    end
end

-- 0xAARRGGBB -> { r, g, b, a } floats
local function argb_to_v4(c)
    c = c or 0xFFFFFFFF;
    local a = bit.band(bit.rshift(c, 24), 0xFF);
    local r = bit.band(bit.rshift(c, 16), 0xFF);
    local g = bit.band(bit.rshift(c, 8), 0xFF);
    local b = bit.band(c, 0xFF);
    return { r / 255, g / 255, b / 255, a / 255 };
end

-- { r, g, b, a } floats -> 0xAARRGGBB
local function v4_to_argb(v)
    local function ch(x) return math.max(0, math.min(255, math.floor((x * 255) + 0.5))); end
    local n = bit.bor(bit.lshift(ch(v[4]), 24), bit.lshift(ch(v[1]), 16), bit.lshift(ch(v[2]), 8), ch(v[3]));
    if (n < 0) then n = n + 4294967296; end
    return n;
end

local function mark_dirty()
    ui.dirty = true;
end

-- Each helper returns (newValue, changed)
local function checkbox(label, value, help)
    local changed = imgui.Checkbox(label, { value == true });
    show_help(help);
    if changed then
        return (not (value == true)), true;
    end
    return (value == true), false;
end

local function slider_int(label, value, min, max, help)
    local t = T{ value };
    imgui.SliderInt(label, t, min, max, '%dpx');
    show_help(help);
    return t[1], (t[1] ~= value);
end

local function slider_plain(label, value, min, max, help)
    local t = T{ value };
    imgui.SliderInt(label, t, min, max, '%d');
    show_help(help);
    return t[1], (t[1] ~= value);
end

local function color_edit(label, value, help)
    local c = argb_to_v4(value);
    local changed = imgui.ColorEdit4(label, c);
    show_help(help);
    if changed then
        return v4_to_argb(c), true;
    end
    return value, false;
end

----------------------------------------------------------------------------------------------------
-- Buff catalog (id + name for every buff the game knows about). Built once.
----------------------------------------------------------------------------------------------------
local gCatalog = nil;
local function get_catalog()
    if (gCatalog == nil) then
        gCatalog = {};
        local resMgr = AshitaCore:GetResourceManager();
        for i = 1, 1024 do
            local name = resMgr:GetString('buffs.names', i);
            if (name ~= nil) and (name ~= '') then
                table.insert(gCatalog, { id = i, name = name });
            end
        end
        table.sort(gCatalog, function(a, b)
            local an, bn = a.name:lower(), b.name:lower();
            if (an == bn) then return a.id < b.id; end
            return an < bn;
        end);
    end
    return gCatalog;
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

----------------------------------------------------------------------------------------------------
-- General tab
----------------------------------------------------------------------------------------------------
ui.render_general_tab = function(settings, hooks)
    imgui.TextColored(gHeaderColor, 'General');
    imgui.BeginChild('pb_general', { 0, 120 }, true);
        local v, ch;

        v, ch = checkbox('Show Self?', settings.show_self, 'Show your own buffs in the list.');
        if ch then settings.show_self = v; mark_dirty(); end

        v, ch = slider_int('Icon Size', settings.size, 8, 64, 'Size of each buff icon in pixels.');
        if ch then settings.size = v; mark_dirty(); end

        v, ch = slider_int('Row Spacing', settings.row_spacing or 20, 8, 60, 'Vertical distance between party members.');
        if ch then settings.row_spacing = v; mark_dirty(); end
    imgui.EndChild();

    imgui.TextColored(gHeaderColor, 'List Position');
    imgui.BeginChild('pb_position', { 0, 100 }, true);
        v, ch = slider_plain('X Offset', settings.list_offset_x or 0, -1000, 1000, 'Move the whole buff list horizontally (negative = left).');
        if ch then settings.list_offset_x = v; mark_dirty(); end

        v, ch = slider_plain('Y Offset', settings.list_offset_y or 0, -1000, 1000, 'Move the whole buff list vertically (negative = up).');
        if ch then settings.list_offset_y = v; mark_dirty(); end

        if imgui.Button('Reset Position') then
            settings.list_offset_x = 0;
            settings.list_offset_y = 0;
            mark_dirty();
        end
    imgui.EndChild();
end

----------------------------------------------------------------------------------------------------
-- Range text tab
----------------------------------------------------------------------------------------------------
ui.render_range_tab = function(settings, hooks)
    local font = settings.distance_object;
    local v, ch;

    imgui.TextColored(gHeaderColor, 'Range Text');
    imgui.BeginChild('pb_range', { 0, 175 }, true);
        v, ch = checkbox('Enabled?', settings.show_distance, 'Show the distance to each party member.');
        if ch then settings.show_distance = v; mark_dirty(); end

        v, ch = slider_plain('Decimals', settings.distance_decimals or 1, 0, 2, 'Number of decimal places in the distance.');
        if ch then settings.distance_decimals = v; mark_dirty(); end

        v, ch = checkbox('Fixed Position?', settings.distance_fixed,
            'Unchecked: text follows the left edge of each member\'s buffs (moves as buffs come and go). '..
            'Checked: text stays at a fixed spot relative to the right edge of the buff row.');
        if ch then settings.distance_fixed = v; mark_dirty(); end

        v, ch = slider_plain('X Offset', settings.distance_offset_x or 0, -800, 800, 'Move the range text horizontally (negative = left).');
        if ch then settings.distance_offset_x = v; mark_dirty(); end

        v, ch = slider_plain('Y Offset', settings.distance_offset_y or 0, -300, 300, 'Move the range text vertically (negative = up).');
        if ch then settings.distance_offset_y = v; mark_dirty(); end

        if imgui.Button('Reset Range Text Position') then
            settings.distance_offset_x = 0;
            settings.distance_offset_y = 0;
            mark_dirty();
        end
    imgui.EndChild();

    imgui.TextColored(gHeaderColor, 'Range Font');
    imgui.BeginChild('pb_range_font', { 0, 160 }, true);
        local fam = T{ tostring(font.font_family or '') };
        if imgui.InputText('Font Family', fam, 255) then
            font.font_family = (table.concat(fam):gsub('%z', ''));
            ui.font_pending = true;   -- applied on mouse release / focus loss to avoid rebuilding every keystroke
            mark_dirty();
        end
        show_help('Name of an installed font. Applies when you release the mouse / finish typing.');

        v, ch = slider_plain('Font Size', font.font_height or 8, 4, 40, 'Font size.');
        if ch then font.font_height = v; hooks.apply_font(); mark_dirty(); end

        v, ch = checkbox('Bold?', font.bold, 'Bold text.');
        if ch then font.bold = v; hooks.apply_font(); mark_dirty(); end
        imgui.SameLine();
        imgui.Dummy({ 10, 1 });
        imgui.SameLine();
        v, ch = checkbox('Italic?', font.italic, 'Italic text.');
        if ch then font.italic = v; hooks.apply_font(); mark_dirty(); end

        v, ch = color_edit('Text Color', font.color, 'Color of the range text.');
        if ch then font.color = v; hooks.apply_font(); mark_dirty(); end

        v, ch = color_edit('Outline Color', font.color_outline, 'Outline color of the range text.');
        if ch then font.color_outline = v; hooks.apply_font(); mark_dirty(); end
    imgui.EndChild();
end

----------------------------------------------------------------------------------------------------
-- Filter / priority list tabs
----------------------------------------------------------------------------------------------------
local LIST_PAGE_SIZE = 40;
local gSearch = {};
local gView   = {};
local gPage   = {};
local gCache  = {};

local VIEW_LABELS = {
    filter   = { [0] = 'All', [1] = 'Shown only', [2] = 'Hidden only' },
    priority = { [0] = 'All', [1] = 'Priority only', [2] = 'Non-priority only' },
};

-- mode = 'filter'   : checked => buff is SHOWN; unchecked => buff is in settings.exclusions
-- mode = 'priority' : checked => buff is in settings.priority (drawn first)
local function render_list_tab(settings, hooks, mode)
    local is_filter = (mode == 'filter');
    local list      = is_filter and settings.exclusions or settings.priority;

    local function is_on(id)
        if is_filter then
            return list_index(list, id) == nil;
        end
        return list_index(list, id) ~= nil;
    end

    local function set_on(id, on)
        if is_filter then
            list_set(list, id, not on);
        else
            list_set(list, id, on);
        end
        ui.version = ui.version + 1;
        hooks.rebuild();
        mark_dirty();
    end

    imgui.TextColored(gHeaderColor, is_filter and 'Buff Filters' or 'Priority Buffs');
    imgui.BeginChild('pb_list_options_' .. mode, { 0, 441 }, true);
        if is_filter then
            imgui.TextWrapped('Checked buffs are shown. Uncheck a buff to hide it.');
        else
            imgui.TextWrapped('Checked buffs are always drawn first (closest to the party list).');
        end

        if is_filter then
            if imgui.Button('Show All##pb_showall') then
                for i = #list, 1, -1 do table.remove(list, i); end
                ui.version = ui.version + 1; hooks.rebuild(); mark_dirty();
            end
            show_help('Clear all exclusions so every buff is shown.');
            imgui.SameLine();
            if imgui.Button('Hide All##pb_hideall') then
                for i = #list, 1, -1 do table.remove(list, i); end
                for _, entry in ipairs(get_catalog()) do table.insert(list, entry.id); end
                ui.version = ui.version + 1; hooks.rebuild(); mark_dirty();
            end
            show_help('Hide every buff. Check the ones you want to see.');
            imgui.SameLine();
            if imgui.Button('Default##pb_default') then
                for i = #list, 1, -1 do table.remove(list, i); end
                for _, id in ipairs(hooks.default_exclusions) do table.insert(list, id); end
                ui.version = ui.version + 1; hooks.rebuild(); mark_dirty();
            end
            show_help('Reset to the default exclusion list (hides most non-party-relevant effects).');
            imgui.SameLine();
        else
            if imgui.Button('Clear##pb_clearprio') then
                for i = #list, 1, -1 do table.remove(list, i); end
                ui.version = ui.version + 1; hooks.rebuild(); mark_dirty();
            end
            show_help('Remove all priority buffs.');
            imgui.SameLine();
        end

        gView[mode] = gView[mode] or 0;
        if imgui.Button('View: ' .. VIEW_LABELS[mode][gView[mode]] .. '##pb_view_' .. mode) then
            gView[mode] = (gView[mode] + 1) % 3;
        end
        show_help('Cycle between listing all buffs, only checked ones, or only unchecked ones.');

        gSearch[mode] = gSearch[mode] or { '' };
        imgui.InputText('Search##pb_search_' .. mode, gSearch[mode], 64);
        show_help('Type part of a buff name (or its ID) to narrow the list.');
        local raw   = (tostring(gSearch[mode][1] or ''):gsub('%z', ''));
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
        local pages = math.max(1, math.ceil(#entries / LIST_PAGE_SIZE));

        -- Back to the first page whenever the search text or view changes
        local pkey = query .. '|' .. view;
        if (gPage[mode] == nil) or (gPage[mode].key ~= pkey) then
            gPage[mode] = { key = pkey, page = 1 };
        end
        local pg = gPage[mode];
        if (pg.page > pages) then pg.page = pages; end
        if (pg.page < 1) then pg.page = 1; end

        if imgui.Button('< Prev##pb_prev_' .. mode) and pg.page > 1 then pg.page = pg.page - 1; end
        imgui.SameLine();
        if imgui.Button('Next >##pb_next_' .. mode) and pg.page < pages then pg.page = pg.page + 1; end
        imgui.SameLine();
        imgui.Text(('Page %d / %d  (%d buffs)'):format(pg.page, pages, #entries));

        imgui.BeginChild('pb_list_' .. mode, { 0, 290 }, true);
            if (#entries == 0) then
                imgui.TextDisabled('No buffs match.');
            end

            local first = ((pg.page - 1) * LIST_PAGE_SIZE) + 1;
            local last  = math.min(#entries, first + LIST_PAGE_SIZE - 1);
            for i = first, last do
                local entry = entries[i];
                local on = is_on(entry.id);
                local label = ('%s (%d)##pb_%s_%d'):format(entry.name, entry.id, mode, entry.id);
                if imgui.Checkbox(label, { on }) then
                    set_on(entry.id, not on);
                end
            end
        imgui.EndChild();
    imgui.EndChild();
end

ui.render_filter_tab = function(settings, hooks)
    render_list_tab(settings, hooks, 'filter');
end

ui.render_priority_tab = function(settings, hooks)
    render_list_tab(settings, hooks, 'priority');
end

----------------------------------------------------------------------------------------------------
-- Main window
----------------------------------------------------------------------------------------------------
ui.render_config_ui = function(settings, hooks)
    -- Flush pending changes once the mouse is released (also runs after the window is closed)
    if ui.dirty and not imgui.IsMouseDown(0) then
        ui.dirty = false;
        if ui.font_pending then
            ui.font_pending = false;
            hooks.apply_font();
        end
        hooks.save();
    end

    if (not ui.is_open[1]) then return; end

    imgui.SetNextWindowSize({ 480, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin(('PartyBuffs v%s'):format(addon.version), ui.is_open) then
        if imgui.BeginTabBar('##partybuffs_tabbar', ImGuiTabBarFlags_NoCloseWIthMiddleMouseButton) then
            if imgui.BeginTabItem('General', nil) then
                ui.render_general_tab(settings, hooks);
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Range Text', nil) then
                ui.render_range_tab(settings, hooks);
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Filters', nil) then
                ui.render_filter_tab(settings, hooks);
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Priority', nil) then
                ui.render_priority_tab(settings, hooks);
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end
        imgui.TextDisabled(('%s - %s'):format(addon.author, addon.link));
    end
    imgui.End();
end

return ui;
