--[[
vcmenu 1.3.0 - Vanacore-style menu windows for Ashita v4 / VanaCore addons.

The look of VanaCore's own menus (first built for StopMove's settings window): a header bar
with a menu glyph, minimize and close; pages in a darker sidebar with a search box; Segoe UI
page titles; teal section headers; Vanacore's colours, switches, segmented buttons and sliders.

Each addon ships its own copy: put this file in the addon's folder (addons/ashita/<addon>/vcmenu.lua),
so the addon works as a single download. require() looks in the addon's own folder first.
The master copy lives in Documents/vcmenu; copy it into an addon when you create or update it.
Bump vc.VERSION with every change: last number for fixes, middle for additions, first for
changes that could break an addon written for an older copy. In an addon:

    local vc = require('vcmenu');

    local state = vc.new_state('mypage');   -- { open = { false }, page = 'mypage', search = { '' }, scale = 1 }

    local PAGES = {};
    PAGES.mypage = function ()
        vc.title('My page', 'a dim subtitle');
        vc.section('OPTIONS');
        local v = vc.switch('opt1', 'Do the thing', settings.thing);
        if v ~= nil then settings.thing = v; end
        vc.note('Dim wrapped help text with an info icon.');
    end

    ashita.events.register('d3d_present', 'my_present', function ()
        vc.window(state, {
            id      = 'myaddon',                       -- unique window id
            title   = 'MyAddon',                       -- header bar title
            size    = { 700, 520 },                    -- first-use size (optional)
            min     = { 600, 400 },                    -- minimum size (optional)
            pages   = PAGES,                           -- page id -> draw function
            subtitle = function (page) return 'General'; end,   -- dim text after the title (optional)
            header_right = function () return '123 G', vc.colors.gold; end,  -- text before the - and x (optional)
            scaler  = true,                            -- the header's < 100% > window scale (optional)
            on_scale = function (s) settings.ui_scale = s; end,   -- called when it changes, to save it (optional)
            sidebar = function (nav)                   -- the sidebar rows (optional: no sidebar if left out)
                if nav.head('about', 'About', state.page == 'about') then state.page = 'about'; end
                nav.gap();
                nav.head('gear', 'Settings', false);
                if nav.item('General', state.page == 'mypage') then state.page = 'mypage'; end
                nav.caption('TOOLS');
                if nav.head('refresh', 'Reload', false) then ... end
            end,
        });
    end);

Toggle the window with state.open[1] = not state.open[1]. state.search[1] holds the sidebar's
menu search: it filters the sidebar entries (heads, items, captions) by label, and picking a
result clears it. Lists on a page get their own box: vc.search_box('##myfind', buf, 'Search items').

Scale: state.scale (75% to 150%) sizes the whole window: text, rows, switches, sliders, padding.
With spec.scaler the header shows Vanacore's < 100% > stepper for it (steps of 5%); the window
grows or shrinks with it. Set state.scale from your saved settings before the first vc.window.
Every pixel size you pass to vcmenu (widths in vc.slider, vc.button, vc.search_box, vc.label_row,
vc.right, vc.stat, sizes in spec) is at 100%: vcmenu scales it. Text you measure yourself with
imgui.CalcTextSize is already at the window's scale: divide it by vc.scale() before passing it.

nav (passed to spec.sidebar): nav.head(icon, label, on, uid), nav.item(label, on, uid) -> clicked;
nav.tip(text) tooltip for the entry just above; nav.gap(h); nav.caption(text). The sidebar function
may run twice a frame while searching (once only to collect labels), so keep it free of side
effects other than reacting to clicks.

Everything here draws into the current ImGui window and is safe to call every frame.

API
  vc.VERSION                       this copy's version, e.g. '1.3.0'
  vc.colors                       the palette: bg side line text dim mute gold teal acc on off knob field seg good bad
  vc.xy(a, b)                      unpack an ImGui vector return (table or two numbers) -> x, y
  vc.u32(col)                      { r, g, b, a } (0..1) -> packed colour for draw-list calls
  vc.alpha(col, a)                 the colour with a different alpha
  vc.avail_w(), vc.screen_pos()    content width left; cursor in screen coordinates
  vc.scale(), vc.z(n)              the window's scale now (1 = 100%); n pixels at that scale
  vc.commas(n)                     12345 -> '12,345'
  vc.fit_text(text, max_w)         cut text to max_w pixels, ending in '...'
  vc.safe(fn, ...)                 run fn in pcall; prints each new error once (keeps ImGui balanced)
  vc.in_font(kind, px, fn)         run fn in a Segoe UI face: 'reg', 'bold', 'ital', 'bi' (no-op outside VanaCore)
  vc.icon(dl, kind, x, cy, sz, col)  line icons: about info gear list star spark equip escha sell coin stop
                                   refresh reset files widget test play bag search
  vc.item_icon(item_id)            the game's icon for an item: { ptr } for dl:AddImage / imgui.Image, or nil

  Page blocks
  vc.title(text, sub)              page title (Segoe UI bold italic), optional dim subtitle
  vc.section(text, right, reset_fn)  teal header with a rule; optional dim right text and a reset icon
  vc.note(text)                    dim wrapped text with an info icon
  vc.stat(label, value, col, label_w)  dim label, value at a fixed column (label_w, default 130)
  vc.label_row(label, control_w)   label on the left, then moves the cursor so a control of control_w ends at the right edge
  vc.right(w)                      on the current line, move to where a w-wide control ends at the right edge
  vc.button(label, kind, w)        kind: nil, 'primary' (blue) or 'danger' (red). Returns clicked
  vc.switch(id, label, v)          a toggle then its label. Returns the new value when clicked, else nil
  vc.switch_row(id, label, v)      label on the left, toggle at the right edge (settings-page style)
  vc.seg(id, opts, cur)            segmented buttons, opts = { { value, 'Label' }, ... }. Returns the picked value or nil
  vc.slider(id, v, lo, hi, step, fmt, w)  Vanacore's slider (track + knob + value). Returns the new value while dragged
  vc.search_box(id, buf, hint, w)  a framed search box (buf = { '' }); w px or -1 for the full row. Returns edited
  vc.progress(t)                   a thin full-width progress bar, t = 0..1
  vc.list(id, reserve, fn)         a framed scrolling panel filling the page down to `reserve` px from the bottom
  vc.row(id, opts)                 a list row: { icon = item id, name, mid, right, right_col, selected, dim,
                                   cols = { { text, col }, ... } extra value columns between mid and right }. Returns clicked
  vc.row_height()                  a vc.row's height at the window's scale
  vc.row_headers(name, mid, right, cols)  headers above a vc.list; cols = { 'Header', ... } matching the rows' cols

  Window
  vc.new_state(page)               a window state table
  vc.window(state, spec)           draws the whole window (see the example above)
]]

