addon.name      = 'PartyBuffs';
addon.author    = 'Thorny';
addon.version   = '2.1';
addon.desc      = 'Displays party buffs next to the party list, with party TP and target health.';
addon.link      = 'https://github.com/ThornyFFXI/MiscAshita4';

require('common');
local chat = require('chat');
ffi  = require('ffi');
d3d8 = require('d3d8');
d3d8_device = d3d8.get_device();
renderer = require('spriterenderer');

local imgui = require('imgui');
local scaling = require('scaling');
local memberDisplay = require('memberdisplay');
local buffTimers = require('bufftimers');
local timerShare = require('timershare');
local ringOverlay = require('ringoverlay');
local yunaFont = require('yunafont');
local tpDisplay = require('tpdisplay');
local confUI = require('conf_ui');
local settingLib = require('settings');
local partyMembers = T{};

local DEFAULT_EXCLUSIONS = T{ 34, 35, 38, 56, 57, 58, 59, 60, 62, 65, 68, 72, 73, 74, 75, 76, 77, 78, 79, 87, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 114, 115, 117, 118, 127, 143, 150, 151, 152, 155, 157, 158, 159, 160, 161, 162, 171, 172, 176, 187, 188, 190, 191, 229, 230, 232, 235, 236, 237, 238, 239, 240, 241, 242, 243, 249, 250, 252, 253, 254, 256, 257, 258, 260, 261, 262, 263, 264, 266, 267, 268, 269, 270, 271, 272, 273, 274, 276, 277, 278, 279, 280, 281, 282, 284, 285, 287, 288, 289, 290, 292, 293, 294, 295, 296, 297, 298, 300, 301, 302, 303, 304, 305, 306, 307, 308, 340, 341, 342, 343, 345, 346, 349, 350, 351, 352, 353, 354, 355, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 371, 375, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400, 401, 402, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 422, 423, 424, 425, 426, 427, 428, 429, 430, 431, 432, 433, 434, 435, 436, 438, 439, 440, 441, 442, 443, 447, 448, 449, 450, 451, 452, 456, 457, 460, 461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 472, 474, 475, 476, 478, 479, 480, 481, 482, 483, 484, 486, 487, 488, 489, 510, 511, 512, 523, 524, 525, 526, 527, 528, 529, 530, 532, 576, 577, 578, 579, 585, 605, 606, 607, 608, 609, 610, 611, 613, 614, 615, 616 };

