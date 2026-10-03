--[[
    tests/test_phase2_chunker.lua - Standalone unit test suite for Phase 2
    Validates text extraction, sanitization, Vietnamese pronunciation dictionary,
    3-tier sentence chunking algorithm, and Bounding Box mapping.
    Run via: luajit tests/test_phase2_chunker.lua
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local Settings = require("settings")
local TextChunker = require("text_chunker")
local KoreaderTTS = require("main")

local function run_test(name, func)
    io.write(string.format("[TEST] %-52s ... ", name))
    local ok, err = pcall(func)
    if ok then
        print("PASS")
    else
        print("FAIL")
        error(string.format("Test '%s' failed: %s", name, tostring(err)))
    end
end

print("==========================================================")
print("  STANDALONE TEST SUITE - PHASE 2 (TEXT CHUNKING)")
print("==========================================================")

-- Test 1: Sanitization - Filter page numbers, footnotes, soft-hyphens
run_test("Sanitize: Filter [1], *, soft-hyphen, page numbers", function()
    local chunker = TextChunker:new()
    local raw = " 42 \nMột đoạn văn bản chứa chú thích[1] và dấu sao* cùng từ ngắt\194\173dòng mềm.\n 42 "
    local cleaned = chunker:sanitize(raw)

    assert(not cleaned:find("%[1%]"), "Must not contain footnote [1]")
    assert(not cleaned:find("%*"), "Must not contain asterisk")
    assert(not cleaned:find("\194\173"), "Must not contain soft hyphen")
    assert(not cleaned:find("^42"), "Must not contain header page number")
    assert(not cleaned:find("42$"), "Must not contain footer page number")
    assert(cleaned:find("Một đoạn văn bản chứa chú thích và dấu sao cùng từ ngắtdòng mềm"), "Text content must remain intact")
end)

-- Test 2: Default Pronunciation Dictionary
run_test("Pronunciation: Expand standard Vietnamese abbreviations", function()
    local chunker = TextChunker:new()
    local text = "Hôm nay tôi đến TP. Hồ Chí Minh gặp GS. Nguyễn Văn Nam và ThS. Lê Thị Mai, v.v."
    local normalized = chunker:normalizePronunciation(text)

    assert(normalized:find("Thành phố"), "TP. must expand to Thành phố")
    assert(normalized:find("Giáo sư"), "GS. must expand to Giáo sư")
    assert(normalized:find("Thạc sĩ"), "ThS. must expand to Thạc sĩ")
    assert(normalized:find("vân vân"), "v.v. must expand to vân vân")
end)

-- Test 3: Custom Dictionary CRUD
run_test("Pronunciation: Custom dictionary CRUD via Settings", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    -- 1. Add mapping
    local ok = s:setWordMapping("AI", "Trí tuệ nhân tạo")
    assert(ok == true, "setWordMapping must succeed")
    assert(s:getCustomMappings()["AI"] == "Trí tuệ nhân tạo")

    -- 2. Verify applied in chunker
    local chunker = TextChunker:new{ custom_mappings = s:getCustomMappings() }
    local res = chunker:normalizePronunciation("Công nghệ AI đang phát triển mạnh.")
    assert(res:find("Trí tuệ nhân tạo"), "AI must be replaced with Trí tuệ nhân tạo")

    -- 3. Update mapping
    s:setWordMapping("AI", "Trí thông minh nhân tạo")
    chunker = TextChunker:new{ custom_mappings = s:getCustomMappings() }
    res = chunker:normalizePronunciation("Công nghệ AI.")
    assert(res:find("Trí thông minh nhân tạo"), "Updated term must take effect")

    -- 4. Delete mapping
    s:removeWordMapping("AI")
    assert(s:getCustomMappings()["AI"] == nil, "AI must be removed from custom mappings")

    -- 5. Reset to defaults
    s:setWordMapping("CustomTerm", "Replacement")
    s:resetWordMappings()
    assert(next(s:getCustomMappings()) == nil, "resetWordMappings must clear custom dict")
end)

-- Test 4: Prevent false sentence splits on abbreviations with periods
run_test("Chunker: No false split on abbreviations with period", function()
    local chunker = TextChunker:new{ min_chars = 20 }
    local text = "Đoàn đại biểu đã đến TP. Hồ Chí Minh để tham dự hội thảo khoa học quốc tế."
    local cleaned = chunker:sanitize(text)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences == 1, string.format("Must remain 1 complete sentence, got %d", #sentences))
    assert(sentences[1]:find("TP%. Hồ Chí Minh"), "Context must remain unbroken")
end)

-- Test 5: Proper splitting of sentence delimiters and dialogue quotes
run_test("Chunker (Tier 1): Delimiters ! ? … and dialogue quotes", function()
    local chunker = TextChunker:new{ min_chars = 15 }
    local raw = '"Bạn có đi không?" anh ấy hỏi dồn dập. Tôi ngập ngừng trả lời: "Chắc là có!" và mỉm cười…'
    local cleaned = chunker:sanitize(raw)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences >= 2, "Must split into at least 2 sentences")
    assert(sentences[1]:find("Bạn có đi không"), "Sentence 1 must contain dialogue question")
end)

-- Test 6: Preserve decimal numbers (3.14, 10.5)
run_test("Chunker (Tier 1): Preserve decimal numbers with periods", function()
    local chunker = TextChunker:new{ min_chars = 10 }
    local raw = "Hằng số Pi xấp xỉ 3.14159 trong hình học phẳng. Tốc độ tăng trưởng đạt 8.5% năm qua."
    local cleaned = chunker:sanitize(raw)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences == 2, string.format("Must be exactly 2 sentences, got %d", #sentences))
    assert(sentences[1]:find("3.14159"), "Sentence 1 must preserve 3.14159")
    assert(sentences[2]:find("8.5%%"), "Sentence 2 must preserve 8.5%")
end)

-- Test 7: Tier 2 algorithm - Merge short chunks (< 30 chars) into next chunk
run_test("Chunker (Tier 2): Merge short chunks under 30 chars", function()
    local chunker = TextChunker:new{ min_chars = 30 }
    local raw = "Trời mưa. Gió thổi mạnh từng cơn trên những tán cây ven đường làng quê yên bình."
    local cleaned = chunker:sanitize(raw)
    local sentences = chunker:splitSentences(cleaned)

    -- 'Trời mưa.' is only 9 chars, must be merged into following chunk
    assert(#sentences == 1, string.format("Short sentence must be merged into 1 chunk, got %d", #sentences))
    assert(sentences[1]:find("^Trời mưa%. Gió thổi mạnh"), "Merged chunk must start with 'Trời mưa.'")
    assert(#sentences[1] >= 30, "Merged chunk must meet minimum length")
end)

-- Test 8: Tier 3 algorithm - Split oversized sentences (> 300 chars) at punctuation
run_test("Chunker (Tier 3): Safety split long chunks > 300 chars", function()
    local chunker = TextChunker:new{ max_chars = 100 } -- Threshold set to 100 for testing
    local long_s = "Trong một buổi chiều thu êm ả, ánh nắng vàng nhạt trải dài trên con đường làng quanh co, những đứa trẻ cùng nhau thả diều trên triền đê xanh ngát gió mát rượi, tạo nên một khung cảnh thanh bình đến lạ kỳ."
    local cleaned = chunker:sanitize(long_s)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences >= 2, "Long chunk must be split into 2 or more sub-chunks")
    for idx, s in ipairs(sentences) do
        assert(#s <= 150, string.format("Sub-chunk %d exceeds safe limit: %d chars", idx, #s))
    end
end)

-- Test 9: Extract & map Bounding Boxes from Crengine mock (EPUB/MOBI)
run_test("Hybrid Engine: Extract from Crengine with Bounding Box", function()
    local sample_text = "Hôm nay là một ngày đẹp trời tại thủ đô Hà Nội. Mặt trời mọc sáng rực rỡ khắp muôn nơi."
    local mock_boxes = {
        { x = 10, y = 20, w = 200, h = 20, char_start = 1, char_end = 45 },
        { x = 10, y = 45, w = 220, h = 20, char_start = 46, char_end = 90 },
    }
    local doc = MockKOReader.createMockCrengineDocument(sample_text, mock_boxes)

    local chunker = TextChunker:new{ min_chars = 25 }
    local chunks = chunker:extractPageChunks(doc, 1)

    assert(#chunks >= 1, "Must extract chunks from Crengine")
    assert(chunks[1].index == 1)
    assert(chunks[1].page == 1)
    assert(type(chunks[1].text) == "string" and #chunks[1].text > 0)
    assert(type(chunks[1].bboxes) == "table", "bboxes must be a table")
end)

-- Test 10: Extract & map Bounding Boxes from MuPDF mock (PDF)
run_test("Hybrid Engine: Extract from MuPDF with Bounding Box", function()
    local sample_text = "Tài liệu kỹ thuật lập trình hệ thống phân tán. Nghiên cứu kiến trúc vi dịch vụ và xử lý dữ liệu lớn."
    local mock_boxes = {
        { x = 50, y = 100, w = 300, h = 25 },
        { x = 50, y = 130, w = 350, h = 25 },
    }
    local doc = MockKOReader.createMockMuPDFDocument(sample_text, mock_boxes)

    local chunker = TextChunker:new{ min_chars = 20 }
    local chunks = chunker:extractPageChunks(doc, 1)

    assert(#chunks >= 1, "Must extract chunks from MuPDF")
    assert(chunks[1].page == 1)
    assert(type(chunks[1].bboxes) == "table")
end)

-- Test 11: Crash-proof defensive test - nil or faulty document
run_test("Crash-proof: Empty or faulty doc returns safe {}", function()
    local chunker = TextChunker:new()

    -- 1. Document nil
    local chunks = chunker:extractPageChunks(nil, 1)
    assert(type(chunks) == "table" and #chunks == 0, "Nil doc must return empty table")

    -- 2. Document throws exception
    local faulty_doc = {
        getPageText = function() error("MuPDF out of memory error!") end
    }
    chunks = chunker:extractPageChunks(faulty_doc, 1)
    assert(type(chunks) == "table" and #chunks == 0, "Faulty doc must be caught safely via pcall")
end)

-- Test 12: main.lua onStartTTS integration
run_test("main.lua integration: onStartTTS calls chunker & logs", function()
    MockKOReader.UIManager:reset()
    local sample_text = "Khoa học công nghệ đang thay đổi thế giới từng ngày. Chúng ta cần chủ động học hỏi những điều mới mẻ."
    local mock_doc = MockKOReader.createMockCrengineDocument(sample_text)

    local plugin = KoreaderTTS:new{
        ui = {
            document = mock_doc,
            menu = { registerToMainMenu = function() end },
        },
        view = {
            state = { page = 5 }
        }
    }
    plugin.settings = Settings:new(MockKOReader.createMockSettings())

    local chunks = plugin:onStartTTS()
    assert(type(chunks) == "table", "onStartTTS must return chunks table")
    assert(#chunks >= 1, "Must have at least 1 chunk")
    assert(#MockKOReader.UIManager._shown_widgets >= 1, "Must show InfoMessage notice")

    local info = MockKOReader.UIManager._shown_widgets[1]
    assert(info.text:find("Trang: 5"), "Notice must display correct page number 5")
    assert(info.text:find("Tổng số câu:"), "Notice must display total chunks count")
end)

print("==========================================================")
print("  ALL 12 TESTS PASSED SUCCESSFULLY!                      ")
print("==========================================================")
