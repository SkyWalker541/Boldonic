-- Boldonic Home: the plugin's app-style dashboard (the "Storefront" look).
-- A Storefront-style brand lockup (logo + name top-left, ✕ to leave), an
-- underlined tab bar (Convert A File / Settings), rich rows with live
-- selection hints, tap-to-act. The white card covers the whole screen so
-- nothing shows behind it.
--
-- Conversion is COMPLETELY LOCAL: everything happens on this KOReader
-- device through the bundled ffi/archiver. There is no networking: no WiFi,
-- no Xteink, no probes, no sockets — this dashboard never leaves the
-- machine it is running on, and the only moving parts are the EPUB scan, the
-- bold engine rewrite, and the copy/replace of the archive file.
--
-- HEADER RULE: the brand header and the tab bar NEVER leave the screen.
-- Picking files and choosing the destination happen INSIDE the active tab's
-- content region — no stacked full-screen dialogs — and every back/leave/
-- tab-switch returns to the tab's landing with the browser's state (picked
-- files, search filter) cached on the browser object.
--
-- Every conversion happens INSIDE this dashboard: chooseAndConvert opens the
-- picker on the Convert tab, and the batch's sink callbacks
-- (onBeginFile/onFileSent/onFileFailed/onDone) rebuild the Convert tab in
-- place. The dashboard never closes during a conversion, and "Convert more
-- files…"/"Try again" keep going from the same window.
--
-- E-INK REPAINT RULE (the issue that hid the whole flow on the device):
-- when one of these callbacks flips the convert STATE (converting a file /
-- done / failed) it does a full refresh — bare forceRePaint() partials over
-- a whole-screen white card were being swallowed by the panel, so the
-- conversion ran to completion with the screen still showing the old tab.
-- State boundaries that almost always stand alone (batch start, done,
-- failed) flash; only genuinely transient intermediate paints (none during
-- a single-file batch) use the soft path.

-- Uses only the plugin API exported from main.lua:
--   ratio()        setRatio(value)       (10-90, default 40)
--   mode()         setMode("copy"|"replace")
--   destFolder()   setDestFolder(path)   ("" == next to the original)
--   outputPathFor(path)  outputDescription(path)
--   chooseAndConvert()   convertCurrentBook()   convertBooks(paths, self)
--   isEpub(path)         currentBookPath()      deviceRoot()  listSubfolders(dir)
--   mkdirs(path)         VERSION

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")
local logger = require("logger")

