-- Boldonic word-bolding engine: a pure-Lua port of boldonic.c (the GitHub
-- project's C helper). Bolds the first ~ratio% of each word with <b>…</b> to
-- help reading speed. Byte-level, UTF-8-aware, and faithful to the original:
--
--   * word starts: ASCII letters, or any 2-byte UTF-8 lead (0xC0-0xDF,
--     catches Latin-1 accented letters and Cyrillic)
--   * word characters: those, plus any continuation byte (0x80-0xBF)
--   * <b> tag / <?xml ?> declaration runs are copied through untouched
--   * lines are processed independently (state resets at each newline),
--     and every line is re-emitted with its trailing newline (the C helper
--     prints `putchar('\n')` after every line it reads)
--   * bold count per word: 1 char for words up to 2 chars, else
--     round(wlen * ratio / 100), clamped to [1, wlen-1]

local Boldify = {}

local function is_ascii_letter(b)
    return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A)
end

local function is_word_start(b)
    if is_ascii_letter(b) then return true end
    return b >= 0xC0 and b <= 0xDF -- any 2-byte UTF-8 lead byte
end

local function is_word_cont(b)
    if is_ascii_letter(b) then return true end
    if b >= 0x80 and b <= 0xBF then return true end -- continuation byte
    return b >= 0xC0 and b <= 0xDF -- 2-byte lead byte continues a word
end

local function get_utf8_char_len(b)
    if b < 0x80 then return 1 end
    if b >= 0xC0 and b <= 0xDF then return 2 end
    if b >= 0xE0 and b <= 0xEF then return 3 end
    if b >= 0xF0 and b <= 0xF7 then return 4 end
    return 1
end

local function process_line(line, ratio)
    local len = #line
    local i = 1
    local in_tag, in_decl = false, false
    local out = {}

    while i <= len do
        local c = line:byte(i)

        if in_decl then
            out[#out + 1] = string.char(c)
            if c == 0x3E and i > 1 and line:byte(i - 1) == 0x3F then
                in_decl = false
            end
            i = i + 1
        elseif in_tag then
            out[#out + 1] = string.char(c)
            if c == 0x3E then
                in_tag = false
            end
            i = i + 1
        elseif c == 0x3C then
            if i + 1 <= len and line:byte(i + 1) == 0x3F then
                in_decl = true
            else
                in_tag = true
            end
            out[#out + 1] = string.char(c)
            i = i + 1
        elseif is_word_start(c) then
            -- collect the whole word (bytes + char count), like the C buffer
            local word_parts, wbytes, wlen = {}, 0, 0
            while i <= len do
                local bc = line:byte(i)
                if is_word_cont(bc) then
                    local clen = get_utf8_char_len(bc)
                    word_parts[#word_parts + 1] = line:sub(i, i + clen - 1)
                    wbytes = wbytes + clen
                    wlen = wlen + 1
                    i = i + clen
                else
                    break
                end
            end
            local word = table.concat(word_parts)

            local bold_count
            if wlen <= 2 then
                bold_count = 1
            else
                bold_count = math.floor(wlen * ratio / 100.0 + 0.5)
                if bold_count < 1 then bold_count = 1 end
                if bold_count >= wlen then bold_count = wlen - 1 end
            end

            -- byte position that ends the bold_count-th character
            local bold_byte_pos = 0
            local chars_seen = 0
            local pos = 1
            while pos <= wbytes and chars_seen < bold_count do
                pos = pos + get_utf8_char_len(word:byte(pos))
                chars_seen = chars_seen + 1
            end
            bold_byte_pos = pos - 1

            out[#out + 1] = "<b>" .. word:sub(1, bold_byte_pos)
            out[#out + 1] = "</b>" .. word:sub(bold_byte_pos + 1)
        else
            out[#out + 1] = string.char(c)
            i = i + 1
        end
    end

    return table.concat(out)
end

-- Bold the first `ratio` percent of each word in an HTML/XHTML source string.
-- Line handling mirrors the C helper's stdin loop exactly.
function Boldify.process(content, ratio)
    ratio = tonumber(ratio) or 40
    if ratio < 10 or ratio > 90 then ratio = 40 end
    content = tostring(content or "")
    if content == "" then return "" end

    local out = {}
    local pos = 1
    local n = #content
    while pos <= n do
        local nl = content:find("\n", pos, true)
        if not nl then
            out[#out + 1] = process_line(content:sub(pos), ratio)
            out[#out + 1] = "\n"
            break
        end
        out[#out + 1] = process_line(content:sub(pos, nl - 1), ratio)
        out[#out + 1] = "\n"
        pos = nl + 1
    end
    return table.concat(out)
end

return Boldify