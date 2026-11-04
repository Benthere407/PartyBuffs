--[[
* Buff time tracking for the timer rings.
*
* Self (party index 0): exact time left, read from the client's status timers.
* Other members: the server does not send their buff timers, so time left is estimated from
*   when the buff appeared (or was last recast on them, seen through action packets) and a
*   duration for that buff. Durations come from, in order:
*     1. what we learned watching the buff (your own exact timer when it lands on you, or the
*        longest a buff has lasted on a party member), saved in settings.learned_durations
*     2. the BASE_DURATIONS table below
*   If neither is known, or the buff was already up when we first saw the member (e.g. after
*   loading the addon or zoning), the time left is unknown.
--]]

local timers = {};

local INFINITE_DURATION = 0x7FFFFFFF;
local UTCSTAMP_ID = 'partybuffs:realutcstamp';
local MISSING_GRACE = 1.5;   -- seconds a buff can vanish from memory before we forget it
local RECAST_WINDOW = 5.0;   -- seconds an action packet stays valid while waiting for the buff to show
local MAX_DURATION  = 3 * 60 * 60;

-- Base durations (seconds) for common buffs, used until a better value is learned.
local BASE_DURATIONS = {
    [33]  = 180,  -- Haste
    [36]  = 300,  -- Blink
    [37]  = 300,  -- Stoneskin
    [39]  = 600,  -- Aquaveil
    [40]  = 1800, -- Protect
    [41]  = 1800, -- Shell
    [42]  = 75,   -- Regen
    [43]  = 150,  -- Refresh
    [113] = 3600, -- Reraise
    [116] = 180,  -- Phalanx
    [94]  = 180, [95] = 180, [96] = 180, [97] = 180, [98] = 180, [99] = 180, -- Enspells
    [100] = 180, [101] = 180, [102] = 180, [103] = 180, [104] = 180, [105] = 180, -- Barspells
    [106] = 180, [107] = 180, [108] = 180, [109] = 180, [110] = 180, [111] = 180, -- Barstatus
    [195] = 120, [196] = 120, [197] = 120, [198] = 120, [199] = 120, [200] = 120, -- Songs
    [201] = 120, [214] = 120, [215] = 120, [216] = 120, [218] = 120,
    [219] = 120, [220] = 120, [221] = 120, [222] = 120,
};
for id = 310, 339 do BASE_DURATIONS[id] = 300; end -- Corsair rolls

-- Action messages whose param is a status id the target gained.
local GAIN_MESSAGES = { [194] = true, [205] = true, [230] = true, [236] = true, [237] = true, [266] = true,
                        [268] = true, [270] = true, [271] = true, [280] = true, [319] = true };

local loadTime = os.clock();
local members  = {};   -- [serverId] = { [buffId] = { start, last_seen, unknown } }
local pending  = {};   -- [serverId] = { [buffId] = time an action applied it }
local selfFull = {};   -- [buffId] = longest time left seen on you since it appeared

local function Now()
    return os.clock();
end

----------------------------------------------------------------------------------------------------
-- Learned durations
----------------------------------------------------------------------------------------------------
local function Learned()
    settings.learned_durations = settings.learned_durations or T{};
    return settings.learned_durations;
end

local function GetDuration(id)
    local learned = Learned()[tostring(id)];
    if (learned ~= nil) and (learned > 0) then
        return learned;
    end
    return BASE_DURATIONS[id];
end

local function Learn(id, seconds, replace)
    if (seconds < 3) or (seconds > MAX_DURATION) then
        return;
    end
    seconds = math.floor(seconds + 0.5);
    local learned = Learned();
    local key = tostring(id);
    if replace or (learned[key] == nil) or (seconds > learned[key]) then
        learned[key] = seconds;
    end
end

----------------------------------------------------------------------------------------------------
-- Self timers
----------------------------------------------------------------------------------------------------
local triedPointer = false;

