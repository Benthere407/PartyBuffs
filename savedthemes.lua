--[[
* Saved themes: the whole look of PartyBuffs (icon size and spacing, icon theme, timer rings,
* timer text and range text) as a file, savedthemes\<name>.lua in this addon's folder, so every
* character can load it.
*
* Not part of a theme: where the buffs sit on screen, your own row, the filters and priority
* lists (those are Profiles), and learned buff durations.
--]]

require('common');

local saved = {};

-- The look settings a theme holds
saved.KEYS = {
    'size', 'icon_spacing', 'row_spacing', 'icon_theme', 'icon_zigzag', 'icon_zigzag_offset', 'icon_zigzag_text', 'icon_zigzag_first',
    'show_distance', 'show_self_distance', 'distance_decimals', 'distance_fixed',
    'distance_offset_x', 'distance_offset_y', 'distance_outline_color', 'distance_outline_thickness',
    'show_rings', 'ring_thickness', 'ring_gap', 'ring_color', 'ring_gone_color', 'ring_warn',
    'ring_low_percent', 'ring_only_low', 'ring_dot_only_low', 'ring_low_color', 'ring_tip',
    'ring_dot_size', 'ring_show_unknown',
    'show_timer_text', 'timer_text_scale', 'timer_text_font', 'timer_text_color', 'timer_text_outline_color',
    'timer_text_offset_x', 'timer_text_offset_y', 'timer_text_cap', 'timer_text_cap_minutes', 'timer_text_cap_hide',
};
-- And these from the range text's font (settings.distance_object)
saved.FONT_KEYS = { 'font_family', 'font_height', 'bold', 'italic', 'color' };

function saved.dir()
    return (tostring(addon.path):gsub('[\\/]+$', '')) .. '\\savedthemes\\';
end

-- A name that is safe as a file name: letters, numbers, spaces and - _ . ( )
function saved.clean_name(n)
    n = tostring(n or ''):gsub('%z', ''):gsub('[^%w%s%-_%.%(%)]', '');
    n = n:gsub('^[%s%.]+', ''):gsub('[%s%.]+$', '');
    return n:sub(1, 48);
end

local function path_of(name) return saved.dir() .. name .. '.lua'; end

function saved.exists(name)
    local f = io.open(path_of(name), 'r');
    if f then f:close(); return true; end
    return false;
end

-- Writes a value as Lua source (tables with sorted keys, so the file reads well)
local function serialize(v, indent)
    local t = type(v);
    if (t == 'number') then
        return ('%.17g'):format(v);
    elseif (t == 'string') then
        return ('%q'):format(v);
    elseif (t == 'boolean') then
        return tostring(v);
    elseif (t == 'table') then
        local keys = {};
        for k in pairs(v) do
            if (type(k) == 'string') or (type(k) == 'number') then keys[#keys + 1] = k; end
        end
        table.sort(keys, function(a, b)
            if (type(a) == type(b)) then return a < b; end
            return type(a) == 'number';
        end);
        if (#keys == 0) then return '{}'; end
        local inner = indent .. '    ';
        local out = { '{' };
        for _, k in ipairs(keys) do
            local key = ((type(k) == 'string') and k:match('^[%a_][%w_]*$')) and k or ('[' .. serialize(k, inner) .. ']');
            out[#out + 1] = ('%s%s = %s,'):format(inner, key, serialize(v[k], inner));
        end
        out[#out + 1] = indent .. '}';
        return table.concat(out, '\n');
    end
    return 'nil';
end

-- Theme file names (without .lua), sorted
function saved.list()
    local names = {};
    local ok, files = pcall(ashita.fs.get_dir, saved.dir(), '.*\\.lua', true);
    if (not ok) or (type(files) ~= 'table') then ok, files = pcall(ashita.fs.get_directory, saved.dir()); end
    if ok and (type(files) == 'table') then
        for _, f in pairs(files) do
            local n = (type(f) == 'string') and f:match('([^\\/]+)%.lua$');
            if n then names[#names + 1] = n; end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower(); end);
    return names;
end

-- Saves the current look as <name>. Returns ok, error
function saved.save(name, settings)
    name = saved.clean_name(name);
    if (name == '') then return false, 'Give the theme a name.'; end

    local data = { version = 1, look = {}, range_font = {} };
    for _, k in ipairs(saved.KEYS) do data.look[k] = settings[k]; end
    local fo = settings.distance_object or {};
    for _, k in ipairs(saved.FONT_KEYS) do data.range_font[k] = fo[k]; end

    local dir = saved.dir();
    if not ashita.fs.exists(dir) then
        if not pcall(ashita.fs.create_dir, dir) then pcall(ashita.fs.create_directory, dir); end
    end
    local f, err = io.open(path_of(name), 'w');
    if not f then return false, tostring(err); end
    f:write('-- A PartyBuffs theme. Load it on the Saved Themes page of /partybuffs.\n');
    f:write('return ', serialize(data, ''), '\n');
    f:close();
    return true, name;
end

-- Loads <name> into settings (settings the file doesn't have are left as they are). Returns ok, error
function saved.load(name, settings)
    local fn = loadfile(path_of(name));
    if not fn then return false, 'Could not read ' .. name .. '.lua'; end
    setfenv(fn, {});   -- (data only: the file sees no globals)
    local ok, data = pcall(fn);
    if (not ok) or (type(data) ~= 'table') or (type(data.look) ~= 'table') then
        return false, name .. '.lua is not a PartyBuffs theme.';
    end
    for _, k in ipairs(saved.KEYS) do
        if (data.look[k] ~= nil) then settings[k] = data.look[k]; end
    end
    if (type(data.range_font) == 'table') and (settings.distance_object ~= nil) then
        for _, k in ipairs(saved.FONT_KEYS) do
            if (data.range_font[k] ~= nil) then settings.distance_object[k] = data.range_font[k]; end
        end
    end
    return true;
end

function saved.delete(name)
    local ok, err = os.remove(path_of(name));
    if (not ok) and saved.exists(name) then return false, tostring(err); end
    return true;
end

return saved;
