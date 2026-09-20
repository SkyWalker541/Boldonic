-- Boldonic picker: the "Convert A File" screen, built on the SAME widget
-- architecture as the Boldonic dashboard (boldonic_home.lua) — the only
-- widget set proven to render and take taps on this device: rows are
-- Buttons (menu-style), everything sits on the full-screen white card, and
-- the header is the TitleBar whose ✕ the user already uses on the dashboard.
--
-- Instead of wrapping KOReader's built-in file browser (which never worked
-- on the Kindle — see CrossDrop's AGENTS.md), the picker SCANS the device for
-- EPUBs the way bookshelf.koplugin (854★, the storefront's most popular home
-- screen) does: one recursive walk with an extension filter, skipping hidden
-- entries, .sdr sidecar dirs, app/system directories — and past Boldonic
-- outputs, so a "<stem>_boldonic.epub" copy is never offered to be bolded a
-- second time. The result is a flat, alphabetical "every EPUB on this
-- device" list — pick any of them without navigating folders.
--
-- Screen layout (one cohesive style: every row the same font; action rows are
-- framed boxes, book rows are bare text separated by hairline rules; every
-- interactive thing a proper button):
--
--   TitleBar: "Convert A File" + "N files — tap to pick; the top row converts"
--   [Convert to Boldonic — convert N file(s) now]  (dark button: THE action)
--   ─────────────
--   [Search files…]                       (opens a keyword-search popup)
--   Search "treis" — 4 results            (only while a filter is active)
--   [Clear search]                        (only while a filter is active)
--   ─────────────
--   book title                          (no box — hairlines only)
--   Converted · 2.4 MB — tap to convert again (overwrites the copy)
--   ───────────── book title ───────────── …
--   ─────────────
--   ⟨Page X of Y⟩              (Storefront footer pager: chevrons + jump)
--
-- Picked books get a light-gray row background plus a "picked" hint line
-- (no reliance on icon glyphs, which never rendered here). The picked set
-- lives on the dialog and survives paging. Tapping the action row opens the
-- confirm dialog whose OK button is the labeled "Convert to Boldonic"
-- button; the conversion then runs inside the open dashboard
-- (plugin:convertBooks with plugin.home as the repaint sink).
--
-- A book whose <stem>_boldonic.epub ALREADY exists (per the current
-- Settings) is flagged "Converted ·" on its row and the pick pauses on a
-- "Convert again? (the copy is overwritten)" prompt — the flag is impossible
-- to walk past. In replace mode every row converts cleanly (outputPathFor
-- has nothing to flag).
--
-- Rows show REAL titles (EPUBs have metadata), not the (often horrendous)
-- filenames side-loaders produce. Titles are resolved cheapest-first:
--   1. KOReader's own metadata cache (coverbrowser's BookInfoManager);
--   2. our durable on-disk boldonic_titles_cache.lua;
--   3. a cleaned-up filename (side-loader junk tokens dropped);
--   4. lazy per-page upgrade via DocumentRegistry.
-- The search matches the DISPLAYED title as well as the raw filename.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local _ = require("gettext")
local logger = require("logger")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Where this module lives on disk: used for the durable title cache next to
-- the plugin. Derived from the source path (works on device and in tests);
-- KOReader's loader also stamps .path on the plugin module, but never on our
-- instances, so we prefer the file's own location.
local PLUGIN_DIR
do
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source
    if src and src:sub(1, 1) == "@" then
        PLUGIN_DIR = src:sub(2):match("^(.*)/[^/]+$")
    end
end

-- Boldonic converts EPUBs only (the bolding engine rewrites XHTML; other
-- formats have no such content and would be copied unmodified). KOReader
-- reads much more, but only EPUBs make sense to offer. Case is handled by
-- lowercasing the extension (real devices carry ".EPUB" files).
local SUPPORTED_EXT = {
    epub = true,
}

-- Directory names never descended into: the KOReader install itself and the
-- Kindle system/content dirs hold no convertable books (and walking them is
-- slow on device storage). Hidden entries (leading ".") are skipped by the
-- walk, which also kills macOS AppleDouble "._book.epub" companions.
local EXCLUDED_DIRS = {
    koreader = true, extensions = true, mrpackages = true,
    system = true, audible = true, fonts = true, voice = true,
    screenshots = true, wallpapers = true, kmc = true, libkh = true,
    proc = true, sys = true, dev = true, run = true, tmp = true,
    ["lost+found"] = true,
}

-- A past Boldonic output: "<stem>_boldonic.epub". Never offered as a source
-- (it IS a finished product — picking it would just re-bold a bolded book).
local function is_boldonic_output(name)
    return tostring(name or ""):lower():match("_boldonic%.[^.]+$") ~= nil
end

