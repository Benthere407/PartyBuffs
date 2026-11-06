--[[
* Buff time tracking for the timer rings.
*
* Self (party index 0): exact time left, read from the client's status timers.
* Your other clients: exact, sent by that client itself (timershare.lua), while it keeps sending.
* Other members: the server does not send their buff timers, so time left is estimated from
*   when the buff appeared (or was last recast on them, seen through action packets) and a
*   duration for that buff. Durations come from, in order:
*     1. a length measured for that caster, job and spell (durations.lua, shared by your characters)
*     2. the length any caster's cast of that spell was last measured at
*     3. what we learned watching the buff (your own exact timer when it lands on you, or the
*        longest a buff has lasted on a party member), saved in settings.learned_durations
*     4. the BASE_DURATIONS table below
*   If none is known, or the buff was already up when we first saw the member (e.g. joining a
*   party), the time left is unknown. Start times are saved on unload so a reload carries on, and
*   zoning or a member being in another zone doesn't restart them.
*
* A length is measured when a cast seen in an action packet lands on a character with exact timers.
* Enhancing spells under Composure last about 3 times longer on the caster, so those are kept apart.
--]]

local durations = require('durations');

local timers = {};

local INFINITE_DURATION = 0x7FFFFFFF;
local WRAP          = 0x100000000;   -- the game's timers wrap at 32 bits
local UTCSTAMP_ID = 'partybuffs:realutcstamp';
local MISSING_GRACE = 1.5;   -- seconds a buff can vanish from memory before we forget it
local RECAST_WINDOW = 5.0;   -- seconds an action packet stays valid while waiting for the buff to show
local MAX_DURATION  = 3 * 60 * 60;
local GAP           = 2.0;    -- seconds without an update for a member that count as not watching them
local EMPTY_GRACE   = 10.0;   -- seconds a member's whole buff list can be empty before we forget their buffs
local OVERDUE       = 10.0;   -- seconds a buff can outlast its expected duration before its time counts as unknown
local SHARED_STALE  = 3.0;    -- seconds without a message from a client before going back to estimating
local MATCH_WINDOW  = 4.0;    -- seconds apart a cast and a new timer can be (the timer can come first)
local DIFF_EVERY    = 0.25;   -- seconds between looks for new timers on you
local GONE_HOLD     = 3.0;    -- seconds a buff stays off a member after its wear off message, while their list catches up
local COMPOSURE     = 419;
local COMPOSURE_X   = 3;
local ENHANCING     = 34;     -- spell skill

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
-- Messages whose param is a status id the target lost.
local LOSE_MESSAGES = { [64] = true, [83] = true, [159] = true, [168] = true, [204] = true, [206] = true, [321] = true,
                        [322] = true, [341] = true, [342] = true, [343] = true, [344] = true, [350] = true, [378] = true,
                        [531] = true, [647] = true, [805] = true, [806] = true };

local loadTime = os.clock();
local members  = {};   -- [serverId] = { [buffId] = { start, last_seen, unknown, duration, actor, action } }
local pending  = {};   -- [serverId] = { [buffId] = { at, duration, actor, action }, an action applied it }
local selfFull = {};   -- [buffId] = longest time left seen on you since it appeared
local shared   = {};   -- [serverId] = { heard, list, arr = { [buffId] = { seconds left, one per icon } }, buffs = { [buffId] = { full, longest } } }
local casts    = {};   -- { { t, target, buff, actor, action, enhancing, name, job, composure } }, waiting for an exact timer
local fresh    = {};   -- [serverId] = { { buff, left, t } }, new exact timers waiting for a cast
local gone     = {};   -- [serverId] = { [buffId] = { at, base, count } }, wear off messages their list hasn't caught up with

local function Now()
    return os.clock();
end

-- /pb timerlog: what the timers see, written to a file
local logFile, logSnapshot = nil, 0;
local function Log(text, ...)
    if (logFile ~= nil) then
        logFile:write(os.date('%H:%M:%S '), text:format(...), '\n');
        logFile:flush();
    end
end

