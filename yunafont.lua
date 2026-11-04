--[[
* YunaUI's font (TeX Gyre Adventor, fonts\texgyreadventor-regular.otf, GUST Font License) for
* the range text and the timer text, so they match YunaUI.
*
* Range text (Ashita font objects): the file is added to Windows as a private font for this
*   process only (nothing is installed), so the family name 'TeX Gyre Adventor' works.
* Timer text (ImGui): the file is loaded as an ImGui font. That needs VanaCore (ImGui 1.92 can
*   add fonts while running); a font added this frame is used from the next. Elsewhere the
*   ImGui font stays.
--]]

local ffi   = require('ffi');
local imgui = require('imgui');

local yf = {};

yf.FAMILY = 'TeX Gyre Adventor';
local FILE    = 'texgyreadventor-regular.otf';
local LOAD_PX = 16;

local function path()
    return ('%s\\fonts\\%s'):format((addon.path:gsub('[\\/]+$', '')), FILE);
end

local registered = false;
-- Make the family usable by name in Ashita font objects. Safe to call more than once.
function yf.register()
    if registered then return true; end
    local ok = pcall(function()
        pcall(ffi.cdef, 'int __stdcall AddFontResourceExA(const char* name, uint32_t fl, void* res);');
        local FR_PRIVATE = 0x10;
        registered = ffi.load('gdi32').AddFontResourceExA(path(), FR_PRIVATE, nil) > 0;
    end);
    return ok and registered;
end

function yf.unregister()
    if not registered then return; end
    pcall(function()
        pcall(ffi.cdef, 'int __stdcall RemoveFontResourceExA(const char* name, uint32_t fl, void* res);');
        ffi.load('gdi32').RemoveFontResourceExA(path(), 0x10, nil);
    end);
    registered = false;
end

local function frame_no()
    local ok, n = pcall(imgui.GetFrameCount);
    return (ok and n) or math.floor(os.clock() * 60);
end

local loaded = nil;   -- nil = not tried, false = not available, else { font, new, frame }
local function load()
    loaded = false;
    if not rawget(_G, 'vana') then return; end
    local fh = io.open(path(), 'rb');
    if not fh then return; end
    fh:close();
    local ok, f = pcall(imgui.AddFontFromFileTTF, path(), LOAD_PX);
    if not (ok and f) then
        ok, f = pcall(function() return imgui.GetIO().Fonts:AddFontFromFileTTF(path(), LOAD_PX); end);
    end
    if ok and f then
        local ok2, ls = pcall(function() return f.LegacySize; end);   -- (ImGui 1.92 fonts draw at any size)
        loaded = { font = f, new = ok2 and ls ~= nil, frame = frame_no() };
    end
end

-- Push the font for ImGui text px pixels tall. Returns whether it was pushed (pass to yf.pop).
-- If it wasn't, the window's font scale is set so ImGui's own 13 px font comes out at px.
function yf.push(px)
    if loaded == nil then pcall(load); end
    local e = loaded;
    if e and frame_no() > e.frame then
        if e.new and pcall(imgui.PushFont, e.font, px) then return true; end
        if pcall(imgui.PushFont, e.font) then
            imgui.SetWindowFontScale(px / LOAD_PX);
            return true;
        end
    end
    imgui.SetWindowFontScale(px / 13);
    return false;
end

function yf.pop(pushed)
    imgui.SetWindowFontScale(1);
    if pushed then imgui.PopFont(); end
end

return yf;
