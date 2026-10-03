--[[
    text_chunker.lua - Text extraction, sanitization, and sentence chunking module
    Compatible with Crengine (EPUB/MOBI) and MuPDF (PDF).
    Implements 3-tier sentence chunking & pronunciation dictionary normalization.
--]]

local Settings = require("settings")

local TextChunker = {}
TextChunker.__index = TextChunker

local DEFAULT_MIN_CHARS = 30
local DEFAULT_MAX_CHARS = 300

--- Initialize TextChunker instance
-- @param options Config table: min_chars, max_chars, filter_footnotes, custom_mappings
function TextChunker:new(options)
    local opts = options or {}
    local instance = setmetatable({}, self)
    instance.min_chars = opts.min_chars or DEFAULT_MIN_CHARS
    instance.max_chars = opts.max_chars or DEFAULT_MAX_CHARS
    instance.filter_footnotes = (opts.filter_footnotes ~= false)
    instance.custom_mappings = opts.custom_mappings or {}
    return instance
end

--- Sanitize raw text: strip footnotes, standalone page numbers, and soft hyphens
-- @param raw_text Raw document text string
-- @return string Cleaned text string
function TextChunker:sanitize(raw_text)
    if not raw_text or type(raw_text) ~= "string" or raw_text == "" then
        return ""
    end

    local text = raw_text

    -- 1. Strip soft hyphens (UTF-8 0xC2 0xAD)
    text = text:gsub("\194\173", "")

    -- 2. Normalize non-breaking spaces (UTF-8 0xC2 0xA0) to standard spaces
    text = text:gsub("\194\160", " ")

    -- 3. Strip standalone page numbers at headers or footers
    text = text:gsub("^%s*%d+%s*[\r\n]+", "")
    text = text:gsub("[\r\n]+%s*%d+%s*$", "")
    text = text:gsub("[\r\n]+%s*%d+%s*/%s*%d+%s*[\r\n]+", " ")

    -- 4. Strip footnote markers: [1], [12], (1), *, †, ‡ (replace with space to prevent glued words)
    if self.filter_footnotes then
        text = text:gsub("%[%d+%]", " ")
        text = text:gsub("%(%d+%)", " ")
        text = text:gsub("%*+", " ")
        text = text:gsub("†", " ")
        text = text:gsub("‡", " ")
    end

    -- 5. Normalize ellipsis: '...' to '…'
    text = text:gsub("%.%.%.+", "…")

    -- 6. Collapse consecutive whitespace and linebreaks into a single space
    text = text:gsub("[\r\n]+", " ")
    text = text:gsub("%s+", " ")

    -- 7. Trim leading and trailing whitespace
    text = text:gsub("^%s+", ""):gsub("%s+$", "")

    return text
end

--- Normalize abbreviations / hard words using pronunciation dictionary
-- @param text Text string to normalize
-- @param custom_dict Additional custom dictionary mappings (optional)
-- @return string Normalized text string ready for TTS
function TextChunker:normalizePronunciation(text, custom_dict)
    if not text or type(text) ~= "string" or text == "" then
        return ""
    end

    -- Merge default dictionary from Settings and custom mappings
    local mappings = {}
    if Settings and Settings.DEFAULT_PRONUNCIATION_MAP then
        for k, v in pairs(Settings.DEFAULT_PRONUNCIATION_MAP) do
            mappings[k] = v
        end
    end
    if self.custom_mappings then
        for k, v in pairs(self.custom_mappings) do
            mappings[k] = v
        end
    end
    if custom_dict then
        for k, v in pairs(custom_dict) do
            mappings[k] = v
        end
    end

    local result = text

    -- Iterate through dictionary mappings with word boundary checks
    for orig, replacement in pairs(mappings) do
        if orig and orig ~= "" and replacement then
            -- Escape Lua pattern special characters in original word
            local escaped_orig = orig:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")

            -- If original word ends with a period (e.g. TP., TS., v.v.)
            if orig:sub(-1) == "." then
                -- Match at start of sentence
                result = result:gsub("^" .. escaped_orig .. "(%s+)", replacement .. "%1")
                result = result:gsub("^" .. escaped_orig .. "$", replacement)
                -- Match after whitespace or opening punctuation
                result = result:gsub("([%s%(\"“])" .. escaped_orig .. "(%s+)", "%1" .. replacement .. "%2")
                result = result:gsub("([%s%(\"“])" .. escaped_orig .. "$", "%1" .. replacement)
                result = result:gsub("([%s%(\"“])" .. escaped_orig .. "([%,%;%:…])", "%1" .. replacement .. "%2")
            else
                -- Standard abbreviation without period (e.g. ĐH, CNTT, AI, NXB)
                result = result:gsub("^" .. escaped_orig .. "(%s+)", replacement .. "%1")
                result = result:gsub("^" .. escaped_orig .. "$", replacement)
                result = result:gsub("([%s%(\"“%[%'%-%,])" .. escaped_orig .. "(%s+)", "%1" .. replacement .. "%2")
                result = result:gsub("([%s%(\"“%[%'%-%,])" .. escaped_orig .. "$", "%1" .. replacement)
                result = result:gsub("([%s%(\"“%[%'%-%,])" .. escaped_orig .. "([%.%?%!%,%;%:…%)\"”%s])", "%1" .. replacement .. "%2")
            end
        end
    end

    return result