require('common');
local imgui = require('imgui');
local chat  = require('chat');
local ffi   = require('ffi');
local d3d   = require('d3d8');

local vc = {};
vc.VERSION = '1.3.0';   -- 1.0.0 first release; 1.1.0 menu search filters the sidebar, vc.search_box, nav.tip; 1.2.0 row cols;
                        -- 1.3.0 window scale (state.scale, spec.scaler, vc.scale, vc.z, vc.row_height)

vc.colors = {                  -- Vanacore's colours
    bg    = { 0.078, 0.094, 0.129, 0.98 },
    side  = { 0.063, 0.075, 0.102, 1.00 },
    line  = { 0.137, 0.157, 0.212, 1.00 },
    text  = { 0.85, 0.87, 0.90, 1.00 },
    dim   = { 0.56, 0.59, 0.66, 1.00 },
    mute  = { 0.43, 0.46, 0.53, 1.00 },
    gold  = { 0.91, 0.69, 0.29, 1.00 },
    teal  = { 0.25, 0.82, 0.72, 1.00 },
    acc   = { 0.36, 0.78, 1.00, 1.00 },
    on    = { 0.36, 0.55, 0.94, 1.00 },
    off   = { 0.165, 0.184, 0.235, 1.00 },
    knob  = { 0.90, 0.91, 0.94, 1.00 },
    field = { 0.047, 0.059, 0.082, 1.00 },
    seg   = { 0.165, 0.192, 0.259, 1.00 },
    good  = { 0.40, 0.85, 0.55, 1.00 },
    bad   = { 1.00, 0.45, 0.45, 1.00 },
};
local C = vc.colors;

local HEAD_H = 40;      -- header bar height (at 100%)
local ROW_H  = 28;      -- list row height
local ICON_S = 24;      -- item icon size in a row
vc.SCALE_MIN, vc.SCALE_MAX = 0.75, 1.5;

--------------------------------------------------------------------------------
-- Scale: the window being drawn's scale (1 outside vc.window). Z(n) is n pixels at it.
--------------------------------------------------------------------------------
local S = 1;
local function Z(n) return n * S; end
function vc.scale() return S; end
function vc.z(n) return n * S; end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
function vc.xy(a, b)
    if type(a) == 'table' then return a[1] or a.x or 0, a[2] or a.y or 0; end
    return a or 0, b or 0;
end
local xy = vc.xy;

function vc.u32(c)
    local function c8(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5); end
    return c8(c[4] or 1) * 16777216 + c8(c[3]) * 65536 + c8(c[2]) * 256 + c8(c[1]);
end
local u32 = vc.u32;

function vc.alpha(c, a) return { c[1], c[2], c[3], a }; end

function vc.avail_w() return (xy(imgui.GetContentRegionAvail())); end
function vc.screen_pos() return xy(imgui.GetCursorScreenPos()); end
local avail_w, screen_pos = vc.avail_w, vc.screen_pos;

function vc.commas(n)
    local s = tostring(math.floor(tonumber(n) or 0));
    local neg = s:sub(1, 1) == '-';
    if neg then s = s:sub(2); end
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '');
    return (neg and '-' or '') .. out;
end

function vc.fit_text(text, max_w)
    if max_w <= 0 then return ''; end
    if xy(imgui.CalcTextSize(text)) <= max_w then return text; end
    local lo, hi = 0, #text;
    while lo < hi do
        local m = math.ceil((lo + hi) / 2);
        if xy(imgui.CalcTextSize(text:sub(1, m) .. '...')) <= max_w then lo = m; else hi = m - 1; end
    end
    return text:sub(1, lo) .. '...';
end
local fit_text = vc.fit_text;

local last_err = nil;
function vc.safe(fn, ...)
    local ok, e = pcall(fn, ...);
    if not ok and e ~= last_err then
        last_err = e;
        local name = (addon and addon.name) or 'vcmenu';
        print(chat.header(name) .. chat.error('UI error: ' .. tostring(e)));
    end
    return ok;
end

--------------------------------------------------------------------------------
-- Fonts: Vanacore's menus use Segoe UI. Under VanaCore (ImGui 1.92 can add fonts while
-- running) it is loaded once and used from the next frame; anywhere else the default font stays.
--------------------------------------------------------------------------------
local fonts, fonts_next = nil, nil;   -- nil = not tried yet, false = not available, else { reg, bold, ital, bi }
local function load_fonts()
    fonts = false;
    if not rawget(_G, 'vana') then return; end
    local dir = (os.getenv('WINDIR') or 'C:\\Windows') .. '\\Fonts\\';
    local function add(file)
        local fh = io.open(dir .. file, 'rb');
        if not fh then return nil; end
        fh:close();
        local ok, f = pcall(imgui.AddFontFromFileTTF, dir .. file, 16);
        if not (ok and f) then ok, f = pcall(function() return imgui.GetIO().Fonts:AddFontFromFileTTF(dir .. file, 16); end); end
        return ok and f or nil;
    end
    local reg = add('segoeui.ttf');
    if not reg then return; end
    fonts_next = { reg = reg, bold = add('segoeuib.ttf') or reg, ital = add('segoeuii.ttf') or reg, bi = add('segoeuiz.ttf') or reg };
end

function vc.has_fonts() return fonts and true or false; end

-- Without the Segoe UI fonts, text is scaled per window (each child window too)
local function text_scale()
    if not fonts then pcall(imgui.SetWindowFontScale, S); end
end

function vc.in_font(kind, px, fn)
    local on = fonts and fonts[kind] and pcall(imgui.PushFont, fonts[kind], px * S);
    local ok, e = pcall(fn);
    if on then pcall(imgui.PopFont); end
    if not ok then error(e, 0); end
end
local in_font = vc.in_font;

--------------------------------------------------------------------------------
-- Line icons
--------------------------------------------------------------------------------
local function poly(dl, p, col, th)
    for i = 1, #p do dl:AddLine(p[i], p[i % #p + 1], col, th or 1.3); end
end

