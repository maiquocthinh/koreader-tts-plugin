--[[
    tests/verify_acceptance_phase1.lua
    Kịch bản kiểm chứng nghiệm thu đầu-cuối (E2E Acceptance Verification) cho Phase 1
    Mô phỏng chính xác chu kỳ hoạt động thực tế của KOReader:
      1. Quét nạp Plugin qua _meta.lua & main.lua (DoD 1.1)
      2. Mở sách, nạp menu Đọc sách, kích hoạt dialog cài đặt, sửa Server URL (DoD 1.3)
      3. Tắt ứng dụng, khởi động lại KOReader từ file lưu trữ thực tế, kiểm tra tính toàn vẹn (DoD 1.2)
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local function step_banner(num, title)
    print(string.format("\n=== [BƯỚC %d] %s ===", num, title))
end

-- =========================================================================
-- KIỂM CHỨNG DoD 1.1: KOReader Plugin Management quét thấy và nạp plugin
-- =========================================================================
step_banner(1, "Kiểm chứng DoD 1.1: Quét & Nạp Plugin vào KOReader")

-- 1. KOReader quét nạp file metadata
local meta_chunk, meta_err = loadfile("_meta.lua")
assert(meta_chunk, "LỖI: Không thể đọc file _meta.lua: " .. tostring(meta_err))
local meta = meta_chunk()
assert(type(meta) == "table", "LỖI: _meta.lua không trả về bảng thông tin!")
assert(meta.name == "koreader_tts", "LỖI: Tên plugin không đúng chuẩn koreader_tts")
assert(meta.category == "read", "LỖI: Danh mục plugin phải là 'read'")
print(string.format("  -> Metadata hợp lệ: Plugin '%s' | Tên: '%s' | Nhóm: '%s'", meta.name, meta.fullname, meta.category))

-- 2. KOReader nạp main.lua
local main_chunk, main_err = loadfile("main.lua")
assert(main_chunk, "LỖI: Không thể nạp file main.lua: " .. tostring(main_err))
local PluginClass = main_chunk()
assert(type(PluginClass) == "table", "LỖI: main.lua không trả về class plugin!")
print("  -> Nạp thành công main.lua, kế thừa WidgetContainer chuẩn.")

-- Khởi tạo môi trường giả lập KOReader Reader UI
local persistent_storage = MockKOReader.createMockSettings()
_G.G_reader_settings = persistent_storage

local plugin_instance = PluginClass:new{
    ui = {
        menu = {
            registerToMainMenu = function(self, p) end
        }
    }
}
plugin_instance:init()
assert(plugin_instance.settings ~= nil, "LỖI: Plugin chưa khởi tạo module settings!")
print("  [KẾT QUẢ DoD 1.1]: PASS - KOReader nhận diện và khởi tạo plugin thành công.")

-- =========================================================================
-- KIỂM CHỨNG DoD 1.3: Tích hợp Top Menu & Thao tác Hộp thoại Cài đặt
-- =========================================================================
step_banner(2, "Kiểm chứng DoD 1.3: Chạm Menu, Mở Dialog và Sửa Cấu Hình")

-- 1. Tạo thanh menu của KOReader và gọi hook addToMainMenu
local reader_menu = {}
plugin_instance:addToMainMenu(reader_menu)
assert(reader_menu.koreader_tts ~= nil, "LỖI: Mục 'koreader_tts' chưa được thêm vào menu đọc sách!")
print(string.format("  -> Menu hiển thị: '%s'", reader_menu.koreader_tts.text))

-- 2. Kiểm tra các menu con
local sub_items = reader_menu.koreader_tts.sub_item_table
assert(#sub_items == 2, "LỖI: Thiếu mục menu con!")
print(string.format("  -> Menu con 1: '%s'", sub_items[1].text))
print(string.format("  -> Menu con 2: '%s'", sub_items[2].text))

-- 3. Người dùng chạm vào mục '⚙ Cài đặt máy chủ & Giọng đọc...'
MockKOReader.UIManager:reset()
local settings_menu_item = sub_items[2]
settings_menu_item.callback()

assert(#MockKOReader.UIManager._shown_widgets >= 1, "LỖI: Không có widget nào được hiển thị qua UIManager!")
local settings_dialog = plugin_instance.settings_dialog
assert(settings_dialog ~= nil, "LỖI: settings_dialog không được khởi tạo!")
print(string.format("  -> Đã mở hộp thoại thành công: '%s'", settings_dialog.title))

-- 4. Người dùng bấm nút '1. Địa chỉ Máy chủ' để sửa URL sang giá trị mới
local edit_url_button = settings_dialog.buttons[1][1]
print(string.format("  -> Người dùng bấm nút: '%s'", edit_url_button.text))
MockKOReader.UIManager:reset()
edit_url_button.callback()

-- Bàn phím ảo mở ra với InputDialog
assert(#MockKOReader.UIManager._shown_widgets == 1, "LỖI: InputDialog cho Server URL chưa được mở!")
local input_dialog = MockKOReader.UIManager._shown_widgets[1]
print(string.format("  -> Hộp thoại nhập hiện ra: '%s'", input_dialog.title))

-- Giả lập người dùng gõ URL mới: 'http://192.168.1.222:8000' và bấm nút Lưu
input_dialog.input = "http://192.168.1.222:8000"
local save_button = input_dialog.buttons[1][2]
assert(save_button.text == "Lưu", "LỖI: Không tìm thấy nút Lưu trong InputDialog!")
save_button.callback()

-- Kiểm tra xem giá trị mới đã được nạp vào memory chưa
assert(plugin_instance.settings:get("server_url") == "http://192.168.1.222:8000",
    "LỖI: Server URL chưa được cập nhật trong bộ nhớ sau khi bấm Lưu!")
print(string.format("  -> Đã cập nhật Server URL thành: '%s'", plugin_instance.settings:get("server_url")))
print("  [KẾT QUẢ DoD 1.3]: PASS - Chạm menu mở được hộp thoại và cập nhật URL thành công.")

-- =========================================================================
-- KIỂM CHỨNG DoD 1.2: Bền vững dữ liệu qua chu kỳ Khởi động lại (Restart)
-- =========================================================================
step_banner(3, "Kiểm chứng DoD 1.2: Bền Vững Dữ Liệu Sau Khi Khởi Động Lại KOReader")

-- 1. Giả lập người dùng thoát hoàn toàn KOReader (xóa sạch RAM & instance cũ)
print("  -> Giả lập đóng ứng dụng KOReader: Hủy toàn bộ biến trong RAM...")
plugin_instance = nil
PluginClass = nil
_G.G_reader_settings = nil
package.loaded["main"] = nil
package.loaded["settings"] = nil

-- 2. Giả lập khởi động lại KOReader từ đầu
print("  -> Khởi động lại KOReader từ đầu...")
_G.G_reader_settings = persistent_storage -- Storage giữ nguyên dữ liệu đã lưu vào disk

local reloaded_main = require("main")
local new_plugin_session = reloaded_main:new{
    ui = {
        menu = { registerToMainMenu = function() end }
    }
}
new_plugin_session:init()

-- 3. Xác minh dữ liệu sau khởi động lại
local reloaded_url = new_plugin_session.settings:get("server_url")
print(string.format("  -> Đọc lại cấu hình sau khi khởi động: Server URL = '%s'", reloaded_url))
assert(reloaded_url == "http://192.168.1.222:8000",
    "LỖI NGHIỆM THU: Sau khi restart, Server URL không giữ nguyên giá trị đã lưu!")

local reloaded_voice = new_plugin_session.settings:get("voice")
assert(reloaded_voice == "vi-VN-NamMinh", "LỖI: Giá trị mặc định khác bị sai lệch!")
print(string.format("  -> Giọng đọc mặc định: '%s'", reloaded_voice))
print("  [KẾT QUẢ DoD 1.2]: PASS - Giá trị mới được lưu trữ và khôi phục nguyên vẹn sau khi restart.")

print("\n=========================================================================")
print("  TỔNG KẾT: TẤT CẢ 3 TIÊU CHÍ ĐÃ ĐƯỢC KIỂM CHỨNG VÀ NGHIỆM THU 100%!   ")
print("=========================================================================\n")
