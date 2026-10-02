--[[
    tests/test_phase4_queue.lua - Bộ kiểm thử độc lập cho Giai đoạn 4 (Phase 4)
    Kiểm tra:
      - Máy trạng thái FSM (IDLE, PREFETCHING, PLAYING, PAUSED)
      - Sliding Window 3 vị trí & Zero-gap playback (< 100ms)
      - Tải trước xuyên trang (Cross-page preload) & Tự động chuyển trang
      - Điều hướng câu (Next/Prev/Seek) kèm hủy đệm thông minh theo token
    Chạy trực tiếp qua: luajit tests/test_phase4_queue.lua
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local Settings = require("settings")

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

--- Hàm tạo chuỗi nhị phân WAV hợp lệ phục vụ kiểm thử
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

print("==========================================================")
print("  CHẠY BỘ KIỂM THỬ ĐỘC LẬP - GIAI ĐOẠN 4 (PHASE 4)")
print("==========================================================")

local sample_wav_data = create_sample_wav_bytes(0.3, 24000)

-- Test 1: Khởi tạo FSM và chuyển đổi trạng thái cơ bản
run_test("FSM: Chuyển đổi trạng thái IDLE -> PREFETCH -> PLAY -> STOP", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu số một của bài đọc này. Câu số hai của bài đọc này."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q1",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local state_history = {}
    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
        on_state_change = function(old_s, new_s)
            table.insert(state_history, new_s)
        end
    }

    assert(queue:getState() == PlaybackQueue.STATE_IDLE, "Trạng thái ban đầu phải là IDLE")

    -- Bắt đầu đọc
    queue:start(1, 1)

    -- Đang tải Slot N -> chuyển PREFETCHING
    MockKOReader.UIManager:tick(0.01)

    assert(queue:getState() == PlaybackQueue.STATE_PLAYING, "Sau khi tải xong câu 1 phải chuyển sang PLAYING")

    -- Tạm dừng
    queue:pause()
    assert(queue:getState() == PlaybackQueue.STATE_PAUSED, "Gọi pause() phải chuyển sang PAUSED")

    -- Tiếp tục
    queue:resume()
    assert(queue:getState() == PlaybackQueue.STATE_PLAYING, "Gọi resume() phải chuyển lại PLAYING")

    -- Dừng
    queue:stop()
    assert(queue:getState() == PlaybackQueue.STATE_IDLE, "Gọi stop() phải chuyển về IDLE")
end)

-- Test 2: Sliding Window 3 vị trí (Slot N, N+1, N+2)
run_test("Sliding Window: Duy trì 3 slots kế tiếp nhau", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu thứ nhất trong trang một. Câu thứ hai trong trang một. Câu thứ ba trong trang một. Câu thứ tư trong trang một."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q2",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
    }

    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)

    -- Kiểm tra 3 slots:
    -- Slot 0 (N) phải là câu 1
    -- Slot 1 (N+1) phải là câu 2
    -- Slot 2 (N+2) phải là câu 3
    local s0 = queue:getSlot(0)
    local s1 = queue:getSlot(1)
    local s2 = queue:getSlot(2)

    assert(s0 ~= nil and s0.chunk_index == 1, "Slot 0 phải là câu 1")
    assert(s1 ~= nil and s1.chunk_index == 2, "Slot 1 phải là câu 2")
    assert(s2 ~= nil and s2.chunk_index == 3, "Slot 2 phải là câu 3")

    assert(s0.status == "READY", "Slot 0 phải ở trạng thái READY")
    assert(s1.status == "READY", "Slot 1 phải được tải trước ở trạng thái READY")
    assert(s2.status == "READY", "Slot 2 phải được tải trước ở trạng thái READY")

    queue:stop()
end)

-- Test 3: Zero-gap Playback (< 100ms)
run_test("Zero-gap: Slot N kết thúc, Slot N+1 phát ngay lập tức", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu một thử nghiệm độ trễ âm thanh. Câu hai thử nghiệm độ trễ âm thanh."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q3",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local chunks_played = {}
    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
        on_chunk_change = function(chunk, page, index)
            table.insert(chunks_played, { page = page, index = index })
        end
    }

    queue:start(1, 1)
    -- Chờ tải xong 3 slots ban đầu
    MockKOReader.UIManager:tick(0.05)

    assert(#chunks_played == 1 and chunks_played[1].index == 1, "Câu 1 phải bắt đầu phát")

    -- Cho câu 1 phát hết thời lượng (0.3s)
    MockKOReader.UIManager:tick(0.35)

    -- Câu 2 phải được kích hoạt ngay lập tức trong cùng nhịp (Zero-gap)
    assert(#chunks_played == 2 and chunks_played[2].index == 2, "Câu 2 phải được phát ngay lập tức không có khoảng lặng")
    assert(queue:getCurrentIndex() == 2, "Vị trí hiện tại phải là câu 2")

    queue:stop()
end)

-- Test 4: Tải trước xuyên trang khi gặp câu áp chót
run_test("Cross-page Preload: Tải trước câu 1 trang sau khi tới câu áp chót", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu một của trang thứ nhất. Câu hai của trang thứ nhất.",
        [2] = "Câu một của trang thứ hai. Câu hai của trang thứ hai.",
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()

    local fetched_chunks = {}
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q4",
        _mock_transport = function(text, voice, done)
            table.insert(fetched_chunks, text)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
    }

    -- Bắt đầu tại câu 1 trang 1 (đây cũng chính là câu áp chót vì trang 1 có 2 câu)
    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)

    -- Slot 0: Trang 1 Câu 1
    -- Slot 1: Trang 1 Câu 2
    -- Slot 2: Trang 2 Câu 1 (Được tải trước xuyên trang!)
    local s2 = queue:getSlot(2)
    assert(s2 ~= nil, "Slot 2 phải tồn tại")
    assert(s2.page == 2 and s2.chunk_index == 1, "Slot 2 phải là Câu 1 của Trang 2")
    assert(s2.status == "READY", "Slot 2 (Trang 2 Câu 1) phải được tải trước ở trạng thái READY")

    queue:stop()