end

--- Split a long sentence (> max_chars) at natural punctuation near the middle (Tier 3)
-- @param sentence Long sentence string
-- @param max_limit Maximum character threshold
-- @return table Array of shorter sentence chunks
local function splitLongSentence(sentence, max_limit)
    if #sentence <= max_limit then
        return { sentence }
    end

    local chunks = {}
    local remaining = sentence

    while #remaining > max_limit do
        local search_sub = remaining:sub(1, max_limit)

        -- Find natural split point before max_limit: comma, semicolon, colon, dash
        local split_pos = nil
        local best_punc = { ",", ";", ":", "—", "-" }
        for _, punc in ipairs(best_punc) do
            local p_idx = nil
            local cur = 1
            while true do
                local found = search_sub:find(punc, cur, true)
                if not found or found > max_limit then break end
                if found >= 20 then
                    p_idx = found
                end
                cur = found + 1
            end
            if p_idx then
                split_pos = p_idx
                break
            end
        end

        -- Fallback: split at space nearest to limit
        if not split_pos then
            local space_idx = nil
            local cur = 1
            while true do
                local found = search_sub:find(" ", cur, true)
                if not found or found > max_limit then break end
                if found >= 20 then
                    space_idx = found
                end
                cur = found + 1
            end
            split_pos = space_idx
        end

        -- Hard split fallback at max_limit
        if not split_pos then
            split_pos = max_limit
        end

        local part1 = remaining:sub(1, split_pos):gsub("^%s+", ""):gsub("%s+$", "")
        local part2 = remaining:sub(split_pos + 1):gsub("^%s+", ""):gsub("%s+$", "")

        if #part1 > 0 then
            table.insert(chunks, part1)
        end
        remaining = part2
    end

    if #remaining > 0 then
        table.insert(chunks, remaining)
    end

    return chunks
end

