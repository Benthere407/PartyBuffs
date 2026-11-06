local fonts = require('fonts');
local imgui = require('imgui');
local scaling = require('scaling');
local buffTimers = require('bufftimers');
local tpDisplay = require('tpdisplay');
local groups = require('buffgroups');

local partyBuffs = AshitaCore:GetPointerManager():Get('party.statusicons');
partyBuffs = ashita.memory.read_uint32(partyBuffs);

-- [statusId] = { texture = ptr, size = pixel width } for the current theme
local StatusCache = {};
local cachedTheme = nil;

-- Fast set lookups for exclusions / priority (rebuilt via member.RebuildLookups())
local lookups = { exclusions = {}, priority = {} };

local function opt(name, default)
    local v = settings[name];
    if (v == nil) then
        return default;
    end
    return v;
end

-- Key used to detect "the same buff" (by name, so e.g. different IDs sharing a name collapse too).
local keyCache = {};
local function BuffKey(id)
    local key = keyCache[id];
    if (key == nil) then
        local name = AshitaCore:GetResourceManager():GetString('buffs.names', id);
        if (name ~= nil) and (name ~= '') then
            key = string.lower(name);
        else
            key = id;
        end
        keyCache[id] = key;
    end
    return key;
end

local debuffCache = {};
local function IsDebuff(id)
    local v = debuffCache[id];
    if (v == nil) then
        v = groups.is_debuff(id, AshitaCore:GetResourceManager():GetString('buffs.names', id));
        debuffCache[id] = v;
    end
    return v;
end

local function LoadStatusIconFromResource(statusId)
    local resource = AshitaCore:GetResourceManager():GetStatusIconByIndex(statusId);

    if resource then
        local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
        if (ffi.C.D3DXCreateTextureFromFileInMemoryEx(d3d8_device, resource.Bitmap, resource.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0xFF000000, nil, nil, dx_texture_ptr) == ffi.C.S_OK) then
            return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
        end
    end

    return nil;
end

-- Load <addon>\themes\<theme>\<statusId>.png, or nil if the theme has no icon for it.
local function LoadStatusIconFromTheme(theme, statusId)
    local path = ('%s\\themes\\%s\\%d.png'):fmt(addon.path, theme, statusId);
    local handle = io.open(path, 'rb');
    if (handle == nil) then
        return nil;
    end
    handle:close();

    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    if (ffi.C.D3DXCreateTextureFromFileA(d3d8_device, path, dx_texture_ptr) == ffi.C.S_OK) then
        return d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
    end
    return nil;
end

local function TextureSize(texture)
    local ok, res, desc = pcall(function() return texture:GetLevelDesc(0); end);
    if ok and (res == ffi.C.S_OK) and (desc ~= nil) then
        return tonumber(desc.Width);
    end
    return 32;
end

