--[[
    settings.lua - Quản lý cấu hình bền vững cho KOReader TTS Plugin
    Lưu trữ cấu hình trong G_reader_settings dưới khóa "koreader_tts".
--]]

local Settings = {}
Settings.__index = Settings

local SETTING_KEY = "koreader_tts"

-- Bảng cấu hình mặc định chuẩn (Schema Default)
local DEFAULT_SETTINGS = {
    -- 1. Máy chủ & Mạng
    server_url          = "http://192.168.1.100:7860", -- Base API endpoint (OpenAI / VieNeu)
    api_key             = "",                          -- Bearer token (nếu có)
    request_timeout     = 10,                          -- Timeout mạng (giây)

    -- 2. Giọng đọc & Âm thanh
    voice               = "vi-VN-NamMinh",             -- ID giọng đọc
    speed               = 1.0,                         -- Tốc độ đọc (0.5 - 2.0)
    audio_backend       = "auto",                      -- "auto" | "android" | "mpv" | "aplay"

    -- 3. Ngắt câu & Bộ đệm
    chunk_mode          = "sentence",                  -- "sentence"
    max_chunk_chars     = 300,                         -- Giới hạn ký tự tối đa một câu
    preload_count       = 2,                           -- Số câu tải trước (1 - 3)
    preload_cross_page  = true,                        -- Tải trước xuyên trang

    -- 4. Trải nghiệm E-ink
    highlight_mode      = "gray",                      -- "gray" | "underline" | "none"
    auto_turn_page      = true,                        -- Tự động lật trang khi đọc hết trang
    keep_screen_on      = true,                        -- Giữ màn hình sáng khi đang phát
    filter_footnotes    = true,                        -- Lọc bỏ số trang và chú thích [1], *

    -- 5. Trạng thái phiên đọc gần nhất
    last_book_id        = "",                          -- Định danh sách gần nhất
    last_page           = 1,                           -- Trang đọc gần nhất
    last_chunk_index    = 1,                           -- Vị trí câu đọc dở gần nhất

    -- 6. Từ điển phát âm & Mapping từ đọc (Pronunciation Dictionary)
    custom_pronunciations = {},                        -- Bảng { [từ_gốc] = "từ_phát_âm" } do người dùng tùy biến
}

-- Danh mục mặc định các từ viết tắt tiếng Việt chuẩn sang dạng phát âm đầy đủ cho TTS
local DEFAULT_PRONUNCIATION_MAP = {
    ["TP."]     = "Thành phố",
    ["Tp."]     = "Thành phố",
    ["TS."]     = "Tiến sĩ",
    ["ThS."]    = "Thạc sĩ",
    ["PGS."]    = "Phó giáo sư",
    ["GS."]     = "Giáo sư",
    ["BS."]     = "Bác sĩ",
    ["v.v."]    = "vân vân",
    ["ĐH"]      = "Đại học",
    ["CNTT"]    = "Công nghệ thông tin",
    ["NXB"]     = "Nhà xuất bản",
    ["K/g"]     = "Kính gửi",
}

local function deep_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = deep_copy(orig_value)
        end
    else
        copy = orig
    end
    return copy
end

--- Khởi tạo đối tượng quản lý Settings
-- @param storage_backend Đối tượng lưu trữ (mặc định sử dụng global G_reader_settings nếu nil)
-- @return Settings instance
function Settings:new(storage_backend)
    local instance = setmetatable({}, self)
    instance.storage = storage_backend or _G.G_reader_settings
    instance.data = deep_copy(DEFAULT_SETTINGS)

    if instance.storage and type(instance.storage.readSetting) == "function" then
        local ok, saved = pcall(function()
            return instance.storage:readSetting(SETTING_KEY)
        end)
        if ok and type(saved) == "table" then
            -- Hợp nhất dữ liệu đã lưu với schema mặc định (tự động bổ sung các key mới nếu có cập nhật)
            for k, default_val in pairs(DEFAULT_SETTINGS) do
                if saved[k] ~= nil and type(saved[k]) == type(default_val) then
                    instance.data[k] = deep_copy(saved[k])
                end
            end
        end
    end

    return instance
end

--- Lấy giá trị của một khóa cấu hình
-- @param key Tên khóa
-- @return Giá trị cấu hình hoặc nil nếu không tồn tại
function Settings:get(key)
    if key == nil then return nil end
    local val = self.data[key]
    if val ~= nil then
        return val
    end
    return DEFAULT_SETTINGS[key]
end

--- Lấy bản sao toàn bộ bảng cấu hình
-- @return table Chứa toàn bộ cấu hình hiện tại
function Settings:getAll()
    return deep_copy(self.data)
end

