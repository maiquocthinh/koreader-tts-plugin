--[[
    tests/test_phase3_network_audio.lua - Bộ kiểm thử độc lập cho Giai đoạn 3 (Phase 3)
    Kiểm tra:
      - JSON serialization UTF-8 tiếng Việt
      - Phân tích cấu trúc header file WAV & tính thời lượng
      - Non-blocking HTTP Client & cơ chế atomic cache
      - Multi-platform Audio Backend, playback lifecycle & token cancellation
    Chạy trực tiếp qua: luajit tests/test_phase3_network_audio.lua
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")

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
        .. pack32(16) -- fmt chunk size
        .. pack16(1)  -- PCM format
        .. pack16(channels)
        .. pack32(sample_rate)
        .. pack32(byte_rate)
        .. pack16(channels * (bits_per_sample / 8))
        .. pack16(bits_per_sample)
        .. "data"
        .. pack32(data_size)

    -- Data bytes (chuỗi 0)
    local data = string.rep("\0", math.min(data_size, 1024))
    return header .. data
end

print("==========================================================")
print("  CHẠY BỘ KIỂM THỬ ĐỘC LẬP - GIAI ĐOẠN 3 (PHASE 3)")
print("==========================================================")

-- Test 1: JSON Serializer
run_test("Mã hóa JSON UTF-8 tiếng Việt & ký tự đặc biệt", function()
    local encode = TTSClient._json_encode
    assert(encode("Xin chào") == '"Xin chào"')
    assert(encode("Câu có dấu \"ngoặc kép\" và \n xuống dòng") == '"Câu có dấu \\"ngoặc kép\\" và \\n xuống dòng"')

    local tbl = { input = "Thử nghiệm", voice = "vi-VN-NamMinh", speed = 1.0 }
    local json = encode(tbl)
    assert(json:find('"input":"Thử nghiệm"', 1, true))
    assert(json:find('"voice":"vi-VN-NamMinh"', 1, true))
    assert(json:find('"speed":1', 1, true))
end)

-- Test 2: URL Parser
run_test("Phân tích URL linh hoạt (http/https, custom port/path)", function()
    local parse = TTSClient._parse_url

    local u1 = parse("http://192.168.1.100:7860")
    assert(u1.scheme == "http")
    assert(u1.host == "192.168.1.100")
    assert(u1.port == 7860)
    assert(u1.path == "/v1/audio/speech")

    local u2 = parse("https://api.example.com/v1/custom")
    assert(u2.scheme == "https")
    assert(u2.host == "api.example.com")
    assert(u2.port == 443)
    assert(u2.path == "/v1/custom")
end)

-- Test 3: FNV-1a Hash & Đường dẫn Cache
run_test("Sinh mã hash FNV-1a & đường dẫn cache nhất quán", function()
    local client = TTSClient:new{ cache_dir = "cache/tts_test" }
    local p1 = client:getCacheFilePath("Hôm nay trời đẹp.", "vi-VN-NamMinh")
    local p2 = client:getCacheFilePath("Hôm nay trời đẹp.", "vi-VN-NamMinh")
    local p3 = client:getCacheFilePath("Hôm nay trời mưa.", "vi-VN-NamMinh")
    local p4 = client:getCacheFilePath("Hôm nay trời đẹp.", "vi-VN-NuMaiPhuong")

    assert(p1 == p2, "Cùng text và voice phải cho cùng đường dẫn cache")
    assert(p1 ~= p3, "Khác text phải cho đường dẫn cache khác nhau")
    assert(p1 ~= p4, "Khác voice phải cho đường dẫn cache khác nhau")
    assert(p1:match("%.wav$"), "Đường dẫn cache phải có đuôi .wav")
end)

-- Test 4: Phân tích Header WAV và tính thời lượng
run_test("Phân tích cấu trúc file WAV & tính duration chính xác", function()
    local wav_data = create_sample_wav_bytes(1.5, 24000)
    local test_path = "cache/tts_test_sample.wav"

    -- Đảm bảo thư mục tồn tại và ghi file mẫu
    local f = io.open(test_path, "wb")
    assert(f, "Không thể mở file test_sample.wav để ghi")
    f:write(wav_data)
    f:close()

    local duration, byte_rate, sample_rate = AudioBackend.getWavDuration(test_path)
    os.remove(test_path)

    assert(sample_rate == 24000, "Sample rate phải là 24000")
    assert(byte_rate == 48000, "Byte rate phải là 48000")
    assert(math.abs(duration - 1.5) < 0.05, "Thời lượng tính toán phải xấp xỉ 1.5 giây")
end)

-- Test 5: Tải âm thanh bất đồng bộ qua TTSClient (Mock Transport)
run_test("fetchSpeechAsync tải thành công & lưu cache nguyên tử", function()
    MockKOReader.UIManager:reset()

    local sample_wav = create_sample_wav_bytes(1.0, 24000)
    local client = TTSClient:new{
        cache_dir = "cache/tts_unit",
        _mock_transport = function(text, voice, done)
            -- Mô phỏng kết nối thành công trả về stream WAV
            done(true, sample_wav)
        end
    }

    local test_text = "Thử nghiệm tải audio non-blocking."
    local received_success = nil
    local received_result = nil

    client:fetchSpeechAsync(test_text, function(success, result)
        received_success = success
        received_result = result
    end)

    -- Chạy vòng lặp scheduler
    MockKOReader.UIManager:runAllScheduled()

    assert(received_success == true, "fetchSpeechAsync phải thành công")
    assert(type(received_result) == "string", "Kết quả phải là đường dẫn file")
    assert(client:hasValidCache(test_text, client.voice) == true, "File cache phải hợp lệ")

    -- Dọn dẹp file test
    os.remove(received_result)
end)

-- Test 6: Kiểm tra Cache Hit (không tải lại khi đã có cache)
run_test("Nhận diện Cache Hit và trả về ngay file có sẵn", function()
    local sample_wav = create_sample_wav_bytes(0.8, 24000)
    local client = TTSClient:new{
        cache_dir = "cache/tts_unit",
    }
    local text = "Câu này đã được cache sẵn."
    local cache_file = client:getCacheFilePath(text, client.voice)

    local f = io.open(cache_file, "wb")
    f:write(sample_wav)
    f:close()

    local called_transport = false
    client._mock_transport = function()
        called_transport = true
    end

    local returned_path = nil
    client:fetchSpeechAsync(text, function(ok, path)
        returned_path = path
    end)

    assert(called_transport == false, "Không được gọi transport khi đã có cache")
    assert(returned_path == cache_file, "Phải trả về đúng đường dẫn file cache")

    os.remove(cache_file)
end)

-- Test 7: Xử lý lỗi tải mạng & không để lại file rác .tmp
run_test("Xử lý lỗi mạng an toàn, không sập & dọn dẹp file .tmp", function()
    MockKOReader.UIManager:reset()

    local client = TTSClient:new{
        cache_dir = "cache/tts_unit",
        _mock_transport = function(text, voice, done)
            done(false, "Lỗi kết nối máy chủ 503 Service Unavailable")
        end
    }

    local text = "Câu bị lỗi mạng."
    local err_received = nil
    local ok_received = nil

    client:fetchSpeechAsync(text, function(ok, res)
        ok_received = ok
        err_received = res
    end)

    MockKOReader.UIManager:runAllScheduled()

    assert(ok_received == false, "Phải trả về trạng thái thất bại")
    assert(err_received:find("503"), "Thông báo lỗi phải chứa thông tin server")

    -- Xác nhận không có file .tmp sót lại
    local tmp_file = client:getCacheFilePath(text, client.voice) .. ".tmp"
    local f = io.open(tmp_file, "r")
    assert(f == nil, "File .tmp phải được dọn dẹp sạch sẽ")
end)

-- Test 8: AudioBackend Playback Lifecycle & Callback
run_test("AudioBackend:play kích hoạt và gọi callback khi phát xong", function()
    MockKOReader.UIManager:reset()

    local sample_wav = create_sample_wav_bytes(0.5, 24000)
    local test_path = "cache/tts_play_test.wav"
    local f = io.open(test_path, "wb")
    f:write(sample_wav)
    f:close()

    local backend = AudioBackend:new{ backend_type = "mock", speed = 1.0 }
    assert(backend:isPlaying() == false, "Ban đầu không được ở trạng thái playing")

    local finished_called = false
    backend:play(test_path, function(success)
        finished_called = success
    end)

    assert(backend:isPlaying() == true, "Sau khi gọi play() phải chuyển sang isPlaying = true")

    -- Giả lập trôi qua 0.5s thời gian
    MockKOReader.UIManager:tick(0.6)

    assert(finished_called == true, "Callback on_finished phải được kích hoạt sau khi hết thời lượng")
    assert(backend:isPlaying() == false, "Sau khi phát xong phải chuyển về isPlaying = false")

    os.remove(test_path)
end)

-- Test 9: AudioBackend Token Cancellation (Dừng ngay khi gọi stop)
run_test("AudioBackend:stop vô hiệu hóa phiên cũ & hủy callback", function()
    MockKOReader.UIManager:reset()

    local sample_wav = create_sample_wav_bytes(1.0, 24000)
    local test_path = "cache/tts_stop_test.wav"
    local f = io.open(test_path, "wb")
    f:write(sample_wav)
    f:close()

    local backend = AudioBackend:new{ backend_type = "mock" }
    local old_callback_fired = false

    backend:play(test_path, function()
        old_callback_fired = true
    end)

    assert(backend:isPlaying() == true)

    -- Gọi stop ngay lập tức
    backend:stop()
    assert(backend:isPlaying() == false, "Gọi stop() phải lập tức tắt cờ isPlaying")

    -- Giả lập trôi qua hết thời lượng file cũ
    MockKOReader.UIManager:tick(1.5)

    assert(old_callback_fired == false, "Callback của phiên đã bị stop() không được kích hoạt")

    os.remove(test_path)
end)

-- Test 10: Tốc độ đọc (Speed Clamping & Playback time)
run_test("AudioBackend:setSpeed giới hạn [0.5, 2.0] & thay đổi thời lượng", function()
    local backend = AudioBackend:new{ speed = 1.0 }
    backend:setSpeed(0.1)
    assert(backend.speed == 0.5, "speed < 0.5 phải clamp về 0.5")
    backend:setSpeed(5.0)
    assert(backend.speed == 2.0, "speed > 2.0 phải clamp về 2.0")
    backend:setSpeed(1.5)
    assert(backend.speed == 1.5)
end)

-- Test 11: Nhận diện Platform theo Device
run_test("AudioBackend tự động nhận diện Platform theo Device", function()
    _G.Device:setPlatform("android")
    local b1 = AudioBackend:new()
    assert(b1.driver_name == "android", "Trên Android phải nhận diện driver android")

    _G.Device:setPlatform("kobo")
    local b2 = AudioBackend:new()
    assert(b2.driver_name == "linux", "Trên Kobo phải nhận diện driver linux")

    _G.Device:setPlatform("desktop")
    local b3 = AudioBackend:new()
    assert(b3.driver_name == "desktop", "Trên Desktop phải nhận diện driver desktop")
end)

print("==========================================================")
print("  TẤT CẢ 11 BÀI KIỂM THỬ ĐỀU ĐÃ VƯỢT QUA THÀNH CÔNG!     ")
print("==========================================================")