function vc.icon(dl, kind, x, cy, sz, col)
    local r  = sz / 2;
    local cx = x + r;
    if kind == 'about' or kind == 'info' then
        dl:AddCircle({ cx, cy }, r, col, 16, 1.2);
        dl:AddLine({ cx, cy - r * 0.15 }, { cx, cy + r * 0.5 }, col, 1.4);
        dl:AddCircleFilled({ cx, cy - r * 0.45 }, 1.1, col, 6);
    elseif kind == 'gear' then
        dl:AddCircle({ cx, cy }, r * 0.42, col, 12, 1.2);
        for i = 0, 7 do
            local a = i * math.pi / 4;
            dl:AddLine({ cx + math.cos(a) * r * 0.62, cy + math.sin(a) * r * 0.62 }, { cx + math.cos(a) * r, cy + math.sin(a) * r }, col, 1.6);
        end
    elseif kind == 'list' then
        for i = -1, 1 do dl:AddLine({ cx - r * 0.8, cy + i * r * 0.6 }, { cx + r * 0.8, cy + i * r * 0.6 }, col, 1.3); end
    elseif kind == 'star' or kind == 'spark' then  -- five- or four-point star
        local n = (kind == 'star') and 5 or 4;
        local p = {};
        for i = 0, n * 2 - 1 do
            local a = i * math.pi / n - math.pi / 2;
            local k = (i % 2 == 0) and r or r * ((kind == 'star') and 0.45 or 0.32);
            p[#p + 1] = { cx + math.cos(a) * k, cy + math.sin(a) * k };
        end
        poly(dl, p, col);
    elseif kind == 'equip' then                    -- a shield
        poly(dl, { { cx - r * 0.8, cy - r * 0.8 }, { cx + r * 0.8, cy - r * 0.8 }, { cx + r * 0.8, cy + r * 0.05 },
                   { cx, cy + r }, { cx - r * 0.8, cy + r * 0.05 } }, col);
    elseif kind == 'escha' then                    -- a portal: two rings
        dl:AddCircle({ cx, cy }, r * 0.95, col, 16, 1.2);
        dl:AddCircle({ cx, cy }, r * 0.45, col, 12, 1.2);
    elseif kind == 'sell' or kind == 'coin' then   -- a coin
        dl:AddCircle({ cx, cy }, r * 0.95, col, 16, 1.2);
        dl:AddLine({ cx, cy - r * 0.5 }, { cx, cy + r * 0.5 }, col, 1.4);
    elseif kind == 'bag' then
        dl:AddRect({ cx - r * 0.8, cy - r * 0.35 }, { cx + r * 0.8, cy + r }, col, 2, 0, 1.2);
        dl:AddLine({ cx - r * 0.35, cy - r * 0.35 }, { cx - r * 0.35, cy - r * 0.8 }, col, 1.2);
        dl:AddLine({ cx - r * 0.35, cy - r * 0.8 }, { cx + r * 0.35, cy - r * 0.8 }, col, 1.2);
        dl:AddLine({ cx + r * 0.35, cy - r * 0.8 }, { cx + r * 0.35, cy - r * 0.35 }, col, 1.2);
    elseif kind == 'search' then
        dl:AddCircle({ cx - r * 0.2, cy - r * 0.2 }, r * 0.6, col, 12, 1.2);
        dl:AddLine({ cx + r * 0.25, cy + r * 0.25 }, { cx + r * 0.9, cy + r * 0.9 }, col, 1.5);
    elseif kind == 'stop' then                     -- a stop sign (octagon)
        local p, k = {}, r * 0.92;
        for i = 0, 7 do
            local a = (i + 0.5) * math.pi / 4;
            p[#p + 1] = { cx + math.cos(a) * k, cy + math.sin(a) * k };
        end
        poly(dl, p, col);
        dl:AddLine({ cx - r * 0.4, cy }, { cx + r * 0.4, cy }, col, 1.6);
    elseif kind == 'widget' then                   -- four small squares
        local q = r * 0.8;
        for _, o in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            local qx, qy = cx + o[1] * q * 0.6, cy + o[2] * q * 0.6;
            dl:AddRect({ qx - q * 0.42, qy - q * 0.42 }, { qx + q * 0.42, qy + q * 0.42 }, col, 1, 0, 1.2);
        end
    elseif kind == 'files' then                    -- a floppy disk
        dl:AddRect({ cx - r, cy - r }, { cx + r, cy + r }, col, 2, 0, 1.2);
        dl:AddRect({ cx - r * 0.5, cy - r }, { cx + r * 0.4, cy - r * 0.25 }, col, 0, 0, 1.1);
        dl:AddRect({ cx - r * 0.55, cy + r * 0.15 }, { cx + r * 0.55, cy + r }, col, 0, 0, 1.1);
    elseif kind == 'test' or kind == 'play' then   -- a play triangle
        poly(dl, { { cx - r * 0.6, cy - r }, { cx + r * 0.85, cy }, { cx - r * 0.6, cy + r } }, col);
    elseif kind == 'reset' or kind == 'refresh' then  -- a circular arrow
        local n, a0, a1 = 14, -0.25 * math.pi, 1.45 * math.pi;
        local prev;
        for i = 0, n do
            local a  = a0 + (a1 - a0) * i / n;
            local pt = { cx + math.cos(a) * r * 0.85, cy + math.sin(a) * r * 0.85 };
            if prev then dl:AddLine(prev, pt, col, 1.3); end
            prev = pt;
        end
        local tip = { cx + math.cos(a0) * r * 0.85, cy + math.sin(a0) * r * 0.85 };
        dl:AddLine(tip, { tip[1] - r * 0.55, tip[2] - r * 0.05 }, col, 1.3);
        dl:AddLine(tip, { tip[1] + r * 0.05, tip[2] - r * 0.6 }, col, 1.3);
    end
end
local icon = vc.icon;

--------------------------------------------------------------------------------
-- Item icons from the game's own resources, loaded on first use.
--------------------------------------------------------------------------------
local item_icons = {};   -- [itemId] = { tex, ptr } or false
function vc.item_icon(id)
    if id == nil then return nil; end
    local ic = item_icons[id];
    if ic ~= nil then return ic or nil; end
    item_icons[id] = false;
    pcall(function()
        local item = AshitaCore:GetResourceManager():GetItemById(id);
        if item == nil or item.Bitmap == nil or (item.ImageSize or 0) == 0 then return; end
        local ptr = ffi.new('IDirect3DTexture8*[1]');
        if ffi.C.D3DXCreateTextureFromFileInMemoryEx(d3d.get_device(), item.Bitmap, item.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
                ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0xFF000000, nil, nil, ptr) == ffi.C.S_OK then
            local tex = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
            item_icons[id] = { tex = tex, ptr = tonumber(ffi.cast('uint32_t', tex)) };
        end
    end);
    return item_icons[id] or nil;
end

--------------------------------------------------------------------------------
-- Page blocks
--------------------------------------------------------------------------------
function vc.title(t, sub)
    if fonts then
        in_font('bi', 21, function() imgui.TextColored(C.text, t); end);
    else
        pcall(imgui.SetWindowFontScale, 1.35 * S);
        imgui.TextColored(C.text, t);
        pcall(imgui.SetWindowFontScale, S);
    end
    if sub then
        imgui.SameLine();
        pcall(imgui.AlignTextToFramePadding);
        imgui.TextColored(C.dim, sub);
    end
    imgui.Dummy({ 1, Z(2) });
end

function vc.section(t, right, reset_fn)
    imgui.Dummy({ 1, Z(4) });
    in_font('ital', 15, function() imgui.TextColored(C.teal, t); end);
    local _, y0 = xy(imgui.GetItemRectMin());
    local x1, y1 = xy(imgui.GetItemRectMax());
    local wx = screen_pos() + avail_w();
    local rx = wx - (reset_fn and Z(28) or 0);
    pcall(function()
        local dl = imgui.GetWindowDrawList();
        if right ~= nil and right ~= '' then
            local tw, th = xy(imgui.CalcTextSize(right));
            dl:AddText({ rx - tw, (y0 + y1 - th) / 2 }, u32(C.dim), right);
            rx = rx - tw - Z(10);
        end
        dl:AddLine({ x1 + Z(10), (y0 + y1) / 2 }, { rx, (y0 + y1) / 2 }, u32(vc.alpha(C.teal, 0.55)), 1);
    end);
    if reset_fn then
        imgui.SameLine(imgui.GetCursorPosX() + avail_w() - Z(18));
        local ix, iy = screen_pos();
        if imgui.InvisibleButton('##rst_' .. t, { Z(16), Z(16) }) then reset_fn(); end
        local hov = imgui.IsItemHovered();
        pcall(icon, imgui.GetWindowDrawList(), 'reset', ix + Z(1), iy + Z(8), Z(13), u32(hov and C.text or C.mute));
        if hov then imgui.SetTooltip('Put this section back to its defaults'); end
    end
end

function vc.note(t)
    local ix, iy = screen_pos();
    pcall(icon, imgui.GetWindowDrawList(), 'info', ix + Z(1), iy + Z(8), Z(12), u32(C.mute));
    pcall(imgui.Indent, Z(20));
    imgui.PushStyleColor(ImGuiCol_Text, C.dim);
    pcall(imgui.PushTextWrapPos, 0);
    imgui.Text(t);
    pcall(imgui.PopTextWrapPos);
    imgui.PopStyleColor(1);
    pcall(imgui.Unindent, Z(20));
end

function vc.stat(label, value, col, label_w)
    local x0 = imgui.GetCursorPosX();
    imgui.TextColored(C.dim, label);
    imgui.SameLine(x0 + Z(label_w or 130));
    imgui.TextColored(col or C.text, value);
end

function vc.right(w)
    imgui.SameLine();
    local x = imgui.GetCursorPosX();
    imgui.SameLine(math.max(x, x + avail_w() - Z(w)));
end

function vc.label_row(label, cw)
    local x0 = imgui.GetCursorPosX();
    local aw = avail_w();
    pcall(imgui.AlignTextToFramePadding);
    imgui.Text(label);
    imgui.SameLine(x0 + math.max(Z(160), aw - Z(cw)));
end

function vc.button(label, kind, w)
    local n = 0;
    if kind == 'primary' then
        imgui.PushStyleColor(ImGuiCol_Button, C.on);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.45, 0.63, 1.00, 1 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, C.acc);
        imgui.PushStyleColor(ImGuiCol_Text, { 1, 1, 1, 1 });
        n = 4;
    elseif kind == 'danger' then
        imgui.PushStyleColor(ImGuiCol_Button, { 0.55, 0.16, 0.18, 1 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.68, 0.20, 0.22, 1 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.78, 0.25, 0.27, 1 });
        n = 3;
    end
    local clicked = imgui.Button(label, { w and Z(w) or 0, 0 });
    if n > 0 then imgui.PopStyleColor(n); end
    return clicked;
end

local function toggle(id, v)
    local x, y = screen_pos();
    local w, h = Z(34), Z(18);
    local clicked = imgui.InvisibleButton('##sw_' .. id, { w, h });
    pcall(function()
        local dl = imgui.GetWindowDrawList();
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(v and C.on or C.off), h / 2);
        dl:AddCircleFilled({ v and (x + w - h / 2) or (x + h / 2), y + h / 2 }, h / 2 - Z(2), u32(C.knob), 16);
    end);
    return clicked;