local default_settings = T{
    distance_object = {
        visible        = true,
        can_focus      = false,
        locked         = true,
        lockedz        = true,
        is_dirty       = true,
        font_file      = nil,
        font_family    = 'Comic Sans MS',
        font_height    = 8,
        bold           = true,
        italic         = false,
        right_justified= true,
        strike_through = false,
        underlined     = false,
        color          = 0xFFFF0000,
        color_outline  = 0x00000000,
        padding        = 0.1,
        position_x     = 0,
        position_y     = 0,
        auto_resize    = true,
        anchor         = FrameAnchor.TopLeft,
        anchor_parent  = FrameAnchor.TopLeft,
        text           = '',
    
        -- Font Background Defaults
        background = T{
            texture_offset_x= 0.0,
            texture_offset_y= 0.0,
            border_visible  = false,
            border_color    = 0x00000000,
            border_flags    = FontBorderFlags.None,
            border_sizes    = '0,0,0,0',
            visible         = false,
            position_x      = 0,
            position_y      = 0,
            can_focus       = true,
            locked          = false,
            lockedz         = false,
            scale_x         = 1.0,
            scale_y         = 1.0,
            width           = 0.0,
            height          = 0.0,
            color           = 0xFFFFFFFF,
        }
    },
    show_distance = true,
    show_self = false,
    show_self_distance = false,
    size = 20,
    icon_spacing = 0,  -- extra horizontal pixels between icons
    icon_zigzag = false,       -- stagger every other icon
    icon_zigzag_offset = 8,    -- how far (px, below 0 = up)
    icon_zigzag_first = 'top',  -- first icon (next to the party list) on the 'top' or 'bottom' of the zigzag
    icon_zigzag_text = 'below', -- timer text: 'below', 'zig' (in-line icons' text above) or 'zag' (moved icons' text above)
    saved_theme = '',  -- the saved theme (savedthemes\<name>.lua) last loaded or saved, shown in the menu
    ui_scale = 1.0,    -- the settings window's scale (its header's < 100% > stepper)
    icon_theme = '',   -- folder name under themes\, '' = the game's own icons

    -- Timer rings around each icon
    show_rings = false,
    ring_thickness = 2,
    ring_gap = 0,
    ring_color = 0xFF66CCFF,      -- time left
    ring_gone_color = 0x2E66CCFF, -- time gone (the used up part of the ring)
    ring_warn = true,             -- fade to ring_low_color once low
    ring_low_percent = 25,        -- below this % of time left a buff counts as low
    ring_only_low = false,        -- only draw rings on low buffs
    ring_dot_only_low = false,    -- only draw the dot on low buffs
    ring_low_color = 0xFFFF4040,
    ring_tip = 'sparkle',         -- moving end: 'sparkle', 'dot' or 'none'
    ring_dot_size = 3,            -- dot radius in pixels
    ring_show_unknown = true,     -- dim full ring when a party member's time left is unknown
    learned_durations = T{},      -- [tostring(buff id)] = seconds
    tracked_buffs = T{},          -- [tostring(server id)] = { [tostring(buff id)] = start (os.time) }, kept over reloads
    share_timers = false,         -- swap exact buff timers with your other clients on this PC
    test_buff_count = 6,          -- sample buffs per member in Test Mode (1-18)
    debuffs_first = false,        -- enfeebles and debuffs go next to the party list
    ring_debuff = false,          -- debuffs get their own plain ring (instead of the timer ring)
    ring_debuff_thickness = 2,
    ring_debuff_gap = 0,
    ring_debuff_color = 0xFFFF4040,
    test_debuff_count = 0,        -- sample debuffs per member in Test Mode (0-4)

    -- Party TP and target health numbers (tpdisplay.lua)
    tp = tpDisplay.defaults,
    tp_imported = false,          -- this character's settings were brought over from the old tparty addon

    -- Time left text under each icon ("16m", "50")
    show_timer_text = false,
    timer_text_scale = 0.85,
    timer_text_font = 'yuna',  -- 'yuna' (YunaUI's TeX Gyre Adventor, under VanaCore) or 'default' (ImGui's font)
    timer_text_color = 0xFFFFFFFF,
    timer_text_outline_color = 0xFF000000,
    timer_text_offset_x = 0,
    timer_text_offset_y = -2,
    timer_text_cap = false,        -- show "5+" instead of the time while more than the cap is left
    timer_text_cap_minutes = 5,
    timer_text_cap_hide = false,   -- above the cap show nothing instead of "5+"
    exclusions = T{},
    priority = T{},

    -- Only show one icon per buff (e.g. no stacked copies of the same BRD song)
    unique_buffs = true,

    -- List layout
    row_spacing = 20,
    list_offset_x = 0,
    list_offset_y = 0,

    -- Range text placement
    distance_fixed = false,
    distance_offset_x = 0,
    distance_offset_y = 0,
    distance_decimals = 1,
    distance_outline_color = 0xFF000000,
    distance_outline_thickness = 1,

    -- Saved filter profiles
    profiles = T{},          -- [name] = { exclusions = {ids}, priority = {ids} }
    job_profiles = T{},      -- [job abbreviation] = profile name
    auto_profile = false,
    active_profile = '',
};

settings = settingLib.load(default_settings);

local function EnsureSettings()
    settings.profiles       = settings.profiles or T{};
    settings.job_profiles   = settings.job_profiles or T{};
    settings.active_profile = settings.active_profile or '';
    settings.exclusions     = settings.exclusions or T{};
    settings.priority       = settings.priority or T{};
    settings.learned_durations = settings.learned_durations or T{};
    tpDisplay.Import();
end
EnsureSettings();
memberDisplay.RebuildLookups();

local function ApplyFonts()
    for _,member in ipairs(partyMembers) do
        member:ApplyFont();
    end
end

----------------------------------------------------------------------------------------------------
-- Filter profiles
----------------------------------------------------------------------------------------------------
local JOB_ABBR = { 'WAR','MNK','WHM','BLM','RDM','THF','PLD','DRK','BST','BRD','RNG','SAM','NIN','DRG','SMN','BLU','COR','PUP','DNC','SCH','GEO','RUN' };

local function CurrentJob()
    local ok, id = pcall(function()
        return AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
    end);
    if ok and id and id > 0 then
        return JOB_ABBR[id];
    end
    return nil;