-- Returns { texture, size } for the status icon in the selected theme (falls back to the game's icon).
local function GetStatusIconById(statusId)
    local theme = opt('icon_theme', '');
    if (theme ~= cachedTheme) then
        StatusCache = {};
        cachedTheme = theme;
    end

    local icon = StatusCache[statusId];
    if (icon ~= nil) then
        return icon;
    end

    local texture = nil;
    if (theme ~= '') then
        texture = LoadStatusIconFromTheme(theme, statusId);
    end
    if (texture == nil) then
        texture = LoadStatusIconFromResource(statusId);
    end
    if (texture ~= nil) then
        icon = { texture = texture, size = TextureSize(texture), ptr = tonumber(ffi.cast('uint32_t', texture)) };
        StatusCache[statusId] = icon;
    end

    return icon;
end

-- Names of the icon theme folders under <addon>\themes (for the config UI).
local function GetIconThemes()
    local themes = T{};
    local ok, dirs = pcall(ashita.fs.get_directory, ('%s\\themes\\'):fmt(addon.path));
    if ok and (dirs ~= nil) then
        for _,name in ipairs(dirs) do
            themes:append(name);
        end
    end
    table.sort(themes, function(a, b) return a:lower() < b:lower(); end);
    return themes;
end

local function GetBuffs(index)
    local buffs = T{};
    if (index == 0) then
        local icons = AshitaCore:GetMemoryManager():GetPlayer():GetStatusIcons();
        for i = 1,32 do
            if icons[i] > 0 and icons[i] ~= 255 then
                buffs:append(icons[i]);
            else
                break;
            end
        end
        return buffs;
    end

    -- One of your own characters: its client's list, up to date even when the party list isn't yet
    local sharedList = buffTimers.GetSharedList(index);
    if (sharedList ~= nil) then
        for _,buff in ipairs(sharedList) do
            buffs:append(buff);
        end
        return buffTimers.DropGone(index, buffs);
    end

    local partyMgr = AshitaCore:GetMemoryManager():GetParty();
    local playerId = partyMgr:GetMemberServerId(index)
    for i = 0,4 do
        if partyMgr:GetStatusIconsServerId(i) == playerId then
            local memberPtr = partyBuffs + (0x30 * i);
            for j = 0,31 do
                local highBits = ashita.memory.read_uint8(memberPtr + 8 + (math.floor(j / 4)));
                local fMod = math.fmod(j, 4) * 2;
                highBits = bit.lshift(bit.band(bit.rshift(highBits, fMod), 0x03), 8);
                local lowBits = ashita.memory.read_uint8(memberPtr + 16 + j);
                local buff = highBits + lowBits;
                if (buff == 255) then
                    break;
                else
                    buffs:append(buff);
                end
            end
        end
    end
    return buffTimers.DropGone(index, buffs);
end

-- Sample buffs used by the config UI's test mode: Protect, Shell, Haste, Regen, Refresh, Stoneskin, then
-- Blink, Aquaveil, Phalanx, Reraise, an enspell, a barspell and songs. The first test_buff_count are shown.
local TEST_BUFFS = { 40, 41, 33, 42, 43, 37, 36, 39, 116, 113, 94, 100, 195, 196, 197, 198, 199, 200 };
local TEST_DEBUFFS = { 4, 13, 3, 6 };   -- Paralysis, Slow, Poison, Silence

-- Screen rectangle covering everything drawn this frame (used for shift+drag hit testing).
local bounds = nil;

-- Timer rings to draw this frame: { x, y, size, fraction, seed }
local rings = {};

local function ExtendBounds(x1, y1, x2, y2)
    if (bounds == nil) then
        bounds = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 };
        return;
    end
    bounds.x1 = math.min(bounds.x1, x1);
    bounds.y1 = math.min(bounds.y1, y1);
    bounds.x2 = math.max(bounds.x2, x2);
    bounds.y2 = math.max(bounds.y2, y2);
end

local member = {};

-- Static helper for the config UI: returns a list of buff ids currently on party member `index` (0-5).
member.GetBuffs = GetBuffs;
member.GetIconThemes = GetIconThemes;

-- Call once per frame before rendering members.
function member.ResetBounds()
    bounds = nil;
    rings = {};
end

-- Timer rings collected while rendering this frame (see ringoverlay.lua).
function member.GetRings()
    return rings;
end

-- Returns { x1, y1, x2, y2 } of the area drawn last frame, or nil if nothing was drawn.
function member.GetBounds()
    return bounds;
end

-- Call whenever settings.exclusions / settings.priority change.
function member.RebuildLookups()
    lookups.exclusions = {};
    for _,id in ipairs(settings.exclusions) do
        lookups.exclusions[id] = true;
    end
    lookups.priority = {};
    for _,id in ipairs(settings.priority) do
        lookups.priority[id] = true;
    end
end

function member:New()
    local o = {};
    setmetatable(o, self);
    self.__index = self;
    return o;
end

-- Offsets (in units of "thickness" pixels) for the outline copies drawn around the range text.
-- Ashita's font object has no outline-thickness setting, so the outline is drawn manually as
-- 8 copies of the text in the outline color, behind the main text.
local OUTLINE_DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1}, {-1,-1}, {1,-1}, {-1,1}, {1,1} };

local function ScaledHeight(h)
    return math.floor(scaling.scale_height(h));
end

-- (Re)apply distance font settings from the settings table, scaled to the current resolution.
function member:ApplyFont()
    local fo = settings.distance_object;

    self.FontObject:apply(fo);
    self.FontObject.color_outline = 0x00000000; -- native outline disabled; custom outline is used instead
    self.FontObject.font_height = ScaledHeight(self.FontObject.font_height);

    local outlineColor = opt('distance_outline_color', 0xFF000000);
    for _,o in ipairs(self.Outlines) do
        o:apply(fo);
        o.color = outlineColor;
        o.color_outline = 0x00000000;
        o.font_height = ScaledHeight(o.font_height);
        o.visible = false;
    end
end

function member:Initialize(index)
    self.Index = index;

    -- Outline fonts are created first so they are drawn underneath the main text.
    self.Outlines = {};
    for i = 1,#OUTLINE_DIRS do
        self.Outlines[i] = fonts.new(settings.distance_object);
    end
    self.FontObject = fonts.new(settings.distance_object);
    self:ApplyFont();
end

function member:Destroy()
    for _,o in ipairs(self.Outlines) do
        o:destroy();
    end
    self.FontObject:destroy();
