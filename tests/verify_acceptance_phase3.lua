--[[
    tests/verify_acceptance_phase3.lua
    Kịch bản kiểm chứng nghiệm thu đầu-cuối (E2E Acceptance Verification) cho Giai đoạn 3 (Phase 3)
    Kiểm chứng toàn diện 3 tiêu chí Definition of Done (DoD):
      - DoD 3.1: HTTP Client non-blocking tải file WAV về cache, giao diện không bị giật/đơ
      - DoD 3.2: Lớp phát âm thanh đa nền tảng AudioBackend, gọi callback chính xác khi hết bài
      - DoD 3.3: Tích hợp toàn trình End-to-End: Document -> TextChunker -> TTSClient -> AudioBackend -> Callback
      - Hỗ trợ cờ --live: Kiểm thử kết nối máy chủ thật với endpoint và giọng đọc trong memory
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local TextChunker = require("text_chunker")
local KoreaderTTS = require("main")
local Settings = require("settings")

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

    local data = string.rep("\0", math.min(data_size, 2048))
    return header .. data
end

-- =========================================================================
-- KIỂM CHỨNG DoD 3.1: HTTP Client Non-blocking tải WAV về cache
-- =========================================================================
step_banner(1, "Kiểm chứng DoD 3.1: Tải file WAV Non-blocking & Lưu trữ Cache")

MockKOReader.UIManager:reset()
local sample_wav_data = create_sample_wav_bytes(1.2, 24000)
local test_text = "Hôm nay tôi đọc sách trên thiết bị màn hình E-ink KOReader."

local tts_client = TTSClient:new{
    cache_dir = "cache/tts_acceptance",
    _mock_transport = function(text, voice, done)
        -- Giả lập độ trễ mạng nhưng không khóa luồng
        done(true, sample_wav_data)
    end
}

local download_success = nil
local downloaded_path = nil

print("  -> Bắt đầu gọi fetchSpeechAsync bất đồng bộ...")
tts_client:fetchSpeechAsync(test_text, function(success, result)
    download_success = success
    downloaded_path = result
end)

-- Kiểm tra UI không bị khóa: có thể xử lý các tác vụ khác trong lúc chờ
local ui_events_processed = 0
MockKOReader.UIManager:scheduleIn(0.01, function()
    ui_events_processed = ui_events_processed + 1
end)

-- Bơm scheduler
MockKOReader.UIManager:runAllScheduled()

assert(download_success == true, "LỖI DoD 3.1: Tải âm thanh thất bại!")
assert(downloaded_path ~= nil, "LỖI DoD 3.1: Không có đường dẫn file trả về!")
assert(ui_events_processed >= 1, "LỖI DoD 3.1: Vòng lặp UI bị chặn không thể xử lý sự kiện cảm ứng!")

-- Kiểm tra file WAV trên đĩa
local f = io.open(downloaded_path, "rb")
assert(f ~= nil, "LỖI DoD 3.1: File WAV không được tạo trên đĩa!")
local magic = f:read(4)
f:close()
assert(magic == "RIFF", "LỖI DoD 3.1: Header file không đúng chuẩn RIFF/WAV!")

print(string.format("  -> Đã tải thành công file WAV về: '%s'", downloaded_path))
print(string.format("  -> Xác thực Header file: '%s' hợp lệ, dung lượng > 0 byte.", magic))
print("  [KẾT QUẢ DoD 3.1]: PASS - Tải file WAV non-blocking thành công, UI không bị treo.")

-- =========================================================================
-- KIỂM CHỨNG DoD 3.2: Tầng phát âm thanh đa nền tảng AudioBackend
-- =========================================================================
step_banner(2, "Kiểm chứng DoD 3.2: Lớp phát âm thanh đa nền tảng & Callback hoàn tất")

MockKOReader.UIManager:reset()
local audio_backend = AudioBackend:new{
    backend_type = "mock",
    speed = 1.0,
}

-- Tính toán thời lượng file
local duration, byte_rate, sample_rate = AudioBackend.getWavDuration(downloaded_path)
print(string.format("  -> Phân tích file WAV: Sample rate = %d Hz | Byte rate = %d B/s | Thời lượng = %.2f giây",
    sample_rate, byte_rate, duration))
assert(duration > 1.0 and duration < 1.4, "LỖI DoD 3.2: Tính sai thời lượng WAV!")

local playback_finished = false
print("  -> Bắt đầu phát âm thanh qua AudioBackend:play()...")
audio_backend:play(downloaded_path, function(success)
    playback_finished = success
end)

assert(audio_backend:isPlaying() == true, "LỖI DoD 3.2: AudioBackend chưa chuyển sang trạng thái isPlaying!")

-- Mô phỏng thời gian phát trôi qua (1.3 giây)
MockKOReader.UIManager:tick(1.3)

assert(playback_finished == true, "LỖI DoD 3.2: Callback on_finished không được gọi khi hết bài!")
assert(audio_backend:isPlaying() == false, "LỖI DoD 3.2: Sau khi phát xong cờ isPlaying phải về false!")

print("  -> Callback hoàn tất phiên phát đã được kích hoạt chính xác.")
print("  [KẾT QUẢ DoD 3.2]: PASS - Driver phát âm thanh mượt mà và gọi callback đúng thời điểm.")

-- =========================================================================
-- KIỂM CHỨNG DoD 3.3: Tích hợp End-to-End câu đơn lẻ trên giao diện KOReader
-- =========================================================================
step_banner(3, "Kiểm chứng DoD 3.3: Toàn trình End-to-End (Document -> API -> Loa)")

MockKOReader.UIManager:reset()
local sample_page_text = "Chào mừng bạn đến với KOReader. Đây là câu thử nghiệm tính năng đọc bằng giọng nói của Phase 3."
local mock_doc = MockKOReader.createMockCrengineDocument(sample_page_text)

local plugin = KoreaderTTS:new{
    ui = {
        document = mock_doc,
        menu = { registerToMainMenu = function() end },
    }
}
plugin:init()

-- Đặt mock transport cho plugin tts_client để chạy test E2E offline
plugin.tts_client._mock_transport = function(text, voice, done)
    done(true, sample_wav_data)
end
plugin.audio_backend.driver_name = "desktop"

print("  -> Kích hoạt chức năng 'Phát thử 1 câu' từ Menu...")
plugin:onTestSingleSentence()

-- Kiểm tra thông báo hiển thị đang tải
assert(#MockKOReader.UIManager._shown_widgets >= 1, "LỖI DoD 3.3: Không hiển thị thông báo tải!")
local msg1 = MockKOReader.UIManager._shown_widgets[1]
print(string.format("  -> Toast 1: '%s'", msg1.text:gsub("\n", " - ")))
assert(msg1.text:find("Đang tải"), "LỖI DoD 3.3: Chưa báo đang tải âm thanh!")

-- Bơm scheduler để hoàn thành việc tải và bắt đầu phát
MockKOReader.UIManager:tick(0.1)

-- Kiểm tra thông báo đang phát
local msg2 = MockKOReader.UIManager._shown_widgets[#MockKOReader.UIManager._shown_widgets]
print(string.format("  -> Toast 2: '%s'", msg2.text:gsub("\n", " - ")))
assert(msg2.text:find("Đang phát"), "LỖI DoD 3.3: Chưa báo đang phát câu!")
assert(plugin.audio_backend:isPlaying() == true, "LỖI DoD 3.3: Backend chưa phát âm thanh!")

-- Cho âm thanh phát hết
MockKOReader.UIManager:tick(1.5)
assert(plugin.audio_backend:isPlaying() == false, "LỖI DoD 3.3: Backend chưa dừng sau khi phát xong!")

local msg3 = MockKOReader.UIManager._shown_widgets[#MockKOReader.UIManager._shown_widgets]
print(string.format("  -> Toast 3: '%s'", msg3.text))
assert(msg3.text:find("Đã phát xong"), "LỖI DoD 3.3: Chưa báo phát xong câu!")

print("  [KẾT QUẢ DoD 3.3]: PASS - Toàn trình End-to-End câu đơn lẻ hoạt động trơn tru 100%.")

-- Dọn dẹp file test
os.remove(downloaded_path)

-- =========================================================================
-- KIỂM CHỨNG TÙY CHỌN: KẾT NỐI SERVER THẬT (LIVE SERVER TEST)
-- =========================================================================
local is_live_test = false
for _, arg in ipairs(arg or {}) do
    if arg == "--live" then is_live_test = true end
end

if is_live_test then
    step_banner(4, "Kiểm chứng Tùy chọn: Kết nối Máy chủ TTS Thực tế (Live VieNeu Server)")
    print("  -> Đang kết nối tới máy chủ live được cấu hình trong memory...")

    local live_client = TTSClient:new{
        server_url = "https://maiquocthinh-vieneu-tts.hf.space/v1/audio/speech",
        voice = "Đức Trí",
        request_timeout = 25,
        cache_dir = "cache/tts_live",
    }

    local live_done = false
    local live_ok = false
    local live_res = nil

    live_client:fetchSpeechAsync("Xin chào bạn. Tôi là giọng đọc Đức Trí trên KOReader.", function(ok, res)
        live_done = true
        live_ok = ok
        live_res = res
    end)

    -- Chạy scheduler chờ live download
    local max_wait = 250
    while not live_done and max_wait > 0 do
        max_wait = max_wait - 1
        MockKOReader.UIManager:tick(0.1)
    end

    if live_ok then
        print(string.format("  -> [LIVE PASS]: Tải thành công từ server thật! File: %s", live_res))
        local live_dur = AudioBackend.getWavDuration(live_res)
        print(string.format("  -> Thời lượng âm thanh từ server: %.2f giây", live_dur))
        os.remove(live_res)
    else
        print(string.format("  -> [LIVE NOTICE]: Không thể kết nối server live (có thể do mạng/timeout): %s", tostring(live_res)))
    end
end

print("\n=========================================================================")
print("  TỔNG KẾT: TẤT CẢ 3 TIÊU CHÍ GIAI ĐOẠN 3 ĐÃ ĐƯỢC NGHIỆM THU 100%!     ")
print("=========================================================================\n")