-- Grey out (or restore) a pager chevron via Button:enableDisable — guarded
-- so the harness stub (which has no enableDisable) keeps a plain disabled
-- flag and never crashes a page build.
local function setButtonEnabled(btn, enabled)
    if btn and btn.enableDisable then
        btn:enableDisable(enabled)
    elseif btn then
        btn.disabled = not enabled
    end
end

local PickerDialog = InputContainer:extend{
    modal = true,
    dismissable = false,
    -- covers_fullscreen is the storefront browser's flag: it tells
    -- UIManager the dialog is a dominant full-screen layer, so repaints
    -- start here and everything below (the dashboard) is not painted over
    -- it. Without it, the picker can appear to open BEHIND the dashboard.
    covers_fullscreen = true,
    plugin = nil,
    books = nil,       -- the scan result, cached for the dialog's lifetime
    query = nil,       -- active search filter (lowercased), nil = no filter
    picked = nil,      -- full path -> true (survives paging)
    title_cache = {},  -- path -> real title, from past lazy upgrades
    title_failed = {}, -- path -> true: never retried this session
    title_cache_file = nil,
    title_cache_dirty = nil,
    page = 1,
    rows_per_page = 10,
    scan_root = nil,   -- override for tests
}

-- ─────────────────── pure, testable logic ──────────────────────