--- Cập nhật giá trị một khóa cấu hình kèm kiểm tra kiểu và biên độ hợp lệ
-- @param key Tên khóa
-- @param value Giá trị mới
-- @return boolean Thành công hay thất bại, string Thông báo lỗi nếu thất bại
function Settings:set(key, value)
    if key == nil then
        return false, "Key cannot be nil"
    end
    if DEFAULT_SETTINGS[key] == nil then
        return false, "Unknown setting key: " .. tostring(key)
    end

    local expected_type = type(DEFAULT_SETTINGS[key])
    if type(value) ~= expected_type then
        return false, string.format("Invalid type for %s: expected %s, got %s", key, expected_type, type(value))
    end

    -- Kiểm tra ràng buộc và chuẩn hóa từng trường cụ thể
    if key == "speed" then
        -- Clamping tốc độ trong khoảng [0.5, 2.0]
        value = math.max(0.5, math.min(2.0, value))
    elseif key == "preload_count" then
        -- Clamping số câu tải trước trong khoảng [1, 3]
        value = math.max(1, math.min(3, math.floor(value)))
    elseif key == "request_timeout" then
        -- Clamping timeout trong khoảng [2, 60]
        value = math.max(2, math.min(60, value))
    elseif key == "max_chunk_chars" then
        value = math.max(50, math.min(1000, math.floor(value)))
    elseif key == "last_page" or key == "last_chunk_index" then
        value = math.max(1, math.floor(value))
    elseif key == "server_url" then
        -- Loại bỏ ký tự gạch chéo cuối nếu có
        value = value:gsub("/+$", "")
    elseif key == "audio_backend" then
        local allowed = { auto = true, android = true, mpv = true, aplay = true }
        if not allowed[value] then
            return false, "Invalid audio_backend: " .. tostring(value)
        end
    elseif key == "highlight_mode" then
        local allowed = { gray = true, underline = true, none = true }
        if not allowed[value] then
            return false, "Invalid highlight_mode: " .. tostring(value)
        end
    elseif key == "voice" then
        -- ponytail: static voice ID check, upgrade to dynamic list verification in Phase 3 via GET /v1/voices
        if type(value) ~= "string" or value == "" then
            return false, "Voice cannot be empty"
        end
    end

    self.data[key] = value
    return true
end

--- Ghi toàn bộ dữ liệu cấu hình vào bộ nhớ lưu trữ bền vững (G_reader_settings)
-- Bọc toàn bộ thao tác trong pcall để chống văng lỗi sập ứng dụng (Crash-proof)
-- @return boolean Thành công hay thất bại, string Lỗi nếu có
function Settings:save()
    if not self.storage then
        return false, "No storage backend available"
    end

    if type(self.storage.saveSetting) ~= "function" then
        return false, "Storage backend does not implement saveSetting"
    end

    local ok, err = pcall(function()
        self.storage:saveSetting(SETTING_KEY, self.data)
        if type(self.storage.flush) == "function" then
            self.storage:flush()
        end
    end)

    if not ok then
        return false, tostring(err)
    end
    return true
end

--- Khôi phục toàn bộ cấu hình về giá trị mặc định ban đầu
function Settings:resetDefaults()
    self.data = deep_copy(DEFAULT_SETTINGS)
    return true
end

-- =========================================================================
-- QUẢN LÝ TỪ ĐIỂN PHÁT ÂM (PRONUNCIATION DICTIONARY CRUD)
-- =========================================================================

--- Lấy bảng hợp nhất tất cả các quy tắc mapping từ phát âm (Mặc định + Tùy biến)
-- @return table Bảng mapping { [từ_gốc] = "từ_phát_âm" }
function Settings:getWordMappings()
    local merged = deep_copy(DEFAULT_PRONUNCIATION_MAP)
    local custom = self.data.custom_pronunciations or {}
    for word, replacement in pairs(custom) do
        merged[word] = replacement
    end
    return merged
end

--- Lấy danh sách từ mapping do người dùng tự cấu hình
-- @return table Bảng sao chép các mapping tùy biến
function Settings:getCustomMappings()
    return deep_copy(self.data.custom_pronunciations or {})
end

--- Thêm mới hoặc cập nhật một cặp từ phát âm tùy biến
-- @param word Từ gốc (viết tắt hoặc từ cần sửa)
-- @param replacement Từ phát âm thay thế
-- @return boolean Thành công hay thất bại, string Lỗi nếu có
function Settings:setWordMapping(word, replacement)
    if type(word) ~= "string" or word == "" then
        return false, "Word cannot be empty"
    end
    if type(replacement) ~= "string" or replacement == "" then
        return false, "Replacement cannot be empty"
    end

    if type(self.data.custom_pronunciations) ~= "table" then
        self.data.custom_pronunciations = {}
    end
    self.data.custom_pronunciations[word] = replacement
    return true
end

--- Xóa một từ khỏi danh mục tùy biến của người dùng
-- @param word Từ cần xóa
-- @return boolean Thành công hay thất bại
function Settings:removeWordMapping(word)
    if type(word) ~= "string" or not self.data.custom_pronunciations then
        return false
    end
    self.data.custom_pronunciations[word] = nil
    return true
end

--- Xóa sạch danh sách từ tùy biến, khôi phục về từ điển mặc định ban đầu
function Settings:resetWordMappings()
    self.data.custom_pronunciations = {}
    return true
end

-- Export module và bảng schema mặc định (hỗ trợ kiểm thử)
Settings.DEFAULT_SETTINGS = DEFAULT_SETTINGS
Settings.DEFAULT_PRONUNCIATION_MAP = DEFAULT_PRONUNCIATION_MAP
Settings.SETTING_KEY = SETTING_KEY

return Settings
