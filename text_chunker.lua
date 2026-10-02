--[[
    text_chunker.lua - Module bóc tách, làm sạch và phân đoạn văn bản cho KOReader TTS
    Tương thích cả Crengine (EPUB/MOBI) và MuPDF (PDF).
    Triển khai thuật toán cắt câu 3 tầng & Từ điển phát âm tiếng Việt.
--]]

local Settings = require("settings")

local TextChunker = {}
TextChunker.__index = TextChunker

local DEFAULT_MIN_CHARS = 30
local DEFAULT_MAX_CHARS = 300

--- Khởi tạo instance TextChunker
-- @param options Bảng cấu hình tùy chọn: min_chars, max_chars, filter_footnotes, custom_mappings
function TextChunker:new(options)
    local opts = options or {}
    local instance = setmetatable({}, self)
    instance.min_chars = opts.min_chars or DEFAULT_MIN_CHARS
    instance.max_chars = opts.max_chars or DEFAULT_MAX_CHARS
    instance.filter_footnotes = (opts.filter_footnotes ~= false)
    instance.custom_mappings = opts.custom_mappings or {}
    return instance
end

--- Làm sạch văn bản thô: lọc bỏ chú thích chân trang, số trang, ngắt dòng mềm
-- @param raw_text Chuỗi văn bản thô từ tài liệu
-- @return string Chuỗi văn bản đã được làm sạch
function TextChunker:sanitize(raw_text)
    if not raw_text or type(raw_text) ~= "string" or raw_text == "" then
        return ""
    end

    local text = raw_text

    -- 1. Loại bỏ dấu ngắt dòng mềm (soft hyphens: UTF-8 0xC2 0xAD)
    text = text:gsub("\194\173", "")

    -- 2. Chuẩn hóa khoảng trắng không ngắt dòng (non-breaking spaces: UTF-8 0xC2 0xA0)
    text = text:gsub("\194\160", " ")

    -- 3. Lọc số trang đứng đơn độc ở đầu trang hoặc chân trang (header/footer)
    text = text:gsub("^%s*%d+%s*[\r\n]+", "")
    text = text:gsub("[\r\n]+%s*%d+%s*$", "")
    text = text:gsub("[\r\n]+%s*%d+%s*/%s*%d+%s*[\r\n]+", " ")

    -- 4. Lọc ký hiệu chú thích chân trang: [1], [12], (1), *, †, ‡ (thay bằng khoảng trắng để tránh dính từ)
    if self.filter_footnotes then
        text = text:gsub("%[%d+%]", " ")
        text = text:gsub("%(%d+%)", " ")
        text = text:gsub("%*+", " ")
        text = text:gsub("†", " ")
        text = text:gsub("‡", " ")
    end

    -- 5. Chuẩn hóa ba chấm: '...' thành '…'
    text = text:gsub("%.%.%.+", "…")

    -- 6. Gộp các khoảng trắng liên tiếp và ngắt dòng thành một khoảng trắng duy nhất
    text = text:gsub("[\r\n]+", " ")
    text = text:gsub("%s+", " ")

    -- 7. Loại bỏ khoảng trắng ở đầu và cuối chuỗi
    text = text:gsub("^%s+", ""):gsub("%s+$", "")

    return text
end

--- Chuẩn hóa từ viết tắt / từ khó theo Từ điển phát âm TTS (Pronunciation Dictionary)
-- @param text Chuỗi văn bản cần chuẩn hóa
-- @param custom_dict Bảng mapping tùy biến bổ sung (nếu có)
-- @return string Chuỗi văn bản đã được chuyển đổi từ ngữ dễ đọc
function TextChunker:normalizePronunciation(text, custom_dict)
    if not text or type(text) ~= "string" or text == "" then
        return ""
    end

    -- Hợp nhất từ điển mặc định từ Settings và custom_dict
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

    -- Duyệt qua từng từ khóa trong từ điển
    for orig, replacement in pairs(mappings) do
        if orig and orig ~= "" and replacement then
            -- Escape ký tự đặc biệt của Lua pattern trong từ gốc
            local escaped_orig = orig:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")

            -- Nếu từ gốc kết thúc bằng dấu chấm (ví dụ: TP., TS., v.v.)
            if orig:sub(-1) == "." then
                -- Thay thế ở đầu câu: ^TP. -> Thành phố
                result = result:gsub("^" .. escaped_orig .. "(%s+)", replacement .. "%1")
                result = result:gsub("^" .. escaped_orig .. "$", replacement)
                -- Thay thế sau khoảng trắng hoặc mở ngoặc: %sTP. -> %sThành phố
                result = result:gsub("([%s%(\"“])" .. escaped_orig .. "(%s+)", "%1" .. replacement .. "%2")
                result = result:gsub("([%s%(\"“])" .. escaped_orig .. "$", "%1" .. replacement)
                result = result:gsub("([%s%(\"“])" .. escaped_orig .. "([%,%;%:…])", "%1" .. replacement .. "%2")
            else
                -- Từ viết tắt thông thường không có chấm: ĐH, CNTT, AI, NXB...
                -- Khớp với ranh giới từ (không nằm giữa một từ khác)
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