end

local function CopyList(list)
    local copy = T{};
    for _,v in ipairs(list or {}) do
        copy:append(v);
    end
    return copy;
end

local function SaveProfile(name)
    settings.profiles[name] = {
        exclusions = CopyList(settings.exclusions),
        priority   = CopyList(settings.priority),
    };
    settings.active_profile = name;
    settingLib.save();
    print(chat.header('PartyBuffs') .. chat.message('Saved profile ') .. chat.color1(2, name) .. chat.message('.'));
end

local function LoadProfile(name)
    local profile = settings.profiles[name];
    if (profile == nil) then
        return false;
    end
    settings.exclusions = CopyList(profile.exclusions);
    settings.priority   = CopyList(profile.priority);
    settings.active_profile = name;
    memberDisplay.RebuildLookups();
    confUI.invalidate();
    settingLib.save();
    print(chat.header('PartyBuffs') .. chat.message('Loaded profile ') .. chat.color1(2, name) .. chat.message('.'));
    return true;
end

local function DeleteProfile(name)
    settings.profiles[name] = nil;
    for job,profileName in pairs(settings.job_profiles) do
        if (profileName == name) then
            settings.job_profiles[job] = nil;
        end
    end
    if (settings.active_profile == name) then
        settings.active_profile = '';
    end
    settingLib.save();
    print(chat.header('PartyBuffs') .. chat.message('Deleted profile ') .. chat.color1(2, name) .. chat.message('.'));
end

-- Buffs currently on each active party member (for the "Active" tab)
local function GetActiveBuffs()
    local result = {};
    local partyMgr = AshitaCore:GetMemoryManager():GetParty();
    for i = 0,5 do
        if (partyMgr:GetMemberIsActive(i) ~= 0) and ((i == 0) or (partyMgr:GetMemberZone(i) == partyMgr:GetMemberZone(0))) then
            table.insert(result, {
                index = i,
                name  = tostring(partyMgr:GetMemberName(i) or ('Member ' .. i)),
                buffs = memberDisplay.GetBuffs(i),
            });
        end
    end
    return result;
end

local uiHooks = {
    save               = function() settingLib.save(); end,
    rebuild            = function() memberDisplay.RebuildLookups(); end,
    apply_font         = ApplyFonts,
    apply_tp           = tpDisplay.ApplyFonts,
    default_exclusions = DEFAULT_EXCLUSIONS,
    get_active_buffs   = GetActiveBuffs,
    get_icon_themes    = memberDisplay.GetIconThemes,
    get_rings          = memberDisplay.GetRings,
    share_status       = timerShare.Status,
    current_job        = CurrentJob,
    save_profile       = SaveProfile,
    load_profile       = LoadProfile,
    delete_profile     = DeleteProfile,
};

settingLib.register('settings', 'settings_update', function(newSettings)
    settings = newSettings;
    EnsureSettings();
    memberDisplay.RebuildLookups();
    ApplyFonts();
    tpDisplay.ApplyFonts();
end);

ashita.events.register('load', 'load_cb', function ()
    yunaFont.register();   -- before the range text font objects are made
    for i = 0,5 do
        local newMember = memberDisplay:New();
        newMember:Initialize(i);
        partyMembers:append(newMember);
    end
    tpDisplay.Load();
end)

ashita.events.register('unload', 'unload_cb', function ()
    for _,member in ipairs(partyMembers) do
        member:Destroy();
    end
    tpDisplay.Unload();
    yunaFont.unregister();
    pcall(timerShare.Close);
    pcall(buffTimers.Save);
    settingLib.save();   -- keep learned buff durations and party members' buff timers
end)

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    if (e.id == 0x028) then
        pcall(buffTimers.HandleAction, e.data_modified);
    end
end)