-- The file picker renders INSIDE this dashboard (the Convert tab's browser)
-- but lives in its own module. Loaded lazily — requiring Home must never
-- pull the picker's widget code at plugin load time (the Harness guards that).
local picker_mod
local function pickerModule()
    picker_mod = picker_mod or require("boldonic_picker")
    return picker_mod
end

-- This file's own plugin directory (icon.png lives beside it). The on-device
-- PluginLoader sets plugin.path on the module; this mirrors how the picker
-- finds titles_cache.lua so the logo also resolves when running without it.
local LUA_PLUGIN_DIR
do
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        LUA_PLUGIN_DIR = src:sub(2):match("^(.*)/[^/]+$")
    end
end

-- ────────────────────── small presentation helpers ──────────────────────

local function file_size(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.attributes then
        return lfs.attributes(path, "size") or 0
    end
    return 0
end

-- A preset-style name for a ratio value: 30 = Light, 40 = Medium, 50 =
-- Strong (the full presets), anything else is shown as a bare percentage.
local function ratio_label(v)
    if v == 30 then return _("Light") end
    if v == 40 then return _("Medium") end
    if v == 50 then return _("Strong") end
    return tostring(v) .. "%"
end

-- Bold: how many leading characters of each word get bolded (per the engine
-- semantics). Round of wlen/ratio clamped to [1, wlen-1].
local function bold_count(wlen, ratio)
    if wlen <= 2 then return 1 end
    local n = math.floor(wlen * ratio / 100)
    if n < 1 then n = 1 end
    if n > wlen - 1 then n = wlen - 1 end
    return n
end

-- "Next to the original" vs a chosen folder path, for the display rows.
local function dest_name(plugin)
    local raw = plugin and plugin:destFolder() or ""
    if raw == nil or raw == "" then
        return _("Next to the original")
    end
    return raw
end

-- ─────────────────────────────── the widget ──────────────────────────────

local HomeDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    plugin = nil,
    tab = "convert",
    -- In-dashboard conversion state machine (see buildTabContent dispatch).
    convert_state = "idle", -- "idle" | "converting" | "done" | "failed"
    convert_paths = nil,    -- full list passed to beginConvertBatch
    convert_index = 0,      -- 1-based: current file number within the batch
    convert_total = 0,      -- total files in the batch
    convert_path = nil,     -- path of the file currently converting
    convert_filename = nil, -- basename of convert_path (for display)
    conversion_list = {},   -- basenames of files converted so far
    fail_reason = nil,      -- text shown on "failed"
    -- Everything below the tab bar happens INSIDE this dashboard: the file
    -- picker and the destination browser render into the tab content region
    -- instead of stacked full-screen dialogs. The browser objects keep their
    -- state (picked files, search filter) for the whole Home lifetime; these
    -- screen fields only say which browser, if any, the active tab is
    -- showing. nil == that tab's landing.
    convert_screen = nil, -- "files" (picker)
    dest_screen = nil,    -- "browser" (destination folder tree)
    convert_picker = nil, -- PickerDialog parked on the Convert tab
    dest_cwd = nil,       -- current folder of the inline destination browser
    content_h = nil,      -- height of the tab content region (measured at init)
}

function HomeDialog:init()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    self.dimen = Geom:new{ w = sw, h = sh }

    -- Storefront-style sizing: every dimension is derived from the device via
    -- scaleBySize, and no text widget is allowed to auto-size past the card
    -- (every TextBoxWidget/row gets an explicit width). The white card covers
    -- the WHOLE screen (frame.dimen = sw x sh) so no other app shows behind
    -- it, while still never spilling past the edges on any device.
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w

    -- The tab content region's height: the card's inner height minus the
    -- MEASURED brand header, tab bar and the three breathing spans. The
    -- inline browsers (file picker, destination tree) use this as their
    -- budget, so their pagers and footers strap to the bottom of the tab
    -- region exactly like they used to strap to the bottom of a full-screen
    -- card.
    local header_vg = self:buildHeader(inner_w, sc)
    local tabbar_vg = self:buildTabBar(inner_w)
    local gh = function(w)
        local s = w.getSize and w:getSize()
        return (s and s.h) or 0
    end
    self.content_h = math.max(sc(120),
        math.floor((sh - pad * 2) - gh(header_vg) - sc(8) - gh(tabbar_vg) - sc(20) - sc(8)))

    local content = self:buildTabContent(self.tab, inner_w, self.content_h)

    -- A full-screen white frame (not a centered content-sized card): the
    -- whole screen paints white on top of whatever UI sits behind it. Both
    -- `dimen` AND `width`/`height` are required — FrameContainer:paintTo paints
    -- its background at container_width/height (= self.width/self.height or the
    -- content size), NOT at dimen. Without width/height the frame only painted
    -- over its content bounds and a strip of the UI below showed at the bottom.
    local frame = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw,
        height = sh,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            header_vg,
            VerticalSpan:new{ width = sc(8) },
            tabbar_vg,
            VerticalSpan:new{ width = sc(20) },
            content,
            VerticalSpan:new{ width = sc(8) },
        },
    }
    self.frame = frame
    self[1] = frame

    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
end

function HomeDialog:onBack()
    -- Back inside a browser leaves it for this tab's landing (state stays
    -- cached on the browser objects). Only a back on a landing closes the
    -- whole dashboard — the ✕ on the header does the same. Everything is a
    -- flashless "ui" repaint: this is an in-place state change, never a
    -- flicker-worthy transition. It delegates to the browser's own leave()
    -- so its _closed flag flips too (the picker uses it to gate its deferred
    -- title upgrade).
    if self.convert_screen == "files" then
        if self.convert_picker then self.convert_picker:leave() end
    elseif self.dest_screen == "browser" then
        self.dest_screen = nil
        self:init()
        UIManager:setDirty(self, "ui")
    else
        UIManager:close(self)
    end
    return true
end

