--[[
Boldonic — KOReader plugin.

Adds a "Boldonic" entry to the menu that opens a full-screen dashboard where
you pick EPUBs and re-render them with a larger share of each word in bold
(an assistive reading comfort feature). The word-bolding engine is a pure-Lua
port of the GitHub project's boldonic.c helper, byte-identical to it; EPUB
read/write uses the libarchive bindings KOReader ships (ffi/archiver), so the
device needs no external tool and the result is a valid EPUB the built-in
reader opens as a book.

The dashboard is the CrossDrop plugin's look and flow (same storefront-style
full-screen card, tab bar and picker), simplified to three tabs:

  * Convert A File — a device-wide EPUB picker (multi-select, real titles, a
    keyword search). The top row converts the picked files.
  * Settings — how much of each word to bold (Light 30 / Medium 40 [default]
    / Strong 50 / Custom 10-90), whether to write a copy or replace the
    original, and where a copy lands (next to the original, or any folder you
    browse to / create on this device).

Conversions keep the reading history: a copy is a sibling
"<stem>_boldonic.epub" (underscore suffix, like the Kindle extension); replace
writes a temp file next to the original and renames it over the original, so
the path KOReader has open never changes. A chosen output folder is created
(mkdir -p) only when an actual conversion writes into it.

Filesystem access goes through lfs only (no os.rename/os.mkdir), so the test
harness can stub it out of the way.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local DEFAULT_RATIO = 40
local RATIO_MIN, RATIO_MAX = 10, 90

-- UI extras (toast, waiting dialog, full-screen Home) are sibling modules in
-- this plugin folder. They must be required at plugin load (the Storefront
-- pattern), because PluginLoader only keeps this folder on package.path for
-- the duration of loading main.lua — a lazy bare require from a later
-- button/nextTick callback would search a path that no longer contains this
-- folder and crash with "module not found".
local toast_mod = require("boldonic_toast")
local progress_mod = require("boldonic_progress")
local home_mod = require("boldonic_home")
local picker_mod = require("boldonic_picker")
local log_mod = require("boldonic_log")
local function toastModule() return toast_mod end
local function progressModule() return progress_mod end
local function homeModule() return home_mod end
local function pickerModule() return picker_mod end
local function logModule() return log_mod end

local BOLDONIC = WidgetContainer:extend{
    name = "boldonic",
    is_doc_only = false,
    -- Shown at the bottom of the Settings tab so the running build is always
    -- identifiable on the device (KOReader loads plugins once at startup).
    VERSION = "1.0.0",
}

-- ─────────────────────────────── settings ────────────────────────────────

function BOLDONIC:ratio()
    local v = tonumber(G_reader_settings:readSetting("boldonic_ratio"))
    if v and v >= RATIO_MIN and v <= RATIO_MAX then return v end
    return DEFAULT_RATIO
end

function BOLDONIC:setRatio(v)
    v = tonumber(v) or DEFAULT_RATIO
    if v < RATIO_MIN then v = RATIO_MIN end
    if v > RATIO_MAX then v = RATIO_MAX end
    G_reader_settings:saveSetting("boldonic_ratio", v)
end

-- "copy" writes a <stem>_boldonic.epub; "replace" rewrites the original in
-- place (its path never changes, so reading history survives).
function BOLDONIC:mode()
    return (G_reader_settings:readSetting("boldonic_mode") == "replace") and "replace" or "copy"
end

function BOLDONIC:setMode(m)
    G_reader_settings:saveSetting("boldonic_mode", (m == "replace") and "replace" or "copy")
end

-- Destination folder: "" == next to the original (the default). Anything
-- else is an absolute folder path (e.g. "/mnt/us/Boldonic Books"), created
-- on disk only when a conversion actually writes into it.
function BOLDONIC:destFolder()
    return G_reader_settings:readSetting("boldonic_dest") or ""
end

function BOLDONIC:setDestFolder(path)
    if not path or path == "" then
        G_reader_settings:saveSetting("boldonic_dest", nil)
        return
    end
    G_reader_settings:saveSetting("boldonic_dest", tostring(path))
end

-- Where a conversion of `book_path` lands, or nil when the mode rewrites the
-- original in place (replace mode — see convertOne).
function BOLDONIC:outputPathFor(book_path)
    if not book_path or book_path == "" then return nil end
    if self:mode() == "replace" then return nil end
    local base = tostring(book_path):match("([^/]+)$") or tostring(book_path)
    local stem = base:match("^(.*)%.[^.]+$") or base
    if stem == "" then stem = base end
    local dir = self:destFolder()
    if not dir or dir == "" then
        dir = tostring(book_path):match("^(.*)/[^/]+$")
        if not dir then return tostring(book_path) .. "_boldonic.epub" end
        if dir == "" then dir = "/" end
    else
        dir = tostring(dir):gsub("/+$", "")
    end
    if dir == "/" then
        return "/" .. stem .. "_boldonic.epub"
    end
    return dir .. "/" .. stem .. "_boldonic.epub"
end

-- Human line for where conversions land (toasts, and the Settings tab).
function BOLDONIC:outputDescription(book_path)
    if self:mode() == "replace" then
        return _("replaces the original")
    end
    local dest = self:destFolder()
    if not dest or dest == "" then
        return _("next to the original")
    end
    return "/" .. tostring(dest):gsub("^/+", ""):gsub("/+$", "")
end

-- Conversion log (persistent, survives plugin updates)
function BOLDONIC:isConverted(source_path)
    return logModule().isConverted(source_path)
end

function BOLDONIC:recordConversion(source_path, output_path)
    local title = self:titleForPath(source_path) or ""
    local ratio = self:ratio()
    local mode = self:mode()
    return logModule().record(source_path, output_path, mode, ratio, title)
end

function BOLDONIC:syncLog()
    return logModule().sync()
end

-- Optional: get title from document registry for log entry
function BOLDONIC:titleForPath(path)
    local ok, registry = pcall(require, "document/documentregistry")
    if ok and registry and registry.openDocument then
        local doc = registry:openDocument(path)
        if doc and doc.getProps then
            local props = doc:getProps()
            if props and props.title then
                if doc.close then pcall(doc.close, doc) end
                return props.title
            end
        end
        if doc and doc.close then pcall(doc.close, doc) end
    end
    return nil
end

-- ─────────────────────────── device folder tree ──────────────────────────

-- Directory names never offered as output folders (the picker's EXCLUDED_DIRS
-- rationale; walking them is slow and they hold no books).
local EXCLUDED_DIRS = {
    koreader = true, extensions = true, mrpackages = true,
    system = true, audible = true, fonts = true, voice = true,
    screenshots = true, wallpapers = true, kmc = true, libkh = true,
    proc = true, sys = true, dev = true, run = true, tmp = true,
    ["lost+found"] = true,
}

-- Where the destination browser roots: the Kindle user partition, else
-- KOReader's home folder, else the filesystem root.
function BOLDONIC:deviceRoot()
    if self.scan_root then return self.scan_root end
    if Device and Device.isKindle and Device:isKindle() then
        return "/mnt/us"
    end
    local ok, fmu = pcall(require, "apps/filemanager/filemanagerutil")
    if ok and fmu and fmu.getHomeFolder then
        local home = fmu.getHomeFolder()
        if home and home ~= "" then return home end
    end
    return "/"
end

-- The folder names directly inside `dir`, sorted (lfs-only walk). Used by
-- the destination browser's tree; an unreadable dir yields an empty list.
function BOLDONIC:listSubfolders(dir)
    local out = {}
    if not dir or not lfs.dir then return out end
    local ok, iter, obj = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return out end
    for entry in iter, obj do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "."
            and not EXCLUDED_DIRS[entry] and entry:sub(-4) ~= ".sdr" then
            local fp = dir .. "/" .. entry
            local attr = lfs.attributes(fp)
            if type(attr) == "table" and attr.mode == "directory" then
                out[#out + 1] = entry
            end
        end
    end
    table.sort(out)
    return out
end

-- mkdir -p (lfs.mkdir is single-level): create every ancestor of `dir`.
-- Returns (true) or (nil, path_that_failed).
function BOLDONIC:mkdirs(dir)
    dir = tostring(dir or "")
    if dir == "" or dir == "/" then return true end
    local cur = ""
    for seg in dir:gmatch("[^/]+") do
        cur = cur .. "/" .. seg
        local mode = lfs.attributes(cur, "mode")
        if not mode then
            if not lfs.mkdir(cur) then
                return nil, cur
            end
        elseif mode ~= "directory" then
            return nil, cur
        end
    end
    return true
end

-- ────────────────────────────── conversion ───────────────────────────────

function BOLDONIC:isEpub(path)
    local ext = tostring(path or ""):match("%.([^.]+)$")
    return ext ~= nil and string.lower(ext) == "epub"
end

function BOLDONIC:currentBookPath()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file or doc.file == "" then return nil end
    return doc.file
end

-- Convert one book to its final path. Copy mode writes into the chosen
-- folder (created on demand). Replace mode converts to a temp file next to
-- the original, then renames it over the original — the path never changes.
-- Returns (true) or (nil, err).
function BOLDONIC:convertOne(path, ratio)
    local Convert = require("boldonic_convert")
    ratio = ratio or self:ratio()
    if self:mode() == "replace" then
        local dir = tostring(path):match("^(.*)/[^/]+$") or "."
        local base = tostring(path):match("([^/]+)$") or path
        local stem = base:match("^(.*)%.[^.]+$") or base
        local tmp = dir .. "/." .. stem .. ".boldonic.tmp"
        local ok, err = Convert.file(path, tmp, ratio)
        if not ok then
            return nil, err
        end
        if lfs.rename(tmp, path) then
            return true
        end
        os.remove(tmp)
        return nil, _("could not replace the original file")
    end
    local out = self:outputPathFor(path)
    if not out then return nil, "no output path" end
    local out_dir = out:match("^(.*)/[^/]+$") or "."
    local ok_dir, err_dir = self:mkdirs(out_dir)
    if not ok_dir then
        return nil, _("could not create the output folder (") .. tostring(err_dir) .. ")"
    end
    -- Write to a temp file in the same folder, then rename it into place: a
    -- failed conversion must never delete a pre-existing converted copy, and
    -- re-converting over an old copy stays atomic.
    local dest_base = out:match("([^/]+)$") or out
    local dest_stem = dest_base:match("^(.*)%.[^.]+$") or dest_base
    local tmp_out = out_dir .. "/." .. dest_stem .. ".boldonic.tmp"
    local ok, err = Convert.file(path, tmp_out, ratio)
    if not ok then return nil, err end
    if lfs.rename(tmp_out, out) then
        self:recordConversion(path, out)
        return true
    end
    os.remove(tmp_out)
    return nil, _("could not move the converted file into place")
end

-- Convert a batch of picked books. `sink` is the open dashboard: its
-- callbacks (onBeginFile/onProgress/onFileSent/onFileFailed/onDone) repaint
-- the Convert tab in place, so nothing is ever closed mid-batch. Without a
-- dashboard sink it falls back to the standalone per-file dialog. Returns
-- true when every file converted.
function BOLDONIC:convertBooks(paths, sink)
    sink = sink or {}
    local seen, ordered = {}, {}
    for _, p in ipairs(paths or {}) do
        p = tostring(p or "")
        if p ~= "" and not seen[p] then
            seen[p] = true
            ordered[#ordered + 1] = p
        end
    end
    if #ordered == 0 then return false end
    table.sort(ordered)
    local ratio = self:ratio()

    -- The dashboard sink drives its own callbacks (onBeginFile/onDone...); a
    -- bare call (convertBooks(paths) with no sink — or any sink without
    -- onBeginFile) means standalone per-file conversion. Gate on onBeginFile,
    -- NOT onProgress: the Home sink has none, and gating on it would send
    -- every in-dashboard batch down the standalone path.
    if type(sink.onBeginFile) ~= "function" then
        for _, p in ipairs(ordered) do
            self:convertFile(p)
        end
        return true
    end

    local all_ok = true
    for i, path in ipairs(ordered) do
        if sink.onBeginFile then sink:onBeginFile(path, i, #ordered) end
        local ok, err = self:convertOne(path, ratio)
        if not ok then
            all_ok = false
            if sink.onFileFailed then
                sink:onFileFailed(path, tostring(err or "conversion failed"))
            end
            break
        end
        if sink.onFileSent then sink:onFileSent(path, self:outputPathFor(path)) end
        logger.info("boldonic: converted ", path)
    end
    if sink.onDone then sink:onDone(all_ok) end
    return all_ok
end

-- Standalone conversion (no dashboard sink): a waiting dialog per file, then
-- a toast. Used by convertCurrentBook and as convertBooks' fallback.
function BOLDONIC:convertFile(book_path)
    if not book_path or book_path == "" then return end
    local filename = book_path:match("([^/]+)$") or book_path
    local progress = progressModule().new(filename, { folder = self:outputDescription(book_path) })
    local ok, err = self:convertOne(book_path, self:ratio())
    UIManager:close(progress)
    if ok then
        toastModule().show(string.format(_("Converted  %s\n(%s)"),
            tostring(filename), self:outputDescription(book_path)), 3)
    else
        toastModule().show(_("Conversion failed: ") .. tostring(err or "unknown error"), 5)
        logger.warn("boldonic: conversion failed (", book_path, "): ", err)
    end
end

-- The one-tap convert paths ("Currently open" row) bypass the picker, so they
-- skip the dup-aware pick flow. When the target copy already exists, pause on
-- the same "Convert again?" confirm instead of painting over it silently.
-- `on_ok` always receives the ORIGINAL batch.
function BOLDONIC:guardConverted(paths, on_ok)
    local ConfirmBox = require("ui/widget/confirmbox")
    for _i, p in ipairs(paths or {}) do
        local out = self:outputPathFor(p)
        if out and lfs.attributes(out, "mode") == "file" then
            local title = tostring(p):match("([^/]+)$") or tostring(p)
            local confirm
            confirm = ConfirmBox:new{
                text = string.format(_("%s \226\128\148 already converted\n(%s)\n\nConvert it again? (the copy is overwritten)"),
                    tostring(title), tostring(out)),
                ok_text = _("Convert again"),
                cancel_text = _("Don't convert"),
                ok_callback = function()
                    UIManager:close(confirm)
                    on_ok(paths)
                end,
                cancel_callback = function()
                    UIManager:close(confirm)
                end,
            }
            logger.info("boldonic: quick-convert flagged an existing output: ",
                tostring(p), " -> ", out)
            UIManager:show(confirm)
            return
        end
    end
    on_ok(paths)
end

function BOLDONIC:convertCurrentBook()
    local book_path = self:currentBookPath()
    if not book_path then
        UIManager:show(InfoMessage:new{
            text = _("There is no file to convert. Use Convert A File to pick one."),
        })
        return
    end
    if not self:isEpub(book_path) then
        UIManager:show(InfoMessage:new{
            text = _("Only EPUB books can be bolded."),
        })
        return
    end
    self:guardConverted({ book_path }, function()
        self:convertFile(book_path)
    end)
end

-- "Convert A File": open the file picker (boldonic_picker.lua) — a
-- device-wide EPUB scan rendered INSIDE the dashboard's Convert tab (the
-- brand header + tab bar stay on screen; the list paints below them). The
-- picker scans once per Home lifetime (cached), keeps its own picked set,
-- and its first row is the always-visible "Convert to Boldonic" action.
function BOLDONIC:chooseAndConvert()
    local home = self.home
    if not home then
        self:openHome()
        home = self.home
    end
    if home and type(home.openFilesBrowser) == "function" then
        home:openFilesBrowser()
    end
    local picker = home and home.convert_picker
    logger.info("boldonic: picker open in Convert tab (books=",
        picker and picker.books and #picker.books or 0,
        " screen=", home and home.convert_screen or "nil", ")")
end

-- Open the full-screen Boldonic dashboard. Shown with a "ui" refresh (the
-- same call Storefront uses) so the whole screen paints cleanly on e-ink.
-- The open instance is stored on the plugin so convert flows can target it
-- and keep every conversion inside the dashboard (see convertBooks).
function BOLDONIC:openHome()
    local home = homeModule():new{ plugin = self }
    self.home = home
    UIManager:show(home, "ui")
    UIManager:forceRePaint()
end

function BOLDONIC:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("boldonic: self.ui or self.ui.menu not initialized")
    end
end

-- Pin the Boldonic item at the top of the Tools menu (position 2, right
-- under "Read Timer"), the same way the Storefront and CrossDrop plugins do.
-- Without this it is grouped with the other plugins at the bottom of Tools.
local function injectBoldonicIntoToolsMenu()
    local menu_orders = {
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }
    local function contains_id(tbl, id)
        if type(tbl) ~= "table" then return false end
        for _, val in pairs(tbl) do
            if val == id then
                return true
            elseif type(val) == "table" and contains_id(val, id) then
                return true
            end
        end
        return false
    end
    for _, order_path in ipairs(menu_orders) do
        local ok, order = pcall(require, order_path)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            if not contains_id(order, "boldonic") then
                table.insert(order.tools, 2, "boldonic")
            end
        end
    end
end

-- The Boldonic item opens the dashboard directly; all actions live there.
function BOLDONIC:addToMainMenu(menu_items)
    injectBoldonicIntoToolsMenu()
    menu_items.boldonic = {
        text = _("Boldonic"),
        sorting_hint = "tools",
        callback = function() self:openHome() end,
    }
end

return BOLDONIC