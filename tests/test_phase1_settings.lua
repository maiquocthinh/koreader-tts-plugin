--[[
    tests/test_phase1_settings.lua - Bộ tự kiểm tra độc lập cho Phase 1
    Chạy trực tiếp qua: luajit tests/test_phase1_settings.lua
--]]

-- Thêm thư mục hiện tại vào package.path
package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local Settings = require("settings")
local meta = require("_meta")
local KoreaderTTS = require("main")

local function run_test(name, func)
    io.write(string.format("[TEST] %-48s ... ", name))
    local ok, err = pcall(func)
    if ok then
        print("PASS")
    else
        print("FAIL")
        error(string.format("Test '%s' failed: %s", name, tostring(err)))
    end
end

print("==========================================================")
print("  CHẠY BỘ KIỂM THỬ ĐỘC LẬP - GIAI ĐOẠN 1 (PHASE 1)")
print("==========================================================")

-- Test 1: Kiểm tra metadata plugin
run_test("Metadata _meta.lua hợp lệ", function()
    assert(type(meta) == "table", "_meta.lua phải trả về table")
    assert(meta.name == "koreader_tts", "name phải là koreader_tts")
    assert(meta.category == "read", "category phải là read")
    assert(type(meta.fullname) == "string", "fullname phải là string")
    assert(type(meta.description) == "string", "description phải là string")
    assert(meta.version == "0.1.0", "version phải là 0.1.0")
end)

-- Test 2: Khởi tạo với Default Settings
run_test("Khởi tạo Settings mặc định đầy đủ", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    assert(s:get("server_url") == "http://192.168.1.100:7860")
    assert(s:get("voice") == "vi-VN-NamMinh")
    assert(s:get("speed") == 1.0)
    assert(s:get("preload_count") == 2)
    assert(s:get("preload_cross_page") == true)
    assert(s:get("request_timeout") == 10)
    assert(s:get("chunk_mode") == "sentence")
    assert(s:get("audio_backend") == "auto")
    assert(s:get("highlight_mode") == "gray")
    assert(s:get("auto_turn_page") == true)
    assert(s:get("keep_screen_on") == true)
    assert(s:get("filter_footnotes") == true)
    assert(s:get("last_book_id") == "")
    assert(s:get("last_page") == 1)
    assert(s:get("last_chunk_index") == 1)
end)

-- Test 3: Đọc/ghi cấu hình (set/get)
run_test("Đọc/ghi giá trị hợp lệ", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    local ok = s:set("server_url", "http://10.0.0.5:8000")
    assert(ok == true, "set server_url phải thành công")
    assert(s:get("server_url") == "http://10.0.0.5:8000")

    ok = s:set("voice", "vi-VN-NuMaiPhuong")
    assert(ok == true)
    assert(s:get("voice") == "vi-VN-NuMaiPhuong")

    ok = s:set("speed", 1.25)
    assert(ok == true)
    assert(math.abs(s:get("speed") - 1.25) < 0.001)
end)

-- Test 4: Ràng buộc biên độ & Chuẩn hóa dữ liệu (Clamping & Normalization)
run_test("Kiểm tra Clamping và loại bỏ slash cuối URL", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    -- Speed clamping [0.5, 2.0]
    s:set("speed", 0.1)
    assert(s:get("speed") == 0.5, "speed < 0.5 phải bị clamp về 0.5")
    s:set("speed", 5.0)
    assert(s:get("speed") == 2.0, "speed > 2.0 phải bị clamp về 2.0")

    -- Preload count clamping [1, 3]
    s:set("preload_count", 0)
    assert(s:get("preload_count") == 1, "preload_count < 1 phải bị clamp về 1")
    s:set("preload_count", 10)
    assert(s:get("preload_count") == 3, "preload_count > 3 phải bị clamp về 3")

    -- Timeout clamping [2, 60]
    s:set("request_timeout", 1)
    assert(s:get("request_timeout") == 2, "timeout < 2 phải clamp về 2")
    s:set("request_timeout", 120)
    assert(s:get("request_timeout") == 60, "timeout > 60 phải clamp về 60")

    -- Server URL trailing slash removal
    s:set("server_url", "http://my-tts-server.local:7860///")
    assert(s:get("server_url") == "http://my-tts-server.local:7860", "Dấu slash cuối URL phải được loại bỏ")
end)

-- Test 5: Từ chối giá trị không hợp lệ (Type & Enum safety)
run_test("Từ chối kiểu dữ liệu sai hoặc enum không cho phép", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    -- Sai type
    local ok, err = s:set("speed", "nhanh")
    assert(ok == false, "Phải từ chối string cho speed")

    ok, err = s:set("preload_cross_page", "co")
    assert(ok == false, "Phải từ chối string cho boolean")

    -- Sai enum
    ok, err = s:set("audio_backend", "invalid_backend")
    assert(ok == false, "Phải từ chối backend lạ")

    ok, err = s:set("highlight_mode", "rainbow")
    assert(ok == false, "Phải từ chối highlight_mode lạ")

    -- Key không tồn tại
    ok, err = s:set("non_existent_key", 123)
    assert(ok == false, "Phải từ chối key không có trong schema")
end)