-- Starts a log at `path`, or stops it with nil. Returns true if logging.
function timers.SetLog(path)
    if (logFile ~= nil) then
        logFile:close();
        logFile = nil;
    end
    if (path ~= nil) then
        logFile = io.open(path, 'a');
    end
    return logFile ~= nil;
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
    if (raw < 0) then
        raw = raw + WRAP;
    end
    if (raw == INFINITE_DURATION) then
        return -1;
    end
    local left = raw - (((stamp - 0x3C307D70) * 60) % WRAP);
    if (left < -2147483648) then
        left = left + WRAP;
    elseif (left > 2147483647) then
        left = left - WRAP;
    end
    if (left < 0) then
        return 0;
    end
    return left / 60;
end

-- New timers between two readings of someone's buffs: one that isn't an old timer counted down just landed
-- or was renewed. arr = { [buffId] = { seconds left, one per icon } }. Returns { { buff, left } }
local function Diff(oldArr, oldTime, arr, now)
    local out = {};
    if (oldArr == nil) then
        return out;
    end
    local passed = now - oldTime;
    for id,list in pairs(arr) do
        local was = {};
        for _,left in ipairs(oldArr[id] or {}) do
            was[#was + 1] = left - passed;
        end
        for _,left in ipairs(list) do
            local hit = nil;
            for i,old in ipairs(was) do
                if (math.abs(left - old) < 3) then
                    hit = i;
                    break;
                end
            end
            if (hit ~= nil) then
                table.remove(was, hit);
            elseif (left > 5) then
                out[#out + 1] = { id, left };
            end
        end
    end
    return out;
end

local function NoteFresh(serverId, new, now)
    if (#new == 0) then
        return;
    end
    local list = fresh[serverId] or {};
    fresh[serverId] = list;
    for _,item in ipairs(new) do
        list[#list + 1] = { buff = item[1], left = item[2], t = now };
        Log('new timer: member %s buff %d left %.1f', tostring(serverId), item[1], item[2]);
    end
end

local selfLeft = {};   -- [buffId] = seconds left this frame (-1 permanent), the longest if there are several
local selfArr  = {};   -- [buffId] = { seconds left, one per icon in the game's order }
local selfList = {};   -- your buffs in the game's order
local diffArr, diffTime = nil, 0;

local function UpdateSelf()
    selfLeft, selfArr, selfList = {}, {}, {};
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
        selfList[#selfList + 1] = id;
        selfArr[id] = selfArr[id] or {};
        table.insert(selfArr[id], left);
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
                    -- (Composure stretches your own spells: not this buff's usual length)
                    if (selfLeft[COMPOSURE] == nil) then
                        Learn(id, left, true);
                    end
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

    if (now - diffTime >= DIFF_EVERY) then
        local new = Diff(diffArr, diffTime, selfArr, now);
        diffArr, diffTime = selfArr, now;
        NoteFresh(AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0), new, now);
        for _,item in ipairs(new) do
            if (item[2] >= selfLeft[item[1]]) then
                selfFull[item[1]] = item[2];   -- renewed, maybe shorter than it was
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Lengths by caster
----------------------------------------------------------------------------------------------------
-- An actor's party or alliance slot: name and main job, or nil if they're not in it
local function FindMember(serverId)
    local party = AshitaCore:GetMemoryManager():GetParty();
    for i = 0,17 do
        if (party:GetMemberIsActive(i) ~= 0) and (party:GetMemberServerId(i) == serverId) then
            return (tostring(party:GetMemberName(i) or ''):gsub('%W', '')), party:GetMemberMainJob(i) or 0;
        end
    end
    return nil;
end

local function HasComposure(serverId)
    if (serverId == AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)) then
        return selfLeft[COMPOSURE] ~= nil;
    end
    local client = shared[serverId];
    if (client ~= nil) and (Now() - client.heard <= SHARED_STALE) then
        return client.arr[COMPOSURE] ~= nil;
    end
    local state = members[serverId];
    return (state ~= nil) and (state.buffs[COMPOSURE] ~= nil);
end

local function IsEnhancing(spell)
    local ok, skill = pcall(function()
        return AshitaCore:GetResourceManager():GetSpellById(spell).Skill;
    end);
    return ok and (skill == ENHANCING);
end

local function CasterKey(cast, where)
    return ('%s:%d:%s:%s'):format(cast.name, cast.job, cast.action, where);
end

-- The length a cast should last, or nil if nothing better than the buff's own length is known
local function FindLength(cast)
    local length = nil;
    if (cast.name ~= nil) then
        local onSelf = durations.get(CasterKey(cast, 's'));
        local onOther = durations.get(CasterKey(cast, 'o'));
        local composed = durations.get(CasterKey(cast, 'c'));
        local third = composed and math.floor((composed / COMPOSURE_X) + 0.5);
        if (cast.actor ~= cast.target) then
            length = onOther or onSelf or third;
        elseif cast.composure then
            length = composed or ((onSelf or onOther) and ((onSelf or onOther) * COMPOSURE_X));
        else
            length = onSelf or onOther or third;
        end
    end
    return length or durations.get('*:' .. cast.action);
end

-- A cast landed on someone with exact timers: keep its real length
local function Measured(cast, seconds)
    seconds = math.floor(seconds + 0.5);
    Log('measured: %s action %s buff %d on %s = %d', tostring(cast.name), cast.action, cast.buff, tostring(cast.target), seconds);
    local usual = cast.composure and math.floor((seconds / COMPOSURE_X) + 0.5) or seconds;
    if (usual < 3) or (usual > MAX_DURATION) then
        return;
    end
    if (cast.name ~= nil) then
        local where = (cast.actor ~= cast.target) and 'o' or (cast.composure and 'c' or 's');
        durations.set(CasterKey(cast, where), seconds);
    end
    durations.set('*:' .. cast.action, usual);

    -- The same cast on the others (a -ra, a song) landed before this was known
    for _,state in pairs(members) do
        local entry = state.buffs[cast.buff];
        if (entry ~= nil) and (entry.actor == cast.actor) and (entry.action == cast.action)
            and (math.abs(entry.start - cast.t) < MATCH_WINDOW) then
            entry.duration = usual;
        end
    end
end

-- Pairs casts with the new exact timers they made
local function Resolve(now)
    for i = #casts,1,-1 do
        local cast = casts[i];
        local list = fresh[cast.target];
        local hit = nil;
        for j,item in ipairs(list or {}) do
            if (item.buff == cast.buff) and (math.abs(item.t - cast.t) < MATCH_WINDOW) then
                hit = j;
                break;
            end
        end
        if (hit ~= nil) then
            local item = table.remove(list, hit);
            table.remove(casts, i);
            Measured(cast, item.left + math.max(0, item.t - cast.t));
        elseif (now - cast.t > MATCH_WINDOW) then
            table.remove(casts, i);
        end
    end
    for serverId,list in pairs(fresh) do
        for j = #list,1,-1 do
            if (now - list[j].t > MATCH_WINDOW) then
                table.remove(list, j);
            end
        end
        if (#list == 0) then
            fresh[serverId] = nil;
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
        local cast = applied[id];
        if (cast ~= nil) and (now - cast.at > RECAST_WINDOW) then
            cast = nil;
            applied[id] = nil;
        end

        if (entry == nil) then
            local savedStart = saved and saved[id];
            if (cast == nil) and (savedStart ~= nil) then
                -- Up before the addon was reloaded: carry on from when it started
                entry = { start = now - (os.time() - savedStart), unknown = false };
            else
                entry = { start = cast and cast.at or now, unknown = firstLook and (cast == nil) };
            end
            if (cast ~= nil) then
                entry.duration, entry.actor, entry.action = cast.duration, cast.actor, cast.action;
            end
            state.buffs[id] = entry;
        elseif (cast ~= nil) and (cast.at > entry.start) then
            entry.start = cast.at;     -- recast while still up
            entry.unknown = false;
            entry.no_learn = nil;
            entry.duration, entry.actor, entry.action = cast.duration, cast.actor, cast.action;
        elseif recast[id] then
            entry.start = now;         -- recast where we couldn't see the action (moved to the end of their list)
            entry.unknown = false;
            entry.no_learn = nil;
            entry.duration, entry.actor, entry.action = nil, nil, nil;
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

-- A party member's client, if it has been heard from lately
local function FreshClient(serverId)
    local client = shared[serverId];
    if (client ~= nil) and (Now() - client.heard <= SHARED_STALE) then
        return client;
    end
    return nil;
end

local function WriteSnapshot(now)
    local party = AshitaCore:GetMemoryManager():GetParty();
    for id,lefts in pairs(selfArr) do
        Log('self: buff %d left %s full %s', id, table.concat(lefts, ' '), tostring(selfFull[id]));
    end
    for i = 1,5 do
        local serverId = party:GetMemberServerId(i);
        if (serverId ~= 0) then
            local client = FreshClient(serverId);
            for id,buff in pairs(client and client.buffs or {}) do
                Log('member %d shared: buff %d left %.1f full %.1f', i, id, buff.longest - (now - client.heard), buff.full);
            end
            local state = members[serverId];
            for id,entry in pairs(state and state.buffs or {}) do
                Log('member %d estimate: buff %d elapsed %.1f duration %s general %s unknown %s', i, id, now - entry.start,
                    tostring(entry.duration), tostring(GetDuration(id)), tostring(entry.unknown));
            end
        end
    end
end

-- Call once per frame for each member drawn, with that member's raw buff list.
-- Index 0 (self) reads its own timers and ignores `buffs`; call it every frame so durations keep being learned.
function timers.Update(index, buffs)
    if (index == 0) then
        UpdateSelf();
        Resolve(Now());
        durations.Update();
        if (logFile ~= nil) and (Now() - logSnapshot >= 5) then
            logSnapshot = Now();
            WriteSnapshot(logSnapshot);
        end
        return;
    end
    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    if (serverId ~= 0) then
        UpdateMember(serverId, buffs);
        if (FreshClient(serverId) ~= nil) then
            members[serverId].order = nil;   -- (their client's order, not the party list's: no use for spotting recasts)
        end
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
    local duration = entry.duration or GetDuration(id);
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
    durations.save();
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
-- Your own timers, to send: [buffId] = { seconds left, one per icon }, [buffId] = full duration, your buffs in order
function timers.GetOwn()
    return selfArr, selfFull, selfList;
end

-- Another client's timers. arr = { [buffId] = { seconds left, one per icon } }, fulls = { [buffId] = full duration },
-- list = its buffs in the game's order
function timers.SetShared(serverId, arr, fulls, list)
    local now = Now();
    local old = shared[serverId];
    local client = { heard = now, arr = {}, buffs = {}, list = list };

    for id,lefts in pairs(arr) do
        local longest = nil;
        for _,left in ipairs(lefts) do
            if (longest == nil) or (left == -1) or ((longest ~= -1) and (left > longest)) then
                longest = left;
            end
        end
        local full = fulls[id] or 0;
        if (longest == -1) or ((longest ~= nil) and (longest > 0) and (longest <= full)) then
            client.arr[id] = lefts;
            client.buffs[id] = { full = full, longest = longest };
            if (longest > 0) then
                if (arr[COMPOSURE] == nil) then
                    Learn(id, full, false);
                end
                -- Keep the estimate level with it, so it carries on from here if this client goes quiet
                local state = members[serverId];
                local entry = state and state.buffs[id];
                if (entry ~= nil) then
                    entry.start = now - (full - longest);
                    entry.duration = full;
                    entry.unknown = false;
                    entry.no_learn = true;
                end
            end
        end
    end

    if (old ~= nil) and (now - old.heard <= SHARED_STALE) then
        NoteFresh(serverId, Diff(old.arr, old.heard, client.arr, now), now);
    end
    shared[serverId] = client;
end

-- A party member's buff list as their client sent it, or nil
function timers.GetSharedList(index)
    local client = FreshClient(AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index));
    if (client ~= nil) and (client.list ~= nil) and (#client.list > 0) then
        return client.list;
    end
    return nil;
end

-- A party member's buff as sent by their client: seconds left and full duration (-1 for permanent), or nil.
-- nth = which icon of that buff; nil = the one lasting longest
local function SharedLeft(index, id, nth)
    local client = FreshClient(AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index));
    local buff = client and client.buffs[id];
    if (buff == nil) then
        return nil;
    end
    local left = (nth ~= nil) and client.arr[id][nth] or buff.longest;
    if (left == -1) then
        return -1, -1;
    end
    return math.max(0, left - (Now() - client.heard)), buff.full;
end

-- Returns seconds left, -1 for permanent buffs, or nil if unknown.
-- nth = which icon of a buff shown more than once; nil = the one lasting longest
function timers.GetRemaining(index, id, nth)
    if (index == 0) then
        return (nth ~= nil) and selfArr[id] and selfArr[id][nth] or selfLeft[id];
    end
    local left = SharedLeft(index, id, nth);
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
function timers.GetFraction(index, id, nth)
    if (index == 0) then
        local left = (nth ~= nil) and selfArr[id] and selfArr[id][nth] or selfLeft[id];
        if (left == nil) then return nil; end
        if (left == -1) then return -1; end
        local full = selfFull[id];
        if (full == nil) or (full <= 0) then return nil; end
        return math.max(0, math.min(1, left / full));
    end

    local left, full = SharedLeft(index, id, nth);
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
-- Wear off messages: a buff leaves its member now, not at their next list update
----------------------------------------------------------------------------------------------------
local function NoteGone(serverId, id)
    if (FindMember(serverId) == nil) then
        return;
    end
    Log('wears off: member %s buff %d', tostring(serverId), id);
    local list = gone[serverId] or {};
    gone[serverId] = list;
    local item = list[id];
    if (item == nil) then
        list[id] = { at = Now(), count = 1 };
    else
        item.at = Now();
        item.count = item.count + 1;
    end
end

-- Takes buffs off a member's list that a wear off message says are gone. Changes `buffs` and returns it.
function timers.DropGone(index, buffs)
    local serverId = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(index);
    local list = gone[serverId];
    if (list == nil) then
        return buffs;
    end
    local now = Now();
    for id,item in pairs(list) do
        local count = 0;
        for _,buff in ipairs(buffs) do
            if (buff == id) then count = count + 1; end
        end
        item.base = item.base or count;
        if (count <= item.base - item.count) or (now - item.at > GONE_HOLD) then
            list[id] = nil;   -- their list caught up (or it never left)
        else
            local drop = count - (item.base - item.count);
            for i = #buffs,1,-1 do
                if (drop > 0) and (buffs[i] == id) then
                    table.remove(buffs, i);
                    drop = drop - 1;
                end
            end
        end
    end
    if (next(list) == nil) then
        gone[serverId] = nil;
    end
    return buffs;
end

----------------------------------------------------------------------------------------------------
-- Action packets (0x028): note buffs landing on party members so recasts restart their timer
----------------------------------------------------------------------------------------------------
function timers.HandleAction(data)
    local bytes = data:totable();
    local unpack = ashita.bits.unpack_be;
    local actor = unpack(bytes, 40, 32);
    local targetCount = unpack(bytes, 72, 10);
    local category = unpack(bytes, 82, 4);
    local actionId = unpack(bytes, 86, 16);
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
                if (FindMember(targetId) ~= nil) then
                    local name, job = FindMember(actor);
                    local enhancing = (category == 4) and IsEnhancing(actionId);
                    local cast = {
                        t = now, target = targetId, buff = param, actor = actor, action = category .. '.' .. actionId,
                        enhancing = enhancing, name = name, job = job,
                        composure = enhancing and (actor == targetId) and HasComposure(actor),
                    };
                    casts[#casts + 1] = cast;
                    pending[targetId] = pending[targetId] or {};
                    pending[targetId][param] = { at = now, duration = FindLength(cast), actor = actor, action = cast.action };
                    Log('cast: %s action %s buff %d on %s length %s composure %s', tostring(name), cast.action, param, tostring(targetId),
                        tostring(pending[targetId][param].duration), tostring(cast.composure));
                    if (gone[targetId] ~= nil) then
                        gone[targetId][param] = nil;
                    end
                end
            elseif LOSE_MESSAGES[message] and (param > 0) and (param < 0x400) then
                NoteGone(targetId, param);
            end
        end
    end
end

-- Message packets (0x029): the wear off messages
function timers.HandleMessage(data)
    local function U32(at)
        local a, b, c, d = data:byte(at + 1, at + 4);
        return a + (b * 0x100) + (c * 0x10000) + (d * 0x1000000);
    end
    local message = data:byte(0x19) + (data:byte(0x1A) * 0x100);
    local param = U32(0x0C);
    if LOSE_MESSAGES[message] and (param > 0) and (param < 0x400) then
        NoteGone(U32(0x08), param);
    end
end

return timers;