end

function vc.switch(id, label, v)
    local clicked = toggle(id, v);
    imgui.SameLine(0, Z(10));
    imgui.TextColored(v and C.text or C.dim, label);
    if clicked then return not v; end
    return nil;
end

function vc.switch_row(id, label, v)
    vc.label_row(label, 36);
    if toggle(id, v) then return not v; end
    return nil;
end

function vc.seg(id, opts, cur)
    local picked = nil;
    local gx, gy = screen_pos();
    for i, op in ipairs(opts) do
        if i > 1 then imgui.SameLine(0, 0); end
        local on = (op[1] == cur);
        imgui.PushStyleColor(ImGuiCol_Button, on and C.seg or C.field);
        imgui.PushStyleColor(ImGuiCol_Text, on and C.text or C.dim);
        if imgui.Button(op[2] .. '##seg_' .. id .. i) then picked = op[1]; end
        imgui.PopStyleColor(2);
    end
    pcall(function()           -- one frame round the group, as Vanacore's
        local x1, y1 = xy(imgui.GetItemRectMax());
        imgui.GetWindowDrawList():AddRect({ gx - 1, gy - 1 }, { x1 + 1, y1 + 1 }, u32(C.line), Z(6), 0, 1);
    end);
    if picked ~= nil and picked ~= cur then return picked; end
    return nil;
end