-- Test 6: Lưu trữ và khôi phục (Persistence)
run_test("Lưu vào storage và tải lại nguyên vẹn", function()
    local storage = MockKOReader.createMockSettings()
    local s1 = Settings:new(storage)

    s1:set("server_url", "http://192.168.1.50:5000")
    s1:set("voice", "vi-VN-Custom")
    s1:set("speed", 1.5)
    s1:set("preload_count", 3)
    local save_ok = s1:save()
    assert(save_ok == true, "save() phải thành công")
    assert(storage._saved == true, "storage phải ghi nhận đã save")

    -- Khởi tạo instance s2 từ cùng storage
    local s2 = Settings:new(storage)
    assert(s2:get("server_url") == "http://192.168.1.50:5000")
    assert(s2:get("voice") == "vi-VN-Custom")
    assert(s2:get("speed") == 1.5)
    assert(s2:get("preload_count") == 3)
end)

-- Test 7: Phục hồi khi dữ liệu trong storage bị thiếu hoặc sai lệch
run_test("Khôi phục an toàn khi storage chứa dữ liệu bẩn", function()
    local corrupted_storage = MockKOReader.createMockSettings({
        [Settings.SETTING_KEY] = {
            server_url = "http://corrupted.local:7860",
            speed = "not_a_number",
        }
    })

    local s = Settings:new(corrupted_storage)
    assert(s:get("server_url") == "http://corrupted.local:7860", "Trường hợp lệ phải được giữ lại")
    assert(s:get("speed") == 1.0, "Trường bị hỏng kiểu phải fallback về mặc định an toàn")
    assert(s:get("voice") == "vi-VN-NamMinh", "Trường thiếu phải tự động lấy giá trị mặc định")
    assert(s:get("preload_count") == 2, "Trường thiếu phải tự động lấy giá trị mặc định")
end)

-- Test 8: Khôi phục cấu hình về mặc định (resetDefaults)
run_test("resetDefaults() khôi phục tất cả cài đặt", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    s:set("speed", 1.8)
    s:set("server_url", "http://custom-url:1234")
    s:resetDefaults()

    assert(s:get("speed") == 1.0)
    assert(s:get("server_url") == "http://192.168.1.100:7860")
end)

-- Test 9: An toàn chống Crash (Crash-proof pcall test)
run_test("Crash-proof: Không sập khi storage ném exception", function()
    local faulty_storage = {
        readSetting = function() error("Disk read I/O error!") end,
        saveSetting = function() error("Disk write I/O error!") end,
    }

    local s = Settings:new(faulty_storage)
    assert(s ~= nil, "new() phải thành công ngay cả khi storage read bị lỗi")
    assert(s:get("server_url") == "http://192.168.1.100:7860", "Phải fallback về default an toàn")

    local ok, err = s:save()
    assert(ok == false, "save() phải trả về false")
    assert(type(err) == "string", "save() phải trả về chuỗi thông báo lỗi")
end)

-- Test 10: Tích hợp Top Menu chính trong main.lua (Task 1.3)
run_test("Hook addToMainMenu đăng ký mục menu hợp lệ", function()
    local plugin = KoreaderTTS:new{
        ui = {
            menu = {
                registerToMainMenu = function(self, p) end
            }
        }
    }
    plugin.settings = Settings:new(MockKOReader.createMockSettings())

    local menu_items = {}
    plugin:addToMainMenu(menu_items)

    assert(menu_items.koreader_tts ~= nil, "menu_items phải chứa koreader_tts")
    assert(menu_items.koreader_tts.text == "Đọc bằng giọng nói (TTS)")
    assert(type(menu_items.koreader_tts.sub_item_table) == "table")
    assert(#menu_items.koreader_tts.sub_item_table >= 2)
end)

-- Test 11: Mở hộp thoại cài đặt showSettingsDialog (Task 1.3)
run_test("showSettingsDialog mở ButtonDialog thành công", function()
    MockKOReader.UIManager:reset()
    local plugin = KoreaderTTS:new{
        ui = { menu = {} }
    }
    plugin.settings = Settings:new(MockKOReader.createMockSettings())

    plugin:showSettingsDialog()

    assert(#MockKOReader.UIManager._shown_widgets == 1, "Phải mở 1 dialog hiển thị")
    assert(plugin.settings_dialog ~= nil, "plugin.settings_dialog phải được gán")
    assert(plugin.settings_dialog.title == "Cài đặt TTS Plugin")
end)

-- Test 12: Kích hoạt onStartTTS hiển thị thông báo
run_test("onStartTTS hiển thị InfoMessage không blocking", function()
    MockKOReader.UIManager:reset()
    local plugin = KoreaderTTS:new{
        ui = { menu = {} }
    }
    plugin.settings = Settings:new(MockKOReader.createMockSettings())

    plugin:onStartTTS()

    assert(#MockKOReader.UIManager._shown_widgets == 1, "Phải hiển thị InfoMessage")
    local msg = MockKOReader.UIManager._shown_widgets[1]
    assert(msg.text ~= nil and string.find(msg.text, "VieNeu TTS Plugin"), "Thông báo phải chứa nội dung trạng thái")
end)

print("==========================================================")
print("  TẤT CẢ 12 BÀI KIỂM THỬ ĐỀU ĐÃ VƯỢT QUA THÀNH CÔNG!     ")
print("==========================================================")
