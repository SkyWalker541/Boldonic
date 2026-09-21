-- Stub harness for the Boldonic KOReader plugin: load main.lua and exercise
-- (a) the pure logic — settings, outputPathFor, mkdirs, convertOne/convertBooks,
--     the duplicate guard — and
-- (b) the dashboard — Home tabs, the inline EPUB picker (device scan, the
--     "already converted" flag + confirm), the destination browser, the
--     in-dashboard conversion state machine —
-- against a FAKE device + a FAKE epub archive (ffi/archiver stub). There is
-- NO networking anywhere: every conversion is strictly local, exactly like
-- the plugin.

-- Resolve the plugin root relative to this harness file so it runs from any
-- checkout (and in CI): arg[0] is "test/harness_boldonic.lua"; the plugin
-- lives in the sibling boldonic.koplugin/ directory (first on the path so
-- any stale flat copies at the repo root can never shadow it).
local HARNESS_DIR = (arg and arg[0] and arg[0]:gsub("(.*/)[^/]+$", "%1")) or "test/"
local PLUGIN_ROOT = HARNESS_DIR .. "../"
package.path = PLUGIN_ROOT .. "/boldonic.koplugin/?.lua;" .. PLUGIN_ROOT .. "/?.lua;" .. package.path

-- ── KOReader module stubs ────────────────────────────────────────────────

-- Geometry emulation: the Kindle PW5 SE reports 1236x1648 (portrait) and
-- scaleBySize(px) = ceil(px * min(w,h)/600) (see its ffi/framebuffer.lua).
-- The stubs measure auto-sized text instead of returning {0,0}, so a layout
-- that runs past the screen edges on the device fails the harness too.
local SCREEN_W, SCREEN_H = 1236, 1648
local SCREEN_SCALE = SCREEN_W / 600
local function scal(v) return math.ceil((v or 0) * SCREEN_SCALE) end

local FACE_SIZES = {
    cfont = 24, tfont = 26, smalltfont = 24, x_smalltfont = 22,
    ffont = 20, smallffont = 15, largeffont = 25, pgfont = 20,
    scfont = 20, rifont = 16, hpkfont = 20, hfont = 24,
    infont = 22, smallinfont = 16, infofont = 24, smallinfofont = 22,
    smallinfofontbold = 22, x_smallinfofont = 20, xx_smallinfofont = 18,
}