local function StringToBuff(buffString)
    local resMgr = AshitaCore:GetResourceManager();
    local compLower = string.lower(buffString);
    for i = 1,1024 do
        local buffName = resMgr:GetString('buffs.names', i);
        if (buffName ~= nil) and (string.lower(buffName) == compLower) then
            return i, buffName;
        end
    end    
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end

    -- The old tparty addon's commands
    if (string.lower(args[1]) == '/tparty') then
        e.blocked = true;
        local rest = {};
        for i = 2,#args do rest[#rest + 1] = args[i]; end
        tpDisplay.Command(rest, confUI.open_tp);
        return;
    end

    if (string.lower(args[1]) ~= '/pb') and (string.lower(args[1]) ~= '/partybuffs') then
        return;
    end
    e.blocked = true;

    -- '/pb', '/partybuffs' or '/pb config' toggles the config window
    if (#args < 2) or (string.lower(args[2]) == 'config') or (string.lower(args[2]) == 'ui') then
        confUI.is_open[1] = not confUI.is_open[1];
        return;
    end
    
    -- /pb profile [name]  -> load a saved profile
    if (string.lower(args[2]) == 'profile') then
        if (#args < 3) then
            print(chat.header('PartyBuffs') .. chat.error('Command format is: ') .. chat.color1(2, '/pb profile [name]') .. chat.error('.'));
            return;
        end
        local name = table.concat(args, ' ', 3);
        if (not LoadProfile(name)) then
            print(chat.header('PartyBuffs') .. chat.error(string.format('No profile named: %s', name)));
        end
        return;
    end

    if (string.lower(args[2]) == 'distance') then
        settings.show_distance = not settings.show_distance;
        settingLib.save();
        print(chat.header('PartyBuffs') .. chat.message('Distance display ') .. chat.color1(2, settings.show_distance and 'enabled' or 'disabled') .. chat.message('.'));
        return;
    end
    
    if (string.lower(args[2]) == 'self') then
        settings.show_self = not settings.show_self;
        settingLib.save();
        print(chat.header('PartyBuffs') .. chat.message('Self display ') .. chat.color1(2, settings.show_self and 'enabled' or 'disabled') .. chat.message('.'));
        return;
    end

    if (string.lower(args[2]) == 'exclusion') then
        if (#args > 2) and (args[3] ~= nil) and (string.lower(args[3]) == 'default') then
            settings.exclusions = T{};
            for _,id in ipairs(DEFAULT_EXCLUSIONS) do
                settings.exclusions:append(id);
            end
            memberDisplay.RebuildLookups();
            settingLib.save();
            return;
        end
        if (#args < 4) then
            print(chat.header('PartyBuffs') .. chat.error('Command format is: ') .. chat.color1(2, '/pb exclusion [add/remove] [buff name]') .. chat.error('.'));
            return;
        elseif (string.lower(args[3]) == 'add') then
            local buffId, buffName = StringToBuff(args[4]);
            if (buffId == nil) then
                print(chat.header('PartyBuffs') .. chat.error(string.format('Could not find a buff named: %s', args[4])));
            elseif (settings.exclusions:contains(buffId)) then
                print(chat.header('PartyBuffs') .. chat.error(string.format('%s was already in your exclusions!', buffName)));
            else
                settings.exclusions:append(buffId);
                memberDisplay.RebuildLookups();
                print(chat.header('PartyBuffs') .. chat.color1(2, buffName) .. chat.message(' added to exclusions.'));
                settingLib.save();
            end
        elseif (string.lower(args[3]) == 'remove') then
            local buffId, buffName = StringToBuff(args[4]);
            if (buffId == nil) then
                print(chat.header('PartyBuffs') .. chat.error(string.format('Could not find a buff named: %s', args[4])));
            elseif (settings.exclusions:contains(buffId)) then
                local newExclusions = T{};
                for _,exclusion in ipairs(settings.exclusions) do
                    if (exclusion ~= buffId) then
                        newExclusions:append(exclusion);
                    end
                end
                settings.exclusions = newExclusions;
                memberDisplay.RebuildLookups();
                print(chat.header('PartyBuffs') .. chat.color1(2, buffName) .. chat.message(' removed from exclusions.'));
                settingLib.save();
            else
                print(chat.header('PartyBuffs') .. chat.error(string.format('%s was not in your exclusions!', buffName)));
            end
        end
    end
    
    if (string.lower(args[2]) == 'priority') then
        if (#args < 4) then
            print(chat.header('PartyBuffs') .. chat.error('Command format is: ') .. chat.color1(2, '/pb priority [add/remove] [buff name]') .. chat.error('.'));
            return;
        elseif (string.lower(args[3]) == 'add') then
            local buffId, buffName = StringToBuff(args[4]);
            if (buffId == nil) then
                print(chat.header('PartyBuffs') .. chat.error(string.format('Could not find a buff named: %s', args[4])));
            elseif (settings.priority:contains(buffId)) then
                print(chat.header('PartyBuffs') .. chat.error(string.format('%s was already in your priorities!', buffName)));
            else
                settings.priority:append(buffId);
                memberDisplay.RebuildLookups();
                print(chat.header('PartyBuffs') .. chat.color1(2, buffName) .. chat.message(' added to priorities.'));
                settingLib.save();
            end
        elseif (string.lower(args[3]) == 'remove') then
            local buffId, buffName = StringToBuff(args[4]);
            if (buffId == nil) then
                print(chat.header('PartyBuffs') .. chat.error(string.format('Could not find a buff named: %s', args[4])));
            elseif (settings.priority:contains(buffId)) then
                local newPrioritys = T{};
                for _,priority in ipairs(settings.priority) do
                    if (priority ~= buffId) then
                        newPrioritys:append(priority);
                    end
                end
                settings.priority = newPrioritys;
                memberDisplay.RebuildLookups();
                print(chat.header('PartyBuffs') .. chat.color1(2, buffName) .. chat.message(' removed from priorities.'));
                settingLib.save();
            else
                print(chat.header('PartyBuffs') .. chat.error(string.format('%s was not in your priorities!', buffName)));
            end
        end
    end

end);

----------------------------------------------------------------------------------------------------
-- Shift + left click drag to move the buff list
----------------------------------------------------------------------------------------------------
local drag = { active = false, start_x = 0, start_y = 0, offset_x = 0, offset_y = 0 };

local function IsShiftDown()
    local ok, down = pcall(function() return imgui.GetIO().KeyShift; end);
    return ok and (down == true);
end

local function ImguiWantsMouse()
    local ok, wants = pcall(function() return imgui.GetIO().WantCaptureMouse; end);
    return ok and (wants == true);
end

local function HitTest(x, y)
    local b = memberDisplay.GetBounds();
    return (b ~= nil) and (x >= b.x1) and (x <= b.x2) and (y >= b.y1) and (y <= b.y2);
end

ashita.events.register('mouse', 'mouse_cb', function (e)
    -- Mouse move
    if (e.message == 512) then
        if drag.active then
            -- Offsets are stored in menu units, so convert the pixel delta back
            settings.list_offset_x = math.floor(drag.offset_x + ((e.x - drag.start_x) / scaling.scaled.w) + 0.5);
            settings.list_offset_y = math.floor(drag.offset_y + ((e.y - drag.start_y) / scaling.scaled.h) + 0.5);
            e.blocked = true;
        end
    -- Left button down
    elseif (e.message == 513) then
        if IsShiftDown() and (not ImguiWantsMouse()) and HitTest(e.x, e.y) then
            drag.active   = true;
            drag.start_x  = e.x;
            drag.start_y  = e.y;
            drag.offset_x = settings.list_offset_x or 0;
            drag.offset_y = settings.list_offset_y or 0;
            e.blocked = true;
        end
    -- Left button up
    elseif (e.message == 514) then
        if drag.active then
            drag.active = false;
            settingLib.save();
            e.blocked = true;
        end
    end
end);

-- Outline of the list while it can be (or is being) dragged, or nil
local function GetDragOutline()
    if (not drag.active) and (not IsShiftDown()) then
        return nil;
    end
    local b = memberDisplay.GetBounds();
    if (b == nil) then
        return nil;
    end
    return { x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, active = drag.active };
end

local lastJob = nil;

ashita.events.register('d3d_present', 'd3d_present_cb', function ()
    -- Auto-load the profile assigned to the current job when it changes
    local job = CurrentJob();
    if (job ~= lastJob) then
        lastJob = job;
        if (job ~= nil) and settings.auto_profile then
            local name = settings.job_profiles[job];
            if (name ~= nil) and (settings.profiles[name] ~= nil) then
                LoadProfile(name);
            end
        end
    end

    -- Test mode only previews while the config window is open
    local testMode = confUI.is_open[1] and confUI.test_mode[1];

    pcall(buffTimers.Update, 0);   -- reads player memory, which can be unavailable while zoning / logging in
    pcall(timerShare.Update);
    memberDisplay.ResetBounds();
    renderer:Begin();
    for _,member in ipairs(partyMembers) do
        member:Render(testMode);
    end
    renderer:End();

    ringOverlay.Draw(memberDisplay.GetRings(), GetDragOutline());
    confUI.render_config_ui(settings, uiHooks);
    tpDisplay.Render(testMode);
end);
