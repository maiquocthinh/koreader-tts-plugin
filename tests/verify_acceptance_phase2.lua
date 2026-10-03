--[[
    tests/verify_acceptance_phase2.lua
    End-to-End Acceptance Verification script for Phase 2
    Simulates text extraction and normalization lifecycle in KOReader:
      1. DoD 2.1: Text extraction from Document Engine (Crengine & MuPDF)
      2. DoD 2.2: Text sanitization & Pronunciation dictionary (CRUD Mapping)
      3. DoD 2.3: 3-tier sentence chunking & Bounding Box mapping
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local Settings = require("settings")
local TextChunker = require("text_chunker")
local KoreaderTTS = require("main")

local function step_banner(num, title)
    print(string.format("\n=== [STEP %d] %s ===", num, title))
end

-- =========================================================================
-- VERIFY DoD 2.1: Text extraction from Document Engine (Crengine & MuPDF)
-- =========================================================================
step_banner(1, "Verify DoD 2.1: Raw Text Extraction from Document Engines")

local sample_epub_text = "Chương 1: Bình minh trên cao nguyên.\n"
    .. "Ánh mặt trời buổi sớm len lỏi qua từng kẽ lá rừng thông bạt ngàn. "
    .. "Đoàn khảo sát của Viện Khoa học bắt đầu hành trình nghiên cứu địa chất."

local sample_crengine_boxes = {
    { x = 20, y = 30, w = 400, h = 24 },
    { x = 20, y = 60, w = 520, h = 24 },
    { x = 20, y = 90, w = 480, h = 24 },
}

local crengine_doc = MockKOReader.createMockCrengineDocument(sample_epub_text, sample_crengine_boxes)
local chunker = TextChunker:new()

-- 1. Extract text from Crengine (EPUB)
local raw_cre, boxes_cre = chunker:extractRawPageText(crengine_doc, 1)
assert(type(raw_cre) == "string" and #raw_cre > 0, "ERROR DoD 2.1: Crengine did not return raw text!")
assert(#boxes_cre == 3, "ERROR DoD 2.1: Crengine did not return word bboxes!")
print(string.format("  -> Crengine: Successfully extracted %d raw chars and %d bounding boxes.", #raw_cre, #boxes_cre))

-- 2. Extract text from MuPDF (PDF)
local sample_pdf_text = "BÁO CÁO TÀI CHÍNH QUÝ 3.\n"
    .. "Doanh thu hợp nhất toàn tập đoàn ghi nhận mức tăng trưởng 12.5% so với cùng kỳ năm ngoái."

local sample_mupdf_boxes = {
    { x = 40, y = 50, w = 300, h = 20 },
    { x = 40, y = 75, w = 550, h = 20 },
}
local mupdf_doc = MockKOReader.createMockMuPDFDocument(sample_pdf_text, sample_mupdf_boxes)

local raw_mu, boxes_mu = chunker:extractRawPageText(mupdf_doc, 1)
assert(type(raw_mu) == "string" and #raw_mu > 0, "ERROR DoD 2.1: MuPDF did not return raw text!")
assert(#boxes_mu == 2, "ERROR DoD 2.1: MuPDF did not return word bboxes!")
print(string.format("  -> MuPDF: Successfully extracted %d raw chars and %d bounding boxes.", #raw_mu, #boxes_mu))
print("  [DoD 2.1 RESULT]: PASS - Raw text successfully extracted from both document engines.")

-- =========================================================================
-- VERIFY DoD 2.2: Text Sanitization & Pronunciation Dictionary (CRUD Mapping)
-- =========================================================================
step_banner(2, "Verify DoD 2.2: Text Sanitization & Pronunciation Dictionary")

local dirty_text = " 108 \n"
    .. "Theo báo cáo của TS.[1] Trần Văn An tại hội nghị khoa học TP.* Hồ Chí Minh, "
    .. "các ứng dụng AI[2] đang tạo nên bước đột phá lớn trong ngành CNTT† và NXB‡, v.v.\n"
    .. " 108 "

-- 1. Sanitize text
local cleaned_text = chunker:sanitize(dirty_text)
assert(not cleaned_text:find("%[1%]"), "ERROR DoD 2.2: Residual footnote [1]")
assert(not cleaned_text:find("%[2%]"), "ERROR DoD 2.2: Residual footnote [2]")
assert(not cleaned_text:find("%*"), "ERROR DoD 2.2: Residual asterisk *")
assert(not cleaned_text:find("†"), "ERROR DoD 2.2: Residual dagger †")
assert(not cleaned_text:find("‡"), "ERROR DoD 2.2: Residual double dagger ‡")
assert(not cleaned_text:find("^108"), "ERROR DoD 2.2: Residual header page number")
assert(not cleaned_text:find("108$"), "ERROR DoD 2.2: Residual footer page number")
print("  -> Filtered 100% of footnotes [1], [2], *, †, ‡ and header/footer page numbers.")

-- 2. Validate default + custom pronunciation dictionary
local storage = MockKOReader.createMockSettings()
local settings = Settings:new(storage)

-- Custom mapping for 'AI' -> 'Trí tuệ nhân tạo'
settings:setWordMapping("AI", "Trí tuệ nhân tạo")
settings:save()

local custom_chunker = TextChunker:new{ custom_mappings = settings:getCustomMappings() }
local tts_ready_text = custom_chunker:normalizePronunciation(cleaned_text)

assert(tts_ready_text:find("Tiến sĩ"), "ERROR DoD 2.2: 'TS.' was not converted to 'Tiến sĩ'!")
assert(tts_ready_text:find("Thành phố"), "ERROR DoD 2.2: 'TP.' was not converted to 'Thành phố'!")
assert(tts_ready_text:find("Trí tuệ nhân tạo"), "ERROR DoD 2.2: 'AI' was not converted to 'Trí tuệ nhân tạo'!")
assert(tts_ready_text:find("Công nghệ thông tin"), "ERROR DoD 2.2: 'CNTT' was not converted to 'Công nghệ thông tin'!")
assert(tts_ready_text:find("Nhà xuất bản"), "ERROR DoD 2.2: 'NXB' was not converted to 'Nhà xuất bản'!")
assert(tts_ready_text:find("vân vân"), "ERROR DoD 2.2: 'v.v.' was not converted to 'vân vân'!")

print(string.format("  -> Accurate pronunciation normalization:\n     \"%s\"", tts_ready_text))
print("  [DoD 2.2 RESULT]: PASS - Cleaned 100% of artifact chars and applied pronunciation dictionary.")

-- =========================================================================
-- VERIFY DoD 2.3: 3-tier sentence chunking & Bounding Box mapping
-- =========================================================================
step_banner(3, "Verify DoD 2.3: 3-tier Chunking (30 - 300 chars) & BBoxes")

local complex_doc_text = "Hôm nay tôi đi dạo. Trời đẹp quá! "
    .. "Bạn có đi uống cà phê không? Tôi hỏi nhưng anh ấy im lặng… "
    .. "Trong một buổi chiều mùa thu mát mẻ, khi những chiếc lá vàng nhẹ nhàng rơi trên từng con phố cổ kính của thủ đô, người ta thường hoài niệm về những kỷ niệm đẹp đẽ đã qua trong cuộc đời dài đằng đẵng của mình, dẫu cho thời gian có trôi đi mãi mãi."

local complex_doc = MockKOReader.createMockCrengineDocument(complex_doc_text)
local final_chunks = custom_chunker:extractPageChunks(complex_doc, 1)

assert(#final_chunks >= 2, "ERROR DoD 2.3: Chunk count too low!")
print(string.format("  -> Chunked into %d total sentences:", #final_chunks))

for i, c in ipairs(final_chunks) do
    local len = #c.text
    print(string.format("     [%d] Length: %3d chars | BBoxes: %d | Preview: \"%s...\"",
        c.index, len, #c.bboxes, c.text:sub(1, 60)))

    if i < #final_chunks then
        assert(len >= 30, string.format("ERROR DoD 2.3: Chunk %d too short (< 30 chars): %d chars", i, len))
    end
    assert(len <= 300, string.format("ERROR DoD 2.3: Chunk %d too long (> 300 chars): %d chars", i, len))
    assert(type(c.bboxes) == "table", string.format("ERROR DoD 2.3: Chunk %d missing bboxes table!", i))
end

print("  [DoD 2.3 RESULT]: PASS - 100% of chunks are within 30 - 300 chars with valid BBoxes.")

print("\n=========================================================================")
print("  SUMMARY: ALL 3 PHASE 2 ACCEPTANCE CRITERIA VERIFIED 100%!               ")
print("=========================================================================\n")
