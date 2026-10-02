--[[
    tests/test_phase2_chunker.lua - Bộ kiểm thử độc lập cho Giai đoạn 2 (Phase 2)
    Kiểm tra bóc tách văn bản, làm sạch ký tự rác, từ điển phát âm tiếng Việt,
    thuật toán ngắt câu 3 tầng và ánh xạ Bounding Box.
    Chạy trực tiếp qua: luajit tests/test_phase2_chunker.lua
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
print("  CHẠY BỘ KIỂM THỬ ĐỘC LẬP - GIAI ĐOẠN 2 (PHASE 2)")
print("==========================================================")

-- Test 1: Làm sạch văn bản (Sanitization) - Lọc số trang, chú thích rác, soft-hyphen
run_test("Sanitize: Lọc chú thích [1], *, soft-hyphen, số trang", function()
    local chunker = TextChunker:new()
    local raw = " 42 \nMột đoạn văn bản chứa chú thích[1] và dấu sao* cùng từ ngắt\194\173dòng mềm.\n 42 "
    local cleaned = chunker:sanitize(raw)

    assert(not cleaned:find("%[1%]"), "Không được chứa chú thích [1]")
    assert(not cleaned:find("%*"), "Không được chứa dấu *")
    assert(not cleaned:find("\194\173"), "Không được chứa soft hyphen")
    assert(not cleaned:find("^42"), "Không được chứa số trang header")
    assert(not cleaned:find("42$"), "Không được chứa số trang footer")
    assert(cleaned:find("Một đoạn văn bản chứa chú thích và dấu sao cùng từ ngắtdòng mềm"), "Nội dung chữ phải nguyên vẹn")
end)

-- Test 2: Từ điển phát âm mặc định (Default Pronunciation Dictionary)
run_test("Pronunciation: Mở rộng từ viết tắt chuẩn tiếng Việt", function()
    local chunker = TextChunker:new()
    local text = "Hôm nay tôi đến TP. Hồ Chí Minh gặp GS. Nguyễn Văn Nam và ThS. Lê Thị Mai, v.v."
    local normalized = chunker:normalizePronunciation(text)

    assert(normalized:find("Thành phố"), "TP. phải đổi thành Thành phố")
    assert(normalized:find("Giáo sư"), "GS. phải đổi thành Giáo sư")
    assert(normalized:find("Thạc sĩ"), "ThS. phải đổi thành Thạc sĩ")
    assert(normalized:find("vân vân"), "v.v. phải đổi thành vân vân")
end)

-- Test 3: Từ điển phát âm tùy biến của người dùng (Custom Dictionary CRUD)
run_test("Pronunciation: CRUD từ điển tùy biến qua Settings", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    -- 1. Thêm mới
    local ok = s:setWordMapping("AI", "Trí tuệ nhân tạo")
    assert(ok == true, "setWordMapping phải thành công")
    assert(s:getCustomMappings()["AI"] == "Trí tuệ nhân tạo")

    -- 2. Kiểm tra áp dụng vào Chunker
    local chunker = TextChunker:new{ custom_mappings = s:getCustomMappings() }
    local res = chunker:normalizePronunciation("Công nghệ AI đang phát triển mạnh.")
    assert(res:find("Trí tuệ nhân tạo"), "AI phải được thay thế thành Trí tuệ nhân tạo")

    -- 3. Sửa từ
    s:setWordMapping("AI", "Trí thông minh nhân tạo")
    chunker = TextChunker:new{ custom_mappings = s:getCustomMappings() }
    res = chunker:normalizePronunciation("Công nghệ AI.")
    assert(res:find("Trí thông minh nhân tạo"), "Từ cập nhật phải có hiệu lực")

    -- 4. Xóa từ
    s:removeWordMapping("AI")
    assert(s:getCustomMappings()["AI"] == nil, "AI phải bị xóa khỏi custom mappings")

    -- 5. Reset về mặc định
    s:setWordMapping("CustomTerm", "TừThayThế")
    s:resetWordMappings()
    assert(next(s:getCustomMappings()) == nil, "resetWordMappings phải xóa sạch custom dict")
end)

-- Test 4: Không ngắt nhầm câu tại các từ viết tắt có dấu chấm
run_test("Chunker: Không ngắt nhầm tại từ viết tắt có dấu chấm", function()
    local chunker = TextChunker:new{ min_chars = 20 }
    local text = "Đoàn đại biểu đã đến TP. Hồ Chí Minh để tham dự hội thảo khoa học quốc tế."
    local cleaned = chunker:sanitize(text)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences == 1, string.format("Phải là 1 câu hoàn chỉnh duy nhất, nhưng nhận %d câu", #sentences))
    assert(sentences[1]:find("TP%. Hồ Chí Minh"), "Câu phải giữ nguyên ngữ cảnh liền mạch")
end)

-- Test 5: Tách đúng các loại dấu ngắt câu và câu hội thoại trong ngoặc
run_test("Chunker (Tầng 1): Dấu câu ! ? … và hội thoại ngoặc kép", function()
    local chunker = TextChunker:new{ min_chars = 15 }
    local raw = '"Bạn có đi không?" anh ấy hỏi dồn dập. Tôi ngập ngừng trả lời: "Chắc là có!" và mỉm cười…'
    local cleaned = chunker:sanitize(raw)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences >= 2, "Phải tách được ít nhất 2 câu")
    assert(sentences[1]:find("Bạn có đi không"), "Câu 1 phải chứa thoại hỏi")
end)

-- Test 6: Không ngắt câu tại số thập phân (3.14, 10.5)
run_test("Chunker (Tầng 1): Bảo toàn số thập phân có dấu chấm", function()
    local chunker = TextChunker:new{ min_chars = 10 }
    local raw = "Hằng số Pi xấp xỉ 3.14159 trong hình học phẳng. Tốc độ tăng trưởng đạt 8.5% năm qua."
    local cleaned = chunker:sanitize(raw)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences == 2, string.format("Phải là đúng 2 câu, nhận %d câu", #sentences))
    assert(sentences[1]:find("3.14159"), "Câu 1 phải chứa 3.14159 nguyên vẹn")
    assert(sentences[2]:find("8.5%%"), "Câu 2 phải chứa 8.5% nguyên vẹn")
end)

-- Test 7: Thuật toán Tầng 2 - Gộp câu ngắn (< 30 ký tự) vào câu kế tiếp
run_test("Chunker (Tầng 2): Gộp câu ngắn dưới 30 ký tự", function()
    local chunker = TextChunker:new{ min_chars = 30 }
    local raw = "Trời mưa. Gió thổi mạnh từng cơn trên những tán cây ven đường làng quê yên bình."
    local cleaned = chunker:sanitize(raw)
    local sentences = chunker:splitSentences(cleaned)

    -- 'Trời mưa.' chỉ có 9 ký tự, phải được gộp vào câu tiếp theo
    assert(#sentences == 1, string.format("Câu ngắn phải được gộp lại thành 1 câu, nhưng nhận %d", #sentences))
    assert(sentences[1]:find("^Trời mưa%. Gió thổi mạnh"), "Câu gộp phải bắt đầu bằng 'Trời mưa.'")
    assert(#sentences[1] >= 30, "Câu sau gộp phải đạt độ dài tối thiểu")
end)

-- Test 8: Thuật toán Tầng 3 - Bẻ câu siêu dài (> 300 ký tự) tại dấu phẩy
run_test("Chunker (Tầng 3): Bẻ câu dài > 300 ký tự an toàn", function()
    local chunker = TextChunker:new{ max_chars = 100 } -- Đặt ngưỡng 100 ký tự để kiểm tra
    local long_s = "Trong một buổi chiều thu êm ả, ánh nắng vàng nhạt trải dài trên con đường làng quanh co, những đứa trẻ cùng nhau thả diều trên triền đê xanh ngát gió mát rượi, tạo nên một khung cảnh thanh bình đến lạ kỳ."
    local cleaned = chunker:sanitize(long_s)
    local sentences = chunker:splitSentences(cleaned)

    assert(#sentences >= 2, "Câu dài vượt ngưỡng phải bị bẻ thành 2 câu trở lên")
    for idx, s in ipairs(sentences) do
        assert(#s <= 150, string.format("Đoạn câu %d vượt ngưỡng an toàn: %d ký tự", idx, #s))
    end
end)

-- Test 9: Trích xuất và ánh xạ Bounding Box từ Mock Crengine (EPUB/MOBI)
run_test("Hybrid Engine: Trích xuất từ Crengine kèm Bounding Box", function()
    local sample_text = "Hôm nay là một ngày đẹp trời tại thủ đô Hà Nội. Mặt trời mọc sáng rực rỡ khắp muôn nơi."
    local mock_boxes = {
        { x = 10, y = 20, w = 200, h = 20, char_start = 1, char_end = 45 },
        { x = 10, y = 45, w = 220, h = 20, char_start = 46, char_end = 90 },
    }
    local doc = MockKOReader.createMockCrengineDocument(sample_text, mock_boxes)

    local chunker = TextChunker:new{ min_chars = 25 }
    local chunks = chunker:extractPageChunks(doc, 1)

    assert(#chunks >= 1, "Phải trích xuất được chunks từ Crengine")
    assert(chunks[1].index == 1)
    assert(chunks[1].page == 1)
    assert(type(chunks[1].text) == "string" and #chunks[1].text > 0)
    assert(type(chunks[1].bboxes) == "table", "bboxes phải là table")
end)

-- Test 10: Trích xuất và ánh xạ Bounding Box từ Mock MuPDF (PDF)
run_test("Hybrid Engine: Trích xuất từ MuPDF kèm Bounding Box", function()
    local sample_text = "Tài liệu kỹ thuật lập trình hệ thống phân tán. Nghiên cứu kiến trúc vi dịch vụ và xử lý dữ liệu lớn."
    local mock_boxes = {
        { x = 50, y = 100, w = 300, h = 25 },
        { x = 50, y = 130, w = 350, h = 25 },
    }
    local doc = MockKOReader.createMockMuPDFDocument(sample_text, mock_boxes)

    local chunker = TextChunker:new{ min_chars = 20 }
    local chunks = chunker:extractPageChunks(doc, 1)

    assert(#chunks >= 1, "Phải trích xuất được chunks từ MuPDF")
    assert(chunks[1].page == 1)
    assert(type(chunks[1].bboxes) == "table")
end)

-- Test 11: An toàn phòng thủ - Document bị nil hoặc lỗi không làm crash
run_test("Crash-proof: Document rỗng hoặc lỗi trả về {} an toàn", function()
    local chunker = TextChunker:new()

    -- 1. Document nil
    local chunks = chunker:extractPageChunks(nil, 1)
    assert(type(chunks) == "table" and #chunks == 0, "Doc nil phải trả về bảng rỗng")

    -- 2. Document ném exception
    local faulty_doc = {
        getPageText = function() error("Lỗi bộ nhớ MuPDF!") end
    }
    chunks = chunker:extractPageChunks(faulty_doc, 1)
    assert(type(chunks) == "table" and #chunks == 0, "Doc lỗi phải bắt an toàn qua pcall")
end)

-- Test 12: Tích hợp main.lua onStartTTS trích xuất trang và báo trạng thái
run_test("Tích hợp main.lua: onStartTTS gọi Chunker và báo kết quả", function()
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
    assert(type(chunks) == "table", "onStartTTS phải trả về danh sách chunks")
    assert(#chunks >= 1, "Phải có ít nhất 1 chunk")
    assert(#MockKOReader.UIManager._shown_widgets >= 1, "Phải hiển thị InfoMessage thông báo")

    local info = MockKOReader.UIManager._shown_widgets[1]
    assert(info.text:find("Trang: 5"), "Thông báo phải hiển thị đúng số trang 5")
    assert(info.text:find("Tổng số câu:"), "Thông báo phải hiển thị tổng số câu")
end)

print("==========================================================")
print("  TẤT CẢ 12 BÀI KIỂM THỬ GIAI ĐOẠN 2 ĐÃ VƯỢT QUA 100%!  ")
print("==========================================================")