function vc.slider(id, v, lo, hi, step, fmt, w)
    w = Z(w or 150);
    local h, k = Z(20), Z(7);
    local x, y = screen_pos();
    imgui.InvisibleButton('##tr_' .. id, { w, h });
    local active, hot = imgui.IsItemActive(), imgui.IsItemHovered();
    local nv = nil;
    if active and hi > lo then
        local mx = xy(imgui.GetMousePos());
        nv = lo + math.max(0, math.min(1, (mx - x - k) / (w - 2 * k))) * (hi - lo);
        if step then nv = lo + math.floor((nv - lo) / step + 0.5) * step; end
        nv = tonumber(('%.4f'):format(math.max(lo, math.min(hi, nv))));
        if math.abs(nv - v) < 1e-6 then nv = nil; end
    end
    local cur = nv or v;
    local t = (hi > lo) and math.max(0, math.min(1, (cur - lo) / (hi - lo))) or 0;
    pcall(function()
        local dl = imgui.GetWindowDrawList();
        local cy, kx, th = y + h / 2, x + k + t * (w - 2 * k), Z(2);
        dl:AddRectFilled({ x + Z(2), cy - th }, { x + w - Z(2), cy + th }, u32(C.off), th);
        dl:AddRectFilled({ x + Z(2), cy - th }, { kx, cy + th }, u32(C.on), th);
        dl:AddCircleFilled({ kx, cy }, Z((active or hot) and 7.5 or 6.5), u32(C.knob), 20);
    end);
    imgui.SameLine(0, Z(10));
    pcall(imgui.AlignTextToFramePadding);
    imgui.TextColored(C.dim, (fmt or '%.2f'):format(cur));
    return nv;
end

--- A framed search box with a hint. w: width in px, -1 for the full row (default 220). Returns true when edited.
function vc.search_box(id, buf, hint, w)
    w = w or 220;
    pcall(imgui.PushItemWidth, (w > 0) and Z(w) or w);
    local sx, sy = screen_pos();
    local ok, edited = pcall(imgui.InputTextWithHint, id, hint or 'Search', buf, 64);
    if not ok then ok, edited = pcall(imgui.InputText, id, buf, 64); end
    pcall(imgui.PopItemWidth);
    pcall(function()
        local x1, y1 = xy(imgui.GetItemRectMax());
        local dl = imgui.GetWindowDrawList();
        dl:AddRect({ sx, sy }, { x1, y1 }, u32(C.line), Z(6), 0, 1);
        if (buf[1] or '') == '' then   -- a magnifier at the right while empty
            local h = y1 - sy;
            icon(dl, 'search', x1 - h + Z(3), sy + h / 2, h - Z(10), u32(C.mute));
        end
    end);
    return ok and edited or false;
end

function vc.progress(t)
    local x, y = screen_pos();
    local w, h = avail_w(), Z(6);
    imgui.Dummy({ w, h + Z(4) });
    pcall(function()
        local dl = imgui.GetWindowDrawList();
        dl:AddRectFilled({ x, y + Z(2) }, { x + w, y + Z(2) + h }, u32(C.off), h / 2);
        dl:AddRectFilled({ x, y + Z(2) }, { x + math.max(h, w * math.max(0, math.min(1, t))), y + Z(2) + h }, u32(C.on), h / 2);
    end);
end

function vc.list(id, reserve, fn)
    imgui.PushStyleColor(ImGuiCol_ChildBg, C.side);
    imgui.PushStyleColor(ImGuiCol_Border, C.line);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, Z(6));
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { Z(4), Z(4) });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
    if imgui.BeginChild(id, { 0, -Z(reserve or 0) }, true) then
        text_scale();
        vc.safe(fn);
    end
    imgui.EndChild();
    imgui.PopStyleVar(3);
    imgui.PopStyleColor(2);
end

-- Row geometry of the last vc.row drawn (screen x of its left / right edges), for column headers.
vc.row_left, vc.row_right = nil, nil;

function vc.row_height() return Z(ROW_H); end

-- Column widths for vc.row: right ('~999,999 G') and mid ('9,999 (99 stk)'), at the current font size.
vc.ROW_PAD, vc.ROW_GAP = 10, 28;
local col_cache = { fs = nil };
function vc.row_cols(right_sample, mid_sample)
    local fs = imgui.GetFontSize();
    local key = fs .. '|' .. (right_sample or '') .. '|' .. (mid_sample or '');
    if col_cache.key ~= key then
        col_cache.key   = key;
        col_cache.right = xy(imgui.CalcTextSize(right_sample or '~999,999 G'));
        col_cache.mid   = xy(imgui.CalcTextSize(mid_sample or '9,999 (99 stk)'));
    end
    return col_cache.right, col_cache.mid;
end

--- Column headers lined up with the rows of a vc.list (drawn above it). cols: headers for the rows' extra cols.
function vc.row_headers(name, mid, right, cols)
    local hx, hy = screen_pos();
    local left = vc.row_left or (hx + Z(5));
    local rgt  = vc.row_right or (hx + avail_w() - Z(19));
    local rw, mw = vc.row_cols();
    local pad, gap = Z(vc.ROW_PAD), Z(vc.ROW_GAP);
    local right_edge = rgt - pad;
    local ncols      = cols and #cols or 0;
    local mid_edge   = right_edge - (ncols + 1) * (rw + gap);
    local dl  = imgui.GetWindowDrawList();
    local col = u32(C.mute);
    if name then dl:AddText({ left + Z(9) + Z(ICON_S) + Z(9), hy }, col, name); end
    for k = 1, ncols do
        local s = fit_text(cols[k], rw);
        dl:AddText({ right_edge - (ncols - k + 1) * (rw + gap) - xy(imgui.CalcTextSize(s)), hy }, col, s);
    end
    if mid then dl:AddText({ mid_edge - xy(imgui.CalcTextSize(mid)), hy }, col, mid); end
    if right then
        local s = fit_text(right, rw);
        dl:AddText({ right_edge - xy(imgui.CalcTextSize(s)), hy }, col, s);
    end
    imgui.Dummy({ 1, imgui.GetFontSize() + Z(2) });
end

