--[[
    settings.lua - Persistent configuration management for KOReader TTS Plugin
    Stores configuration in G_reader_settings under the "koreader_tts" key.
--]]

local Settings = {}
Settings.__index = Settings

local SETTING_KEY = "koreader_tts"

-- Default configuration schema
local DEFAULT_SETTINGS = {
    -- 1. Server & Network
    server_url          = "http://192.168.1.100:7860", -- Base API endpoint (OpenAI-compatible)
    api_key             = "",                          -- Bearer token (optional)
    request_timeout     = 10,                          -- Network timeout in seconds

    -- 2. Voice & Audio
    voice               = "vi-VN-NamMinh",             -- Voice identifier
    speed               = 1.0,                         -- Playback speed (0.5 - 2.0)
    audio_backend       = "auto",                      -- "auto" | "android" | "mpv" | "aplay"

    -- 3. Chunking & Buffer
    chunk_mode          = "sentence",                  -- "sentence"
    max_chunk_chars     = 300,                         -- Maximum characters per chunk
    preload_count       = 2,                           -- Number of chunks to preload (1 - 7)
    preload_cross_page  = true,                        -- Preload across pages

    -- 4. E-ink Experience
    highlight_mode      = "gray",                      -- "gray" | "underline" | "none"
    auto_turn_page      = true,                        -- Auto turn page when page finished
    keep_screen_on      = true,                        -- Prevent screen standby while playing
    filter_footnotes    = true,                        -- Filter page numbers and footnotes [1], *

    -- 5. Last session state
    last_book_id        = "",                          -- Last book identifier (MD5 or path)
    last_page           = 1,                           -- Last read page
    last_chunk_index    = 1,                           -- Last read chunk index

    -- 6. Pronunciation dictionary & custom mappings
    custom_pronunciations = {},                        -- Custom table { [orig_word] = "replacement" }
}

-- Default Vietnamese abbreviations to expanded pronunciation for TTS
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

--- Initialize Settings instance
-- @param storage_backend Storage backend (defaults to global G_reader_settings if nil)
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
            -- Merge saved data with default schema (auto-populate new keys)
            for k, default_val in pairs(DEFAULT_SETTINGS) do
                if saved[k] ~= nil and type(saved[k]) == type(default_val) then
                    instance.data[k] = deep_copy(saved[k])
                end
            end
        end
    end

    return instance
end

--- Get value of a setting key
-- @param key Setting key name
-- @return Setting value or nil
function Settings:get(key)
    if key == nil then return nil end
    local val = self.data[key]
    if val ~= nil then
        return val
    end
    return DEFAULT_SETTINGS[key]
end

--- Get a deep copy of all settings
-- @return table Full settings table copy
function Settings:getAll()
    return deep_copy(self.data)
end

--- Set value of a setting key with validation and bounds clamping
-- @param key Setting key name
-- @param value New value
-- @return boolean success, string error_message
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

    -- Specific clamping and normalization
    if key == "speed" then
        value = math.max(0.5, math.min(2.0, value))
    elseif key == "preload_count" then
        value = math.max(1, math.min(7, math.floor(value)))
    elseif key == "request_timeout" then
        value = math.max(2, math.min(60, value))
    elseif key == "max_chunk_chars" then
        value = math.max(50, math.min(1000, math.floor(value)))
    elseif key == "last_page" or key == "last_chunk_index" then
        value = math.max(1, math.floor(value))
    elseif key == "server_url" then
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
        if type(value) ~= "string" or value == "" then
            return false, "Voice cannot be empty"
        end
    end

    self.data[key] = value
    return true
end

--- Persist configuration to storage backend (G_reader_settings)
-- Wrapped in pcall for crash resilience
-- @return boolean success, string error_message
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

--- Reset all settings to default schema values
function Settings:resetDefaults()
    self.data = deep_copy(DEFAULT_SETTINGS)
    return true
end

-- =========================================================================
-- PRONUNCIATION DICTIONARY CRUD
-- =========================================================================

--- Get merged mapping table (Default + Custom)
-- @return table Mapping table { [orig_word] = "replacement" }
function Settings:getWordMappings()
    local merged = deep_copy(DEFAULT_PRONUNCIATION_MAP)
    local custom = self.data.custom_pronunciations or {}
    for word, replacement in pairs(custom) do
        merged[word] = replacement
    end
    return merged
end

--- Get user custom pronunciation mappings
-- @return table Copy of custom mappings
function Settings:getCustomMappings()
    return deep_copy(self.data.custom_pronunciations or {})
end

--- Add or update a custom pronunciation mapping
-- @param word Original word / abbreviation
-- @param replacement Spoken replacement text
-- @return boolean success, string error_message
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

--- Remove a word from custom pronunciation mappings
-- @param word Word to remove
-- @return boolean success
function Settings:removeWordMapping(word)
    if type(word) ~= "string" or not self.data.custom_pronunciations then
        return false
    end
    self.data.custom_pronunciations[word] = nil
    return true
end

--- Reset custom mappings to default dictionary
function Settings:resetWordMappings()
    self.data.custom_pronunciations = {}
    return true
end

-- Export module and schema defaults for testing
Settings.DEFAULT_SETTINGS = DEFAULT_SETTINGS
Settings.DEFAULT_PRONUNCIATION_MAP = DEFAULT_PRONUNCIATION_MAP
Settings.SETTING_KEY = SETTING_KEY

return Settings
