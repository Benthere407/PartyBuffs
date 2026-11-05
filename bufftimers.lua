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
*   If neither is known, or the buff was already up when we first saw the member (e.g. joining a
*   party), the time left is unknown. Start times are saved on unload so a reload carries on, and
*   zoning or a member being in another zone doesn't restart them.
* Your other clients: exact, sent by that client itself (timershare.lua), while it keeps sending.
--]]

local timers = {};

local INFINITE_DURATION = 0x7FFFFFFF;
local UTCSTAMP_ID = 'partybuffs:realutcstamp';
local MISSING_GRACE = 1.5;   -- seconds a buff can vanish from memory before we forget it
local RECAST_WINDOW = 5.0;   -- seconds an action packet stays valid while waiting for the buff to show
local MAX_DURATION  = 3 * 60 * 60;
local GAP           = 2.0;    -- seconds without an update for a member that count as not watching them
local EMPTY_GRACE   = 10.0;   -- seconds a member's whole buff list can be empty before we forget their buffs
local OVERDUE       = 10.0;   -- seconds a buff can outlast its expected duration before its time counts as unknown
local SHARED_STALE  = 3.0;    -- seconds without a message from a client before going back to estimating

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
local shared   = {};   -- [serverId] = { heard, buffs = { [buffId] = { left, full, at } } }, from your other clients

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
-- A buff is gone: learn how long it lasted, unless that isn't known for sure
local function Forget(state, id, entry)
    if (not entry.unknown) and (not entry.no_learn) then
        local lasted = entry.last_seen - entry.start;
        local duration = GetDuration(id);
        -- (far longer than expected = it was probably recast where we couldn't see it)
        if (duration == nil) or (lasted < duration * 2) then
            Learn(id, lasted, false);
        end
    end
    state.buffs[id] = nil;
end

-- Buffs tracked before the addon was last unloaded: [serverId] = { [buffId] = start as os.time() }
local restored = nil;
local function Restored()
    if (restored == nil) then
        restored = {};
        local now = os.time();
        for sid,list in pairs(settings.tracked_buffs or {}) do
            for id,start in pairs(list) do
                if (type(start) == 'number') and (now - start < MAX_DURATION) then
                    restored[tonumber(sid)] = restored[tonumber(sid)] or {};
                    restored[tonumber(sid)][tonumber(id)] = start;
                end
            end
        end
    end
    return restored;
end

-- Buffs recast between two looks at a member's list, found without seeing the action (e.g. cast out
-- of range): the server drops a recast buff and adds it again at the end of the list, so it either
-- moves behind buffs it used to be in front of, or vanishes and comes back. (A recast of the buff
-- that is already last changes nothing, so it can't be seen.)
local function Recast(old, new)
    local found = {};
    if (old == nil) or (#old == 0) then
        return found;
    end
    local inOld, inNew = {}, {};
    for _,id in ipairs(old) do inOld[id] = true; end
    for _,id in ipairs(new) do inNew[id] = true; end

    -- Came back after vanishing (gone from the last list, but we still remember it)
    for _,id in ipairs(new) do
        if (not inOld[id]) then found[id] = true; end
    end

    -- Moved: walk both lists (only buffs in both), anything out of step in the old order moved back
    local keptNew = {};
    for _,id in ipairs(new) do
        if inOld[id] then keptNew[#keptNew + 1] = id; end
    end
    local j = 1;
    for _,id in ipairs(old) do
        if inNew[id] then
            if (keptNew[j] == id) then
                j = j + 1;
            else
                found[id] = true;
            end
        end
    end
    return found;
end

local function UpdateMember(serverId, buffs)
    local now = Now();
    local state = members[serverId];
    if (state == nil) then
        state = { buffs = {}, updated = now, first = now };
        members[serverId] = state;
    end
    -- First look at this member: buffs already up have an unknown start (unless saved before a reload).
    -- Lasts until their list first loads, or a short while if they have no buffs.
    local firstLook = (state.first ~= nil) and (now - state.first < EMPTY_GRACE);

    -- Not watched for a while (zoning, member in another zone, row hidden): what vanished then
    -- doesn't count as wearing off, and how long those buffs lasted is not known
    if (now - state.updated > GAP) then
        for _,entry in pairs(state.buffs) do
            entry.last_seen = now;
            entry.no_learn = true;
        end
    end
    state.updated = now;

    -- An empty list right after a gap is usually the party data not loaded yet: wait for it
    if (#buffs == 0) then
        for id,entry in pairs(state.buffs) do
            if (now - entry.last_seen > EMPTY_GRACE) then
                Forget(state, id, entry);
            end
        end
        return;
    end

    local applied = pending[serverId] or {};
    local saved = firstLook and Restored()[serverId] or nil;
    state.first = nil;
    local recast = Recast(state.order, buffs);
    state.order = buffs;

    for _,id in ipairs(buffs) do
        local entry = state.buffs[id];
        local appliedAt = applied[id];
        if (appliedAt ~= nil) and (now - appliedAt > RECAST_WINDOW) then
            appliedAt = nil;
            applied[id] = nil;
        end

        if (entry == nil) then
            local savedStart = saved and saved[id];
            if (appliedAt == nil) and (savedStart ~= nil) then
                -- Up before the addon was reloaded: carry on from when it started
                entry = { start = now - (os.time() - savedStart), unknown = false };
            else
                entry = { start = appliedAt or now, unknown = firstLook and (appliedAt == nil) };
            end
            state.buffs[id] = entry;
        elseif (appliedAt ~= nil) and (appliedAt > entry.start) then
            entry.start = appliedAt;   -- recast while still up
            entry.unknown = false;
            entry.no_learn = nil;
        elseif recast[id] then
            entry.start = now;         -- recast where we couldn't see the action (moved to the end of their list)
            entry.unknown = false;
            entry.no_learn = nil;
        end
        applied[id] = nil;
        entry.last_seen = now;
    end

    -- Forget buffs that are gone, learning how long they lasted
    for id,entry in pairs(state.buffs) do
        if (now - entry.last_seen > MISSING_GRACE) then
            Forget(state, id, entry);
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

-- A party member's buff: elapsed seconds and its duration, or nil if unknown
local function MemberElapsed(index, id)
    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    local state = members[serverId];
    local entry = state and state.buffs[id];
    if (entry == nil) or entry.unknown then
        return nil;
    end
    local duration = GetDuration(id);
    if (duration == nil) then
        return nil;
    end
    local elapsed = Now() - entry.start;
    if (elapsed > duration + OVERDUE) then
        return nil;   -- still up well past its time: recast where we couldn't see it, or it lasts longer here
    end
    return elapsed, duration;
end

-- Keep party members' buff start times in settings, so a reload (or logging back in soon) carries on
-- from them instead of showing those buffs as unknown. Call before saving settings on unload.
function timers.Save()
    local out = T{};
    local wall, now = os.time(), Now();
    for sid,state in pairs(members) do
        local list = T{};
        for id,entry in pairs(state.buffs) do
            if (not entry.unknown) then
                list[tostring(id)] = math.floor(wall - (now - entry.start) + 0.5);
            end
        end
        if (next(list) ~= nil) then
            out[tostring(sid)] = list;
        end
    end
    settings.tracked_buffs = out;
end

----------------------------------------------------------------------------------------------------
-- Timers from your other clients (timershare.lua)
----------------------------------------------------------------------------------------------------
-- Your own timers, to send: [buffId] = seconds left (-1 permanent), [buffId] = full duration
function timers.GetOwn()
    return selfLeft, selfFull;
end

-- Another client's timers: buffs = { [buffId] = { left, full } }, all the timers that client has
function timers.SetShared(serverId, buffs)
    local now = Now();
    local list = {};
    for id,buff in pairs(buffs) do
        if (buff.left == -1) or ((buff.left > 0) and (buff.left <= buff.full)) then
            buff.at = now;
            list[id] = buff;
            if (buff.left > 0) then
                Learn(id, buff.full, false);
                -- Keep the estimate level with it, so it carries on from here if this client goes quiet
                local state = members[serverId];
                local entry = state and state.buffs[id];
                local duration = GetDuration(id);
                if (entry ~= nil) and (duration ~= nil) then
                    entry.start = now - math.max(0, duration - buff.left);
                    entry.unknown = false;
                    entry.no_learn = true;
                end
            end
        end
    end
    shared[serverId] = { heard = now, buffs = list };
end

-- A party member's buff as sent by their client: seconds left and full duration (-1 for permanent), or nil
local function SharedLeft(index, id)
    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    local client = shared[serverId];
    local buff = client and client.buffs[id];
    if (buff == nil) or (Now() - client.heard > SHARED_STALE) then
        return nil;
    end
    if (buff.left == -1) then
        return -1, -1;
    end
    return math.max(0, buff.left - (Now() - buff.at)), buff.full;
end

-- Returns seconds left, -1 for permanent buffs, or nil if unknown.
function timers.GetRemaining(index, id)
    if (index == 0) then
        return selfLeft[id];
    end
    local left = SharedLeft(index, id);
    if (left ~= nil) then
        return left;
    end
    local elapsed, duration = MemberElapsed(index, id);
    if (elapsed == nil) then
        return nil;
    end
    return math.max(0, duration - elapsed);
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

    local left, full = SharedLeft(index, id);
    if (left == -1) then
        return -1;
    elseif (left ~= nil) then
        return math.max(0, math.min(1, left / full));
    end

    local elapsed, duration = MemberElapsed(index, id);
    if (elapsed == nil) then
        return nil;
    end
    return math.max(0, math.min(1, 1 - (elapsed / duration)));
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