-- The Storefront-style brand lockup: the plugin logo (icon.png beside this
-- file) as a small 24px glyph with "Boldonic" to its right, all the way in
-- the top-left corner of the title row, with the ✕ that leaves the plugin on
-- the far right (the dashboard's only ✕). A hairline rules the bottom of the
-- row in place of TitleBar's bottom line. No image on disk, no logo and no
-- dead gap — a stripped install just gets the title, and self.logo_shown
-- mirrors that for tests.
function HomeDialog:buildHeader(inner_w, sc)
    local theme = require("boldonic_theme")
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local logo
    if ok and lfs and lfs.attributes then
        local dir = (self.plugin and self.plugin.path) or LUA_PLUGIN_DIR
        -- The lockup glyph is the logo BLACKENED and hardened on white BEFORE
        -- scaling: icon.png is a near-black mark on white whose anti-aliased
        -- edges lighten when the 360px master is squeezed to 24px (it read as
        -- grey next to the wordmark). assets/logo-black.png is the same mark
        -- re-thresholded to pure black/white, so the small glyph stays black.
        -- If a designer ships a dedicated monochrome asset later, this is the
        -- file to replace.
        local dir_assets = dir and (dir .. "/assets")
        local black = dir_assets and (dir_assets .. "/logo-black.png") or nil
        local icon = nil
        if black and lfs.attributes(black, "mode") == "file" then
            icon = black
        elseif dir then
            local plain = dir .. "/icon.png"
            if lfs.attributes(plain, "mode") == "file" then
                icon = plain
            end
        end
        if icon then
            logo = ImageWidget:new{
                file = icon,
                width = sc(24),
                height = sc(24),
                -- opaque-on-white glyph: bake it flat like a core icon (no
                -- alpha path, nothing to blend, nothing to grey out).
                is_icon = true,
            }
        end
    end
    self.logo_shown = logo ~= nil

    local title_label = TextWidget:new{
        text = _("Boldonic"),
        face = Font:getFace("smallinfofont", theme.title_font_size or 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local logo_w = 0
    if logo and type(logo.getSize) == "function" then
        local s = logo:getSize()
        logo_w = s and s.w or sc(24)
    end
    local title_w = 0
    if type(title_label.getSize) == "function" then
        local s = title_label:getSize()
        title_w = s and s.w or 0
    end

    -- The ✕ that leaves the plugin. This EXACTLY follows the two recipes that
    -- work on the device: core TitleBar's right-hand ✕ and Storefront's close
    -- button — an IconButton with width/height = the glyph size, padding
    -- adding the tap zone, polished off with allow_flash = false (the rule for
    -- any control that closes the container holding it). A bare Button here
    -- once left a stuck grey highlight instead of closing.
    local close_btn = IconButton:new{
        icon = "close",
        width = sc(24),
        height = sc(24),
        padding = sc(12),
        bordersize = 0,
        background = nil,
        allow_flash = false,
        show_parent = self,
        callback = function()
            UIManager:close(self)
        end,
    }

    local elems = {}
    if logo then
        elems[#elems + 1] = logo
        elems[#elems + 1] = HorizontalSpan:new{ width = sc(8) }
    end
    elems[#elems + 1] = title_label
    elems[#elems + 1] = HorizontalSpan:new{
        width = math.max(sc(8), inner_w - logo_w - sc(8) - title_w - sc(48) - sc(4)),
    }
    elems[#elems + 1] = close_btn

    return VerticalGroup:new{
        align = "left",
        HorizontalGroup:new(elems),
        VerticalSpan:new{ width = sc(6) },
        LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.thick },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    }
end

function HomeDialog:onCloseWidget()
    if self.plugin then
        self.plugin.home = nil
    end
    return true
end

-- ─────────────────────────────── tab bar ─────────────────────────────────

function HomeDialog:showTab(key)
    -- Re-tapping the ACTIVE tab backs out to that tab's landing (same as the
    -- back press inside a browser): the browser hides, its state (picked
    -- files, search filter) stays cached on the browser object. A re-tap
    -- while already on a landing is a no-op.
    if self.tab == key then
        local backed = false
        if key == "convert" and self.convert_screen ~= nil then
            self.convert_screen = nil
            backed = true
        elseif key == "settings" and self.dest_screen ~= nil then
            self.dest_screen = nil
            backed = true
        end
        if not backed then return end
        self:init()
        UIManager:setDirty(self, "ui")
        return
    end
    -- NOTE: there is NO UIManager:replace in this KOReader build (it crashed
    -- the plugin on the Kindle). Re-init the SAME widget for its new tab and
    -- repaint it in place instead. "ui" (not "partial"): flashless AND never
    -- promoted — the panel promotes every FULL_REFRESH_COUNT-th bare partial
    -- to a flashing full, which is exactly the "random" flashing the
    -- dashboard used to show.
    self.tab = key
    -- Switching tabs always lands on the target tab's LANDING: any browser
    -- open on the old tab hides, while its state (picked files, search
    -- filter) stays cached on the browser object for the next open. The ✕ on
    -- the header is still the only thing that leaves the plugin.
    if key == "settings" then self.dest_screen = nil end
    if key == "convert" then self.convert_screen = nil end
    if key == "about" then
        self.dest_screen = nil
        self.convert_screen = nil
    end
    self:init()
    UIManager:setDirty(self, "ui")
end

-- The tab bar is Storefront's, with one user-facing divergence: EVERY tab
-- keeps its label visible (active = bold black + full-width underline;
-- inactive = grey), because here "Convert A File / Settings" are words, not
-- guessable symbols — icons always sit beside the labels they explain. The
-- plugin SHIPS no glyphs; until assets/* exist the bar falls back to
-- label-only and still reads perfectly. Equal fixed widths keep the bar
-- exactly filling the row; tabs are InputContainers over image/text blocks
-- centered in each window, the same tap recipe as the picker rows.
function HomeDialog:buildTabBar(content_w)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local theme = require("boldonic_theme")
    local tabs = {
        { key = "convert", label = _("Convert A File") },
        { key = "settings", label = _("Settings") },
        { key = "about", label = _("About") },
    }
    local gaps = sc(6) * (#tabs - 1)
    local btn_w = math.floor((content_w - gaps) / #tabs)
    local tab_font = theme.face_label_size or 18
    local icons = self:tabIconPaths()
    local widgets = {}
    for i, t in ipairs(tabs) do
        if i > 1 then
            widgets[#widgets + 1] = HorizontalSpan:new{ width = sc(6) }
        end
        local active = self.tab == t.key
        local icon = icons and icons[t.key]
        local elems = {}
        if icon then
            elems[#elems + 1] = ImageWidget:new{
                file = active and icon.active or icon.inactive,
                width = sc(22),
                height = sc(22),
                -- is_icon makes ImageWidget bake a transparent PNG onto white
                -- at load time (the core elevated-icon path): no alpha blit,
                -- so a glyph can never paint itself black on this panel.
                is_icon = true,
            }
            elems[#elems + 1] = HorizontalSpan:new{ width = sc(6) }
        end
        elems[#elems + 1] = TextWidget:new{
            text = t.label,
            face = Font:getFace("smallinfofont", tab_font),
            bold = active,
            fgcolor = active and Blitbuffer.COLOR_BLACK or theme.color_label_dim,
        }
        local row = HorizontalGroup:new(elems)
        local underline
        if active then
            underline = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = btn_w, h = sc(3) },
            }
        else
            underline = VerticalSpan:new{ width = sc(3) }
        end
        local group = VerticalGroup:new{
            align = "center",
            row,
            VerticalSpan:new{ width = sc(4) },
            underline,
        }
        local gh = type(group.getSize) == "function" and (group:getSize().h or sc(40)) or sc(40)
        local tab_btn = InputContainer:new{
            FrameContainer:new{
                padding_top = sc(4),
                padding_bottom = 0,
                bordersize = 0,
                CenterContainer:new{
                    dimen = Geom:new{ w = btn_w, h = gh },
                    group,
                },
            },
        }
        tab_btn.show_parent = self
        tab_btn.isFocusable = function() return true end
        tab_btn.onTap = function()
            self:showTab(t.key)
            return true
        end
        tab_btn.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function()
                        local d = tab_btn.dimen or { x = 0, y = 0, w = 0, h = 0 }
                        return Geom:new{
                            x = d.x or 0,
                            y = d.y or 0,
                            w = d.w or 0,
                            h = d.h or 0,
                        }
                    end,
                },
            },
        }
        widgets[#widgets + 1] = tab_btn
    end
    return HorizontalGroup:new(widgets)
end

-- Resolve the optional tab glyphs (plugin-local assets/). Storefront's
-- convention, adapted: each tab needs two monochrome variants — the inactive
-- grey glyph (tab-<key>.<ext>) and the active black one (tab-<key>-active.<ext>).
-- Both must exist for a tab's icon to show, which keeps the label fallback
-- above honest. Plain PNGs are the proven-safe render path on this device
-- (icon.png months of uptime); a true vector .svg with the same names is
-- also accepted when one is ever exported. Never throws when assets/ is
-- absent (lfs is stubbed in harness and real on-device).
function HomeDialog:tabIconPaths()
    if self._tab_icon_paths then return self._tab_icon_paths end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs or not lfs.attributes then return nil end
    local has = function(p) return lfs.attributes(p, "mode") == "file" end
    local dir = (self.plugin and self.plugin.path) or LUA_PLUGIN_DIR
    if not dir then return nil end
    local keys = { "convert", "settings", "about" }
    local out = {}
    for _, key in ipairs(keys) do
        local inactive, active
        for _, ext in ipairs({ "png", "svg" }) do
            local base = dir .. "/assets/tab-" .. key
            local inc = base .. "." .. ext
            local act = base .. "-active." .. ext
            if has(inc) and has(act) then
                inactive, active = inc, act
                break
            end
        end
        if inactive and active then
            out[key] = { inactive = inactive, active = active }
        end
    end
    self._tab_icon_paths = next(out) and out or nil
    return self._tab_icon_paths
end

function HomeDialog:row(text, opts)
    opts = opts or {}
    return Button:new{
        text = text,
        menu_style = true,
        -- Explicit radius so the tap highlight inverts the WHOLE box: core's
        -- Button flash uses a rounded rect whenever radius is nil, which on
        -- our square buttons reads as a blob that skips the corners.
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        width = self.row_w,
        callback = opts.callback,
        hold_callback = opts.hold_callback,
    }
end

function HomeDialog:settingRow(label, value)
    return TextBoxWidget:new{
        text = label .. ":  " .. value,
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    }
end

function HomeDialog:header(text)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return FrameContainer:new{
        padding_top = sc(6),
        padding_bottom = sc(2),
        bordersize = 0,
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont"),
        },
    }
end

-- Thin horizontal divider (like KOReader's settings screens)
function HomeDialog:hairline()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return FrameContainer:new{
        width = self.row_w,
        bordersize = 0,
        LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{ w = self.row_w, h = 1 },
        },
    }
end

-- A small caption (plain text, same face as the rows — not a button).
function HomeDialog:caption(text)
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    }
end

-- The Convert/Settings/About tab body. Everything runs BELOW the always-visible
-- brand header + tab bar: the convert state machine, the idle landing, the
-- Settings tab (including destination and bolding controls), and the About tab
-- (version + how-it-works guide).
function HomeDialog:buildTabContent(tab, width, area_h)
    self.row_w = width
    if tab == "about" then
        return self:renderAbout()
    end
    if tab == "settings" then
        if self.dest_screen == "browser" then
            return self:renderDestinationBrowser(area_h)
        end
        return self:renderSettings()
    end
    if self.convert_screen == "files" then
        return self:renderFilesBrowser(area_h)
    end
    if self.convert_state == "converting" then
        return self:renderConvertWaiting()
    end
    if self.convert_state == "done" then
        return self:renderConvertDone()
    end
    if self.convert_state == "failed" then
        return self:renderConvertFailed()
    end
    return self:renderConvertIdle()
end

-- ──────────────── Convert tab browsers (inline, below the tabs) ────────────────
-- The user rule: the brand header and the tab bar NEVER leave the screen.
-- Picking files happens inside the active tab's content region — no stacked
-- full-screen dialogs — and every back/leave/tab-switch returns to the tab's
-- landing with the browser's state (picked files, search filter) cached on
-- the browser object.

function HomeDialog:renderFilesBrowser(area_h)
    local vg = VerticalGroup:new{ align = "left" }
    local picker = self.convert_picker
    if not picker then
        picker = pickerModule():new{ plugin = self.plugin, home = self }
        self.convert_picker = picker
    end
    picker:renderInto(vg, self.row_w, area_h or self.content_h)
    return vg
end

-- Open/leave the inline file picker on the Convert tab (chooseAndConvert
-- wires into this).
function HomeDialog:openFilesBrowser()
    if not self.convert_picker then
        self.convert_picker = pickerModule():new{ plugin = self.plugin, home = self }
    end
    self.convert_picker._closed = false
    self.tab = "convert"
    self.convert_screen = "files"
    self.convert_state = "idle"
    self:refresh()
end

function HomeDialog:leaveFilesBrowser()
    self.convert_screen = nil
    self:refresh()
end

function HomeDialog:refresh()
    UIManager:nextTick(function()
        self:init()
        -- "ui": flashless and never promoted to a flashing full (partials are).
        UIManager:setDirty(self, "ui")
    end)
end

-- ─────────────────────── Settings tab ───────────────────────────────

-- The ratio presets + custom, as selection rows (menu-style, active prefixed
-- with ✓ so the highlighted choice reads even before the highlight).
function HomeDialog:renderSettings()
    local vg = VerticalGroup:new{ align = "left" }
    local plugin = self.plugin
    local ratio = plugin:ratio() or 40
    local mode = plugin:mode() or "copy"
    local sc = function(v) return Device.screen:scaleBySize(v) end

    table.insert(vg, self:header(_("Bolding ratio")))
    table.insert(vg, self:caption(_("How many leading characters of each word get bolded.")))
    local presets = { { 30, _("Light") }, { 40, _("Medium") }, { 50, _("Strong") } }
    local custom = true
    for _, p in ipairs(presets) do
        if ratio == p[1] then custom = false end
        table.insert(vg, self:row(string.format("%s%s  \226\128\148  %d%%",
            (ratio == p[1]) and "\226\156\147  " or "", p[2], p[1]), {
            callback = function()
                plugin:setRatio(p[1])
                self:refresh()
            end,
        }))
    end
    table.insert(vg, self:row(string.format("%s%s \226\128\148  %d%%",
        custom and "\226\156\147  " or "", _("Custom"), ratio), {
        callback = function() self:changeRatioDialog() end,
    }))
    table.insert(vg, VerticalSpan:new{ width = sc(18) })

    table.insert(vg, self:header(_("Keep the original?")))
    local modes = {
        { "copy", _("Copy original (recommended)") },
        { "replace", _("Replace original") },
    }
    for _, m in ipairs(modes) do
        table.insert(vg, self:row(string.format("%s%s",
            (mode == m[1]) and "\226\156\147  " or "", m[2]), {
            callback = function()
                plugin:setMode(m[1])
                self:refresh()
            end,
        }))
    end
    table.insert(vg, self:caption(mode == "copy"
        and _("Keeps the original and creates a bolded copy (named \226\128\156<your-book>_boldonic.epub\226\128\157).")
        or _("Overwrites the original file with the bolded version \226\128\148 the path never changes.")))
    table.insert(vg, VerticalSpan:new{ width = sc(18) })

    table.insert(vg, self:header(_("Destination folder")))
    table.insert(vg, self:row(string.format("%s\n%s  \226\128\164  tap to choose",
        dest_name(plugin), _("where bolded copies land (copy mode)")), {
        callback = function() self:openDestinationBrowser() end,
    }))

    return vg
end

function HomeDialog:renderAbout()
    local vg = VerticalGroup:new{ align = "left" }
    local plugin = self.plugin
    local sc = function(v) return Device.screen:scaleBySize(v) end

    table.insert(vg, TextBoxWidget:new{
        text = "Boldonic " .. tostring((plugin and plugin.VERSION) or ""),
        face = Font:getFace("smallinfofontbold"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(12) })
    table.insert(vg, self:header(_("How it works")))
    table.insert(vg, VerticalSpan:new{ width = sc(4) })
    table.insert(vg, TextBoxWidget:new{
        text = _("1. On the Convert A File tab, pick EPUBs from this device \226\128\148 the list shows every EPUB it scanned, and rows already converted are flagged.\n\n")
            .. _("2. Tap the convert row (or the Currently open row). Boldonic rewrites the book's text so the first characters of every word print darker, then copies the archive.\n\n")
            .. _("3. In copy mode the bolded version lands next to the original (or in the folder you chose in Settings); in replace mode the original is overwritten in place, so your reading history stays. The bolding ratio in Settings tunes how much of each word is darkened."),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })

    return vg
end

function HomeDialog:changeRatioDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local plugin = self.plugin
    local home = self
    local ratio_dialog
    ratio_dialog = InputDialog:new{
        title = _("Custom bolding ratio"),
        input = tostring(plugin:ratio() or 40),
        input_hint = _("10 to 90 (percent of each word bolded)"),
        type = "number",
        modal = true,
        buttons = {
            {
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        local text = ratio_dialog:getInputText() or ""
                        local v = tonumber(text:match("%d+") or "")
                        v = v and math.max(10, math.min(90, math.floor(v))) or nil
                        if v then
                            plugin:setRatio(v)
                            UIManager:close(ratio_dialog)
                            home:refresh()
                        else
                            UIManager:show(Notification:new{
                                text = _("Please enter a number between 10 and 90."),
                                timeout = 4,
                            })
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(ratio_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(ratio_dialog)
end

-- ──────────────── destination folder (inline tree) ─────────────────
-- An inline DRILL-DOWN folder browser on the Settings tab (the same card
-- language as everywhere: menu-style rows). Tapping a folder descends into
-- it; "… (parent folder)" climbs back up; "Select this folder" pins the
-- current folder as the destination; "Create New Folder…" asks for a name,
-- makes it NOW (so "Select this folder" has something to pin), and descends.
-- "Next to the original" (the evergreen default) is a row of its own at the
-- top — the "" value mode alternates with a real folder choice.

function HomeDialog:openDestinationBrowser()
    local plugin = self.plugin
    local start = plugin:destFolder() or ""
    if start == "" then
        start = plugin:deviceRoot()
    end
    -- Safety: never browse into the plugin directories (walking koreader/
    -- on the user partition is slow and pointless).
    self.dest_cwd = start
    self.dest_screen = "browser"
    self:refresh()
end

function HomeDialog:renderDestinationBrowser(area_h)
    local vg = VerticalGroup:new{ align = "left" }
    local plugin = self.plugin
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local cwd = self.dest_cwd
    local root = plugin:deviceRoot()

    table.insert(vg, self:header(_("Destination folder")))
    table.insert(vg, self:row(string.format("%s%s",
        (plugin:destFolder() == "" or plugin:destFolder() == nil)
            and "\226\156\147  " or "", _("Next to the original")), {
        callback = function()
            plugin:setDestFolder("")
            self.dest_screen = nil
            self:refresh()
        end,
    }))

    table.insert(vg, VerticalSpan:new{ width = sc(10) })
    table.insert(vg, self:caption(string.format("%s\n%s",
        _("Inside this folder"), cwd or root)))
    table.insert(vg, VerticalSpan:new{ width = sc(4) })

    if cwd and cwd ~= root and cwd ~= "/" then
        table.insert(vg, self:row(_("\226\128\166  (parent folder)"), {
            callback = function()
                self.dest_cwd = tostring(cwd):match("^(.*)/[^/]+$") or root
                self:refresh()
            end,
        }))
    end

    local subs = plugin:listSubfolders(cwd or root)
    local shown = 0
    local budget = (area_h or self.content_h) - sc(260)
    for _, name in ipairs(subs or {}) do
        if (shown + 1) * self:rowHeightForTree() <= math.max(sc(60), budget) then
            table.insert(vg, self:row("\226\128\186  " .. name, {
                callback = function()
                    self.dest_cwd = (cwd == "/" and "" or (cwd or "")) .. "/" .. name
                    self:refresh()
                end,
            }))
            shown = shown + 1
        end
    end
    if shown < #(subs or {}) then
        table.insert(vg, self:caption(string.format(
            _("\226\128\166  and %d more folder(s)"), #subs - shown))
        )
    end
    if #(subs or {}) == 0 then
        table.insert(vg, self:caption(_("No subfolders here \226\128\148 use Create New Folder\226\128\166 to make one.")))
    end

    table.insert(vg, VerticalSpan:new{ width = sc(12) })
    table.insert(vg, self:row(_("Select this folder"), {
        callback = function()
            plugin:setDestFolder(cwd or root)
            self.dest_screen = nil
            self:refresh()
        end,
    }))
    table.insert(vg, self:row(_("Create New Folder\226\128\166"), {
        callback = function() self:createFolderDialog() end,
    }))
    table.insert(vg, self:row(_("Cancel"), {
        callback = function()
            self.dest_screen = nil
            self:refresh()
        end,
    }))

    return vg
end

-- A measured one-row height for the destination browser's budget check.
function HomeDialog:rowHeightForTree()
    if not self._row_h then
        self._row_h = self:row("probe").getSize and self:row("probe"):getSize().h or 44
    end
    return self._row_h
end

function HomeDialog:createFolderDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local plugin = self.plugin
    local home = self
    local name_dialog
    name_dialog = InputDialog:new{
        title = _("Create New Folder"),
        input = "",
        input_hint = _("A new folder inside:\n") .. tostring(self.dest_cwd or plugin:deviceRoot()),
        type = "text",
        modal = true,
        buttons = {
            {
                {
                    text = _("Create"),
                    is_enter_default = true,
                    callback = function()
                        local text = name_dialog:getInputText() or ""
                        local name = text:match("^%s*(.-)%s*$") or ""
                        if name == "" or name:find("/") then
                            UIManager:show(Notification:new{
                                text = _("Please use a single name without slashes."),
                                timeout = 4,
                            })
                            return
                        end
                        local base = self.dest_cwd or plugin:deviceRoot()
                        local parent = (base == "/") and "" or base
                        local path = parent .. "/" .. name
                        local ok, err = plugin:mkdirs(path)
                        if ok then
                            plugin:setDestFolder(path)
                            UIManager:close(name_dialog)
                            self.dest_cwd = path
                            home:refresh()
                        else
                            UIManager:show(Notification:new{
                                text = _("Could not create the folder: ") .. tostring(err or "?"),
                                timeout = 4,
                            })
                        end
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(name_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(name_dialog)
end

-- ─────────────────────────── Convert tab ───────────────────────────────

-- Idle landing: pick files (the multi-select EPUB picker), or convert the
-- one currently open in the reader (only shown when it is an EPUB), plus a
-- Settings summary row that jumps to the Settings tab.
function HomeDialog:renderConvertIdle()
    local vg = VerticalGroup:new{ align = "left" }
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local plugin = self.plugin
    local book = plugin:currentBookPath()

    table.insert(vg, self:header(_("Convert A File")))
    table.insert(vg, self:row(_("Click Here To Convert File(s)"), {
        callback = function() plugin:chooseAndConvert() end,
    }))

    -- "Currently open" only appears when there IS an open EPUB (bolding only
    -- rewrites XHTML; other formats have no convertable text content). It
    -- breathes with a spacer so the Settings block sits clearly apart.
    if book and book ~= "" and plugin:isEpub(book) then
        table.insert(vg, VerticalSpan:new{ width = sc(18) })
        local name = book:match("([^/]+)$") or book
        local size = file_size(book)
        table.insert(vg, self:header(_("Currently open")))
        table.insert(vg, self:row(
            string.format("\226\151\128  %s\n%s  \226\128\164  tap to convert", name,
                (size > 0 and string.format(_("%.1f MB"), size / 1048576) or "ebook")), {
            callback = function()
                -- one-tap convert (no picker, so no whole-card index): guard
                -- the duplicate before the copy is overwritten
                plugin:guardConverted({ book }, function(paths)
                    self:beginConvertBatch(paths)
                end)
            end,
        }))
    end

    -- Selected settings: clean list showing each setting with its current value.
    -- No navigation button — just clear visibility of what will be used.
    table.insert(vg, VerticalSpan:new{ width = sc(18) })
    local mode = plugin:mode() or "copy"
    local dest = dest_name(plugin)
    local ratio_val = plugin:ratio() or 40
    table.insert(vg, self:header(_("Selected Settings")))
    table.insert(vg, self:settingRow(_("Bolding ratio"), ratio_label(ratio_val)))
    table.insert(vg, self:hairline())
    table.insert(vg, self:settingRow(_("Keep original"),
        mode == "copy" and _("Yes (copy)") or _("No (replace)")))
    table.insert(vg, self:hairline())
    table.insert(vg, self:settingRow(_("Output folder"), dest))

    return vg
end

-- ─────────────── in-dashboard conversion: the progress sink ──────────────
-- plugin:convertBooks(paths, self) drives these callbacks synchronously
-- while each book is rewritten on the UI thread. Each one rebuilds the
-- Convert tab in place, so the whole flow is visible inside Boldonic — the
-- dashboard never closes, and afterwards Convert More / Try Again keep
-- controlling the same window. State changes paint via repaintNow (a
-- flashing full refresh) so the panel really shows them; see the header
-- comment.

function HomeDialog:beginConvertBatch(paths)
    self.convert_state = "converting"
    self.convert_paths = type(paths) == "table" and paths or {}
    self.convert_total = #self.convert_paths
    self.convert_index = 0
    self.conversion_list = {}
    self.fail_reason = nil
    self.plugin:convertBooks(self.convert_paths, self)
end

-- Rebuild this dashboard's frame and repaint it with a flushing FULL refresh
-- (forceRePaint alone enqueues only a partial over the white card, which an
-- e-ink panel can fail to show when the whole screen is repainting).
function HomeDialog:repaintNow()
    self:init()
    UIManager:setDirty(self, "full")
    UIManager:forceRePaint()
end

-- FLASH-FREE variant: rebuilds and repaints in place WITHOUT the
-- full-refresh flash. Used where a change is almost always followed a frame
-- later by a real full transition. The conversion flow is effectively
-- single-file (a failure aborts the batch), so the only soft-repaint is the
-- very first file start, which repaintNow covers anyway; this stays for
-- parity with the CrossDrop sink shape.
function HomeDialog:repaintSoft()
    self:init()
    UIManager:setDirty(self, "partial")
    UIManager:forceRePaint()
end

function HomeDialog:onBeginFile(path, idx, total)
    self.convert_state = "converting"
    self.convert_path = path
    self.convert_filename = path:match("([^/]+)$") or path
    self.convert_index = idx or 1
    self.convert_total = total or #(self.convert_paths or {})
    -- File starts repaint NOW (flashing full): the real transition into
    -- Converting. (Mid-batch soft-repaints would strobe; the batch breaks on
    -- a failure, so there is never more than one live file.)
    self:repaintNow()
    local top = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
        and UIManager._window_stack[#UIManager._window_stack].widget
    logger.info("boldonic: home shows Converting ", idx, "/", total, " ",
        self.convert_filename, " (dashboard on top: ", tostring(top == self) or "?", ")")
end

function HomeDialog:onFileSent(path, outf)
    self.conversion_list[#self.conversion_list + 1] = path:match("([^/]+)$") or path
    return true
end

function HomeDialog:onFileFailed(path, reason)
    self.fail_reason = (path:match("([^/]+)$") or path) .. "\n" .. tostring(reason)
    return true
end

function HomeDialog:onDone(all_ok)
    self.convert_state = all_ok and "done" or "failed"
    if not all_ok and not self.fail_reason then
        self.fail_reason = _("The conversion did not complete.")
    end
    self:repaintNow()
    local top = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
        and UIManager._window_stack[#UIManager._window_stack].widget
    logger.info("boldonic: home shows ", self.convert_state,
        " (dashboard on top: ", tostring(top == self) or "?", ")")
end

function HomeDialog:convertMore()
    self.convert_state = "idle"
    self.convert_paths = nil
    self.conversion_list = {}
    self:init()
    UIManager:forceRePaint()
    self.plugin:chooseAndConvert()
end

function HomeDialog:tryAgain()
    self:beginConvertBatch(self.convert_paths or {})
end

function HomeDialog:backToIdle()
    self.convert_state = "idle"
    self.convert_paths = nil
    self.convert_path = nil
    self.convert_filename = nil
    self.conversion_list = {}
    self.fail_reason = nil
    self:init()
    UIManager:setDirty(self, "full")
end

-- Converting: painted BEFORE the blocking rewrite starts (the Storefront
-- "paint progress first, then block" rule), so no state ever reads as a
-- frozen screen.
function HomeDialog:renderConvertWaiting()
    local vg = VerticalGroup:new{ align = "left" }
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local plugin = self.plugin

    table.insert(vg, self:header(string.format(_("Converting %d of %d"),
        math.max(1, self.convert_index or 1), math.max(1, self.convert_total or 1))))

    table.insert(vg, TextWidget:new{
        text = tostring(self.convert_filename or "?"),
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = self.row_w,
    })
    if self.convert_path and plugin and plugin.outputDescription then
        table.insert(vg, TextWidget:new{
            text = plugin:outputDescription(self.convert_path),
            face = Font:getFace("smallinfofont"),
            max_width = self.row_w,
        })
    end

    table.insert(vg, VerticalSpan:new{ width = sc(12) })
    table.insert(vg, TextBoxWidget:new{
        text = _("… please wait\n\nBoldonic is rewriting the book's text and copying the archive."),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })

    return vg
end

function HomeDialog:renderConvertDone()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local names = self.conversion_list or {}
    local lines = {}
    for _, n in ipairs(names) do
        lines[#lines + 1] = "\226\156\147  " .. n
    end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Done")))
    table.insert(vg, TextBoxWidget:new{
        text = string.format(_("Converted %d file(s)."), #names)
            .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or ""),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Convert more files\226\128\166"), {
        callback = function() self:convertMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

function HomeDialog:renderConvertFailed()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, self:header(_("Conversion failed")))
    table.insert(vg, TextBoxWidget:new{
        text = tostring(self.fail_reason or _("The conversion did not complete.")),
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    })
    table.insert(vg, VerticalSpan:new{ width = sc(8) })
    table.insert(vg, self:row(_("Try again"), {
        callback = function() self:tryAgain() end,
    }))
    table.insert(vg, self:row(_("Convert more files\226\128\166"), {
        callback = function() self:convertMore() end,
    }))
    table.insert(vg, self:row(_("Back"), {
        callback = function() self:backToIdle() end,
    }))
    return vg
end

return HomeDialog