-- Where to scan: the Kindle user partition, else KOReader's home folder,
-- else the filesystem root (the walk's EXCLUDED_DIRS make that survivable).
function PickerDialog.scanRoot()
    local ok, dev = pcall(function() return Device end)
    if ok and dev and dev.isKindle and dev:isKindle() then
        return "/mnt/us"
    end
    local ok_fmu, fmu = pcall(require, "apps/filemanager/filemanagerutil")
    if ok_fmu and fmu and fmu.getHomeFolder then
        local home = fmu.getHomeFolder()
        if home and home ~= "" then return home end
    end
    return "/"
end

-- One recursive walk over the scan root (bookshelf.koplugin's walkBooks
-- pattern): skip dot entries, EXCLUDED_DIRS, .sdr sidecar dirs and past
-- Boldonic outputs; collect every EPUB. Returns a flat, title-sorted list
-- of {name, path, ext, title, size}. Unreadable or missing roots simply
-- yield an empty list. Each entry gets its best-known title via :titleFor.
function PickerDialog:scanAllBooks(root)
    root = root or self.scan_root or PickerDialog.scanRoot()
    local out = {}
    if not (lfs_ok and lfs and lfs.dir and lfs.attributes) then
        return out
    end
    local MAX_DEPTH = 8
    local function walk(dir, depth)
        if depth > MAX_DEPTH then return end
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok or type(iter) ~= "function" then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "."
                and not EXCLUDED_DIRS[entry] then
                local fp = dir .. "/" .. entry
                local attr = lfs.attributes(fp)
                if type(attr) == "table" then
                    if attr.mode == "directory" then
                        if entry:sub(-4) ~= ".sdr" then
                            walk(fp, depth + 1)
                        end
                    elseif attr.mode == "file" then
                        local ext = entry:match("%.([^.]+)$")
                        ext = ext and ext:lower() or nil
                        if ext and SUPPORTED_EXT[ext] and not is_boldonic_output(entry) then
                            local b = { name = entry, path = fp, ext = ext, size = attr.size or 0 }
                            self:titleFor(b)
                            out[#out + 1] = b
                        end
                    end
                end
            end
        end
    end
    walk(root, 0)
    table.sort(out, function(a, b)
        local ta, tb = a.title or a.name, b.title or b.name
        return ta:lower() < tb:lower()
    end)
    return out
end

-- Scan the device once per picker lifetime: the first render of either the
-- inline (dashboard) or the standalone chooser runs the scan, and every later
-- open/repaint reuses the cached list. A picker whose session never opened a
-- file list (e.g. the dashboard's Convert tab was only ever idle) always gets
-- at least one scan before buildContent reads self.books.
function PickerDialog:ensureBooks()
    if self.books == nil then
        self.books = self:scanAllBooks()
    end
    return self.books
end

-- ─────────────────── real titles, cheapest-first ─────────────────────

-- Fallback: a filename made readable. Conservative — it only strips what
-- side-loaders stamp on: separators, underscores, and the junk tokens
-- retailers add (archive names, isbn13, 32-hex thumbprints). Interior
-- punctuation ("sci-fi", digits) is kept. If nothing survives, the raw
-- filename (minus extension) wins.
function PickerDialog:cleanTitle(name)
    local t = name:match("^(.*)%.[^.]+$") or name
    t = t:gsub("_", " ")
    t = t:gsub("%s+", " ")
    -- Anna's Archive (straight or curly apostrophe) + tails
    local APOSTROPHES = "'" .. string.char(226, 128, 152, 226, 128, 153)
    t = t:gsub("Anna[" .. APOSTROPHES .. "]s Archive", " ")
    t = t:gsub("%s+[Oo]ptimized%s*", " ")
    t = t:gsub("[Ii][Ss][Bb][Nn]13[%s%-]*%d%d%d%d%d%d%d%d%d?%d?%d?%s*", " ")
    t = t:gsub(
        "%s+[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]"
        .. "[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]%s*",
        " ")
    t = t:gsub("%s%-+%s*", " ")
    -- left-over double-extension dots ("sci-fi.novel.epub" -> "sci-fi novel")
    t = t:gsub("[%.]+", " ")
    t = t:gsub("%s+", " ")
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    if t == "" then
        return name:match("^(.*)%.[^.]+$") or name
    end
    return t
end

-- Whatever a parser scraped out of a file gets normalized here; returns nil
-- when there is nothing usable (so callers fall through to the next tier).
function PickerDialog:sanitizeTitle(t)
    if not t or t == "" then return nil end
    t = tostring(t)
    t = t:gsub("%c", "")
    t = t:gsub("_", " ")
    t = t:gsub("%s+", " ")
    local words = {}
    for w in t:gmatch("%S+") do
        if words[#words] ~= w then
            words[#words + 1] = w
        end
    end
    t = table.concat(words, " ")
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    if #t > 200 then t = t:sub(1, 200) end
    if t == "" then return nil end
    return t
end

-- Tier 1: KOReader's own metadata cache. coverbrowser's BookInfoManager
-- maintains bookinfo_cache.sqlite3 (real titles for every book KOReader has
-- browsed/extracted). One indexed prepared query, same order of cost as the
-- scan's lfs.attributes calls. Guarded: on a device without coverbrowser, or
-- in the test harness, this is a no-op.
function PickerDialog:koreaderMetaTitle(path)
    if PickerDialog.bim == nil then
        local ok, bim = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
        PickerDialog.bim = ok and bim or false
        if PickerDialog.bim and PickerDialog.bim.init then
            pcall(PickerDialog.bim.init, PickerDialog.bim)
        end
    end
    local bim = PickerDialog.bim
    if not bim or not bim.getDocProps then return nil end
    local ok, props = pcall(bim.getDocProps, bim, path)
    if ok and props and props.title and props.title ~= "" then
        return self:sanitizeTitle(props.title)
    end
    return nil
end

-- Resolve the best-known title for one scan entry, cheapest tier first
-- (see the header comment). `b.real` is true when the title came from real
-- metadata; EPUBs that found nothing keep a cleaned fallback with real=nil,
-- so the lazy per-page Document upgrade (upgradeVisibleTitles) gets a turn.
function PickerDialog:titleFor(b)
    local title = self.title_cache[b.path] or self:koreaderMetaTitle(b.path)
    if title then
        b.title = title
        b.real = true
    else
        b.title = self:cleanTitle(b.name)
        b.real = nil
    end
end

-- Durable cache (tier 2): titles discovered by the lazy upgrade are kept in
-- a Lua file next to the plugin, so the next session starts a page already
-- holding real titles. Plain <path>=<title> lines, %q-quoted and read back
-- with load(); a sub-par read just yields an empty cache.
function PickerDialog:loadTitleCache()
    if not self.title_cache_file then return end
    local f = io.open(self.title_cache_file, "r")
    if not f then return end
    local src = f:read("*a")
    f:close()
    local chunk = src and load(src, "boldonic_titles_cache")
    if chunk then
        local ok, t = pcall(chunk)
        if ok and type(t) == "table" then
            self.title_cache = t
        end
    end
end

function PickerDialog:saveTitleCache()
    if not self.title_cache_file or not self.title_cache_dirty then return end
    local f = io.open(self.title_cache_file, "w")
    if not f then return end
    local lines = {}
    for p, t in pairs(self.title_cache) do
        lines[#lines + 1] = string.format("  [%q] = %q,\n", p, t)
    end
    f:write("-- Boldonic real-title cache, written as titles are discovered.\nreturn {\n")
    f:write(table.concat(lines))
    f:write("}\n")
    f:close()
    self.title_cache_dirty = nil
end

-- Tier 4, the lazy upgrade: the EPUBs on the CURRENT page that still have
-- only a cleaned-filename title get a real title from the Document provider.
-- One Document open per frame (UIManager:nextTick) so the UI never stalls,
-- and every finished title is cached on disk for next session. Failures are
-- black-listed for this session. DocumentRegistry does not exist in the
-- harness, so it is a no-op there.
function PickerDialog:upgradeVisibleTitles()
    if self._upgrading or not self.books then return end
    local books = self:visibleBooks()
    local lo = (self.page - 1) * self.rows_per_page + 1
    local hi = math.min(#books, self.page * self.rows_per_page)
    local todo = {}
    for i = lo, hi do
        local b = books[i]
        if b and not b.real and not self.title_failed[b.path] then
            local known = self.title_cache[b.path] or self:koreaderMetaTitle(b.path)
            if known then
                b.title, b.real = known, true
            else
                todo[#todo + 1] = b
            end
        end
    end
    if #todo == 0 then return end
    local ok_reg, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_reg and DocumentRegistry and DocumentRegistry.openDocument) then return end
    self._upgrading = true
    local picker = self
    local i = 1
    local step
    step = function()
        if picker._closed then
            picker._upgrading = nil
            return
        end
        local b = todo[i]
        if b then
            local ok, title = pcall(function()
                local doc = DocumentRegistry:openDocument(b.path)
                local props = doc and doc.getProps and doc:getProps()
                if doc and doc.close then pcall(doc.close, doc) end
                if DocumentRegistry.closeDocument then
                    pcall(DocumentRegistry.closeDocument, DocumentRegistry, b.path)
                end
                return props and props.title
            end)
            if ok and title then
                title = picker:sanitizeTitle(title)
            end
            if title then
                b.title = title
                b.real = true
                picker.title_cache[b.path] = title
                picker.title_cache_dirty = true
            else
                picker.title_failed[b.path] = true
            end
        end
        i = i + 1
        if i <= #todo then
            UIManager:nextTick(step)
        else
            picker._upgrading = nil
            if picker.title_cache_dirty then picker:saveTitleCache() end
            if not picker._closed then
                picker:init()
                UIManager:setDirty(picker, "ui")
            end
        end
    end
    UIManager:nextTick(step)
end

function PickerDialog:pickedCount()
    local n = 0
    for _ in pairs(self.picked or {}) do n = n + 1 end
    return n
end

-- The pageable list is the scan filtered by the active search: an
-- always-case-insensitive substring match on the DISPLAYED title AND the raw
-- filename (plain find, no pattern magic, so "(" or "." in a query can't
-- blow up). The picked set is untouched by filtering — a picked book stays
-- picked when you search.
function PickerDialog:visibleBooks()
    local books = self.books or {}
    local q = self.query
    if not q or q == "" then
        return books
    end
    q = q:lower() -- defensive: callers store it lowercased, this keeps it safe
    local out = {}
    for _, b in ipairs(books) do
        if b.title and b.title:lower():find(q, 1, true)
            or (b.name and b.name:lower():find(q, 1, true)) then
            out[#out + 1] = b
        end
    end
    return out
end

-- The Search button: a modal keyword popup (the same InputDialog recipe the
-- dashboard's settings use — modal=true is REQUIRED so it stacks above this
-- full-screen picker). Saves the trimmed, lowercased query or clears it.
function PickerDialog:showSearchDialog()
    local InputDialog = require("ui/widget/inputdialog")
    local picker = self
    local search_dialog
    search_dialog = InputDialog:new{
        title = _("Search files"),
        input = self.query or "",
        input_hint = _("Keyword \226\128\148 matches any part of a title or file name"),
        type = "text",
        modal = true,
        buttons = {
            {
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local text = search_dialog:getInputText() or ""
                        local q = text:match("^%s*(.-)%s*$") or ""
                        q = q:lower()
                        picker.query = (q == "") and nil or q
                        picker.page = 1
                        UIManager:close(search_dialog)
                        picker:repaint()
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(search_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(search_dialog)
end

function PickerDialog:clearSearch()
    self.query = nil
    self.page = 1
    self:repaint()
end

-- ─────────────────── the "already converted" duplicate flag ─────────────────────
-- Uses the plugin's persistent conversion log (survives plugin updates, tracks
-- books across destination folders). Falls back to filesystem check for safety.
function PickerDialog:convertedEntryFor(book)
    if not book or not book.path then return nil end
    local plugin = self.plugin
    local converted, entry = plugin and plugin.isConverted and plugin:isConverted(book.path)
    if converted and entry and entry.output_path then
        return { path = entry.output_path, size = entry.size or 0 }
    end
    -- Fallback: filesystem check (in case log is stale or missing)
    local out = plugin and plugin.outputPathFor and plugin:outputPathFor(book.path)
    if not out or not (lfs_ok and lfs and lfs.attributes) then return nil end
    local mode = lfs.attributes(out, "mode")
    if mode ~= "file" then return nil end
    return { path = out, size = lfs.attributes(out, "size") or 0 }
end

function PickerDialog:onConvertedCount()
    local n = 0
    for _, b in ipairs(self.books or {}) do
        if self:convertedEntryFor(b) then n = n + 1 end
    end
    return n
end

-- The action row text: the convert button the user asked for, always
-- visible, carrying the running count so it doubles as the selection
-- readout.
function PickerDialog:convertRowText()
    local n = self:pickedCount()
    if n > 0 then
        return string.format(_("Convert to Boldonic  \226\128\162  convert %d file(s) now"), n)
    end
    return _("Convert to Boldonic  \226\128\162  pick files below")
end

-- The action: confirm dialog whose OK button is the labeled
-- "Convert to Boldonic" button (core ConfirmBox buttons — proven), then the
-- whole batch converts inside the open dashboard. With nothing picked it is
-- a gentle hint, never a conversion.
function PickerDialog:confirmAndConvert()
    local paths = {}
    for p in pairs(self.picked or {}) do paths[#paths + 1] = p end
    if #paths == 0 then
        UIManager:show(Notification:new{
            text = _("Tap files below to pick them \226\128\148 then this row converts them."),
            timeout = 4,
        })
        return
    end
    table.sort(paths)
    local titles = {}
    for _, b in ipairs(self.books or {}) do
        titles[b.path] = b.title or b.name
    end
    local names = {}
    for i = 1, math.min(3, #paths) do
        names[#names + 1] = "  " .. (titles[paths[i]] or (paths[i]:match("([^/]+)$") or paths[i]))
    end
    if #paths > 3 then
        names[#names + 1] = string.format("  \226\128\166  %d more", #paths - 3)
    end
    local picker = self
    local plugin = self.plugin
    local confirm
    confirm = ConfirmBox:new{
        text = string.format(_("Convert %d file(s) to Boldonic?"), #paths)
            .. "\n" .. table.concat(names, "\n"),
        ok_text = _("Convert to Boldonic"),
        ok_callback = function()
            UIManager:close(confirm)
            -- Inline: the picker lives INSIDE the dashboard's Convert tab, so
            -- the conversion takes over the same region — the convert-state
            -- machine (converting/done/failed) renders in place from here on,
            -- with the brand header and tabs still on screen.
            local home = plugin and plugin.home
            if home then home.convert_screen = nil end
            local paths_now = {}
            for _, p in ipairs(paths) do paths_now[#paths_now + 1] = p end
            UIManager:nextTick(function()
                plugin:convertBooks(paths_now, plugin.home)
                -- e-ink: the batch ran blocking on the UI thread; whatever
                -- state the dashboard ends in (done/failed) must be truly ON
                -- the screen. convertBooks' own full refreshes cover this,
                -- but belt-and-braces: dirty Home for one flashing FULL
                -- refresh after the batch.
                local h2 = plugin and plugin.home
                if h2 and h2.frame then
                    UIManager:setDirty(h2, "full")
                    UIManager:forceRePaint()
                end
            end)
        end,
        cancel_callback = function()
            UIManager:close(confirm)
        end,
    }
    UIManager:show(confirm)
end

-- ────────────────────── interactions ─────────────────────────────

function PickerDialog:bookByPath(path)
    for _, b in ipairs(self.books or {}) do
        if b.path == path then return b end
    end
    return nil
end

-- The "already converted" prompt when a converted book is picked. THIS is
-- the flag the picker is for — unpickable to walk past, unlike a toast — so
-- it is the same core ConfirmBox the convert action already proves on this
-- device. Tapping the row does NOT pick the book yet; only "Convert again"
-- picks it (re-bolding a just-changed original is a legitimate ask), "Don't
-- convert" leaves the tick off.
function PickerDialog:confirmConvertDuplicate(book, entry, path)
    local title = (book and (book.title or book.name)) or ""
    local picker = self
    local confirm
    confirm = ConfirmBox:new{
        text = string.format(_("%s \226\128\148 already converted\n(%s)\n\nConvert it again? (the copy is overwritten)"),
            tostring(title), tostring(entry and entry.path or "")),
        ok_text = _("Convert again"),
        cancel_text = _("Don't convert"),
        ok_callback = function()
            UIManager:close(confirm)
            picker.picked = picker.picked or {}
            picker.picked[path] = true
            picker:repaint()
        end,
        cancel_callback = function()
            UIManager:close(confirm)
        end,
    }
    UIManager:show(confirm)
end

-- Toggle one book in the picked set and repaint in place. A flashless PARTIAL
-- update: the tap only changes a tick on the row (the scanning cache on self
-- means this never rescans), so a full-screen e-ink wipe is pure strobing.
-- Picking a book whose copy ALREADY exists never silently swallows it: the
-- pick pauses on the confirmConvertDuplicate prompt so the duplication is
-- impossible to walk past.
function PickerDialog:toggle(path)
    self.picked = self.picked or {}
    if self.picked[path] then
        self.picked[path] = nil
    else
        local book = self:bookByPath(path)
        local entry = self:convertedEntryFor(book)
        if entry then
            self:confirmConvertDuplicate(book, entry, path)
            return
        end
        self.picked[path] = true
    end
    self:repaint()
end

function PickerDialog:gotoPage(n)
    self.page = math.max(1, n)
    self:repaint()
end

-- The Storefront footer pager: a centered strip of two bare chevron buttons
-- around a Page-N-of-M readout, always rendered when there are books. The
-- chevrons are the same icon-only Buttons as the dashboard chrome (48x48 tap
-- targets, 24px glyphs, no border/background); they grey out — never
-- disappear — at the ends via Button:enableDisable. The page readout is its
-- own Button that jumps to a number via the core SpinWidget.
function PickerDialog:buildPager(max_page)
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local prev_btn = Button:new{
        icon = "chevron.left",
        icon_width = sc(24),
        icon_height = sc(24),
        width = sc(48),
        height = sc(48),
        bordersize = 0,
        background = nil,
        allow_flash = false,
        show_parent = self,
        callback = function() self:gotoPage(self.page - 1) end,
    }
    setButtonEnabled(prev_btn, self.page > 1)
    local page_btn = Button:new{
        text = string.format(_("Page %d of %d"), self.page, math.max(1, max_page)),
        width = sc(140),
        height = sc(48),
        bordersize = 0,
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        background = nil,
        align = "center",
        text_font_face = "smallinfofont",
        text_font_size = 18,
        allow_flash = false,
        show_parent = self,
        callback = function() self:showGotoPage(max_page) end,
    }
    local next_btn = Button:new{
        icon = "chevron.right",
        icon_width = sc(24),
        icon_height = sc(24),
        width = sc(48),
        height = sc(48),
        bordersize = 0,
        background = nil,
        allow_flash = false,
        show_parent = self,
        callback = function() self:gotoPage(self.page + 1) end,
    }
    setButtonEnabled(next_btn, self.page < max_page)
    return CenterContainer:new{
        dimen = Geom:new{ w = self.row_w, h = sc(48) },
        HorizontalGroup:new{
            prev_btn,
            HorizontalSpan:new{ width = sc(24) },
            page_btn,
            HorizontalSpan:new{ width = sc(24) },
            next_btn,
        },
    }
end

function PickerDialog:showGotoPage(max_page)
    if not max_page or max_page <= 1 then return end
    local ok, SpinWidget = pcall(require, "ui/widget/spinwidget")
    if not ok or not SpinWidget then return end
    UIManager:show(SpinWidget:new{
        title_text = _("Go to page"),
        value = self.page,
        value_min = 1,
        value_max = max_page,
        ok_text = _("Go"),
        callback = function(spin)
            if spin and spin.value and spin.value ~= self.page then
                self:gotoPage(spin.value)
            end
        end,
    })
end

-- Leaving the picker (Back, or the convert flow moving on) always lands back
-- on the Boldonic dashboard: inline this is the Convert tab's landing, with
-- the picked set / page / search filter cached on self for the next open.
-- A picker built without a home keeps the old dialog-close behaviour.
function PickerDialog:close()
    self._closed = true
    local home = self.home
    if home and type(home.leaveFilesBrowser) == "function" then
        home:leaveFilesBrowser()
        return
    end
    UIManager:close(self, "ui")
    local plugin = self.plugin
    if plugin then
        if plugin.home then
            UIManager:setDirty(plugin.home, "ui")
            UIManager:forceRePaint()
        else
            plugin:openHome()
        end
    end
end

function PickerDialog:leave()
    self:close()
end

-- Every in-place repaint goes through the dashboard's refresh (flashless
-- "ui", brand header + tab bar stay painted — the picker has no frame of its
-- own when it renders inline). Standalone usage (no home) falls back to the
-- old init + setDirty path.
function PickerDialog:repaint()
    if self.home and type(self.home.refresh) == "function" then
        self.home:refresh()
        return
    end
    self:init()
    UIManager:setDirty(self, "ui")
end

-- ────────────────────── rendering ─────────────────────────────

-- Menu-style Button row (the dashboard's row widget): one consistent font
-- everywhere (smallinfofont 22, the same as the dashboard's rows). Built
-- manually rather than via menu_style so bold and colors stay controllable.
-- avoid_text_truncation is OFF on purpose: with it on, Button shrinks the
-- font for any title too wide for the row, so long and short titles render
-- at visibly different sizes. Off, every row keeps font 22 and a too-long
-- title is truncated instead. Action rows are framed boxes; book rows pass
-- bordersize = 0 so the list shows as bare text separated by hairlines.
function PickerDialog:row(text, opts)
    opts = opts or {}
    return Button:new{
        text = text,
        width = self.row_w,
        align = "left",
        bordersize = opts.bordersize or Size.border.button,
        radius = Size.radius.button - 1, -- -1: core's unhighlight resets radius == Size.radius.button to nil, squaring the button after first tap
        avoid_text_truncation = false,
        padding_h = Size.padding.large,
        text_font_face = "smallinfofont",
        text_font_size = 22,
        text_font_bold = opts.bold == true,
        background = opts.background,
        text_font_color = opts.text_color,
        callback = opts.callback,
    }
end

-- The hairline between rows: a thin gray line with a little air around it,
-- so the list reads as discrete rows instead of one dense block.
function PickerDialog:separator()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    return VerticalGroup:new{
        VerticalSpan:new{ width = sc(2) },
        LineWidget:new{
            dimen = Geom:new{ w = self.row_w, h = Size.line.thick },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        VerticalSpan:new{ width = sc(2) },
    }
end

-- A small caption (plain text, same face as the rows — not a button).
function PickerDialog:caption(text)
    return TextBoxWidget:new{
        text = text,
        face = Font:getFace("smallinfofont"),
        width = self.row_w,
    }
end

function PickerDialog:buildContent()
    local vg = VerticalGroup:new{ align = "left" }
    local books = self:visibleBooks()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local h_of = function(w)
        local s = w.getSize and w:getSize()
        return (s and s.h) or 0
    end

    -- THE convert button: always the first row of every page, dark and bold
    -- so it reads as THE primary control (storefront's ok-button styling).
    local convert_row = self:row(self:convertRowText(), {
        bold = true,
        background = Blitbuffer.COLOR_DARK_GRAY,
        text_color = Blitbuffer.COLOR_WHITE,
        callback = function() self:confirmAndConvert() end,
    })
    -- Search: the button is always there; the active filter is spelled out
    -- in a caption with a Clear button right under it.
    local search_row = self:row(_("Search files\226\128\166"), {
        callback = function() self:showSearchDialog() end,
    })
    local query_rows = {}
    if self.query then
        local results = #books
        local label = (results == 1) and _("result") or _("results")
        query_rows[#query_rows + 1] = self:separator()
        query_rows[#query_rows + 1] = self:caption(string.format(
            _("Search \226\128\156%s\226\128\157 \226\128\148 %d %s"),
            self.query, results, label))
        query_rows[#query_rows + 1] = self:row(_("Clear search"), {
            callback = function() self:clearSearch() end,
        })
    end

    -- Rows per page MEASURED, not chosen: the frame's inner height minus the
    -- title bar (self.content_h), minus the fixed controls above the list,
    -- minus the pager strip below it, divided by one REAL book row. The
    -- inline (dashboard-hosted) build also carries a one-line count caption
    -- under the search block, folded into the same fixed-controls measure so
    -- the page size stays honest.
    local count_caption
    if self.hosted then
        count_caption = self:caption(string.format(
            _("%d file(s) on this device \226\128\148 tap to pick; the top row converts"),
            #books))
    end
    local fixed = {}
    local function push(...)
        local n = select("#", ...)
        for i = 1, n do fixed[#fixed + 1] = (select(i, ...)) end
    end
    push(convert_row, self:separator(), search_row)
    for _, w in ipairs(query_rows) do fixed[#fixed + 1] = w end
    push(self:separator())
    if count_caption then fixed[#fixed + 1] = count_caption end
    local top_h = 0
    for _, w in ipairs(fixed) do top_h = top_h + h_of(w) end
    top_h = top_h + h_of(self:separator())
    local row_h = h_of(self:row("probe\nprobe", { bordersize = 0 }))
    local sep_h = h_of(self:separator())
    local pager_h = h_of(self:buildPager(1))
    local content_h = self.content_h or math.floor(Device.screen:getHeight() - Size.padding.default * 2)
    local avail = math.max(0, content_h - top_h - sep_h - pager_h)
    local rpp = math.max(1, math.floor((avail + sep_h) / math.max(row_h + sep_h, 1)))
    self.rows_per_page = rpp
    local max_page = math.max(1, math.ceil(#books / rpp))
    if self.page > max_page then self.page = max_page end
    local lo = (self.page - 1) * rpp + 1
    local hi = math.min(#books, self.page * rpp)

    table.insert(vg, convert_row)
    table.insert(vg, self:separator())
    table.insert(vg, search_row)
    for _, w in ipairs(query_rows) do
        table.insert(vg, w)
    end
    table.insert(vg, self:separator())
    if count_caption then
        table.insert(vg, count_caption)
    end

    if #books == 0 then
        if self.query then
            table.insert(vg, self:caption(_("No files match this search.")))
        else
            table.insert(vg, self:caption(_("No EPUB files found on this device.")))
        end
    end

    for i = lo, hi do
        local e = books[i]
        local picked = (self.picked or {})[e.path] == true
        local converted = self:convertedEntryFor(e) ~= nil
        local size_str = string.format("%.1f MB", (e.size or 0) / 1048576)
        -- The "Converted ·" lede sits BEFORE the size: the row text truncates
        -- from the tail, so long book names can never cut the duplicate mark.
        local meta = (converted and (_("Converted") .. " \194\183 ") or "")
            .. size_str
            .. (picked and _("  \226\128\148 picked, tap to un-pick")
                or (converted and _("  \226\128\148 tap to convert again (overwrites the copy)")
                    or _("  \226\128\148 tap to convert")))
        table.insert(vg, self:row(e.title .. "\n" .. meta, {
            bordersize = 0,
            background = picked and Blitbuffer.COLOR_LIGHT_GRAY or nil,
            callback = function() self:toggle(e.path) end,
        }))
        if i < hi then
            table.insert(vg, self:separator())
        end
    end

    -- Paging: Storefront's compact centered footer strip. The strip sits on
    -- the VERY BOTTOM edge: a flexible spacer under the last book row soaks
    -- up whatever the measured rows left over.
    if #books > 0 then
        table.insert(vg, self:separator())
        local rows_h = rpp * row_h + math.max(0, rpp - 1) * sep_h
        local filler = math.floor(math.max(0, avail - rows_h))
        if filler > 0 then
            table.insert(vg, VerticalSpan:new{ width = filler })
        end
        table.insert(vg, self:buildPager(max_page))
    end

    return vg
end

-- STANDALONE build: the picker as its own full-screen card (the home keeps a
-- copy of this scenario for preview builds; on the device the picker renders
-- inline into the dashboard's Convert tab via renderInto). NO title upgrade,
-- NO scan here — the scan+scan root ran at first books access so a reopen is
-- instant. This is the picker's TitleBar: the back chevron top-left returns
-- to the dashboard; there is no ✕ (X is reserved for leaving the plugin
-- entirely — only the home's header carries it). The subtitle carries the
-- book count, static for the dialog's lifetime.
function PickerDialog:buildStandalone()
    self:ensureBooks()
    local sc = function(v) return Device.screen:scaleBySize(v) end
    local sw = Device.screen:getWidth()
    local sh = Device.screen:getHeight()
    local pad = Size.padding.default
    local inner_w = sw - pad * 2
    self.row_w = inner_w
    self.content_h = (sh - pad * 2) - sc(80) - sc(16)

    local title_bar = TitleBar:new{
        width = inner_w,
        title = _("Convert A File"),
        subtitle = string.format(_("%d file(s) on this device \226\128\148 tap to pick; the top row converts"),
            #(self.books or {})),
        fullscreen = false,
        with_bottom_line = true,
        left_icon = "chevron.left",
        left_icon_tap_callback = function()
            self:close()
        end,
        show_parent = self,
    }

    return FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw,
        height = sh,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = pad,
        VerticalGroup:new{
            align = "left",
            title_bar,
            VerticalSpan:new{ width = sc(8) },
            self:buildContent(),
            VerticalSpan:new{ width = sc(8) },
        },
    }
end

-- (Re)render the whole screen. The storefront/boox convention of a blocking
-- init + UIManager:setDirty("ui") per change: on e-ink, the simplest
-- trigger of a full paint. The frame is rebuilt from the current state every
-- call, so rows/pager/ticks/search all update in one flashless sweep.
function PickerDialog:init()
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    self.frame = self:buildStandalone()
    self[1] = self.frame
    pcall(function() if self.plugin and self.plugin.syncLog then self.plugin:syncLog() end end)
    if not self.dimen then
        self.dimen = Geom:new{
            w = Device.screen:getWidth(),
            h = Device.screen:getHeight(),
        }
    end
    UIManager:setDirty(self, "ui")
end

-- INLINE render: the picker paints into an existing VerticalGroup — the
-- home's Convert-tab content region below the brand header and tab bar. No
-- own frame, no own TitleBar (the top of the card already shows Boldonic and
-- the Convert A File tab); the list fills exactly the AREA height passed in,
-- so the pager straps to the bottom of the tab region the way it used to
-- strap to the bottom of the full-screen card. The `hosted` flag turns the
-- one-line count caption on (the standalone TitleBar subtitle has no home
-- here). _closed is reset so a later repaint()/upgrade never bails.
function PickerDialog:renderInto(vg, area_w, area_h)
    self.hosted = true
    self._closed = false
    if area_w then self.row_w = area_w end
    if area_h then self.content_h = area_h end
    self:ensureBooks()
    pcall(function() if self.plugin and self.plugin.syncLog then self.plugin:syncLog() end end)
    table.insert(vg, self:buildContent())
end

function PickerDialog:onBack()
    self:leave()
    return true
end

PickerDialog:extend{
    -- This is where the (never-rendered) hit-area setup used to live; the
    -- button callbacks drive everything now. Keep the field for parity.
    render_gaps = true,
}

return PickerDialog