--- Split sanitized text into sentences using 3-tier algorithm
-- @param text Sanitized text string
-- @return table Array of sentence strings
function TextChunker:splitSentences(text)
    if not text or type(text) ~= "string" or text == "" then
        return {}
    end

    local raw_sentences = {}
    local len = #text
    local start_idx = 1
    local in_quotes = false
    local quote_char = nil

    local i = 1
    while i <= len do
        local c = text:sub(i, i)
        local next_c = (i < len) and text:sub(i + 1, i + 1) or ""

        -- Track dialogue quotes open/close state
        if c == '"' or c == '“' or c == '”' then
            if not in_quotes then
                in_quotes = true
                quote_char = c
            else
                in_quotes = false
                quote_char = nil
            end
        end

        -- Check sentence terminators: . ? ! …
        local is_delimiter = false
        if (c == "." or c == "?" or c == "!" or c == "…") then
            -- Ignore periods in decimal numbers (e.g. 3.14, 10.5)
            local prev_c = (i > 1) and text:sub(i - 1, i - 1) or ""
            local is_decimal = (c == "." and prev_c:match("%d") and next_c:match("%d"))

            -- Ignore periods in known abbreviations (TP., TS., ThS., GS., v.v.)
            local is_abbrev = false
            if c == "." then
                local check_window = text:sub(math.max(1, i - 10), i)
                local prev_word = check_window:match("([%a%.]+)%.$")
                if prev_word then
                    local lower_pw = prev_word:lower()
                    local KNOWN_ABBREVS = {
                        ["tp"] = true, ["ts"] = true, ["ths"] = true, ["pgs"] = true,
                        ["gs"] = true, ["bs"] = true, ["v.v"] = true, ["nxb"] = true,
                        ["ks"] = true, ["dr"] = true, ["mr"] = true, ["mrs"] = true,
                        ["ms"] = true, ["prof"] = true,
                    }
                    if KNOWN_ABBREVS[lower_pw] or (prev_word:match("^%u+$") and #prev_word <= 4) then
                        is_abbrev = true
                    end
                end
            end

            if not is_decimal and not is_abbrev then
                -- Delimiter is valid if outside quotes or immediately followed by closing quote/space
                if not in_quotes or next_c == '"' or next_c == '”' or next_c == ' ' or next_c == "" then
                    is_delimiter = true
                end
            end
        end

        if is_delimiter then
            -- Collect contiguous punctuation marks (e.g. !?, ..., !!!)
            local end_idx = i
            while end_idx < len do
                local peek = text:sub(end_idx + 1, end_idx + 1)
                if peek == "." or peek == "?" or peek == "!" or peek == "…" or peek == '"' or peek == '”' then
                    end_idx = end_idx + 1
                else
                    break
                end
            end

            local s = text:sub(start_idx, end_idx):gsub("^%s+", ""):gsub("%s+$", "")
            if #s > 0 then
                table.insert(raw_sentences, s)
            end

            i = end_idx + 1
            start_idx = i
        else
            i = i + 1
        end
    end

    -- Append trailing text if not terminated with punctuation
    if start_idx <= len then
        local tail = text:sub(start_idx, len):gsub("^%s+", ""):gsub("%s+$", "")
        if #tail > 0 then
            table.insert(raw_sentences, tail)
        end
    end

    if #raw_sentences == 0 then
        return {}
    end

    -- TIER 2: Merge short chunks (< min_chars) into next chunk (Anti-fragmentation)
    local merged_sentences = {}
    local buffer = ""

    for idx, s in ipairs(raw_sentences) do
        if #buffer > 0 then
            buffer = buffer .. " " .. s
        else
            buffer = s
        end

        if #buffer >= self.min_chars or idx == #raw_sentences then
            table.insert(merged_sentences, buffer)
            buffer = ""
        end
    end

    if #buffer > 0 then
        if #merged_sentences > 0 then
            merged_sentences[#merged_sentences] = merged_sentences[#merged_sentences] .. " " .. buffer
        else
            table.insert(merged_sentences, buffer)
        end
    end

    -- TIER 3: Safety Split sentences longer than max_chars at natural punctuation
    local final_sentences = {}
    for _, s in ipairs(merged_sentences) do
        if #s > self.max_chars then
            local splits = splitLongSentence(s, self.max_chars)
            for _, sub_s in ipairs(splits) do
                if #sub_s > 0 then
                    table.insert(final_sentences, sub_s)
                end
            end
        else
            table.insert(final_sentences, s)
        end
    end

    return final_sentences
end

--- Extract raw text from page via Document Engine (Hybrid Strategy)
-- Supports both Crengine (EPUB/MOBI) and MuPDF (PDF)
-- @param document KOReader self.ui.document object (or mock)
-- @param page_num Page number (1-based)
-- @return string raw text, table word bounding boxes
function TextChunker:extractRawPageText(document, page_num)
    if not document then
        return "", {}
    end

    local text = ""
    local word_boxes = {}

    -- 1. Try MuPDF API: getPageText & getTextWordBoxes
    local ok_mupdf, res_text = pcall(function()
        if type(document.getPageText) == "function" then
            return document:getPageText(page_num)
        end
    end)
    if ok_mupdf and type(res_text) == "string" and #res_text > 0 then
        text = res_text
        pcall(function()
            if type(document.getTextWordBoxes) == "function" then
                word_boxes = document:getTextWordBoxes(page_num) or {}
            end
        end)
        return text, word_boxes
    end

    -- 2. Try Crengine API: getTextFromPositions & getWordBBoxes
    local ok_cre, res_cre = pcall(function()
        if type(document.getTextFromPositions) == "function" then
            return document:getTextFromPositions(page_num)
        end
    end)
    if ok_cre and type(res_cre) == "string" and #res_cre > 0 then
        text = res_cre
        pcall(function()
            if type(document.getWordBBoxes) == "function" then
                word_boxes = document:getWordBBoxes(page_num) or {}
            end
        end)
        return text, word_boxes
    end

    -- 3. Generic fallback
    if type(document.getText) == "function" then
        pcall(function()
            text = document:getText(page_num) or ""
        end)
    end

    return text or "", word_boxes or {}
end

--- Map sentence position to word bounding boxes on the page
-- @param raw_sentence Raw sentence string
-- @param full_text Full page text string
-- @param word_boxes Array of word bounding boxes on the page
-- @param search_offset Search start offset in full_text
-- @return table matched bounding boxes, number end offset
local function mapSentenceToBBoxes(raw_sentence, full_text, word_boxes, search_offset)
    if not word_boxes or #word_boxes == 0 or not full_text or #full_text == 0 then
        return {}, search_offset
    end

    local s_start, s_end = full_text:find(raw_sentence, search_offset, true)
    if not s_start then
        local first_words = raw_sentence:match("^%s*([^%s]+%s+[^%s]+)")
        if first_words then
            s_start = full_text:find(first_words, search_offset, true)
            if s_start then
                s_end = s_start + #raw_sentence - 1
            end
        end
    end

    if not s_start then
        return {}, search_offset
    end

    local matched_bboxes = {}
    for _, wb in ipairs(word_boxes) do
        if wb.char_start and wb.char_end then
            if wb.char_start >= s_start and wb.char_end <= s_end then
                table.insert(matched_bboxes, {
                    x = wb.x, y = wb.y, w = wb.w, h = wb.h
                })
            end
        elseif wb.x and wb.y and wb.w and wb.h then
            table.insert(matched_bboxes, {
                x = wb.x, y = wb.y, w = wb.w, h = wb.h
            })
        end
    end

    return matched_bboxes, (s_end or search_offset)
end

--- Extract and chunk full page content from document engine
-- Returns array of Chunk tables with Bounding Boxes
-- @param document KOReader self.ui.document
-- @param page_num Current page number
-- @return table Array of Chunk objects
function TextChunker:extractPageChunks(document, page_num)
    local raw_page_text, word_boxes = self:extractRawPageText(document, page_num)
    if not raw_page_text or raw_page_text == "" then
        return {}
    end

    -- 1. Sanitize text
    local cleaned_text = self:sanitize(raw_page_text)
    if cleaned_text == "" then
        return {}
    end

    -- 2. 3-tier sentence chunking
    local sentences = self:splitSentences(cleaned_text)
    local chunks = {}
    local offset = 1

    for idx, sentence in ipairs(sentences) do
        -- 3. Pronunciation dictionary normalization for TTS
        local tts_text = self:normalizePronunciation(sentence)

        -- 4. Bounding box mapping
        local bboxes, new_offset = mapSentenceToBBoxes(sentence, raw_page_text, word_boxes, offset)
        offset = new_offset

        table.insert(chunks, {
            index       = idx,
            page        = page_num,
            text        = tts_text,       -- Text sent to TTS server (normalized)
            raw_text    = sentence,       -- Original page text
            start_pos   = offset,
            end_pos     = offset + #sentence,
            char_count  = #tts_text,
            bboxes      = bboxes or {},   -- Highlighting bounding boxes
        })
    end

    return chunks
end

-- Export module and constants
TextChunker.DEFAULT_MIN_CHARS = DEFAULT_MIN_CHARS
TextChunker.DEFAULT_MAX_CHARS = DEFAULT_MAX_CHARS

return TextChunker
