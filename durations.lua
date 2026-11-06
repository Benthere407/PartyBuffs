--[[
* Buff lengths measured from real timers, kept in one file every character reads:
* config\addons\PartyBuffs\shared_durations.lua
*
* Keys:  <caster>:<job>:<action>:<where>   one caster on one job. where: 's' on themselves, 'o' on
*                                          someone else, 'c' on themselves under Composure
*        *:<action>                        any caster
* An action is <action packet category>.<spell or ability id>.
*
* New lengths reach your other clients at once through timershare.lua, and the file a little later.
--]]

local durations = {};

local SAVE_EVERY = 30.0;    -- seconds between writes while there is something new

local lengths  = nil;       -- [key] = seconds
local unsaved  = {};        -- [key] = seconds, measured here and not in the file yet
local unsent   = {};        -- [key] = seconds, measured here and not sent to your other clients yet
local cleared  = false;
local lastSave = 0;

local function Path()
    return ('%s\\config\\addons\\%s\\shared_durations.lua'):format((AshitaCore:GetInstallPath():gsub('[\\/]+$', '')), addon.name);
end

local function ReadFile(path)
    local fn = loadfile(path);
    if (fn == nil) then
        return nil;
    end
    setfenv(fn, {});   -- (data only: the file sees no globals)
    local ok, data = pcall(fn);
    return (ok and (type(data) == 'table')) and data or nil;
end

local function Read()
    local path = Path();
    return ReadFile(path) or ReadFile(path .. '.tmp') or {};
end

local function All()
    if (lengths == nil) then
        lengths = Read();
    end
    return lengths;
end

function durations.get(key)
    return All()[key];
end

-- A length measured on this client
function durations.set(key, seconds)
    if (All()[key] ~= seconds) then
        lengths[key] = seconds;
        unsaved[key] = seconds;
        unsent[key] = seconds;
    end
end

-- A length measured on another client (that client writes it to the file)
function durations.receive(key, seconds)
    All()[key] = seconds;
end

-- Lengths to send to your other clients: up to `limit` of them, taken off the list
function durations.take(limit)
    local out = {};
    for key,seconds in pairs(unsent) do
        if (#out >= limit) then
            break;
        end
        out[#out + 1] = { key, seconds };
    end
    for _,item in ipairs(out) do
        unsent[item[1]] = nil;
    end
    return out;
end

-- Writes what's new on top of what's in the file, keeping what other clients wrote
function durations.save()
    if (next(unsaved) == nil) and (not cleared) then
        return;
    end
    local data = cleared and {} or Read();
    for key,seconds in pairs(unsaved) do
        data[key] = seconds;
    end

    local keys = {};
    for key in pairs(data) do
        keys[#keys + 1] = key;
    end
    table.sort(keys);

    local path = Path();
    local f = io.open(path .. '.tmp', 'w');
    if (f == nil) then
        return;
    end
    f:write('-- Buff lengths PartyBuffs measured from real timers, shared by all your characters.\nreturn {\n');
    for _,key in ipairs(keys) do
        f:write(('    [%q] = %d,\n'):format(key, data[key]));
    end
    f:write('}\n');
    f:close();
    os.remove(path);
    os.rename(path .. '.tmp', path);
    unsaved, cleared = {}, false;
end

-- Call once per frame
function durations.Update()
    local now = os.clock();
    if (now - lastSave >= SAVE_EVERY) then
        lastSave = now;
        durations.save();
    end
end

function durations.count()
    local count = 0;
    for _ in pairs(All()) do
        count = count + 1;
    end
    return count;
end

function durations.clear()
    lengths, unsaved, unsent, cleared = {}, {}, {}, true;
    durations.save();
end

return durations;