end)

-- Test 5: Tự động lật trang KOReader khi câu cuối kết thúc
run_test("Auto Page-turn: Tự động lật trang khi đọc hết câu cuối", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu một của trang thứ nhất. Câu hai của trang thứ nhất.",
        [2] = "Câu một của trang thứ hai. Câu hai của trang thứ hai.",
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local ui = MockKOReader.createMockUI(doc, 1)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q5",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local page_turned_to = nil
    local queue = PlaybackQueue:new{
        ui = ui,
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
        on_page_turn = function(new_p)
            page_turned_to = new_p
        end
    }

    queue:start(1, 2) -- Bắt đầu từ câu 2 (câu cuối trang 1)
    MockKOReader.UIManager:tick(0.05)
    assert(queue:getCurrentPage() == 1 and queue:getCurrentIndex() == 2)

    -- Phát hết câu 2 trang 1 (thời lượng 0.3s)
    MockKOReader.UIManager:tick(0.35)

    -- Xác nhận đã tự động lật sang trang 2
    assert(ui.view.state.page == 2, "UI phải tự động lật sang trang 2")
    assert(page_turned_to == 2, "Callback on_page_turn phải nhận được trang 2")
    assert(queue:getCurrentPage() == 2 and queue:getCurrentIndex() == 1, "Hàng đợi phải chuyển sang Trang 2 Câu 1")

    queue:stop()
end)

-- Test 6: Xử lý trang chỉ có 1 câu duy nhất (M = 1)
run_test("Single Chunk Page: Trang chỉ có 1 câu nạp ngay câu trang sau", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Trang này chỉ có đúng một câu duy nhất.",
        [2] = "Trang thứ hai có câu số một. Trang thứ hai có câu số hai.",
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q6",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
    }

    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)

    -- Vì trang 1 chỉ có 1 câu, Slot 1 (N+1) phải chính là Câu 1 của Trang 2
    local s1 = queue:getSlot(1)
    assert(s1 ~= nil and s1.page == 2 and s1.chunk_index == 1, "Slot 1 phải là Trang 2 Câu 1")
    assert(s1.status == "READY", "Slot 1 phải sẵn sàng")

    queue:stop()
end)

-- Test 7: Tua câu (nextChunk / prevChunk) & Vô hiệu hóa hàng đợi cũ
run_test("Seeking: nextChunk/prevChunk hủy âm thanh cũ và đặt vị trí mới", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu số một của đoạn văn này. Câu số hai của đoạn văn này. Câu số ba của đoạn văn này."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q7",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
    }

    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)
    assert(queue:getCurrentIndex() == 1, "Đang ở câu 1")

    local old_gen = queue.queue_generation

    -- Bấm nextChunk()
    queue:nextChunk()
    MockKOReader.UIManager:tick(0.05)

    assert(queue.queue_generation > old_gen, "queue_generation phải tăng để hủy bỏ phiên cũ")
    assert(queue:getCurrentIndex() == 2, "Sau khi nextChunk() phải nhảy sang câu 2")

    -- Bấm prevChunk()
    queue:prevChunk()
    MockKOReader.UIManager:tick(0.05)
    assert(queue:getCurrentIndex() == 1, "Sau khi prevChunk() phải quay lại câu 1")

    queue:stop()
end)

-- Test 8: Kết thúc toàn bộ tài liệu gọi on_finished
run_test("Hết sách: Câu cuối cùng kết thúc gọi on_finished và dừng", function()
    MockKOReader.UIManager:reset()

    local pages = {
        [1] = "Câu duy nhất và cũng là câu cuối cùng của cả cuốn sách này."
    }
    local doc = MockKOReader.createMockMultiPageDocument(pages, 1)
    local chunker = TextChunker:new()
    local tts_client = TTSClient:new{
        cache_dir = "cache/tts_q8",
        _mock_transport = function(text, voice, done)
            done(true, sample_wav_data)
        end
    }
    local audio_backend = AudioBackend:new{ backend_type = "mock" }

    local finished_called = false
    local queue = PlaybackQueue:new{
        document = doc,
        chunker = chunker,
        tts_client = tts_client,
        audio_backend = audio_backend,
        on_finished = function()
            finished_called = true
        end
    }

    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)
    assert(queue:getState() == PlaybackQueue.STATE_PLAYING)

    -- Phát hết thời lượng câu cuối
    MockKOReader.UIManager:tick(0.35)

    assert(finished_called == true, "on_finished phải được gọi khi hết sách")
    assert(queue:getState() == PlaybackQueue.STATE_IDLE, "Trạng thái phải trở về IDLE")
end)

print("==========================================================")
print("  TẤT CẢ 8 BÀI KIỂM THỬ ĐỀU ĐÃ VƯỢT QUA THÀNH CÔNG!     ")
print("==========================================================")
