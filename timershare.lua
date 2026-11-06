--[[
* Shares exact buff timers and buff lists between your own clients on this PC.
*
* Each client knows its own buffs exactly, so with this on it sends them to the others about twice
* a second, and shows exact times for those characters instead of estimates. It goes through VanaCore's
* messages between clients on this PC (vana.ipc), so there is nothing to set up and nothing leaves the
* PC. Both clients need the option on.
*
* Messages: PBS2|<server id>|L<buff ids in order>|<buff id>,<full duration>,<seconds left>,...|...   (left -1 = permanent)
*           PBD2|<durations.lua key>=<seconds>|...   (new buff lengths)
--]]

local buffTimers = require('bufftimers');
local durations = require('durations');

local share = {};

local TAG        = 'PBS2';
local TAG_LENGTHS = 'PBD2';
local SEND_EVERY = 0.5;     -- seconds between sends
local PEER_GONE  = 3.0;     -- seconds without a message before a client no longer counts as connected
local MAX_LENGTHS = 30;     -- new buff lengths in one message

local available = (rawget(_G, 'vana') ~= nil) and (vana.ipc ~= nil);
local lastSend = 0;
local peers = {};   -- [serverId] = time last heard from

local function Send()
    local me = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
    if (me == 0) then
        return;
    end
    local arr, fulls, list = buffTimers.GetOwn();
    local out = { TAG, tostring(me), 'L' .. table.concat(list, ',') };
    for id,lefts in pairs(arr) do
        local text = {};
        for i,left in ipairs(lefts) do
            text[i] = (left == -1) and '-1' or ('%.1f'):format(left);
        end
        out[#out + 1] = ('%d,%.1f,%s'):format(id, fulls[id] or 0, table.concat(text, ','));
    end
    vana.ipc.send(table.concat(out, '|'));

    local lengths = durations.take(MAX_LENGTHS);
    if (#lengths > 0) then
        local parts = { TAG_LENGTHS };
        for _,item in ipairs(lengths) do
            parts[#parts + 1] = ('%s=%d'):format(item[1], item[2]);
        end
        vana.ipc.send(table.concat(parts, '|'));
    end
end

local function ReadLengths(message)
    for key,seconds in message:gmatch('|([%w%*:%.]+)=(%d+)') do
        durations.receive(key, tonumber(seconds));
    end
end

local function Read(message)
    if (message:sub(1, #TAG_LENGTHS) == TAG_LENGTHS) then
        ReadLengths(message);
        return;
    end
    local serverId, rest = message:match('^' .. TAG .. '|(%d+)(.*)$');
    serverId = tonumber(serverId);
    if (serverId == nil) then
        return;
    end
    local list = {};
    for id in (rest:match('^|L([%d,]*)') or ''):gmatch('%d+') do
        list[#list + 1] = tonumber(id);
    end
    local arr, fulls = {}, {};
    for id,full,lefts in rest:gmatch('|(%d+),([%d%.]+),([%-%d%.,]+)') do
        id, full = tonumber(id), tonumber(full);
        if (id ~= nil) and (full ~= nil) then
            local items = {};
            for left in lefts:gmatch('%-?[%d%.]+') do
                items[#items + 1] = tonumber(left);
            end
            arr[id], fulls[id] = items, full;
        end
    end
    peers[serverId] = os.clock();
    buffTimers.SetShared(serverId, arr, fulls, list);
end

if available then
    vana.on('ipc', function (e)
        if settings.share_timers then
            pcall(Read, tostring(e.message or ''));
        end
    end);
end

-- Call once per frame
function share.Update()
    if (not settings.share_timers) or (not available) then
        return;
    end
    local now = os.clock();
    if (now - lastSend >= SEND_EVERY) then
        lastSend = now;
        Send();
    end
end

-- For the menu: how sharing is going, as text
function share.Status()
    if (not available) then
        return 'Needs VanaCore';
    end
    local count, now = 0, os.clock();
    for _,heard in pairs(peers) do
        if (now - heard < PEER_GONE) then
            count = count + 1;
        end
    end
    return ('%d other client%s connected'):format(count, (count == 1) and '' or 's');
end

return share;
