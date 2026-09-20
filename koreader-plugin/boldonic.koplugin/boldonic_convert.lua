-- EPUB conversion engine: reads a source EPUB with the KOReader libarchive
-- Reader, re-writes it with the Writer (zip/deflate), and runs the word-bold
-- engine over every XHTML/HTML file along the way. Everything else (CSS,
-- images, fonts, mimetype, container.xml) is copied byte-for-byte, so the
-- result is a valid EPUB that the built-in reader opens as a book.
--
-- ffi/archiver is required lazily (only when a conversion actually runs), so
-- loading the plugin never needs the module — and tests can swap in a fake.

local Boldify = require("boldonic_boldify")

local CONTENT_EXT = {
    xhtml = true,
    html = true,
    htm = true,
}

local Convert = {}

local function is_content_file(name)
    local ext = name:match("[.]([^.]+)$")
    return ext ~= nil and CONTENT_EXT[string.lower(ext)] == true
end

-- Convert one EPUB in place of `dest`. `dest` is overwritten if it exists
-- (the caller picks the final path; replace-original callers write to a temp
-- name and rename). Returns (true) or (nil, err).
function Convert.file(src, dest, ratio, on_entry)
    local ok_arch, Arch = pcall(require, "ffi/archiver")
    if not ok_arch or not Arch then
        return nil, "ffi/archiver module unavailable"
    end

    local ok, err = pcall(function()
        local reader = Arch.Reader:new()
        if not reader:open(src) then
            error("could not open the book (is it a valid EPUB?)")
        end

        local writer = Arch.Writer:new()
        if not writer:open(dest, "epub") then
            reader:close()
            error("could not create the converted file at " .. tostring(dest))
        end
        writer:setZipCompression("deflate")

        local ok2, err2 = true, nil
        for entry in reader:iterate() do
            if entry.mode == "file" then
                local content = reader:extractToMemory(entry.path)
                if content == nil then
                    ok2, err2 = false, reader.err or ("could not read " .. tostring(entry.path))
                    break
                end
                if is_content_file(entry.path) then
                    content = Boldify.process(content, ratio)
                end
                if not writer:addFileFromMemory(entry.path, content, entry.mtime) then
                    ok2, err2 = false, writer.err or ("could not write " .. tostring(entry.path))
                    break
                end
                if on_entry then on_entry(entry.path) end
            end
        end

        writer:close()
        reader:close()

        if not ok2 then
            error(err2 or "conversion failed")
        end
    end)

    if not ok then
        -- Clean up partial output on error
        os.remove(dest)
        return nil, err or "conversion failed"
    end
    return true
end

return Convert