local function utf8_chars(s)
    local n = 0
    for _ in (s .. ""):gmatch("[\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end

local function measure_text(text, face, max_width)
    local fsize = (face and face.s) or 22
    local cw = math.ceil(fsize * 0.5)
    local w, lines = 0, 1
    for part in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        w = math.max(w, utf8_chars(part) * cw)
        lines = lines + 1
    end
    if max_width then w = math.min(w, max_width) end
    return { w = w, h = lines * math.ceil(fsize * 1.2) }
end

local class = {}
function class:getSize()
    local name = self.__name
    if name == "VerticalSpan" or name == "HorizontalSpan" then
        local w = self.width or 0
        return { w = name == "HorizontalSpan" and w or 0, h = name == "VerticalSpan" and w or 0 }
    end
    if name == "VerticalGroup" or name == "HorizontalGroup" then
        local w, h = 0, 0
        for i = 1, #self do
            local kid = self[i]
            if type(kid) == "table" and type(kid.getSize) == "function" then
                local s = kid:getSize()
                if name == "VerticalGroup" then
                    w = math.max(w, s.w); h = h + s.h
                else
                    w = w + s.w; h = math.max(h, s.h)
                end
            end
        end
        return { w = w, h = h }
    end
    if name == "FrameContainer" then
        local child = self[1]
        if child == nil then
            error("FrameContainer:getSize on a childless FrameContainer (crashes the Kindle)")
        end
        local cs = (type(child) == "table" and type(child.getSize) == "function") and child:getSize() or { w = 0, h = 0 }
        local p = self.padding or 0
        local b = self.bordersize or 0
        local m = self.margin or 0
        local pad_l = self.padding_left or p
        local pad_r = self.padding_right or p
        local pad_t = self.padding_top or p
        local pad_b = self.padding_bottom or p
        return { w = cs.w + (b + m) * 2 + pad_l + pad_r, h = cs.h + (b + m) * 2 + pad_t + pad_b }
    end
    if name == "CenterContainer" then
        return { w = self.dimen and self.dimen.w or 0, h = self.dimen and self.dimen.h or 0 }
    end
    if self.dimen and self.dimen.w then
        return { w = self.dimen.w, h = self.dimen.h or 0 }
    end
    if self.text ~= nil then
        return measure_text(self.text, self.face, self.width or self.max_width)
    end
    return { w = 0, h = 0 }
end
function class:getTextDimension() return { w = 0, h = 0 } end
function class:isFocusable() return false end
function class:getChildren() return {} end
function class:setText(t) self.text = t end
function class:setTitle(t) self.title = t end
function class:setSubTitle(t) self.subtitle = t end
function class:setLeftIcon(icon) self.left_icon = icon end
function class:setRightIcon(icon) self.right_icon = icon end
function class:updateItems() return true end
function class:switchItemTable() return true end

function class:init() end
function class:new(o)
    o = setmetatable(o or {}, { __index = self })
    o:init()
    if o.__name == "HorizontalGroup" and o.align ~= nil
        and o.align ~= "top" and o.align ~= "center" and o.align ~= "bottom" then
        error(string.format(
            "HorizontalGroup align %q is invalid on the device (top/center/bottom) — it would paint nothing",
            tostring(o.align)))
    end
    if o.__name == "VerticalGroup" and o.align ~= nil
        and o.align ~= "left" and o.align ~= "center" and o.align ~= "right" then
        error(string.format(
            "VerticalGroup align %q is invalid on the device (left/center/right)",
            tostring(o.align)))
    end
    return o
end
function class:extend(over)
    over = over or {}
    setmetatable(over, { __index = self })
    return over
end

local ScreenStub = {}
function ScreenStub:getWidth() return SCREEN_W end
function ScreenStub:getHeight() return SCREEN_H end
function ScreenStub:getSize() return { w = SCREEN_W, h = SCREEN_H } end
function ScreenStub:scaleBySize(v) return scal(v) end

local DevInputStub = { group = { Back = "back", Any = "any" } }
local DeviceStub = {
    screen = ScreenStub,
    input = DevInputStub,
    hasKeys = function() return false end,
    isTouchDevice = function() return true end,
    isKindle = function() return true end, -- deviceRoot() = /mnt/us (FAKE_FS)
}

local function widget_stub(name, extra)
    return class:extend(extra or { __name = name })
end

local reader_menu_order = { tools = { "read_timer" } }
local filemanager_menu_order = { tools = { "read_timer" } }

local SAFE_FACES = {
    cfont = true, tfont = true, smalltfont = true, x_smalltfont = true,
    ffont = true, smallffont = true, largeffont = true, pgfont = true,
    scfont = true, rifont = true, hpkfont = true, hfont = true,
    infont = true, smallinfont = true, infofont = true, smallinfofont = true,
    smallinfofontbold = true, x_smallinfofont = true, xx_smallinfofont = true,
}

-- Font:getFace without a size crashes the plugin on the Kindle (its named
-- fonts have no default size in the sizemap). The stub mirrors that so a
-- regression fails the harness instead of the device.
local FontStub = {
    getFace = function(_, name, size)
        if size then return { f = name, s = size } end
        if SAFE_FACES[name] then return { f = name, s = FACE_SIZES[name] or 22 } end
        error(string.format("Font:getFace(%q) without a size crashed here (exactly what killed the plugin)",
            tostring(name)))
    end,
    getSize = function() return 20 end,
}

-- ── settings + UIManager + global recorder ───────────────────────────────

G_reader_settings = {
    _store = {},
    readSetting = function(self, k) return G_reader_settings._store[k] end,
    saveSetting = function(self, k, v) G_reader_settings._store[k] = v end,
}

UIManager = {
    -- NOTE: this build has NO UIManager:replace (it crashed the plugin on
    -- device, and the harness must not provide one either, or Home's tab
    -- switch would pass against an API that doesn't exist).
    _shown = {},
    _shown_log = {},          -- every show() call, even if close() later pops it
    last_dirty = nil,
    last_show_mode = nil,
    last_show_region = nil,
    last_close_mode = nil,
    last_close_region = nil,
    show = function(_, w, mode, region)
        UIManager.last_show_mode = mode
        UIManager.last_show_region = region
        table.insert(UIManager._shown, w)
        table.insert(UIManager._shown_log, w)
    end,
    close = function(_, w, mode, region)
        UIManager.last_close_mode = mode
        UIManager.last_close_region = region
        for i = #UIManager._shown, 1, -1 do
            if UIManager._shown[i] == w then
                table.remove(UIManager._shown, i)
            end
        end
    end,
    setDirty = function(_, _, mode, region)
        UIManager.last_dirty = mode
        UIManager.last_dirty_region = region
    end,
    forceRePaint = function() end,
    nextTick = function(_, f) return f() end,
    scheduleIn = function() return { cancel = function() end } end,
    unschedule = function() end,
    _window_stack = {},
}

-- ── fake device filesystem ─────────────────────────────────────────────
-- The plugin touches the filesystem ONLY through lfs (never os.rename/os.mkdir
-- directly, so this stub is the single door). To give file semantics real
-- teeth — rename over the original in replace mode, mkdir -p into a chosen
-- destination, os.remove of a failed output — every virtual FAKE_FS path is
-- mirrored into a REAL backing tree under /tmp. Directory LISTING reads the
-- FAKE_FS table (deterministic); existence/mode/size/rename/mkdir hit real
-- files. os.remove is wrapped so the plugin's own paths map through the same
-- door.

local BACKING = "/tmp/boldonic_fs_harness"

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function real_path(p)
    return BACKING .. "/" .. tostring(p or ""):gsub("^/+", "")
end

-- The device layout the scans walk, hidden-dir and sidecar exclusions
-- included. fakebook_boldonic.epub is a PAST Boldonic output (the converted-
-- flag + scan-exclusion fixtures).
local FAKE_FS = {
    ["/mnt/us"] = { "Books", "Boldonic Books", "documents", "koreader", "system", "screenshots", ".hidden", "sneaky.azw3", "Guide.EPUB" },
    ["/mnt/us/Books"] = { "fakebook.epub", "fakebook_boldonic.epub", "sub", "fakebook.sdr", "._fakebook.epub" },
    ["/mnt/us/Books/sub"] = { "nested.epub" },
    ["/mnt/us/Books/fakebook.sdr"] = { "meta.epub" },
    ["/mnt/us/Boldonic Books"] = { "bold.epub" },
    ["/mnt/us/documents"] = { "fakebook2.azw" },
    ["/mnt/us/koreader"] = { "junk.epub" },
    ["/mnt/us/system"] = { "junk2.pdf" },
    ["/mnt/us/screenshots"] = { "screen.png" },
    ["/mnt/us/.hidden"] = { "hidden.epub" },
}

local function reset_fs()
    os.execute("rm -rf " .. shell_quote(BACKING))
    for dir, _ in pairs(FAKE_FS) do
        os.execute("mkdir -p " .. shell_quote(real_path(dir)))
    end
    for dir, entries in pairs(FAKE_FS) do
        for _, e in ipairs(entries) do
            if e:sub(-4) ~= ".sdr" then
                local f = io.open(real_path(dir .. "/" .. e), "w")
                if f then f:write(e .. "\n"); f:close() end
            end
        end
    end
end

local lfsstub = {}
function lfsstub.attributes(path, what)
    path = tostring(path or "")
    -- A real DIRECTORY opens with a trailing slash; a file never does (and
    -- this is quicker + more portable than io.open + lseek, which succeeds
    -- on directories on macOS and can mark dirs as files).
    local d = io.open(real_path(path) .. "/", "rb")
    if d then
        d:close()
        if what == "mode" then return "directory" end
        return { mode = "directory" }
    end
    local f = io.open(real_path(path), "rb")
    if f then
        local size = f:seek("end")
        f:close()
        if what == "size" then return size end
        if what == "mode" then return "file" end
        return { mode = "file", size = size }
    end
    if FAKE_FS[path] then
        if what == "mode" then return "directory" end
        return { mode = "directory" }
    end
    if what == "mode" then return nil end
    return nil
end
function lfsstub.dir(path)
    local entries = FAKE_FS[path]
    if not entries then return nil, path .. ": no such directory" end
    local i = 0
    local function iter()
        i = i + 1
        return entries[i]
    end
    return iter, path
end
function lfsstub.mkdir(path)
    path = tostring(path or ""):gsub("/+$", "")
    if path == "" or path == "/" then return true end
    if FAKE_FS[path] then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent then
        local ok = lfsstub.mkdir(parent)
        if not ok then return nil, "no such parent" end
    end
    os.execute("mkdir -p " .. shell_quote(real_path(path)))
    FAKE_FS[path] = {}
    local par = path:match("^(.*)/[^/]+$")
    if par then
        local list = FAKE_FS[par] or {}
        local name = path:match("([^/]+)$")
        local found = false
        for _, e in ipairs(list) do if e == name then found = true break end end
        if not found then list[#list + 1] = name end
        FAKE_FS[par] = list
    end
    return true
end
function lfsstub.rename(src, dst)
    src, dst = tostring(src or ""), tostring(dst or "")
    local ok = os.rename(real_path(src), real_path(dst))
    if not ok then return nil, "rename failed" end
    if FAKE_FS[src] then
        FAKE_FS[dst] = FAKE_FS[src]
        FAKE_FS[src] = nil
    end
    -- A renamed DIRECTORY must appear in its parent's listing; a renamed
    -- FILE must not. FAKE_FS doubles as reset_fs's static fixture set, and a
    -- one-time conversion rename would otherwise re-materialise the output
    -- copy as a "fixture" (with copy = content) on the very next reset.
    if FAKE_FS[dst] then
        local dp, dn = dst:match("^(.*)/([^/]+)$")
        if dp then
            local list = FAKE_FS[dp] or {}
            local found = false
            for _, e in ipairs(list) do if e == dn then found = true break end end
            if not found then list[#list + 1] = dn end
            FAKE_FS[dp] = list
        end
    end
    return true
end
function lfsstub.currentdir() return "/tmp" end

-- Route the plugin's os.remove() (failed-output cleanup) through the same
-- door so a failed conversion's output is really gone from the backing tree.
local REAL_os_remove = os.remove
os.remove = function(p)
    return REAL_os_remove(real_path(p))
end

-- Route the plugin's os.rename() through the same door (the plugin uses
-- os.rename on-device because some builds ship no lfs.rename).
local REAL_os_rename = os.rename
os.rename = function(src, dst)
    return REAL_os_rename(real_path(src), real_path(dst))
end

-- ── fake epub archive (ffi/archiver) ────────────────────────────────────
-- Reader opens a MANIFEST (registered per source path), Writer accumulates
-- entries and writes a real (concatenated) file into the backing tree so the
-- fs-level assertions (file exists / was removed / replaced) are real. The
-- harness never parses a zip — exactly the seam boldonic_convert.lua draws
-- around libarchive.
local ARC = {
    books = {},        -- [src] = { entries = {{ path, mode, data, mtime }, ...} }
    outputs = {},      -- [dest] = { [archive_path] = content }
    fail_open = {},    -- [src] = true  → Reader:open fails
    fail_extract = {}, -- [src] = true  → every extractToMemory fails (data:nil entries too)
    fail_write = {},   -- [dest] = true → addFileFromMemory fails
}

function ARC.seed(path, entries)
    ARC.books[path] = { entries = entries or {} }
end

function ARC.reset()
    ARC.books = {}
    ARC.outputs = {}
    ARC.fail_open = {}
    ARC.fail_extract = {}
    ARC.fail_write = {}
end

-- ── the require table: gives KOReader widget/font/settings stubs, the fake
-- lfs + archiver, and passes everything else (boldonic_*.lua) through.

local stubs = {
    ["logger"] = { warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s) return s end },
    ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_DARK_GRAY = "dgray", COLOR_LIGHT_GRAY = "lgray", Color8 = function(v) return "gray" .. tostring(v) end },
    ["ui/device"] = DeviceStub,
    ["device"] = DeviceStub,
    ["ui/uimanager"] = UIManager,
    ["ui/font"] = FontStub,
    ["ui/geometry"] = { new = function(_, o) return o or {} end },
    ["ui/gesturerange"] = { new = function(o) return o or {} end },
    ["ui/size"] = {
        radius = { window = scal(7), button = scal(12) },
        padding = { default = scal(5), large = scal(10) },
        span = { horizontal_default = scal(10) },
        border = { window = scal(1.5), button = scal(1.5) },
        line = { thin = scal(1), thick = scal(2) },
    },
    ["ui/widget/container/widgetcontainer"] = class:extend{},
    ["ui/widget/container/inputcontainer"] = class:extend{},
    ["ui/elements/reader_menu_order"] = reader_menu_order,
    ["ui/elements/filemanager_menu_order"] = filemanager_menu_order,
    ["libs/libkoreader-lfs"] = lfsstub,
    ["ffi/archiver"] = {
        Reader = {
            new = function()
                return {
                    open = function(self, src)
                        self.src = src
                        if ARC.fail_open[src] then return false end
                        local b = ARC.books[src]
                        if not b then self.err = "no such archive"; return false end
                        self.entries = b.entries
                        self.i = 0
                        return true
                    end,
                    iterate = function(self)
                        return function()
                            self.i = self.i + 1
                            return self.entries[self.i]
                        end
                    end,
                    extractToMemory = function(self, path)
                        if ARC.fail_extract[self.src] then
                            self.err = "read failed"
                            return nil
                        end
                        if not self.entries then self.err = "not open"; return nil end
                        for _, e in ipairs(self.entries) do
                            if e.path == path then
                                if e.data == nil then
                                    self.err = "entry missing"
                                    return nil
                                end
                                return e.data
                            end
                        end
                        return nil
                    end,
                    close = function() end,
                }
            end,
        },
        Writer = {
            new = function()
                return {
                    open = function(self, dest)
                        self.dest = dest
                        self.parts = {}
                        return true
                    end,
                    setZipCompression = function() end,
                    addFileFromMemory = function(self, path, data, mtime)
                        if ARC.fail_write[self.dest] then
                            self.err = "disk full"
                            return false
                        end
                        self.parts[#self.parts + 1] = { path = path, data = data }
                        return true
                    end,
                    close = function(self)
                        local map = {}
                        for _, p in ipairs(self.parts or {}) do map[p.path] = p.data end
                        ARC.outputs[self.dest] = map
                        local buf = {}
                        for _, p in ipairs(self.parts or {}) do buf[#buf + 1] = (p.data or "") end
                        local f = io.open(real_path(self.dest), "wb")
                        if f then f:write(table.concat(buf)); f:close() end
                    end,
                }
            end,
        },
    },
    -- DocumentRegistry: the picker's lazy per-page title upgrade opens books
    -- through it. The stub hands back a real title so the upgrade path can be
    -- exercised (pcall'd on the plugin side, so it is crash-safe either way).
    ["document/documentregistry"] = {
        openDocument = function(self, path)
            return {
                getProps = function() return { title = "Title From Document For " .. tostring(path) } end,
                close = function() end,
            }
        end,
        closeDocument = function() end,
    },
}

local function make_require()
    local real_require = require
    return function(name)
        if stubs[name] then return stubs[name] end
        if name:match("^ui/widget/") or name:match("^ui/") or name:match("^libs/") then
            return widget_stub(name)
        end
        return real_require(name)
    end
end

-- ── run the tests ─────────────────────────────────────────────────────────

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("PASS  " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

-- Depth-first search for the first widget whose .text field equals `needle`
-- (or contains it when `contains`).
local function find_text(widget, needle, contains)
    if type(widget) ~= "table" then return nil end
    if type(widget.text) == "string" then
        if contains and widget.text:find(needle, 1, true) then return widget end
        if not contains and widget.text == needle then return widget end
    end
    for i = 1, #widget do
        local hit = find_text(widget[i], needle, contains)
        if hit then return hit end
    end
    return nil
end

local function find_all_texts(widget, needle)
    local out = {}
    local function walk(w)
        if type(w) ~= "table" then return end
        if type(w.text) == "string" and w.text:find(needle, 1, true) then
            out[#out + 1] = w.text
        end
        for i = 1, #w do walk(w[i]) end
    end
    walk(widget)
    return out
end

_G.require = make_require()

-- ── load + identity ───────────────────────────────────────────────────────

local BOLDONIC = dofile(PLUGIN_ROOT .. "boldonic.koplugin/main.lua")
check("module loads", type(BOLDONIC) == "table", BOLDONIC)
check("module name is boldonic", BOLDONIC.name == "boldonic")
check("module has a version", type(BOLDONIC.VERSION) == "string")

local FAKEBOOK = "/mnt/us/Books/fakebook.epub"
local NESTED = "/mnt/us/Books/sub/nested.epub"

-- Deterministic device state for every run: wipe the /tmp backing tree the
-- stubs mirror into (a leftover from a previous run must never change the
-- outcome of a filesystem test).
reset_fs()
ARC.reset()

local inst = BOLDONIC:new{ ui = { document = { file = FAKEBOOK } } }

-- ── settings ──────────────────────────────────────────────────────────────

check("ratio defaults to 40", inst:ratio() == 40, tostring(inst:ratio()))
inst:setRatio(70)
check("setRatio persists", inst:ratio() == 70, tostring(inst:ratio()))
inst:setRatio(5)
check("ratio clamps low to 10", inst:ratio() == 10, tostring(inst:ratio()))
inst:setRatio(200)
check("ratio clamps high to 90", inst:ratio() == 90, tostring(inst:ratio()))
inst:setRatio(12)
check("custom (non-preset) ratio allowed", inst:ratio() == 12, tostring(inst:ratio()))
inst:setRatio(40)
check("mode defaults to copy", inst:mode() == "copy", tostring(inst:mode()))
inst:setMode("replace")
check("setMode replace", inst:mode() == "replace")
inst:setMode("copy")
check("setMode copy", inst:mode() == "copy")
check("destFolder defaults to ''", (inst:destFolder() or "") == "")
inst:setDestFolder("/mnt/us/Boldonic Books")
check("setDestFolder persists", inst:destFolder() == "/mnt/us/Boldonic Books", tostring(inst:destFolder()))
inst:setDestFolder("")
check("clearing destFolder returns to ''", (inst:destFolder() or "") == "")

-- ── output paths (outputPathFor / outputDescription) ─────────────────────

inst:setMode("copy")
inst:setDestFolder("")
check("copy lands next to the original (_boldonic suffix)",
    inst:outputPathFor(FAKEBOOK) == "/mnt/us/Books/fakebook_boldonic.epub",
    tostring(inst:outputPathFor(FAKEBOOK)))
check("a root-level book lands in / (no double slash)",
    inst:outputPathFor("/fake.epub") == "/fake_boldonic.epub",
    tostring(inst:outputPathFor("/fake.epub")))
inst:setDestFolder("/mnt/us/Boldonic Books")
check("copy lands in the chosen folder",
    inst:outputPathFor(FAKEBOOK) == "/mnt/us/Boldonic Books/fakebook_boldonic.epub",
    tostring(inst:outputPathFor(FAKEBOOK)))
inst:setMode("replace")
check("replace mode has no output path (overwrites in place)",
    inst:outputPathFor(FAKEBOOK) == nil)
inst:setMode("copy")
inst:setDestFolder("")
check("description: copy/next-to-original", inst:outputDescription(FAKEBOOK) == "next to the original",
    tostring(inst:outputDescription(FAKEBOOK)))
inst:setDestFolder("/mnt/us/Boldonic Books")
check("description: copy/chosen folder",
    inst:outputDescription(FAKEBOOK) == "/mnt/us/Boldonic Books",
    tostring(inst:outputDescription(FAKEBOOK)))
inst:setMode("replace")
check("description: replace", inst:outputDescription(FAKEBOOK) == "replaces the original",
    tostring(inst:outputDescription(FAKEBOOK)))
inst:setMode("copy")

-- ── isEpub / currentBookPath ─────────────────────────────────────────────

check("isEpub accepts .EPUB (case-insensitive)", inst:isEpub("/x/A.EPUB") == true)
check("isEpub accepts .epub", inst:isEpub("/x/a.epub") == true)
check("isEpub rejects mobi", inst:isEpub("/x/a.mobi") ~= true)
check("currentBookPath reads the open document", inst:currentBookPath() == FAKEBOOK)
local bare = BOLDONIC:new{ ui = { document = {} } }
check("currentBookPath nil without a file", bare:currentBookPath() == nil)

-- ── device tree helpers ───────────────────────────────────────────────────

check("deviceRoot is the Kindle user partition (host is a Kindle)",
    inst:deviceRoot() == "/mnt/us", tostring(inst:deviceRoot()))
inst.scan_root = "/mnt/us/Books"
check("scan_root overrides deviceRoot", inst:deviceRoot() == "/mnt/us/Books")
inst.scan_root = nil
local subs_root = inst:listSubfolders("/mnt/us")
check("listSubfolders lists dirs sorted + skips app/system/.hidden",
    subs_root[1] == "Boldonic Books" and subs_root[2] == "Books" and subs_root[3] == "documents"
        and #subs_root == 3,
    table.concat(subs_root, ", "))
check("listSubfolders skips .sdr sidecars",
    #inst:listSubfolders("/mnt/us/Books") == 1 and inst:listSubfolders("/mnt/us/Books")[1] == "sub",
    table.concat(inst:listSubfolders("/mnt/us/Books"), ", "))
check("listSubfolders of a missing dir is empty", #inst:listSubfolders("/mnt/us/nope") == 0)
check("mkdirs('') is a no-op true", inst:mkdirs("") == true)
check("mkdirs('/') is a no-op true", inst:mkdirs("/") == true)
check("mkdirs of an existing dir is true", inst:mkdirs("/mnt/us/Boldonic Books") == true)
local mok = inst:mkdirs("/mnt/us/Boldonic Books/Nested/Deep")
check("mkdirs creates the whole chain", mok == true, tostring(mok))
check("the new chain is real + listable",
    inst:listSubfolders("/mnt/us/Boldonic Books")[1] == "Nested",
    table.concat(inst:listSubfolders("/mnt/us/Boldonic Books"), ", "))
do
    local ok_file, err_file = inst:mkdirs("/mnt/us/Books/fakebook.epub")
    check("mkdirs fails over an existing FILE (not a dir)",
        ok_file == nil and tostring(err_file):match("fakebook.epub"),
        tostring(err_file))
end

-- ── conversion fixtures ───────────────────────────────────────────────────

local XHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>t</title></head><body><p>The quick brown fox jumps over the lazy dog.</p></body></html>"
local XHTML2 = "<html><body><p>Alpha beta gamma delta epsilon zeta.</p></body></html>"

local function seed_book(path)
    ARC.seed(path, {
        { path = "mimetype", mode = "file", mtime = 1600000000, data = "application/epub+zip" },
        { path = "META-INF/container.xml", mode = "file", mtime = 1600000001, data = "<container>rootfile=OEBPS/content.opf</container>" },
        { path = "OEBPS/style.css", mode = "file", mtime = 1600000002, data = "body{margin:0}" },
        { path = "OEBPS/images/cover.jpg", mode = "file", mtime = 1600000003, data = "\255\216\255\224\0\10J" },
        { path = "OEBPS/ch01.xhtml", mode = "file", mtime = 1600000004, data = XHTML },
        { path = "OEBPS/ch02.html", mode = "file", mtime = 1600000005, data = XHTML2 },
    })
end

-- ── convertOne: copy mode, byte-identical side-files, bolded xhtml ──────

reset_fs()
ARC.reset()
seed_book(FAKEBOOK)
inst:setMode("copy")
inst:setDestFolder("")
local ok1, err1 = inst:convertOne(FAKEBOOK, 40)
check("convertOne (copy) succeeds", ok1 == true, tostring(err1))
local OUT = inst:outputPathFor(FAKEBOOK)
-- convertOne writes the copy via a same-folder temp file then renames it into
-- place, so the converted bytes are recorded by the archiver under the temp
-- name while the final path appears atomically.
local function out_tmp(final)
    local dir = final:match("^(.*)/[^/]+$") or "."
    local base = final:match("([^/]+)$") or final
    local stem = base:match("^(.*)%.[^.]+$") or base
    return dir .. "/." .. stem .. ".boldonic.tmp"
end
local map = ARC.outputs[out_tmp(OUT)]
check("the copy was produced", type(map) == "table", OUT)
check("mimetype byte-identical (first entry untouched)",
    map and map["mimetype"] == "application/epub+zip")
check("container.xml byte-identical", map and map["META-INF/container.xml"] == "<container>rootfile=OEBPS/content.opf</container>")
check("style.css byte-identical", map and map["OEBPS/style.css"] == "body{margin:0}")
check("cover.jpg byte-identical", map and map["OEBPS/images/cover.jpg"] == "\255\216\255\224\0\10J")
check("ch01.xhtml was bolded (differs from the source)",
    map and map["OEBPS/ch01.xhtml"] ~= XHTML)
check("ch01.xhtml contains <b> tags",
    map and map["OEBPS/ch01.xhtml"]:find("<b>", 1, true) ~= nil)
check("ch01.xhtml dropped the <b> after the word (ratio honoured)",
    map and map["OEBPS/ch01.xhtml"]:gsub("<b>", ""):gsub("</b>", ""):find("The quick", 1, true) ~= nil)
check("ch02.html bolded too (html ext)",
    map and map["OEBPS/ch02.html"] ~= XHTML2 and map["OEBPS/ch02.html"]:find("<b>", 1, true) ~= nil)
-- the copy actually exists as a real file on the (fake) device
check("the copy exists as a real file",
    io.open(real_path(OUT), "rb") ~= nil, OUT)
check("no stray .boldonic.tmp is left behind after the rename",
    io.open(real_path(out_tmp(OUT)), "rb") == nil)
check("the source still exists unchanged next to a copy",
    io.open(real_path(FAKEBOOK), "rb") ~= nil)

-- convertOne creates an output folder on demand (mkdirs at convert time)
inst:setDestFolder("/mnt/us/Boldonic Books/New Folder")
local ok2 = inst:convertOne(FAKEBOOK, 40)
check("convertOne creates the chosen output folder on demand",
    ok2 == true and FAKE_FS["/mnt/us/Boldonic Books/New Folder"] ~= nil, tostring(ok2))
inst:setDestFolder("")

-- ── convertOne: replace mode rewrites the original in place ──────────────

ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
inst:setMode("replace")
inst:setDestFolder("")
local okr, errr = inst:convertOne(FAKEBOOK, 40)
check("convertOne (replace) succeeds", okr == true, tostring(errr))
check("replace writes no _boldonic copy", ARC.outputs[out_tmp(OUT)] == nil)
-- the ORIGINAL path was renamed over (its bytes are now the bolded book)
local f = io.open(real_path(FAKEBOOK), "rb")
local replaced_content = f and f:read("*a")
if f then f:close() end
check("original rewrote in place with bolded content",
    replaced_content ~= nil and replaced_content:find("<b>", 1, true) ~= nil)
check("no temp file left behind",
    io.open(real_path("/mnt/us/Books/.fakebook.boldonic.tmp"), "rb") == nil)
inst:setMode("copy")

-- ── convertOne: failures are clean (err + failed output removed) ─────────

ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
inst:setMode("copy")
inst:setDestFolder("")
ARC.fail_extract[FAKEBOOK] = true
local okf, errf = inst:convertOne(FAKEBOOK, 40)
check("a read failure surfaces an error", okf == nil and tostring(errf):match("read failed"),
    tostring(errf))
-- A failed conversion must never eat a pre-existing converted copy: only the
-- fresh temp handle is cleaned up (the fixture at OUT here is a PAST output
-- and must survive).
check("a failed conversion leaves a pre-existing output copy untouched",
    io.open(real_path(OUT), "rb") ~= nil
        and io.open(real_path(out_tmp(OUT)), "rb") == nil, OUT)
ARC.fail_extract[FAKEBOOK] = nil

ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
ARC.fail_write[out_tmp(OUT)] = true
local okw, errw = inst:convertOne(FAKEBOOK, 40)
check("a write failure surfaces an error", okw == nil and tostring(errw):match("disk full"),
    tostring(errw))
check("a write failure also leaves a pre-existing copy alone",
    io.open(real_path(OUT), "rb") ~= nil and io.open(real_path(out_tmp(OUT)), "rb") == nil)
ARC.fail_write[out_tmp(OUT)] = nil

ARC.reset()
reset_fs()
ARC.fail_open[FAKEBOOK] = true
local oko, erro = inst:convertOne(FAKEBOOK, 40)
check("an open failure surfaces an error", oko == nil and tostring(erro):match("open"),
    tostring(erro))
ARC.fail_open[FAKEBOOK] = nil

-- ── convertBooks: batch sink, dedupe, sort, done state ───────────────────

ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
seed_book(NESTED)
inst:setMode("copy")
inst:setDestFolder("")
local events = {}
local sink = {}
function sink:onBeginFile(path, i, total) events[#events + 1] = { "begin", path, i, total } end
function sink:onFileSent(path, out) events[#events + 1] = { "sent", path, out } end
function sink:onFileFailed(path, reason) events[#events + 1] = { "failed", path, reason } end
function sink:onDone(ok) events[#events + 1] = { "done", ok } end
local batch_ok = inst:convertBooks({ NESTED, FAKEBOOK, FAKEBOOK, NESTED }, sink)
check("convertBooks batch succeeds", batch_ok == true, tostring(batch_ok))
check("convertBooks dedupes the list (2 unique)",
    events[1][1] == "begin" and events[1][4] == 2 and events[3][1] == "begin" and events[3][4] == 2,
    tostring(events[1][4]))
check("the sink saw both converts and the done(true)",
    events[#events][1] == "done" and events[#events][2] == true
        and events[#events - 1][1] == "sent", events[#events - 1][1])
check("the batch converted the books sorted (fakebook then nested)",
    events[1][2] == FAKEBOOK and events[3][2] == NESTED,
    tostring(events[1][2]) .. " / " .. tostring(events[3][2]))

-- sink without onProgress = the standalone per-file path (dialog + toast).
-- The dialog is closed by the time convertBooks returns, so the "was shown"
-- assertions read the full _shown_log, not the live stack.
ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
UIManager._shown = {}
UIManager._shown_log = {}
inst:convertBooks({ FAKEBOOK }, {})
local shown_wait, shown_toast = false, false
for _, w in ipairs(UIManager._shown_log) do
    if type(w) == "table" then
        if type(w.book) == "string" and w.book == "fakebook.epub" then shown_wait = true end
        if type(w.text) == "string" and w.text:find("Converted", 1, true) then shown_toast = true end
    end
end
check("standalone convertBooks shows the waiting dialog + success toast",
    shown_wait and shown_toast, tostring(shown_wait) .. "/" .. tostring(shown_toast))

-- a failed batch reads failed(done(false)) at the end
ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
seed_book(NESTED)
ARC.fail_extract[NESTED] = true
local events2 = {}
local sink2 = {}
function sink2:onBeginFile(path, i, total) end
function sink2:onFileSent(path, out) end
function sink2:onFileFailed(path, reason) events2[#events2 + 1] = reason end
function sink2:onDone(ok) events2[#events2 + 1] = ok end
local failed_ok = inst:convertBooks({ FAKEBOOK, NESTED }, sink2)
check("a failed batch returns false", failed_ok == false, tostring(failed_ok))
check("a failed batch breaks on the first failure",
    events2[#events2] == false and #events2 == 2, tostring(#events2))

-- ── the duplicate guard + one-tap current-book convert ─────────────────

reset_fs()
ARC.reset()
inst:setMode("copy")
inst:setDestFolder("")
inst:setRatio(40)
inst.ui.document.file = FAKEBOOK

do
    local called = 0
    inst:guardConverted({ FAKEBOOK }, function() called = called + 1 end)
    local cf = UIManager._shown[#UIManager._shown]
    check("guardConverted pauses on an existing _boldonic copy",
        type(cf) == "table" and cf.ok_text == "Convert again",
        cf and cf.ok_text or "no confirm")
    check("guardConverted has NOT called on_ok yet", called == 0)
    if type(cf) == "table" and cf.ok_callback then cf.ok_callback() end
    check("guardConverted on_ok receives the batch after the confirm", called == 1)
    inst:guardConverted({ NESTED }, function() called = called + 10 end)
    check("guardConverted on a fresh book calls on_ok immediately", called == 11)
end

-- convertCurrentBook: the standalone one-tap flow (guards the dup, then the
-- waiting dialog + toast). No open file, a non-EPUB, then a real EPUB.
UIManager._shown = {}
local empty = BOLDONIC:new{ ui = { document = {} } }
empty:convertCurrentBook()
local im1 = UIManager._shown[#UIManager._shown]
check("convertCurrentBook without a file shows an info message",
    type(im1) == "table" and type(im1.text) == "string"
        and im1.text:find("no file to convert", 1, true) ~= nil,
    im1 and im1.text or "?")

UIManager._shown = {}
local azw = BOLDONIC:new{ ui = { document = { file = "/mnt/us/documents/fakebook2.azw" } } }
azw:convertCurrentBook()
local im2 = UIManager._shown[#UIManager._shown]
check("convertCurrentBook refuses a non-EPUB",
    type(im2) == "table" and type(im2.text) == "string"
        and im2.text:find("Only EPUB", 1, true) ~= nil)

ARC.reset()
reset_fs()
seed_book(NESTED)
local current = BOLDONIC:new{ ui = { document = { file = NESTED } } }
UIManager._shown = {}
UIManager._shown_log = {}
current:convertCurrentBook()
local wait_seen, toast_seen = false, false
for _, w in ipairs(UIManager._shown_log) do
    if type(w) == "table" then
        if type(w.book) == "string" and w.book == "nested.epub" then wait_seen = true end
        if type(w.text) == "string" and w.text:find("Converted", 1, true) then toast_seen = true end
    end
end
check("the waiting dialog names the book being converted", wait_seen)
check("the success toast confirms the conversion", toast_seen)
check("current-book conversion wrote the output",
    ARC.outputs[out_tmp("/mnt/us/Books/sub/nested_boldonic.epub")] ~= nil)

-- ── Tools-menu pinning + MainMenu registration ─────────────────────────

local menu_items = {}
inst:addToMainMenu(menu_items)
check("addToMainMenu registers the Boldonic item",
    type(menu_items.boldonic) == "table" and menu_items.boldonic.text == "Boldonic")
check("Tools menu pins Boldonic at position 2 (reader)",
    reader_menu_order.tools[2] == "boldonic",
    table.concat(reader_menu_order.tools, ", "))
check("Tools menu pins Boldonic at position 2 (filemanager)",
    filemanager_menu_order.tools[2] == "boldonic",
    table.concat(filemanager_menu_order.tools, ", "))
local pinned = #reader_menu_order.tools
inst:addToMainMenu(menu_items)
check("pinning is idempotent (no double insert)",
    #reader_menu_order.tools == pinned, tostring(#reader_menu_order.tools))

-- ── the dashboard ───────────────────────────────────────────────────────

inst:openHome()
local home = inst.home
check("openHome creates + keeps the Home instance", type(home) == "table" and home == inst.home)
check("openHome shows the dashboard as a full-screen 'ui' layer",
    UIManager.last_show_mode == "ui", tostring(UIManager.last_show_mode))
check("the dashboard opens on the Convert tab landing",
    home.tab == "convert" and home.convert_state == "idle"
        and home.convert_screen == nil and home.dest_screen == nil)

check("brand header paints the wordmark",
    find_text(home.frame, "Boldonic") ~= nil)
check("the Convert A File tab keeps its label",
    find_text(home.frame, "Convert A File") ~= nil)
check("the Settings tab keeps its label",
    find_text(home.frame, "Settings") ~= nil)

-- Convert landing: the pick action, the currently-open row, the settings
-- summary — all rendered below the always-on tabs.
local landing = home:buildTabContent("convert", home.row_w, home.content_h)
check("landing leads with the pick action",
    find_text(landing, "Click Here To Convert File(s)") ~= nil)
check("landing shows the currently-open EPUB row",
    find_text(landing, "tap to convert", true) ~= nil)
check("landing summarises the saved settings",
    find_text(landing, "Selected Settings", true) ~= nil
        and find_text(landing, "Bolding ratio", true) ~= nil
        and find_text(landing, "Keep original", true) ~= nil
        and find_text(landing, "Output folder", true) ~= nil)

-- Tab switching: Settings landing on the other tab, then back.
home:showTab("settings")
check("showTab('settings') lands on the Settings tab",
    home.tab == "settings" and home.dest_screen == nil)
local settings_vg = home:buildTabContent("settings", home.row_w, home.content_h)
check("Settings holds the ratio presets",
    find_text(settings_vg, "Bolding ratio") ~= nil
        and find_text(settings_vg, "Medium", true) ~= nil
        and find_text(settings_vg, "Custom", true) ~= nil)
check("Settings holds the keep-the-original modes",
    find_text(settings_vg, "Copy original", true) ~= nil
        and find_text(settings_vg, "Replace original") ~= nil)
check("Settings holds the destination row",
    find_text(settings_vg, "Destination folder") ~= nil)
home:showTab("about")
home:showTab("settings")
home:showTab("convert")
check("showTab('convert') back to the Convert tab",
    home.tab == "convert")

-- ── destination folder browser (inline on the Settings tab) ─────────────

home:openDestinationBrowser()
check("destination browser opens inline on the Settings tab",
    home.dest_screen == "browser" and home.dest_cwd == "/mnt/us",
    tostring(home.dest_cwd))
local dest_vg = home:buildTabContent("settings", home.row_w, home.content_h)
check("the default 'Next to the original' row is on top",
    find_text(dest_vg, "Next to the original", true) ~= nil)
check("the current folder is spelled out",
    find_text(dest_vg, "/mnt/us", true) ~= nil)
check("subfolders are listed from the device tree",
    find_text(dest_vg, "Boldonic Books", true) ~= nil
        and find_text(dest_vg, "documents", true) ~= nil
        and find_text(dest_vg, "koreader", true) == nil)
check("the folder rows finish with the three actions",
    find_text(dest_vg, "Select this folder") ~= nil
        and find_text(dest_vg, "Create New Folder", true) ~= nil
        and find_text(dest_vg, "Cancel") ~= nil)

do
    local sub_row = find_text(dest_vg, "Boldonic Books", true)
    check("a subfolder row is tappable into", type(sub_row) == "table" and sub_row.callback ~= nil)
    if sub_row and sub_row.callback then sub_row.callback() end
    check("tapping a subfolder descends into it",
        home.dest_cwd == "/mnt/us/Boldonic Books", tostring(home.dest_cwd))
    local dest2 = home:buildTabContent("settings", home.row_w, home.content_h)
    check("a parent row appears below the tree root",
        find_text(dest2, "parent folder", true) ~= nil)
    local sel = find_text(dest2, "Select this folder")
    check("Select this folder is tappable", type(sel) == "table" and sel.callback ~= nil)
    if sel and sel.callback then sel.callback() end
    check("selecting pins the cwd as the destination",
        inst:destFolder() == "/mnt/us/Boldonic Books",
        tostring(inst:destFolder()))
    check("selecting closes the browser to the Settings landing",
        home.dest_screen == nil)
end

-- Create New Folder: makes the folder NOW, pins it, and lands back on the
-- Settings landing.
UIManager._shown = {}
home:createFolderDialog()
local nd = UIManager._shown[#UIManager._shown]
check("create-folder asks for a name",
    type(nd) == "table" and nd.title == "Create New Folder",
    nd and nd.title or "?")
if type(nd) == "table" then
    nd.getInputText = function() return "  My Shelf Folder  " end
    for _, row in ipairs(nd.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn and btn.text == "Create" and btn.callback then btn.callback() end
        end
    end
end
check("creating a folder really makes it on the device",
    FAKE_FS["/mnt/us/Boldonic Books/My Shelf Folder"] ~= nil)
check("creating pins it as the destination",
    inst:destFolder() == "/mnt/us/Boldonic Books/My Shelf Folder",
    tostring(inst:destFolder()))
check("creating lands back on the Settings landing",
    home.dest_screen == nil)

UIManager._shown = {}
home:createFolderDialog()
local nd2 = UIManager._shown[#UIManager._shown]
if type(nd2) == "table" then
    nd2.getInputText = function() return "bad/name" end
    for _, row in ipairs(nd2.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn and btn.text == "Create" and btn.callback then btn.callback() end
        end
    end
end
local badnote = UIManager._shown[#UIManager._shown]
check("a slashed folder name is rejected with a hint",
    type(badnote) == "table" and type(badnote.text) == "string"
        and badnote.text:find("single name without slashes", 1, true) ~= nil,
    badnote and badnote.text or "?")
check("a slashed name never reached the device tree",
    FAKE_FS["/mnt/us/Boldonic Books/My Shelf Folder/bad/name"] == nil)

-- ── the EPUB picker (scan, exclusions, flags, ticks) ─────────────────────

inst:setMode("copy")
inst:setDestFolder("")
reset_fs()
ARC.reset()
local PickerDialog = require("boldonic_picker")
local pk = PickerDialog:new{ plugin = inst, home = nil }
local books = pk:scanAllBooks("/mnt/us")
check("the device-wide scan finds exactly the EPUBs",
    #books == 4, tostring(#books))
check("the scan is title-sorted (bold, fakebook, Guide, nested)",
    books[1] and books[1].name == "bold.epub"
        and books[2] and books[2].name == "fakebook.epub"
        and books[3] and books[3].name == "Guide.EPUB"
        and books[4] and books[4].name == "nested.epub",
    table.concat((function()
        local n = {}
        for _, b in ipairs(books) do n[#n + 1] = b.name end
        return n
    end)(), ", "))
check("the scan skips past Boldonic outputs and excluded roots", true)
do
    local in_books = pk:scanAllBooks("/mnt/us/Books")
    for _, b in ipairs(in_books) do
        check("  - scan never offers " .. b.name, b.name ~= "fakebook_boldonic.epub")
    end
    check("  - the Books scan returned the real file + its subfolder book",
        #in_books == 2 and in_books[1].name == "fakebook.epub" and in_books[2].name == "nested.epub",
        tostring(#in_books))
end
do
    local all = pk:scanAllBooks("/mnt/us")
    for _, b in ipairs(all) do
        check("  - skipped past the Boldonic product " .. b.name, b.name ~= "fakebook_boldonic.epub")
    end
end
check("the scan skips .sdr sidecars, hidden dirs and excluded roots",
    not (function()
        for _, b in ipairs(books) do
            if b.name == "meta.epub" or b.name == "hidden.epub" or b.name == "junk.epub" then
                return true
            end
        end
        return false
    end)(), "")
check("cleaned titles beat raw filenames for the display",
    books[2].title == "fakebook" and books[3].title == "Guide",
    tostring(books[2].title) .. " / " .. tostring(books[3].title))

pk.books = books
local fb = pk:bookByPath("/mnt/us/Books/fakebook.epub")
local nst = pk:bookByPath("/mnt/us/Books/sub/nested.epub")
check("the converted-flag sees the existing _boldonic copy",
    pk:convertedEntryFor(fb) and pk:convertedEntryFor(fb).path == "/mnt/us/Books/fakebook_boldonic.epub")
check("the converted-flag is empty for a fresh book",
    pk:convertedEntryFor(nst) == nil)
check("onConvertedCount counts exactly the flagged rows", pk:onConvertedCount() == 1)

check("convertRowText reads the selection count when picked",
    pk:convertRowText():find("pick files below", 1, true) ~= nil)
pk.picked = { ["/mnt/us/Books/sub/nested.epub"] = true }
check("convertRowText reads the selection count when picked",
    pk:convertRowText():find("convert 1 file(s) now", 1, true) ~= nil)

-- Switching the picked set on/off: a fresh book ticks and unticks cleanly.
pk.picked = {}
pk:toggle("/mnt/us/Books/sub/nested.epub")
check("tapping a fresh book ticks it", pk.picked["/mnt/us/Books/sub/nested.epub"])
pk:toggle("/mnt/us/Books/sub/nested.epub")
check("tapping it again unticks it", not pk.picked["/mnt/us/Books/sub/nested.epub"])

-- Tapping an ALREADY CONVERTED book must pause on the confirm, never tick
-- silently.
UIManager._shown = {}
pk.picked = {}
local before_pick = pk.picked["/mnt/us/Books/fakebook.epub"]
pk:toggle("/mnt/us/Books/fakebook.epub")
local flag_confirm = UIManager._shown[#UIManager._shown]
check("picking a converted book pauses on a confirm",
    type(flag_confirm) == "table" and flag_confirm.ok_text == "Convert again",
    flag_confirm and flag_confirm.ok_text or "?")
check("the confirm names the existing copy",
    type(flag_confirm) == "table" and type(flag_confirm.text) == "string"
        and flag_confirm.text:find("already converted", 1, true) ~= nil)
check("the book is NOT picked while the confirm waits",
    not pk.picked["/mnt/us/Books/fakebook.epub"])
if type(flag_confirm) == "table" and flag_confirm.ok_callback then flag_confirm.ok_callback() end
check("Convert again ticks the flagged book",
    pk.picked["/mnt/us/Books/fakebook.epub"] == true)

-- Empty pick: a gentle hint, never an accidental batch.
UIManager._shown = {}
pk.picked = {}
pk:confirmAndConvert()
local hint = UIManager._shown[#UIManager._shown]
check("an empty pick does not convert — only a hint",
    type(hint) == "table" and type(hint.text) == "string"
        and hint.text:find("Tap files below to pick them", 1, true) ~= nil)

-- Cleanup of the standalone picker's dashboard link (pk has no home, so the
-- next block starts from a fresh home).
pk.picked = {}

-- ── the picker INSIDE the dashboard + the conversion state machine ────────

ARC.reset()
reset_fs()
seed_book(NESTED)
home.convert_screen = nil
home:openFilesBrowser()
local dp = home.convert_picker
check("openFilesBrowser parks a picker on the Convert tab",
    type(dp) == "table" and home.convert_screen == "files")
dp.books = dp:scanAllBooks("/mnt/us")
local files_vg = home:buildTabContent("convert", home.row_w, home.content_h)
check("the picker renders INSIDE the tab region (no stacked dialog)",
    find_text(files_vg, "Search files", true) ~= nil
        and find_text(files_vg, "Convert to Boldonic", true) ~= nil
        and find_text(files_vg, "file(s) on this device", true) ~= nil)

-- Re-tapping the active tab backs to the landing, state stays cached.
home:showTab("convert")
check("re-tapping the active Convert tab backs out to its landing",
    home.convert_screen == nil)
home:openFilesBrowser()
check("opening the browser again restores the screen", home.convert_screen == "files")

local dp2 = home.convert_picker
dp2.books = dp2:scanAllBooks("/mnt/us")
dp2.picked = { [NESTED] = true }

UIManager._shown = {}
dp2:confirmAndConvert()
local cbox = UIManager._shown[#UIManager._shown]
check("the convert action confirms on the labeled button first",
    type(cbox) == "table" and cbox.ok_text == "Convert to Boldonic",
    cbox and cbox.ok_text or "?")
check("the confirm spells out what will convert",
    type(cbox) == "table" and type(cbox.text) == "string"
        and cbox.text:find("nested", 1, true) ~= nil)
if type(cbox) == "table" and cbox.ok_callback then cbox.ok_callback() end
check("the picked batch converts inside the open dashboard",
    home.convert_state == "done", tostring(home.convert_state))
check("the convert screen hands back to the landing",
    home.convert_screen == nil)
check("the batch wrote the bolded copy",
    ARC.outputs[out_tmp("/mnt/us/Books/sub/nested_boldonic.epub")] ~= nil)
check("the done panel lists the converted file",
    find_text(home:buildTabContent("convert", home.row_w, home.content_h),
        "Converted 1 file(s).", true) ~= nil)

-- A failed batch lands on the failed panel with the reason and Try again.
ARC.fail_extract[NESTED] = true
dp2.picked = { [NESTED] = true }
UIManager._shown = {}
dp2:confirmAndConvert()
local cbox2 = UIManager._shown[#UIManager._shown]
if type(cbox2) == "table" and cbox2.ok_callback then cbox2.ok_callback() end
check("a failed batch shows the failed panel",
    home.convert_state == "failed", tostring(home.convert_state))
check("the failed panel names the file + reason",
    type(home.fail_reason) == "string"
        and home.fail_reason:find("nested.epub", 1, true) ~= nil,
    tostring(home.fail_reason))
check("the failed panel offers Try again",
    find_text(home:buildTabContent("convert", home.row_w, home.content_h), "Try again") ~= nil)
home:backToIdle()
check("back to idle clears the batch state",
    home.convert_state == "idle" and home.convert_paths == nil)

-- The scan only ever showed 4 files; the conversion flag re-checked the
-- batch copy was really written to the (fake) card.
check("the batch output physically exists on the card",
    io.open(real_path("/mnt/us/Books/sub/nested_boldonic.epub"), "rb") ~= nil)

-- ── the "Currently open" one-tap convert (dup-guarded) ───────────────────

ARC.reset()
reset_fs()
seed_book(FAKEBOOK)
inst.ui.document.file = FAKEBOOK
home.convert_screen = nil
home:init()
local open_landing = home:buildTabContent("convert", home.row_w, home.content_h)
local open_row = find_text(open_landing, "tap to convert", true)
check("the Currently open row converts on one tap", open_row ~= nil)
UIManager._shown = {}
if open_row and open_row.callback then open_row.callback() end
local guarded = UIManager._shown[#UIManager._shown]
check("the one-tap path flags the existing copy first",
    type(guarded) == "table" and guarded.ok_text == "Convert again",
    guarded and guarded.ok_text or "?")
if type(guarded) == "table" and guarded.ok_callback then guarded.ok_callback() end
check("confirming overwrote the copy in place",
    home.convert_state == "done"
        and ARC.outputs[out_tmp("/mnt/us/Books/fakebook_boldonic.epub")] ~= nil)

-- ── real titles: lazy per-page Document upgrade ─────────────────────────

local pk2 = PickerDialog:new{ plugin = inst, home = nil }
pk2.books = pk2:scanAllBooks("/mnt/us")
local up_fb = pk2:bookByPath("/mnt/us/Books/fakebook.epub")
local up_nested = pk2:bookByPath("/mnt/us/Books/sub/nested.epub")
check("scan titles start as cleaned filenames (real = nil)",
    up_fb.real == nil and up_nested.real == nil)
UIManager._shown = {}
pk2:upgradeVisibleTitles()
check("the lazy upgrade names the books from the Document provider",
    up_fb.real == true
        and up_fb.title == "Title From Document For /mnt/us/Books/fakebook.epub",
    tostring(up_fb and up_fb.title))
check("the upgrade caches the real title on disk",
    type(pk2.title_cache[up_nested.path]) == "string")

-- ── closing the dashboard ────────────────────────────────────────────────

UIManager._shown = {}
home:onBack()
if home.onCloseWidget then home:onCloseWidget() end
check("Back on a landing closes the dashboard",
    UIManager._shown[1] == nil and inst.home == nil,
    tostring(inst.home == nil))

-- ── verdict ──────────────────────────────────────────────────────────────

print(string.format("boldonic harness: %d failure(s)", failures))
if failures == 0 then
    print("ALL TESTS PASSED")
    os.exit(0)
else
    print("FAILED")
    os.exit(1)
end