--- One list row: item icon, name, optional middle column, right-aligned value. Returns true when clicked.
--- Columns, right to left: right (fixed width), mid (fixed width, if given), then the name cut short with '...'.
--- opts: icon (item id, or nil for an empty slot), no_icon (true: no icon slot at all), name, mid, right,
---       right_col, selected, dim, cols ({ { text, col }, ... }: extra fixed-width columns between mid and
---       right, left to right; col is optional).
function vc.row(id, o)
    local x, y = screen_pos();
    local w    = avail_w();
    local rh, isz = Z(ROW_H), Z(ICON_S);
    vc.row_left, vc.row_right = x, x + w;
    local clicked = imgui.InvisibleButton(id, { math.max(w, 1), rh });
    if not imgui.IsItemVisible() then return clicked; end   -- off-screen: skip drawing (and icon loading)
    local hovered = imgui.IsItemHovered();
    local dl = imgui.GetWindowDrawList();

    if o.selected then
        dl:AddRectFilled({ x, y + 1 }, { x + w, y + rh - 1 }, u32(vc.alpha(C.acc, 0.13)), Z(5), 0);
        dl:AddRectFilled({ x + 1, y + Z(6) }, { x + Z(4), y + rh - Z(6) }, u32(C.acc), 1, 0);
    elseif hovered then
        dl:AddRectFilled({ x, y + 1 }, { x + w, y + rh - 1 }, u32({ 1, 1, 1, 0.05 }), Z(5), 0);
    end

    local nx = x + Z(12);
    if not o.no_icon then
        local ix, iy = x + Z(9), y + (rh - isz) / 2;
        dl:AddRectFilled({ ix - 1, iy - 1 }, { ix + isz + 1, iy + isz + 1 }, u32(C.field), Z(4), 0);
        local ic = vc.item_icon(o.icon);
        if ic ~= nil then dl:AddImage(ic.ptr, { ix, iy }, { ix + isz, iy + isz }); end
        nx = ix + isz + Z(9);
    end

    local th = select(2, xy(imgui.CalcTextSize('Ag')));
    local ty = y + (rh - th) / 2;
    local rw, mw = vc.row_cols();
    local gap = Z(vc.ROW_GAP);
    local right_edge = x + w - Z(vc.ROW_PAD);
    local ncols      = o.cols and #o.cols or 0;
    local mid_edge   = right_edge - (ncols + 1) * (rw + gap);
    local name_edge  = (o.mid ~= nil) and (mid_edge - mw - gap) or mid_edge;

    if o.right ~= nil and o.right ~= '' then
        local s = fit_text(o.right, rw);
        dl:AddText({ right_edge - xy(imgui.CalcTextSize(s)), ty }, u32(o.dim and C.mute or (o.right_col or C.text)), s);
    end
    for k = 1, ncols do
        local c = o.cols[k];
        if c[1] ~= nil and c[1] ~= '' then
            local s = fit_text(c[1], rw);
            local cx = right_edge - (ncols - k + 1) * (rw + gap);
            dl:AddText({ cx - xy(imgui.CalcTextSize(s)), ty }, u32(o.dim and C.mute or (c[2] or C.text)), s);
        end
    end
    if o.mid ~= nil and o.mid ~= '' then
        local s = fit_text(o.mid, mw);
        dl:AddText({ mid_edge - xy(imgui.CalcTextSize(s)), ty }, u32(o.dim and C.mute or C.dim), s);
    end
    local name_col = o.dim and C.mute or (o.selected and { 1, 1, 1, 1 } or C.text);
    dl:AddText({ nx, ty }, u32(name_col), fit_text(o.name or '', name_edge - nx));
    return clicked;
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------
function vc.new_state(page)
    return { open = { false }, page = page, search = { '' }, scale = 1 };
end

local function clamp_scale(v)
    v = math.floor((tonumber(v) or 1) * 20 + 0.5) / 20;   -- (steps of 5%)
    return math.max(vc.SCALE_MIN, math.min(vc.SCALE_MAX, v));
end

local function header(state, spec)
    local x, y = screen_pos();
    local w  = avail_w();
    local hh = Z(HEAD_H);
    local dl = imgui.GetWindowDrawList();
    pcall(function()       -- Vanacore's menu glyph
        for i = -1, 1 do dl:AddLine({ x + Z(16), y + hh / 2 + i * Z(4) }, { x + Z(26), y + hh / 2 + i * Z(4) }, u32(C.dim), 1.5); end
    end);
    local cx, cy = imgui.GetCursorPosX(), imgui.GetCursorPosY();
    in_font('bold', 17, function()
        local th = select(2, xy(imgui.CalcTextSize(spec.title or 'Menu')));
        imgui.SetCursorPosY(cy + (hh - th) / 2);
        imgui.SetCursorPosX(cx + Z(36));
        imgui.TextColored(C.text, spec.title or 'Menu');
        local sub = spec.subtitle and spec.subtitle(state.page) or nil;
        if sub and sub ~= '' then
            imgui.SameLine();
            imgui.TextColored(C.mute, '  ' .. sub);
        end
    end);

    local function glyph(bx, kind)
        local g = Z(22);
        imgui.SetCursorPosX(cx + bx - x);
        imgui.SetCursorPosY(cy + (hh - g) / 2);
        local hit = imgui.InvisibleButton('##hb_' .. kind, { g, g });
        local hov = imgui.IsItemHovered();
        local mx, my, e = bx + g / 2, y + hh / 2, Z(4.5);
        pcall(function()
            if hov then dl:AddRectFilled({ bx, my - g / 2 }, { bx + g, my + g / 2 }, u32({ 1, 1, 1, 0.07 }), Z(4)); end
            local c = u32(hov and C.text or C.dim);
            if kind == 'min' then
                dl:AddLine({ mx - e, my }, { mx + e, my }, c, 1.5);
            elseif kind == 'close' then
                dl:AddLine({ mx - e, my - e }, { mx + e, my + e }, c, 1.5);
                dl:AddLine({ mx - e, my + e }, { mx + e, my - e }, c, 1.5);
            else                               -- < or >
                local sx = (kind == 'down') and 1 or -1;
                dl:AddLine({ mx + sx * e * 0.5, my - e }, { mx - sx * e * 0.5, my }, c, 1.5);
                dl:AddLine({ mx - sx * e * 0.5, my }, { mx + sx * e * 0.5, my + e }, c, 1.5);
            end
        end);
        return hit, hov;
    end
    local win_w, win_h = xy(imgui.GetWindowSize());

    -- the window scale, as Vanacore's: < 100% > in a rounded box, 75% to 150% in steps of 5%
    local right_x = x + w - Z(76);                 -- (where header_right text ends)
    if spec.scaler then
        local sw  = Z(108);
        local sx0 = x + w - Z(72) - sw;
        right_x = sx0 - Z(10);
        pcall(function()
            dl:AddRect({ sx0, y + hh / 2 - Z(13) }, { sx0 + sw, y + hh / 2 + Z(13) }, u32(C.line), Z(6), 0, 1);
        end);
        local new = nil;
        local hit, hov = glyph(sx0 + Z(3), 'down');
        if hit then new = S - 0.05; end
        if hov then imgui.SetTooltip('Smaller'); end
        hit, hov = glyph(sx0 + sw - Z(25), 'up');
        if hit then new = S + 0.05; end
        if hov then imgui.SetTooltip('Bigger'); end
        pcall(function()
            local txt = ('%d%%'):format(math.floor(S * 100 + 0.5));
            local tw, th = xy(imgui.CalcTextSize(txt));
            dl:AddText({ sx0 + (sw - tw) / 2, y + (hh - th) / 2 }, u32(C.text), txt);
        end);
        if new then
            new = clamp_scale(new);
            if new ~= S then
                local f = new / S;
                state.scale = new;
                if state.mini then                 -- the window grows or shrinks with it
                    state.mini = { state.mini[1] * f, state.mini[2] * f };
                    state.mini_set = { win_w * f, Z(HEAD_H) * f };
                else
                    state.mini_set = { win_w * f, win_h * f };
                end
                if spec.on_scale then vc.safe(spec.on_scale, new); end
            end
        end
    end

    if spec.header_right then
        pcall(function()
            local txt, col = spec.header_right();
            if txt and txt ~= '' then
                local tw, th = xy(imgui.CalcTextSize(txt));
                dl:AddText({ right_x - tw, y + (hh - th) / 2 }, u32(col or C.dim), txt);
            end
        end);
    end

    local hit, hov = glyph(x + w - Z(60), 'min');
    if hit then
        if state.mini then state.mini_set, state.mini = state.mini, nil;
        else state.mini = { win_w, win_h }; state.mini_set = { win_w, hh }; end
    end
    if hov then imgui.SetTooltip(state.mini and 'Show the window' or 'Shrink to this bar'); end
    if glyph(x + w - Z(32), 'close') then state.open[1] = false; end
    imgui.SetCursorPosX(cx);
    imgui.SetCursorPosY(cy + hh);
