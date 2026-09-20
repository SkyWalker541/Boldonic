-- Persistent conversion log: tracks converted books across locations
-- Stored in KOReader's data directory, survives plugin updates

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- Try to load optional modules, handle gracefully if unavailable
local ok_json, json = pcall(require, "json")
local ok_storage, storage = pcall(require, "storage")

local Log = {}

-- Log file lives in KOReader's data directory (survives plugin updates)
local function log_dir()
    if not ok_storage or not storage then return nil end
    local dir = storage.getDir() .. "/plugins/data/boldonic"
    return dir
end

local function log_path()
    local dir = log_dir()
    if not dir then return nil end
    return dir .. "/conversions.json"
end

-- Ensure log directory exists
local function ensure_dir()
    local dir = log_dir()
    if not dir then return false end
    if not lfs.attributes(dir, "mode") then
        return lfs.mkdir(dir)
    end
    return true
end

-- Load log from disk (returns table, never nil)
function Log.load()
    if not ok_json or not json or not ensure_dir() then return {} end
    local path = log_path()
    if not path then return {} end
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    logger.warn("boldonic: failed to parse conversion log, starting fresh")
    return {}
end

-- Save log to disk (atomic write)
function Log.save(data)
    if not ok_json or not json or not ensure_dir() then return false end
    local path = log_path()
    if not path then return false end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "could not open log for writing" end
    local content = json.encode(data)
    f:write(content)
    f:close()
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return false, "could not rename log file"
    end
    return true
end

-- Check if a source book has been converted (log + verify file exists)
function Log.isConverted(source_path)
    if not ok_json then return false end
    local log = Log.load()
    local entry = log[source_path]
    if not entry then return false end
    -- Verify the output file still exists
    if entry.output_path and lfs.attributes(entry.output_path, "mode") == "file" then
        return true, entry
    end
    -- Output file gone — mark as stale (will be cleaned on next sync)
    return false, entry
end

-- Record a successful conversion
function Log.record(source_path, output_path, mode, ratio, title)
    if not ok_json then return false end
    local log = Log.load()
    log[source_path] = {
        output_path = output_path,
        mode = mode,
        ratio = ratio,
        title = title or "",
        timestamp = os.time(),
    }
    return Log.save(log)
end

-- Remove stale entries (output file missing) — call on picker open
function Log.sync()
    if not ok_json then return false end
    local log = Log.load()
    local changed = false
    for src, entry in pairs(log) do
        if entry.output_path and lfs.attributes(entry.output_path, "mode") ~= "file" then
            log[src] = nil
            changed = true
        end
    end
    if changed then
        Log.save(log)
    end
    return changed
end

-- Get all conversion records (for history UI)
function Log.getAll()
    return Log.load()
end

-- Delete a record (if user wants to "unconvert" tracking)
function Log.delete(source_path)
    if not ok_json then return false end
    local log = Log.load()
    if log[source_path] then
        log[source_path] = nil
        return Log.save(log)
    end
    return true
end

return Log