local function GetUtcStamp()
    local pm = AshitaCore:GetPointerManager();
    if (not triedPointer) and (pm:Get(UTCSTAMP_ID) == 0) then
        triedPointer = true;   -- the signature scan is slow, only attempt it once
        pm:Add(UTCSTAMP_ID, 'FFXiMain.dll', '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);
    end
    local ptr = pm:Get(UTCSTAMP_ID);
    if (ptr == 0) then
        return nil;
    end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end
    return ashita.memory.read_uint32(ptr + 0x0C);
end

-- Raw client timer -> seconds left (-1 = permanent, nil = unreadable)
local function RawToSeconds(raw, stamp)
    if (raw == INFINITE_DURATION) then
        return -1;
    end
    local comparand = bit.band((stamp - 0x3C307D70) * 60, 0xFFFFFFFF);
    local left = raw - comparand;
    while (left < -2147483648) do
        left = left + 0xFFFFFFFF;
    end
    if (left < 0) then
        return 0;
    end
    return left / 60;
end

local selfLeft = {};   -- [buffId] = seconds left this frame (-1 permanent)

local function UpdateSelf()
    selfLeft = {};
    local ok, stamp = pcall(GetUtcStamp);
    if (not ok) or (stamp == nil) then
        return;
    end
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local icons  = player:GetStatusIcons();
    local raw    = player:GetStatusTimers();
    for i = 1,32 do
        local id = icons[i];
        if (id == nil) or (id <= 0) or (id == 255) then
            break;
        end
        local left = RawToSeconds(raw[i], stamp);
        -- Same buff more than once (e.g. songs): keep the one lasting longest
        if (selfLeft[id] == nil) or (left == -1) or ((selfLeft[id] ~= -1) and (left > selfLeft[id])) then
            selfLeft[id] = left;
        end
    end

    local now = Now();
    for id,left in pairs(selfLeft) do
        if (left > 0) then
            if (selfFull[id] == nil) then
                -- Freshly applied: its time left right now is its full duration
                if (now - loadTime > 3) then
                    Learn(id, left, true);
                    selfFull[id] = left;
                else
                    selfFull[id] = math.max(left, GetDuration(id) or 0);
                end
            elseif (left > selfFull[id]) then
                selfFull[id] = left;   -- recast
            end
        end
    end
    for id,_ in pairs(selfFull) do
        if (selfLeft[id] == nil) then
            selfFull[id] = nil;
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Party member tracking
----------------------------------------------------------------------------------------------------
local function UpdateMember(serverId, buffs)
    local now = Now();
    local state = members[serverId];
    local firstLook = (state == nil);
    if firstLook then
        state = {};
        members[serverId] = state;
    end
    local applied = pending[serverId] or {};

    for _,id in ipairs(buffs) do
        local entry = state[id];
        local appliedAt = applied[id];
        if (appliedAt ~= nil) and (now - appliedAt > RECAST_WINDOW) then
            appliedAt = nil;
            applied[id] = nil;
        end

        if (entry == nil) then
            entry = { start = appliedAt or now, unknown = firstLook and (appliedAt == nil) };
            state[id] = entry;
        elseif (appliedAt ~= nil) and (appliedAt > entry.start) then
            entry.start = appliedAt;   -- recast while still up
            entry.unknown = false;
        end
        applied[id] = nil;
        entry.last_seen = now;
    end

    -- Forget buffs that are gone, learning how long they lasted
    for id,entry in pairs(state) do
        if (now - entry.last_seen > MISSING_GRACE) then
            if (not entry.unknown) then
                Learn(id, entry.last_seen - entry.start, false);
            end
            state[id] = nil;
        end
    end
end

-- Call once per frame for each member drawn, with that member's raw buff list.
-- Index 0 (self) reads its own timers and ignores `buffs`; call it every frame so durations keep being learned.
function timers.Update(index, buffs)
    if (index == 0) then
        UpdateSelf();
        return;
    end
    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    if (serverId ~= 0) then
        UpdateMember(serverId, buffs);
    end
end

-- Returns seconds left, -1 for permanent buffs, or nil if unknown.
function timers.GetRemaining(index, id)
    if (index == 0) then
        return selfLeft[id];
    end

    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    local state = members[serverId];
    local entry = state and state[id];
    if (entry == nil) or entry.unknown then
        return nil;
    end
    local duration = GetDuration(id);
    if (duration == nil) then
        return nil;
    end
    return math.max(0, duration - (Now() - entry.start));
end

-- Returns time left as a fraction 0..1, -1 for permanent buffs, or nil if unknown.
function timers.GetFraction(index, id)
    if (index == 0) then
        local left = selfLeft[id];
        if (left == nil) then return nil; end
        if (left == -1) then return -1; end
        local full = selfFull[id];
        if (full == nil) or (full <= 0) then return nil; end
        return math.max(0, math.min(1, left / full));
    end

    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    local state = members[serverId];
    local entry = state and state[id];
    if (entry == nil) or entry.unknown then
        return nil;
    end
    local duration = GetDuration(id);
    if (duration == nil) then
        return nil;
    end
    return math.max(0, math.min(1, 1 - ((Now() - entry.start) / duration)));
end

----------------------------------------------------------------------------------------------------
-- Action packets (0x028): note buffs landing on party members so recasts restart their timer
----------------------------------------------------------------------------------------------------
function timers.HandleAction(data)
    local bytes = data:totable();
    local unpack = ashita.bits.unpack_be;
    local targetCount = unpack(bytes, 72, 10);
    local now = Now();
    local offset = 150;
    for _ = 1,targetCount do
        local targetId = unpack(bytes, offset, 32);
        local actionCount = unpack(bytes, offset + 32, 4);
        offset = offset + 36;
        for _ = 1,actionCount do
            local param   = unpack(bytes, offset + 27, 17);
            local message = unpack(bytes, offset + 44, 10);
            local hasAdd  = unpack(bytes, offset + 85, 1) == 1;
            offset = offset + 86;
            if hasAdd then offset = offset + 37; end
            local hasSpike = unpack(bytes, offset, 1) == 1;
            offset = offset + 1;
            if hasSpike then offset = offset + 34; end

            if GAIN_MESSAGES[message] and (param > 0) and (param < 0x400) then
                pending[targetId] = pending[targetId] or {};
                pending[targetId][param] = now;
            end
        end
    end
end

return timers;
