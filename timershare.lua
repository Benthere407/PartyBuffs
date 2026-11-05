--[[
* Shares exact buff timers between your own clients on this PC.
*
* Each client knows its own timers exactly, so with this on it sends them to the others about twice
* a second, and shows exact times for those characters instead of estimates. A client takes the first
* free port of a small range on 127.0.0.1 and sends to every other port of it, so there is nothing to
* set up and nothing leaves the PC. Both clients need the option on.
*
* Message: PBS1|<server id>|<buff id>,<seconds left>,<full duration>|...   (left -1 = permanent)
--]]

local buffTimers = require('bufftimers');

local share = {};

local FIRST_PORT = 47620;
local PORT_COUNT = 18;      -- one per client
local HOST       = '127.0.0.1';
local TAG        = 'PBS1';
local POLL_EVERY = 0.1;     -- seconds between reads of the socket
local SEND_EVERY = 0.5;     -- seconds between sends
local PEER_GONE  = 3.0;     -- seconds without a message before a client no longer counts as connected
local RETRY_EVERY = 5.0;    -- seconds between tries at opening the socket
local MAX_READS  = 64;      -- messages read in one go

local sock, port, failed = nil, nil, nil;
local lastPoll, lastSend, lastTry = 0, 0, -RETRY_EVERY;
local peers = {};   -- [serverId] = time last heard from

local function Open()
    failed = nil;
    local ok, socket = pcall(require, 'socket');
    if (not ok) then
        failed = 'LuaSocket could not load';
        return;
    end
    for p = FIRST_PORT,FIRST_PORT + PORT_COUNT - 1 do
        local s = socket.udp();
        if (s ~= nil) then
            s:settimeout(0);
            if s:setsockname(HOST, p) then
                sock, port = s, p;
                return;
            end
            s:close();
        end
    end
    failed = 'No free port';
end

local function Close()
    if (sock ~= nil) then
        sock:close();
    end
    sock, port, failed = nil, nil, nil;
    lastTry = -RETRY_EVERY;
    peers = {};
end

local function Send()
    local me = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
    if (me == 0) then
        return;
    end
    local out = { TAG, tostring(me) };
    local lefts, fulls = buffTimers.GetOwn();
    for id,left in pairs(lefts) do
        if (left == -1) then
            out[#out + 1] = ('%d,-1,-1'):format(id);
        elseif (left > 0) and (fulls[id] ~= nil) then
            out[#out + 1] = ('%d,%.1f,%.1f'):format(id, left, fulls[id]);
        end
    end
    local message = table.concat(out, '|');
    for p = FIRST_PORT,FIRST_PORT + PORT_COUNT - 1 do
        if (p ~= port) then
            sock:sendto(message, HOST, p);
        end
    end
end

local function Read(message, now)
    local serverId, rest = message:match('^' .. TAG .. '|(%d+)(.*)$');
    serverId = tonumber(serverId);
    if (serverId == nil) then
        return;
    end
    local buffs = {};
    for id,left,full in rest:gmatch('|(%d+),(%-?[%d%.]+),(%-?[%d%.]+)') do
        id, left, full = tonumber(id), tonumber(left), tonumber(full);
        if (id ~= nil) and (left ~= nil) and (full ~= nil) then
            buffs[id] = { left = left, full = full };
        end
    end
    peers[serverId] = now;
    buffTimers.SetShared(serverId, buffs);
end

local function Receive(now)
    for _ = 1,MAX_READS do
        local message, err = sock:receivefrom();
        if (message ~= nil) then
            Read(message, now);
        elseif (err == 'timeout') then
            break;   -- (other errors: Windows reports each send to a port no client is on, so keep reading)
        end
    end
end

-- Call once per frame
function share.Update()
    if (not settings.share_timers) then
        if (sock ~= nil) or (failed ~= nil) then
            Close();
        end
        return;
    end
    local now = os.clock();
    if (sock == nil) then
        if (now - lastTry < RETRY_EVERY) then
            return;
        end
        lastTry = now;
        Open();
        if (sock == nil) then
            return;
        end
    end
    if (now - lastPoll >= POLL_EVERY) then
        lastPoll = now;
        Receive(now);
    end
    if (now - lastSend >= SEND_EVERY) then
        lastSend = now;
        Send();
    end
end

share.Close = Close;

-- For the menu: how sharing is going, as text
function share.Status()
    if (failed ~= nil) then
        return failed;
    end
    if (sock == nil) then
        return 'Connecting';
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
