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
*           PBC1|<server id>|<name>|<saved.pack text>   (a setup copied to your other clients)
*           PBA1|<server id it came from>|<name>   (that setup arrived)
* The last two work with sharing off, as they only go out when you press the button.
--]]

local buffTimers = require('bufftimers');
local durations = require('durations');
local savedThemes = require('savedthemes');

local share = {};

local TAG        = 'PBS2';
local TAG_LENGTHS = 'PBD2';
local TAG_COPY   = 'PBC1';
local TAG_COPIED = 'PBA1';
local SEND_EVERY = 0.5;     -- seconds between sends
local PEER_GONE  = 3.0;     -- seconds without a message before a client no longer counts as connected
local MAX_LENGTHS = 30;     -- new buff lengths in one message
local MAX_MESSAGE = 8000;   -- bytes vana.ipc takes in one message
local COPY_WAIT  = 3.0;     -- seconds to wait for another client to answer a copy

local available = (rawget(_G, 'vana') ~= nil) and (vana.ipc ~= nil);
local lastSend = 0;
local peers = {};   -- [serverId] = time last heard from
local copy = nil;      -- the last copy sent: { at, names = { clients that answered } }
local incoming = nil;  -- a copy to apply on the next frame: { from, who, text }

local function MyId()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
end

local function MyName()
    return (tostring(AshitaCore:GetMemoryManager():GetParty():GetMemberName(0) or ''):gsub('%W', ''));
end

local function Send()
    local me = MyId();
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

local function ReadCopy(message)
    local to, name = message:match('^' .. TAG_COPIED .. '|(%d+)|(%w*)$');
    if (to ~= nil) then
        if (tonumber(to) == MyId()) and (copy ~= nil) then
            copy.names[#copy.names + 1] = name;
        end
        return;
    end
    local from, who, text = message:match('^' .. TAG_COPY .. '|(%d+)|(%w*)|(.*)$');
    if (from ~= nil) and (tonumber(from) ~= MyId()) then
        incoming = { from = from, who = who, text = text };
    end
end

local function ApplyCopy(item)
    if savedThemes.unpack(item.text, settings) then
        if (share.on_copied ~= nil) then
            share.on_copied(item.who);
        end
        vana.ipc.send(('%s|%s|%s'):format(TAG_COPIED, item.from, MyName()));
    end
end

if available then
    vana.on('ipc', function (e)
        local message = tostring(e.message or '');
        local tag = message:sub(1, #TAG_COPY);
        if (tag == TAG_COPY) or (tag == TAG_COPIED) then
            pcall(ReadCopy, message);
        elseif settings.share_timers then
            pcall(Read, message);
        end
    end);
end

-- Call once per frame
function share.Update()
    if (incoming ~= nil) then
        local item = incoming;
        incoming = nil;
        ApplyCopy(item);
    end
    if (not settings.share_timers) or (not available) then
        return;
    end
    local now = os.clock();
    if (now - lastSend >= SEND_EVERY) then
        lastSend = now;
        Send();
    end
end

-- Sends this client's setup to your other clients. Returns ok, error
function share.CopySetup()
    if (not available) then
        return false, 'Copying needs VanaCore.';
    end
    local message = ('%s|%d|%s|%s'):format(TAG_COPY, MyId(), MyName(), savedThemes.pack(settings));
    if (#message > MAX_MESSAGE) then
        return false, 'This setup is too large to send.';
    end
    copy = { at = os.clock(), names = {} };
    vana.ipc.send(message);
    return true;
end

-- For the menu: how the last copy went, as text, or nil if there hasn't been one
function share.CopyStatus()
    if (copy == nil) then
        return nil;
    end
    if (#copy.names > 0) then
        return 'Copied to ' .. table.concat(copy.names, ', ');
    elseif (os.clock() - copy.at > COPY_WAIT) then
        return 'No client answered. Each one needs this version of PartyBuffs loaded.';
    end
    return 'Sending...';
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