end

function member:HideText()
    self.FontObject.visible = false;
    for _,o in ipairs(self.Outlines) do
        o.visible = false;
    end
end

local function PlaceText(obj, text, x, y)
    obj.position_x = x;
    obj.position_y = y;
    obj.right_aligned = true;
    if (obj.text ~= text) then
        obj.text = text;
    end
    obj.visible = true;
end

-- testMode: draw a full 6 member party with sample buffs, ignoring real party data and filters.
function member:Render(testMode)
    local partyMgr = AshitaCore:GetMemoryManager():GetParty();
    if (not testMode) and (partyMgr:GetMemberIsActive(self.Index) == 0 or (partyMgr:GetMemberZone(self.Index) ~= partyMgr:GetMemberZone(0)) or ((settings.show_self == false) and (self.Index == 0))) then
        self:HideText();
        return;
    end

    -- List position (base anchor + user offset)
    local rowSpacing = scaling.scale_height(opt('row_spacing', 20));
    self.PositionX = scaling.window.w - scaling.scale_width(135) + scaling.scale_width(opt('list_offset_x', 0));
    self.BasePositionY = scaling.window.h - scaling.scale_height(40) + scaling.scale_height(opt('list_offset_y', 0));

    local partyCount = testMode and 6 or partyMgr:GetAlliancePartyMemberCount1();
    self.PositionY = self.BasePositionY - (((partyCount - 1) - self.Index) * rowSpacing);

    --Get member buffs..
    local buffs;
    if (testMode) then
        -- Rotate the sample list per member so each row looks a little different
        buffs = T{};
        -- Debuffs ahead of the buffs: the far end of the row until Debuffs first moves them
        for i = 1,math.min(#TEST_DEBUFFS, opt('test_debuff_count', 0)) do
            buffs:append(TEST_DEBUFFS[i]);
        end
        local count = math.max(1, math.min(#TEST_BUFFS, opt('test_buff_count', 6)));
        for i = 1,count do
            buffs:append(TEST_BUFFS[((i + self.Index - 1) % count) + 1]);
        end
    else
        buffs = GetBuffs(self.Index);
        if (self.Index ~= 0) then
            buffTimers.Update(self.Index, buffs);   -- self is updated once per frame from partybuffs.lua
        end
    end

    local sorted = T{};
    local unique = opt('unique_buffs', true);
    local seen = {};
    for _,buff in ipairs(buffs) do
        if testMode or (not lookups.exclusions[buff]) then
            local skip = false;
            if (unique) then
                local key = BuffKey(buff);
                if (seen[key]) then
                    skip = true;
                else
                    seen[key] = true;
                end
            end
            if (not skip) then
                if (lookups.priority[buff]) then
                    table.insert(sorted, 1, buff);
                else
                    sorted:append(buff);
                end
            end
        end
    end

    -- Debuffs first: enfeebles and debuffs move next to the party list (the right end of the row)
    if opt('debuffs_first', false) then
        local others, debuffs = T{}, T{};
        for _,buff in ipairs(sorted) do
            if IsDebuff(buff) then
                debuffs:append(buff);
            else
                others:append(buff);
            end
        end
        for _,buff in ipairs(debuffs) do
            others:append(buff);
        end
        sorted = others;
    end

    local iconSize = settings.size;
    local iconSpacing = math.max(opt('icon_spacing', 0), -math.floor(iconSize / 2));   -- extra pixels between icons (below 0 = overlap)
    local firstBuffPositionX = self.PositionX - (#sorted * iconSize) - (math.max(0, #sorted - 1) * iconSpacing);
    local buffPositionX = firstBuffPositionX;

    -- Zigzag: every other icon moved down (or up) by this much
    local zigzag = opt('icon_zigzag', false) and opt('icon_zigzag_offset', 8) or 0;
    local textAbove = opt('icon_zigzag_text', 'below');
    -- Which icons move: the 2nd, 4th... normally; the 1st, 3rd... when that puts the first one where it should be
    -- (moving down leaves the first on top, moving up puts it on top)
    local moveFirst = (opt('icon_zigzag_first', 'top') == 'top') == (zigzag < 0);

    --Draw member buffs..
    local debuffRings = opt('ring_debuff', false);
    local showTimers = opt('show_rings', false) or opt('show_timer_text', false) or debuffRings;
    local frontDraw = opt('front_icons', false) and imgui.GetForegroundDrawList() or nil;   -- in front of the party frames
    local copies = {};   -- how many of each buff so far: each copy of a buff has its own timer
    for slot,buff in ipairs(sorted) do
        copies[buff] = (copies[buff] or 0) + 1;
        local nth = (not unique) and copies[buff] or nil;
        -- Counted from the right, next to the party list, so every row's zigzag lines up there
        -- whatever its number of buffs
        local fromRight = #sorted - slot + 1;
        local moved = (zigzag ~= 0) and ((fromRight % 2 == 1) == moveFirst);
        local iconY = self.PositionY + (moved and zigzag or 0);
        local icon = GetStatusIconById(buff);
        if (icon ~= nil) then
            if (frontDraw ~= nil) then
                frontDraw:AddImage(icon.ptr, { buffPositionX, iconY }, { buffPositionX + iconSize, iconY + iconSize });
            else
                renderer:Draw(icon.texture, buffPositionX, iconY, icon.size, iconSize / icon.size);
            end
        end
        if (showTimers) then
            local fraction, remaining;
            if (testMode) then
                -- Each sample buff counts down over 20-45s on a loop (one row in minutes to show both formats)
                local period = 20 + (((slot * 7) + (self.Index * 5)) % 26);
                if (self.Index == 5) then period = period * 20; end
                fraction = 1 - (((os.clock() / period) + (slot * 0.13) + (self.Index * 0.21)) % 1);
                remaining = fraction * period;
            else
                fraction = buffTimers.GetFraction(self.Index, buff, nth);
                remaining = buffTimers.GetRemaining(self.Index, buff, nth);
            end
            table.insert(rings, { x = buffPositionX, y = iconY, size = iconSize, fraction = fraction, remaining = remaining, seed = (self.Index * 0.37) + (slot * 0.61),
                -- overlapping icons in a straight line: every other label a line lower (zigzag icons stagger them already)
                zig = (iconSpacing < 0) and (zigzag == 0) and (fromRight % 2 == 0),
                -- zigzag icons: the timer text of the zig (in line) or zag (moved) icons can go above them
                above = (zigzag ~= 0) and (textAbove == (moved and 'zag' or 'zig')),
                debuff = debuffRings and IsDebuff(buff) });
        end
        buffPositionX = buffPositionX + iconSize + iconSpacing;
    end

    -- Track the drawn area (at least one icon wide so empty rows can still be grabbed)
    ExtendBounds(math.min(firstBuffPositionX, self.PositionX - iconSize), self.PositionY + math.min(0, zigzag), self.PositionX, self.PositionY + iconSize + math.max(0, zigzag));

    --Update distance if necessary..
    if (settings.show_distance) and ((self.Index ~= 0) or opt('show_self_distance', false)) then
        local entityDistance = nil;
        if (self.Index == 0) then
            entityDistance = 0;   -- you are always 0.0 from yourself
        elseif (testMode) then
            entityDistance = 2.5 + (self.Index * 3.1);
        else
            local entityIndex = partyMgr:GetMemberTargetIndex(self.Index);
            local entMgr = AshitaCore:GetMemoryManager():GetEntity();
            local renderFlags = entMgr:GetRenderFlags0(entityIndex);
            if (bit.band(renderFlags, 0x200) == 0x200) and (bit.band(renderFlags, 0x4000) == 0) then
                entityDistance = math.sqrt(entMgr:GetDistance(entityIndex));
            end
        end
        if (entityDistance ~= nil) then
            local offsetX = scaling.scale_width(opt('distance_offset_x', 0));
            local offsetY = scaling.scale_height(opt('distance_offset_y', 0));

            local x;
            if (opt('distance_fixed', false)) then
                -- Fixed: anchored to the right edge of the buff row, independent of buff count
                x = self.PositionX + offsetX;
            else
                -- Follow: sits just left of the first buff
                x = firstBuffPositionX - 5 + offsetX;
            end
            local y = self.PositionY + offsetY;

            local text = string.format('%.' .. tostring(opt('distance_decimals', 1)) .. 'f', entityDistance);

            local thickness = opt('distance_outline_thickness', 1);
            if opt('front_distance', false) and tpDisplay.can_front then
                self:HideText();
                tpDisplay.draw_text(text, settings.distance_object.color, x, y, self.FontObject.font_height, settings.distance_object,
                    { border_size = thickness, border_color = opt('distance_outline_color', 0xFF000000) });
                return;
            end
            for i,o in ipairs(self.Outlines) do
                if (thickness > 0) then
                    local dir = OUTLINE_DIRS[i];
                    PlaceText(o, text, x + (dir[1] * thickness), y + (dir[2] * thickness));
                else
                    o.visible = false;
                end
            end
            PlaceText(self.FontObject, text, x, y);
            return;
        end
    end

    self:HideText();
end

return member;
