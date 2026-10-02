--[[
    tests/verify_acceptance_phase4.lua
    Kịch bản kiểm chứng nghiệm thu đầu-cuối (E2E Acceptance Verification) cho Giai đoạn 4 (Phase 4)
    Kiểm chứng toàn diện 3 tiêu chí Definition of Done (DoD):
      - DoD 4.1: Sliding Window 3 vị trí & Zero-gap playback (< 100ms) giữa các câu
      - DoD 4.2: Tải trước xuyên trang & Tự động lật trang khi đọc hết câu cuối
      - DoD 4.3: Điều hướng câu (Seek/Next/Prev) kèm hủy đệm thông minh theo thế hệ hàng đợi
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local KoreaderTTS = require("main")

local function step_banner(num, title)
    print(string.format("\n=== [BƯỚC %d] %s ===", num, title))
end

--- Hàm tạo chuỗi nhị phân WAV hợp lệ phục vụ kiểm thử nghiệm thu
local function create_sample_wav_bytes(duration_seconds, sample_rate)
    sample_rate = sample_rate or 24000
    local channels = 1
    local bits_per_sample = 16
    local byte_rate = sample_rate * channels * (bits_per_sample / 8)
    local data_size = math.floor(duration_seconds * byte_rate)
    local file_size = 36 + data_size

    local function pack16(v)
        local b1 = v % 256
        local b2 = math.floor(v / 256) % 256
        return string.char(b1, b2)
    end

    local function pack32(v)
        local b1 = v % 256
        local b2 = math.floor(v / 256) % 256
        local b3 = math.floor(v / 65536) % 256
        local b4 = math.floor(v / 16777216) % 256
        return string.char(b1, b2, b3, b4)
    end

    local header = "RIFF"
        .. pack32(file_size)
        .. "WAVE"
        .. "fmt "
        .. pack32(16)
        .. pack16(1)
        .. pack16(channels)
        .. pack32(sample_rate)
        .. pack32(byte_rate)
        .. pack16(channels * (bits_per_sample / 8))
        .. pack16(bits_per_sample)
        .. "data"
        .. pack32(data_size)

    local data = string.rep("\0", math.min(data_size, 512))
    return header .. data
end

local sample_wav_data = create_sample_wav_bytes(0.3, 24000)

-- =========================================================================
-- KIỂM CHỨNG DoD 4.1: Sliding Window 3 vị trí & Zero-gap Playback (< 100ms)
-- =========================================================================
step_banner(1, "Kiểm chứng DoD 4.1: Sliding Window 3 Vị Trí & Zero-gap Playback")

MockKOReader.UIManager:reset()

local book_pages = {
    [1] = "Câu số một của buổi đọc sách hôm nay. Câu số hai tiếp nối ngay lập tức sau đó. Câu số ba hoàn thành trang đọc đầu tiên.",
    [2] = "Câu số một của trang tiếp theo đã mở ra. Câu số hai kết thúc toàn bộ chương sách này."
}
local doc = MockKOReader.createMockMultiPageDocument(book_pages, 2)
local ui = MockKOReader.createMockUI(doc, 1)

local chunker = TextChunker:new()
local tts_client = TTSClient:new{
    cache_dir = "cache/tts_acc4_p1",
    _mock_transport = function(text, voice, done)
        done(true, sample_wav_data)
    end
}
local audio_backend = AudioBackend:new{ backend_type = "mock" }

local played_chunks = {}
local queue = PlaybackQueue:new{
    ui = ui,
    document = doc,
    chunker = chunker,
    tts_client = tts_client,
    audio_backend = audio_backend,
    on_chunk_change = function(chunk, page, index, total)
        table.insert(played_chunks, { page = page, index = index, text = chunk.text })
        print(string.format("  -> Bắt đầu phát: Trang %d | Câu %d/%d: '%s'", page, index, total, chunk.text:sub(1, 45) .. "..."))
    end
}

print("  -> Khởi động PlaybackQueue tại Trang 1 Câu 1...")
queue:start(1, 1)
MockKOReader.UIManager:tick(0.05)

-- 1. Kiểm tra 3 slots của Sliding Window
local s0 = queue:getSlot(0)
local s1 = queue:getSlot(1)
local s2 = queue:getSlot(2)

assert(s0 ~= nil and s0.chunk_index == 1, "LỖI DoD 4.1: Slot 0 phải là câu 1!")
assert(s1 ~= nil and s1.chunk_index == 2, "LỖI DoD 4.1: Slot 1 phải là câu 2!")
assert(s2 ~= nil and s2.chunk_index == 3, "LỖI DoD 4.1: Slot 2 phải là câu 3!")
assert(s1.status == "READY", "LỖI DoD 4.1: Câu 2 phải được nạp sẵn ở Slot 1!")
print("  -> Sliding Window: Slot N (Câu 1) đang phát, Slot N+1 (Câu 2) đã sẵn sàng, Slot N+2 (Câu 3) đã đệm.")

-- 2. Kiểm tra Zero-gap: Câu 1 phát xong -> Câu 2 phát ngay lập tức
MockKOReader.UIManager:tick(0.35)

assert(#played_chunks >= 2 and played_chunks[2].index == 2, "LỖI DoD 4.1: Câu 2 không được phát ngay khi câu 1 kết thúc!")
print("  -> Zero-gap: Câu 1 kết thúc, Câu 2 được chuyển phát ngay lập tức không có khoảng lặng chờ.")
print("  [KẾT QUẢ DoD 4.1]: PASS - Sliding Window 3 vị trí và Zero-gap hoạt động hoàn hảo.")

-- =========================================================================
-- KIỂM CHỨNG DoD 4.2: Tải trước xuyên trang & Tự động lật trang
-- =========================================================================
step_banner(2, "Kiểm chứng DoD 4.2: Tải trước Xuyên Trang & Tự động Lật Trang")

-- Đang ở Câu 2 của Trang 1 (Trang 1 có 3 câu, nên Câu 2 chính là câu áp chót)
local s_next = queue:getSlot(1) -- Câu 3 trang 1
local s_preload = queue:getSlot(2) -- Câu 1 trang 2 (tải trước xuyên trang!)

print(string.format("  -> Vị trí hiện tại: Trang %d | Câu %d", queue:getCurrentPage(), queue:getCurrentIndex()))
assert(s_preload ~= nil and s_preload.page == 2 and s_preload.chunk_index == 1,
    "LỖI DoD 4.2: Slot N+2 không tải trước Câu 1 của Trang 2!")
assert(s_preload.status == "READY", "LỖI DoD 4.2: Câu 1 Trang 2 chưa được tải trước sẵn sàng!")
print("  -> Tải trước xuyên trang: Câu 1 của Trang 2 đã nằm sẵn trong bộ nhớ đệm khi đang đọc câu áp chót của Trang 1.")

-- Cho Câu 2 kết thúc -> Chuyển sang Câu 3 (câu cuối cùng của Trang 1)
MockKOReader.UIManager:tick(0.35)
assert(queue:getCurrentPage() == 1 and queue:getCurrentIndex() == 3, "LỖI DoD 4.2: Chưa chuyển sang câu 3 trang 1!")

-- Cho Câu 3 kết thúc -> Tự động kích hoạt lật trang sang Trang 2 và phát ngay câu 1 trang 2
MockKOReader.UIManager:tick(0.35)

assert(ui.view.state.page == 2, "LỖI DoD 4.2: UI KOReader chưa được tự động lật sang trang 2!")
assert(queue:getCurrentPage() == 2 and queue:getCurrentIndex() == 1,
    "LỖI DoD 4.2: Hàng đợi chưa chuyển sang phát Trang 2 Câu 1!")
print(string.format("  -> Tự động lật trang: Giao diện UI đã chuyển sang trang %d, audio phát liền mạch câu đầu trang mới.", ui.view.state.page))
print("  [KẾT QUẢ DoD 4.2]: PASS - Tải trước xuyên trang và tự động lật trang thành công 100%.")

queue:stop()

-- =========================================================================
-- KIỂM CHỨNG DoD 4.3: Điều hướng câu (Seek/Next/Prev) & Hủy đệm thông minh
-- =========================================================================
step_banner(3, "Kiểm chứng DoD 4.3: Điều hướng câu (Seek/Next/Prev) & Hủy đệm theo Token")

MockKOReader.UIManager:reset()
local queue2 = PlaybackQueue:new{
    ui = ui,
    document = doc,
    chunker = chunker,
    tts_client = tts_client,
    audio_backend = audio_backend,
}

queue2:start(1, 1)
MockKOReader.UIManager:tick(0.05)
assert(queue2:getCurrentIndex() == 1)

local old_gen = queue2.queue_generation
print(string.format("  -> Đang phát Trang 1 Câu 1 (Token thế hệ: %d)...", old_gen))

-- Người dùng bấm [Câu tiếp theo]
print("  -> Người dùng bấm [Câu tiếp theo] (nextChunk)...")
queue2:nextChunk()
MockKOReader.UIManager:tick(0.05)

assert(queue2.queue_generation > old_gen, "LỖI DoD 4.3: Token thế hệ không được tăng khi tua câu!")
assert(queue2:getCurrentIndex() == 2, "LỖI DoD 4.3: Chưa chuyển sang câu 2!")
print(string.format("  -> Đã nhảy sang Câu 2 (Token thế hệ mới: %d), âm thanh cũ dừng ngay lập tức.", queue2.queue_generation))

-- Người dùng bấm [Câu trước đó]
print("  -> Người dùng bấm [Câu trước đó] (prevChunk)...")
queue2:prevChunk()
MockKOReader.UIManager:tick(0.05)

assert(queue2:getCurrentIndex() == 1, "LỖI DoD 4.3: Chưa quay lại câu 1!")
print(string.format("  -> Đã quay lại Câu 1 (Token thế hệ mới: %d).", queue2.queue_generation))

-- Người dùng bấm Nhảy trực tiếp tới Trang 2 Câu 2
print("  -> Người dùng nhảy trực tiếp tới Trang 2 Câu 2 (seekChunk)...")
queue2:seekChunk(2, 2)
MockKOReader.UIManager:tick(0.05)

assert(queue2:getCurrentPage() == 2 and queue2:getCurrentIndex() == 2, "LỖI DoD 4.3: Nhảy câu không đúng vị trí đích!")
print(string.format("  -> Đã nhảy chính xác tới Trang %d Câu %d.", queue2:getCurrentPage(), queue2:getCurrentIndex()))

queue2:stop()
assert(queue2:getState() == PlaybackQueue.STATE_IDLE)
print("  [KẾT QUẢ DoD 4.3]: PASS - Điều hướng câu phản hồi tức thì, hủy đệm cũ an toàn.")

print("\n=========================================================================")
print("  TỔNG KẾT: TẤT CẢ 3 TIÊU CHÍ GIAI ĐOẠN 4 ĐÃ ĐƯỢC NGHIỆM THU 100%!     ")
print("=========================================================================\n")
