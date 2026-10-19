local fonts = require('fonts');
local scaling = require('scaling');

local partyBuffs = AshitaCore:GetPointerManager():Get('party.statusicons');
partyBuffs = ashita.memory.read_uint32(partyBuffs);

local StatusCache = {};

-- Fast set lookups for exclusions / priority (rebuilt via member.RebuildLookups())
local lookups = { exclusions = {}, priority = {} };

local function opt(name, default)
    local v = settings[name];
    if (v == nil) then
        return default;
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

local function GetStatusIconById(statusId)
    local icon = StatusCache[statusId];
    if (icon ~= nil) then
        return icon;
    end
    
    icon = LoadStatusIconFromResource(statusId);
    if (icon ~= nil) then
        StatusCache[statusId] = icon;
    end

    return icon;
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
    return buffs;
end

local member = {};

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

-- (Re)apply distance font settings from the settings table, scaled to the current resolution.
function member:ApplyFont()
    self.FontObject:apply(settings.distance_object);
    self.FontObject.font_height = math.floor(scaling.scale_height(self.FontObject.font_height));
end

function member:Initialize(index)
    self.Index = index;
    self.FontObject = fonts.new(settings.distance_object);
    self.FontObject.font_height = math.floor(scaling.scale_height(self.FontObject.font_height));
end

function member:Destroy()
    self.FontObject:destroy();
end

function member:Render()
    local partyMgr = AshitaCore:GetMemoryManager():GetParty();
    if partyMgr:GetMemberIsActive(self.Index) == 0 or (partyMgr:GetMemberZone(self.Index) ~= partyMgr:GetMemberZone(0)) or ((settings.show_self == false) and (self.Index == 0)) then
        self.FontObject.visible = false;
        return;
    end

    -- List position (base anchor + user offset)
    local rowSpacing = scaling.scale_height(opt('row_spacing', 20));
    self.PositionX = scaling.window.w - scaling.scale_width(135) + scaling.scale_width(opt('list_offset_x', 0));
    self.BasePositionY = scaling.window.h - scaling.scale_height(40) + scaling.scale_height(opt('list_offset_y', 0));

    local partyCount = partyMgr:GetAlliancePartyMemberCount1();
    self.PositionY = self.BasePositionY - (((partyCount - 1) - self.Index) * rowSpacing);

    --Get member buffs..
    local buffs = GetBuffs(self.Index);

    local sorted = T{};
    for _,buff in ipairs(buffs) do
        if (lookups.priority[buff]) and (not lookups.exclusions[buff]) then
            table.insert(sorted, 1, buff);
        elseif (not lookups.exclusions[buff]) then
            sorted:append(buff);
        end
    end

    local iconSize = settings.size;
    local firstBuffPositionX = self.PositionX - (#sorted * iconSize);
    local buffPositionX = firstBuffPositionX;

    --Draw member buffs..
    for _,buff in ipairs(sorted) do
        local icon = GetStatusIconById(buff);
        if (icon ~= nil) then
            renderer:Draw(icon, buffPositionX, self.PositionY, iconSize / 32);
        end
        buffPositionX = buffPositionX + iconSize;
    end

    --Update distance if necessary..
    if (settings.show_distance) and (self.Index ~= 0) then
        local entityIndex = partyMgr:GetMemberTargetIndex(self.Index);
        local entMgr = AshitaCore:GetMemoryManager():GetEntity();
        local renderFlags = entMgr:GetRenderFlags0(entityIndex);
        if (bit.band(renderFlags, 0x200) == 0x200) and (bit.band(renderFlags, 0x4000) == 0) then        
            local entityDistance = math.sqrt(entMgr:GetDistance(entityIndex));
            local offsetX = scaling.scale_width(opt('distance_offset_x', 0));
            local offsetY = scaling.scale_height(opt('distance_offset_y', 0));

            if (opt('distance_fixed', false)) then
                -- Fixed: anchored to the right edge of the buff row, independent of buff count
                self.FontObject.position_x = self.PositionX + offsetX;
            else
                -- Follow: sits just left of the first buff
                self.FontObject.position_x = firstBuffPositionX - 5 + offsetX;
            end
            self.FontObject.position_y = self.PositionY + offsetY;
            self.FontObject.right_aligned = true;
            self.FontObject.text = string.format('%.' .. tostring(opt('distance_decimals', 1)) .. 'f', entityDistance);
            self.FontObject.visible = true;
            return;
        end
    end

    self.FontObject.visible = false;
end

return member;