end

local function sidebar(state, spec)
    local PADF = ImGuiWindowFlags_AlwaysUseWindowPadding or 0;
    imgui.PushStyleColor(ImGuiCol_ChildBg, C.side);
    pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { Z(12), Z(12) });
    local side_w = spec.sidebar_w and Z(spec.sidebar_w) or (xy(imgui.CalcTextSize('Refresh Sparks ....')) + Z(76));
    local open = imgui.BeginChild('##' .. spec.id .. '_side', { side_w, 0 }, false, PADF);
    pcall(imgui.PopStyleVar, 1);
    if open then
        text_scale();
        local base = imgui.GetCursorPosX();

        if spec.search ~= false then   -- the menu search box: filters the sidebar's own entries
            vc.search_box('##' .. spec.id .. '_search', state.search, 'Search menu', -1);
            imgui.Dummy({ 1, Z(6) });
        end

        -- While searching, the sidebar runs twice: first to collect its entries (nothing is drawn),
        -- then to draw only the visible ones. An entry shows if its label matches, if its head
        -- matches (an item under it), or if anything under it matches (a head). Captions show
        -- when anything below them, up to the next caption, shows.
        local needle = (spec.search ~= false) and (state.search[1] or ''):lower() or '';
        local searching = needle ~= '';
        local entries, show, n = {}, {}, 0;
        local collecting = false;
        local function matches(label) return label:lower():find(needle, 1, true) ~= nil; end
        local drawn = false;               -- whether the last entry was drawn (for nav.tip)
        local function next_shown()       -- false while collecting; true when this entry is visible
            n = n + 1;
            drawn = (not collecting) and (not searching or show[n] == true);
            return drawn;
        end
        local function clicked_then(clicked)   -- a pick from the search results clears the search
            if clicked and searching then state.search[1] = ''; end
            return clicked;
        end

        local nav = {};
        -- a top-level row: a line icon, then a white label. Returns clicked.
        function nav.head(kind, label, on, uid)
            if collecting then entries[#entries + 1] = { 'head', label }; end
            if not next_shown() then return false; end
            local ix = screen_pos();
            imgui.SetCursorPosX(base + Z(22));
            imgui.PushStyleColor(ImGuiCol_Text, on and C.acc or C.text);
            local clicked = imgui.Selectable(label .. '##hd_' .. (uid or label), on);
            imgui.PopStyleColor(1);
            local _, y0 = xy(imgui.GetItemRectMin());
            local _, y1 = xy(imgui.GetItemRectMax());
            pcall(icon, imgui.GetWindowDrawList(), kind, ix, (y0 + y1) / 2, Z(13), u32(on and C.acc or C.dim));
            return clicked_then(clicked);
        end
        -- a page under a head, with the tree line and the accent bar beside the open one. Returns clicked.
        function nav.item(label, on, uid)
            if collecting then entries[#entries + 1] = { 'item', label }; end
            if not next_shown() then return false; end
            imgui.SetCursorPosX(base + Z(34));
            imgui.PushStyleColor(ImGuiCol_Text, on and C.acc or C.dim);
            local clicked = imgui.Selectable(label .. '##nav_' .. (uid or label), on);
            imgui.PopStyleColor(1);
            pcall(function()
                local x0, y0 = xy(imgui.GetItemRectMin());
                local _, y1  = xy(imgui.GetItemRectMax());
                local dl = imgui.GetWindowDrawList();
                dl:AddLine({ x0 - Z(10), y0 }, { x0 - Z(10), y1 + Z(2) }, u32(C.line), 1);
                if on then
                    local wx = xy(imgui.GetWindowPos());
                    dl:AddRectFilled({ wx + Z(3), y0 + 1 }, { wx + Z(6), y1 }, u32(C.acc), 1);
                end
            end);
            return clicked_then(clicked);
        end
        -- a tooltip for the entry just above, shown only if that entry was drawn and is hovered
        function nav.tip(t)
            if drawn and imgui.IsItemHovered() then imgui.SetTooltip(t); end
        end
        function nav.gap(h)
            if collecting or searching then return; end   -- (gaps would leave holes in the results)
            imgui.Dummy({ 1, Z(h or 4) });
        end
        function nav.caption(t)
            if collecting then entries[#entries + 1] = { 'caption', t }; end
            if not next_shown() then return; end
            imgui.Dummy({ 1, Z(8) });
            imgui.TextColored(C.mute, t);
            imgui.Dummy({ 1, Z(2) });
        end

        if searching then
            collecting, n = true, 0;
            vc.safe(spec.sidebar, nav, state);
            collecting = false;
            -- items: match, or their head matches
            local head_i, head_hit = nil, false;
            for i, e in ipairs(entries) do
                if e[1] == 'head' then
                    head_i, head_hit = i, matches(e[2]);
                    show[i] = head_hit;
                elseif e[1] == 'item' then
                    show[i] = head_hit or matches(e[2]);
                    if show[i] and head_i then show[head_i] = true; end   -- a head shows when anything under it does
                else
                    head_i, head_hit = nil, false;
                end
            end
            -- captions: shown when anything after them (up to the next caption) is
            local cap = nil;
            for i, e in ipairs(entries) do
                if e[1] == 'caption' then cap = i; show[i] = false;
                elseif show[i] and cap then show[cap] = true; end
            end
            n = 0;
            local any = false;
            for i = 1, #entries do if show[i] then any = true; break; end end
            if not any then imgui.TextColored(C.mute, 'Nothing in the menu matches.'); end
        end
        vc.safe(spec.sidebar, nav, state);
    end
    imgui.EndChild();
    imgui.PopStyleColor(1);
    pcall(function()       -- the hairline between the sidebar and the page
        local x1, y1 = xy(imgui.GetItemRectMax());
        local _, y0  = xy(imgui.GetItemRectMin());
        imgui.GetWindowDrawList():AddLine({ x1, y0 }, { x1, y1 }, u32(C.line), 1);
    end);
end

function vc.window(state, spec)
    if not state.open[1] then return; end
    if fonts == nil then pcall(load_fonts);
    elseif fonts_next then fonts, fonts_next = fonts_next, nil; end

    state.scale = clamp_scale(state.scale or 1);
    S = state.scale;

    -- window colours and shapes (each push is counted so they always pop)
    local ncol, nvar = 0, 0;
    local function col(id, c) if id then imgui.PushStyleColor(id, c); ncol = ncol + 1; end end
    local function var(id, v) if id and pcall(imgui.PushStyleVar, id, v) then nvar = nvar + 1; end end
    col(ImGuiCol_WindowBg, C.bg);           col(ImGuiCol_ChildBg, { 0, 0, 0, 0 });
    col(ImGuiCol_PopupBg, C.side);          col(ImGuiCol_Border, C.line);
    col(ImGuiCol_Text, C.text);             col(ImGuiCol_TextDisabled, C.dim);
    col(ImGuiCol_FrameBg, C.field);         col(ImGuiCol_FrameBgHovered, C.seg);
    col(ImGuiCol_FrameBgActive, C.seg);
    col(ImGuiCol_Button, { 0.106, 0.125, 0.169, 1 });
    col(ImGuiCol_ButtonHovered, C.seg);     col(ImGuiCol_ButtonActive, { 0.22, 0.26, 0.34, 1 });
    col(ImGuiCol_Header, { 0, 0, 0, 0 });   col(ImGuiCol_HeaderHovered, { 1, 1, 1, 0.04 });
    col(ImGuiCol_HeaderActive, { 1, 1, 1, 0.06 });
    col(ImGuiCol_SliderGrab, C.on);         col(ImGuiCol_SliderGrabActive, C.acc);
    col(ImGuiCol_CheckMark, C.acc);         col(ImGuiCol_ScrollbarBg, { 0, 0, 0, 0 });
    col(ImGuiCol_ScrollbarGrab, C.seg);     col(ImGuiCol_ScrollbarGrabHovered, C.line);
    col(ImGuiCol_ScrollbarGrabActive, C.on);
    col(ImGuiCol_ResizeGrip, { 0.85, 0.85, 0.85, 0.30 });
    col(ImGuiCol_ResizeGripHovered, { 1, 1, 1, 0.70 }); col(ImGuiCol_ResizeGripActive, { 1, 1, 1, 0.90 });
    var(ImGuiStyleVar_WindowRounding, Z(8)); var(ImGuiStyleVar_FrameRounding, Z(6));
    var(ImGuiStyleVar_ItemSpacing, { Z(8), Z(6) });
    var(ImGuiStyleVar_FramePadding, { Z(6), Z(3) });
    var(ImGuiStyleVar_ScrollbarSize, Z(14));

    local size, minsz = spec.size or { 700, 520 }, spec.min or { 520, 320 };
    imgui.SetNextWindowSize({ Z(size[1]), Z(size[2]) }, ImGuiCond_FirstUseEver);
    if state.mini_set then imgui.SetNextWindowSize(state.mini_set, ImGuiCond_Always); state.mini_set = nil; end
    pcall(function()
        local hh = Z(HEAD_H);
        imgui.SetNextWindowSizeConstraints({ Z(minsz[1]), state.mini and hh or Z(minsz[2]) }, { 3000, state.mini and hh or 3000 });
    end);

    local font_on = fonts and pcall(imgui.PushFont, fonts.reg, Z(16));
    pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { 0, 0 });
    local flags = bit.bor(ImGuiWindowFlags_NoCollapse or 0, ImGuiWindowFlags_NoTitleBar or 0,
                          ImGuiWindowFlags_NoScrollbar or 0, ImGuiWindowFlags_NoScrollWithMouse or 0,
                          state.mini and (ImGuiWindowFlags_NoResize or 0) or 0);
    local began = imgui.Begin((spec.title or spec.id) .. '###' .. spec.id .. '_vcwin', state.open, flags);
    pcall(imgui.PopStyleVar, 1);
    if began then
        text_scale();
        vc.safe(header, state, spec);
        if not state.mini then
            if spec.sidebar then
                sidebar(state, spec);
                imgui.SameLine(0, 0);
            end
            pcall(imgui.PushStyleVar, ImGuiStyleVar_WindowPadding, { Z(18), Z(12) });
            local open = imgui.BeginChild('##' .. spec.id .. '_page', { 0, 0 }, false, ImGuiWindowFlags_AlwaysUseWindowPadding or 0);
            pcall(imgui.PopStyleVar, 1);
            if open then
                text_scale();
                pcall(function()   -- the hairline under the header
                    local wx, wy = xy(imgui.GetWindowPos());
                    imgui.GetWindowDrawList():AddLine({ wx, wy }, { wx + xy(imgui.GetWindowSize()), wy }, u32(C.line), 1);
                end);
                local page = spec.pages and spec.pages[state.page];
                if page then vc.safe(page, state); end
            end
            imgui.EndChild();
        end
    end
    imgui.End();
    if font_on then pcall(imgui.PopFont); end
    if nvar > 0 then imgui.PopStyleVar(nvar); end
    if ncol > 0 then imgui.PopStyleColor(ncol); end
    S = 1;
end

return vc;