--- Tách một câu quá dài (> max_chars) tại dấu ngắt tự nhiên gần giữa câu (Tầng 3)
-- @param sentence Chuỗi câu dài
-- @param max_limit Độ dài tối đa
-- @return table Mảng gồm 2 hoặc nhiều đoạn ngắn hơn
local function splitLongSentence(sentence, max_limit)
    if #sentence <= max_limit then
        return { sentence }
    end

    local chunks = {}
    local remaining = sentence

    while #remaining > max_limit do
        local mid = math.floor(max_limit * 0.75)
        local search_sub = remaining:sub(1, max_limit)

        -- Tìm vị trí dấu ngắt tự nhiên gần nhất trước max_limit: dấu phẩy, chấm phẩy, hai chấm, gạch ngang
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

        -- Nếu không có dấu câu phù hợp, ngắt tại khoảng trắng gần mid
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

        -- Nếu vẫn không tìm được điểm ngắt, bắt buộc cắt tại max_limit
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

--- Phân tách văn bản đã làm sạch thành danh sách các câu theo thuật toán 3 tầng
-- @param text Chuỗi văn bản đã qua sanitize
-- @return table Mảng danh sách các câu
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

        -- Theo dõi trạng thái đóng/mở ngoặc kép hội thoại
        if c == '"' or c == '“' or c == '”' then
            if not in_quotes then
                in_quotes = true
                quote_char = c
            else
                in_quotes = false
                quote_char = nil
            end
        end

        -- Kiểm tra ký tự ngắt câu: . ? ! …
        local is_delimiter = false
        if (c == "." or c == "?" or c == "!" or c == "…") then
            -- Bỏ qua dấu chấm trong số thập phân: ví dụ 3.14 hoặc 10.5
            local prev_c = (i > 1) and text:sub(i - 1, i - 1) or ""
            local is_decimal = (c == "." and prev_c:match("%d") and next_c:match("%d"))

            -- Bỏ qua dấu chấm trong các từ viết tắt tiếng Việt / quốc tế phổ biến (TP., TS., ThS., GS., v.v.)
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
                -- Nếu dấu kết thúc câu nằm ngoài dấu ngoặc kép hoặc ngay sau khi ngoặc kép đóng
                if not in_quotes or next_c == '"' or next_c == '”' or next_c == ' ' or next_c == "" then
                    is_delimiter = true
                end
            end
        end

        if is_delimiter then
            -- Thu thập toàn bộ dấu câu đi liền nhau (ví dụ: !?, ..., !!!)
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

    -- Thêm phần còn lại nếu chưa kết thúc bằng dấu chấm
    if start_idx <= len then
        local tail = text:sub(start_idx, len):gsub("^%s+", ""):gsub("%s+$", "")
        if #tail > 0 then
            table.insert(raw_sentences, tail)
        end
    end

    if #raw_sentences == 0 then
        return {}
    end

    -- TẦNG 2: Gộp câu ngắn (< min_chars) vào câu kế tiếp (Anti-fragmentation)
    local merged_sentences = {}
    local buffer = ""

    for idx, s in ipairs(raw_sentences) do
        if #buffer > 0 then
            buffer = buffer .. " " .. s
        else
            buffer = s
        end

        -- Nếu độ dài buffer đã đạt tối thiểu min_chars hoặc đây là câu cuối cùng của trang
        if #buffer >= self.min_chars or idx == #raw_sentences then
            table.insert(merged_sentences, buffer)
            buffer = ""
        end
    end

    if #buffer > 0 then
        -- Trường hợp đặc biệt còn buffer dư ở cuối
        if #merged_sentences > 0 then
            merged_sentences[#merged_sentences] = merged_sentences[#merged_sentences] .. " " .. buffer
        else
            table.insert(merged_sentences, buffer)
        end
    end

    -- TẦNG 3: Bẻ các câu siêu dài (> max_chars) tại dấu phẩy/chấm phẩy (Safety Split)
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

--- Trích xuất văn bản thô của một trang từ Document Engine (Hybrid Strategy)
-- Tương thích cả Crengine (EPUB/MOBI) và MuPDF (PDF)
-- @param document Đối tượng self.ui.document của KOReader (hoặc mock)
-- @param page_num Số trang cần trích xuất (1-based)
-- @return string Chuỗi văn bản thô, table Danh sách word bounding boxes nếu có
function TextChunker:extractRawPageText(document, page_num)
    if not document then
        return "", {}
    end

    local text = ""
    local word_boxes = {}

    -- 1. Thử gọi API MuPDF: getPageText & getTextWordBoxes
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

    -- 2. Thử gọi API Crengine: getTextFromPositions & getWordBBoxes
    local ok_cre, res_cre = pcall(function()
        if type(document.getTextFromPositions) == "function" then
            -- Crengine trích xuất qua bookmark/positions hoặc getPageText
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

    -- 3. Fallback phương thức chung nếu có
    if type(document.getText) == "function" then
        pcall(function()
            text = document:getText(page_num) or ""
        end)
    end

    return text or "", word_boxes or {}
end

--- Ánh xạ vị trí câu vào các bounding boxes của từ trên trang
-- @param raw_sentence Câu thô trên trang sách
-- @param full_text Toàn bộ văn bản của trang
-- @param word_boxes Danh sách bounding boxes của các từ trên trang
-- @param search_offset Vị trí bắt đầu tìm kiếm trong full_text
-- @return table Danh sách bboxes bao quanh câu, number Vị trí kết thúc trong full_text
local function mapSentenceToBBoxes(raw_sentence, full_text, word_boxes, search_offset)
    if not word_boxes or #word_boxes == 0 or not full_text or #full_text == 0 then
        return {}, search_offset
    end

    -- Tìm vị trí của raw_sentence trong full_text
    local s_start, s_end = full_text:find(raw_sentence, search_offset, true)
    if not s_start then
        -- Tìm kiếm không phân biệt khoảng trắng nếu bị lệch
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
        -- Nếu word box có thông tin vị trí ký tự char_offset
        if wb.char_start and wb.char_end then
            if wb.char_start >= s_start and wb.char_end <= s_end then
                table.insert(matched_bboxes, {
                    x = wb.x, y = wb.y, w = wb.w, h = wb.h
                })
            end
        elseif wb.x and wb.y and wb.w and wb.h then
            -- Fallback: nếu word box có bbox hình học tiêu chuẩn
            table.insert(matched_bboxes, {
                x = wb.x, y = wb.y, w = wb.w, h = wb.h
            })
        end
    end

    return matched_bboxes, (s_end or search_offset)
end

--- Trích xuất và phân đoạn toàn bộ nội dung của trang hiện tại từ Document Engine
-- Trả về danh sách các đối tượng Chunk hoàn chỉnh kèm Bounding Boxes
-- @param document Đối tượng self.ui.document của KOReader
-- @param page_num Số trang hiện tại
-- @return table Mảng các bảng Chunk
function TextChunker:extractPageChunks(document, page_num)
    local raw_page_text, word_boxes = self:extractRawPageText(document, page_num)
    if not raw_page_text or raw_page_text == "" then
        return {}
    end

    -- 1. Làm sạch văn bản
    local cleaned_text = self:sanitize(raw_page_text)
    if cleaned_text == "" then
        return {}
    end

    -- 2. Phân đoạn câu 3 tầng
    local sentences = self:splitSentences(cleaned_text)
    local chunks = {}
    local offset = 1

    for idx, sentence in ipairs(sentences) do
        -- 3. Chuẩn hóa phát âm cho TTS
        local tts_text = self:normalizePronunciation(sentence)

        -- 4. Ánh xạ Bounding Box
        local bboxes, new_offset = mapSentenceToBBoxes(sentence, raw_page_text, word_boxes, offset)
        offset = new_offset

        table.insert(chunks, {
            index       = idx,
            page        = page_num,
            text        = tts_text,       -- Văn bản gửi đến máy chủ TTS (đã chuyển từ viết tắt)
            raw_text    = sentence,       -- Văn bản gốc trên trang sách
            start_pos   = offset,
            end_pos     = offset + #sentence,
            char_count  = #tts_text,
            bboxes      = bboxes or {},   -- Tọa độ bôi sáng an toàn (luôn là table)
        })
    end

    return chunks
end

-- Export module và constants
TextChunker.DEFAULT_MIN_CHARS = DEFAULT_MIN_CHARS
TextChunker.DEFAULT_MAX_CHARS = DEFAULT_MAX_CHARS

return TextChunker
