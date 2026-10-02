--[[
    tests/verify_acceptance_phase2.lua
    Kịch bản kiểm chứng nghiệm thu đầu-cuối (E2E Acceptance Verification) cho Phase 2
    Mô phỏng chính xác chu kỳ hoạt động trích xuất và chuẩn hóa văn bản của KOReader:
      1. DoD 2.1: Trích xuất nội dung từ Document Engine (Crengine & MuPDF)
      2. DoD 2.2: Làm sạch văn bản (Sanitization) & Từ điển phát âm (CRUD Mapping)
      3. DoD 2.3: Thuật toán cắt câu 3 tầng & Ánh xạ Bounding Box
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local Settings = require("settings")
local TextChunker = require("text_chunker")
local KoreaderTTS = require("main")

local function step_banner(num, title)
    print(string.format("\n=== [BƯỚC %d] %s ===", num, title))
end

-- =========================================================================
-- KIỂM CHỨNG DoD 2.1: Trích xuất nội dung từ Document Engine (Crengine & MuPDF)
-- =========================================================================
step_banner(1, "Kiểm chứng DoD 2.1: Trích xuất nội dung thô từ Document Engine")

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

-- 1. Trích xuất văn bản từ Crengine (EPUB)
local raw_cre, boxes_cre = chunker:extractRawPageText(crengine_doc, 1)
assert(type(raw_cre) == "string" and #raw_cre > 0, "LỖI DoD 2.1: Crengine không trả về text thô!")
assert(#boxes_cre == 3, "LỖI DoD 2.1: Crengine không trả về word bboxes!")
print(string.format("  -> Crengine: Đã trích xuất thành công %d ký tự thô và %d bounding boxes.", #raw_cre, #boxes_cre))

-- 2. Trích xuất văn bản từ MuPDF (PDF)
local sample_pdf_text = "BÁO CÁO TÀI CHÍNH QUÝ 3.\n"
    .. "Doanh thu hợp nhất toàn tập đoàn ghi nhận mức tăng trưởng 12.5% so với cùng kỳ năm ngoái."

local sample_mupdf_boxes = {
    { x = 40, y = 50, w = 300, h = 20 },
    { x = 40, y = 75, w = 550, h = 20 },
}
local mupdf_doc = MockKOReader.createMockMuPDFDocument(sample_pdf_text, sample_mupdf_boxes)

local raw_mu, boxes_mu = chunker:extractRawPageText(mupdf_doc, 1)
assert(type(raw_mu) == "string" and #raw_mu > 0, "LỖI DoD 2.1: MuPDF không trả về text thô!")
assert(#boxes_mu == 2, "LỖI DoD 2.1: MuPDF không trả về word bboxes!")
print(string.format("  -> MuPDF: Đã trích xuất thành công %d ký tự thô và %d bounding boxes.", #raw_mu, #boxes_mu))
print("  [KẾT QUẢ DoD 2.1]: PASS - Đã trích xuất toàn bộ chuỗi text thô từ cả hai Document Engine.")

-- =========================================================================
-- KIỂM CHỨNG DoD 2.2: Làm sạch văn bản & Từ điển phát âm (CRUD Mapping)
-- =========================================================================
step_banner(2, "Kiểm chứng DoD 2.2: Làm sạch văn bản rác & Từ điển phát âm tùy biến")

local dirty_text = " 108 \n"
    .. "Theo báo cáo của TS.[1] Trần Văn An tại hội nghị khoa học TP.* Hồ Chí Minh, "
    .. "các ứng dụng AI[2] đang tạo nên bước đột phá lớn trong ngành CNTT† và NXB‡, v.v.\n"
    .. " 108 "

-- 1. Làm sạch ký tự rác
local cleaned_text = chunker:sanitize(dirty_text)
assert(not cleaned_text:find("%[1%]"), "LỖI DoD 2.2: Còn sót chú thích [1]")
assert(not cleaned_text:find("%[2%]"), "LỖI DoD 2.2: Còn sót chú thích [2]")
assert(not cleaned_text:find("%*"), "LỖI DoD 2.2: Còn sót dấu hoa thị *")
assert(not cleaned_text:find("†"), "LỖI DoD 2.2: Còn sót dấu †")
assert(not cleaned_text:find("‡"), "LỖI DoD 2.2: Còn sót dấu ‡")
assert(not cleaned_text:find("^108"), "LỖI DoD 2.2: Còn sót số trang đầu")
assert(not cleaned_text:find("108$"), "LỖI DoD 2.2: Còn sót số trang cuối")
print("  -> Lọc sạch 100% chú thích rác [1], [2], *, †, ‡ và số trang header/footer.")

-- 2. Kiểm chứng từ điển mặc định + CRUD tùy biến của người dùng
local storage = MockKOReader.createMockSettings()
local settings = Settings:new(storage)

-- Người dùng tùy biến thêm từ 'AI' thành 'Trí tuệ nhân tạo'
settings:setWordMapping("AI", "Trí tuệ nhân tạo")
settings:save()

local custom_chunker = TextChunker:new{ custom_mappings = settings:getCustomMappings() }
local tts_ready_text = custom_chunker:normalizePronunciation(cleaned_text)

assert(tts_ready_text:find("Tiến sĩ"), "LỖI DoD 2.2: 'TS.' chưa được chuyển thành 'Tiến sĩ'!")
assert(tts_ready_text:find("Thành phố"), "LỖI DoD 2.2: 'TP.' chưa được chuyển thành 'Thành phố'!")
assert(tts_ready_text:find("Trí tuệ nhân tạo"), "LỖI DoD 2.2: 'AI' tùy biến chưa được chuyển thành 'Trí tuệ nhân tạo'!")
assert(tts_ready_text:find("Công nghệ thông tin"), "LỖI DoD 2.2: 'CNTT' chưa được chuyển thành 'Công nghệ thông tin'!")
assert(tts_ready_text:find("Nhà xuất bản"), "LỖI DoD 2.2: 'NXB' chưa được chuyển thành 'Nhà xuất bản'!")
assert(tts_ready_text:find("vân vân"), "LỖI DoD 2.2: 'v.v.' chưa được chuyển thành 'vân vân'!")

print(string.format("  -> Chuẩn hóa phát âm chuẩn xác:\n     \"%s\"", tts_ready_text))
print("  [KẾT QUẢ DoD 2.2]: PASS - Làm sạch 100% ký tự rác và áp dụng từ điển phát âm hoàn hảo.")

-- =========================================================================
-- KIỂM CHỨNG DoD 2.3: Thuật toán cắt câu 3 tầng & Bounding Box
-- =========================================================================
step_banner(3, "Kiểm chứng DoD 2.3: Phân đoạn câu 3 tầng (30 - 300 chars) & BBoxes")

local complex_doc_text = "Hôm nay tôi đi dạo. Trời đẹp quá! "
    .. "Bạn có đi uống cà phê không? Tôi hỏi nhưng anh ấy im lặng… "
    .. "Trong một buổi chiều mùa thu mát mẻ, khi những chiếc lá vàng nhẹ nhàng rơi trên từng con phố cổ kính của thủ đô, người ta thường hoài niệm về những kỷ niệm đẹp đẽ đã qua trong cuộc đời dài đằng đẵng của mình, dẫu cho thời gian có trôi đi mãi mãi."

local complex_doc = MockKOReader.createMockCrengineDocument(complex_doc_text)
local final_chunks = custom_chunker:extractPageChunks(complex_doc, 1)

assert(#final_chunks >= 2, "LỖI DoD 2.3: Số lượng câu phân tách quá ít!")
print(string.format("  -> Phân tách được tổng cộng %d câu:", #final_chunks))

for i, c in ipairs(final_chunks) do
    local len = #c.text
    print(string.format("     [%d] Độ dài: %3d ký tự | BBoxes: %d | Nội dung: \"%s...\"",
        c.index, len, #c.bboxes, c.text:sub(1, 60)))

    -- Kiểm tra điều kiện DoD 2.3:
    -- Mọi câu (trừ câu cuối có thể ngắn hơn) phải có độ dài từ 30 đến 300 ký tự
    if i < #final_chunks then
        assert(len >= 30, string.format("LỖI DoD 2.3: Câu %d quá ngắn (< 30 ký tự): %d ký tự", i, len))
    end
    assert(len <= 300, string.format("LỖI DoD 2.3: Câu %d quá dài (> 300 ký tự): %d ký tự", i, len))
    assert(type(c.bboxes) == "table", string.format("LỖI DoD 2.3: Câu %d không có mảng bboxes!", i))
end

print("  [KẾT QUẢ DoD 2.3]: PASS - 100% câu phân đoạn nằm trong khoảng 30 - 300 ký tự và có BBoxes.")

print("\n=========================================================================")
print("  TỔNG KẾT: TẤT CẢ 3 TIÊU CHÍ GIAI ĐOẠN 2 ĐÃ ĐƯỢC NGHIỆM THU 100%!     ")
print("=========================================================================\n")
