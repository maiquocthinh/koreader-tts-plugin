--[[
    tests/test_phase1_settings.lua - Standalone unit test suite for Phase 1
    Run via: luajit tests/test_phase1_settings.lua
--]]

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
print("  STANDALONE TEST SUITE - PHASE 1 (SETTINGS & FOUNDATION)")
print("==========================================================")

-- Test 1: Plugin metadata validation
run_test("Metadata _meta.lua valid", function()
    assert(type(meta) == "table", "_meta.lua must return table")
    assert(meta.name == "koreader_tts", "name must be koreader_tts")
    assert(meta.category == "read", "category must be read")
    assert(type(meta.fullname) == "string", "fullname must be string")
    assert(type(meta.description) == "string", "description must be string")
    assert(meta.version == "0.1.0", "version must be 0.1.0")
end)

-- Test 2: Default settings initialization
run_test("Initialize default settings schema", function()
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

-- Test 3: Read/write valid settings
run_test("Read/write valid setting values", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    local ok = s:set("server_url", "http://10.0.0.5:8000")
    assert(ok == true, "set server_url must succeed")
    assert(s:get("server_url") == "http://10.0.0.5:8000")

    ok = s:set("voice", "vi-VN-NuMaiPhuong")
    assert(ok == true)
    assert(s:get("voice") == "vi-VN-NuMaiPhuong")

    ok = s:set("speed", 1.25)
    assert(ok == true)
    assert(math.abs(s:get("speed") - 1.25) < 0.001)
end)

-- Test 4: Range clamping & data normalization
run_test("Bounds clamping & trailing slash removal", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    -- Speed clamping [0.5, 2.0]
    s:set("speed", 0.1)
    assert(s:get("speed") == 0.5, "speed < 0.5 must clamp to 0.5")
    s:set("speed", 5.0)
    assert(s:get("speed") == 2.0, "speed > 2.0 must clamp to 2.0")

    -- Preload count clamping [1, 7]
    s:set("preload_count", 0)
    assert(s:get("preload_count") == 1, "preload_count < 1 must clamp to 1")
    s:set("preload_count", 10)
    assert(s:get("preload_count") == 7, "preload_count > 7 must clamp to 7")

    -- Timeout clamping [2, 60]
    s:set("request_timeout", 1)
    assert(s:get("request_timeout") == 2, "timeout < 2 must clamp to 2")
    s:set("request_timeout", 120)
    assert(s:get("request_timeout") == 60, "timeout > 60 must clamp to 60")

    -- Trailing slash removal
    s:set("server_url", "http://my-tts-server.local:7860///")
    assert(s:get("server_url") == "http://my-tts-server.local:7860", "Trailing slashes must be stripped")
end)

-- Test 5: Rejection of invalid types and enums
run_test("Reject invalid types or unallowed enum values", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    -- Type mismatch
    local ok, err = s:set("speed", "fast")
    assert(ok == false, "Must reject string for speed")

    ok, err = s:set("preload_cross_page", "yes")
    assert(ok == false, "Must reject string for boolean")

    -- Invalid enum
    ok, err = s:set("audio_backend", "invalid_backend")
    assert(ok == false, "Must reject unknown audio_backend")

    ok, err = s:set("highlight_mode", "rainbow")
    assert(ok == false, "Must reject unknown highlight_mode")

    -- audio_format validation
    ok, err = s:set("audio_format", "invalid_format")
    assert(ok == false, "Must reject unknown audio_format")
    ok, err = s:set("audio_format", "flac")
    assert(ok == true and s:get("audio_format") == "flac", "Must accept valid flac format")

    -- Non-existent key
    ok, err = s:set("non_existent_key", 123)
    assert(ok == false, "Must reject unknown schema key")
end)

-- Test 6: Persistence to storage
run_test("Persist to storage and reload intact", function()
    local storage = MockKOReader.createMockSettings()
    local s1 = Settings:new(storage)

    s1:set("server_url", "http://192.168.1.50:5000")
    s1:set("voice", "vi-VN-Custom")
    s1:set("speed", 1.5)
    s1:set("preload_count", 3)
    local save_ok = s1:save()
    assert(save_ok == true, "save() must succeed")
    assert(storage._saved == true, "storage must register saved")

    local s2 = Settings:new(storage)
    assert(s2:get("server_url") == "http://192.168.1.50:5000")
    assert(s2:get("voice") == "vi-VN-Custom")
    assert(s2:get("speed") == 1.5)
    assert(s2:get("preload_count") == 3)
end)

-- Test 7: Safe recovery from corrupt storage
run_test("Safe recovery when storage contains corrupt data", function()
    local corrupted_storage = MockKOReader.createMockSettings({
        [Settings.SETTING_KEY] = {
            server_url = "http://corrupted.local:7860",
            speed = "not_a_number",
        }
    })

    local s = Settings:new(corrupted_storage)
    assert(s:get("server_url") == "http://corrupted.local:7860", "Valid fields must be preserved")
    assert(s:get("speed") == 1.0, "Corrupted type must fallback to safe default")
    assert(s:get("voice") == "vi-VN-NamMinh", "Missing fields must take default")
    assert(s:get("preload_count") == 2, "Missing fields must take default")
end)

-- Test 8: Reset to defaults
run_test("resetDefaults() restores all default values", function()
    local storage = MockKOReader.createMockSettings()
    local s = Settings:new(storage)

    s:set("speed", 1.8)
    s:set("server_url", "http://custom-url:1234")
    s:resetDefaults()

    assert(s:get("speed") == 1.0)
    assert(s:get("server_url") == "http://192.168.1.100:7860")
end)

-- Test 9: Crash-proof pcall test
run_test("Crash-proof: No crash on storage I/O exception", function()
    local faulty_storage = {
        readSetting = function() error("Disk read I/O error!") end,
        saveSetting = function() error("Disk write I/O error!") end,
    }

    local s = Settings:new(faulty_storage)
    assert(s ~= nil, "new() must succeed even if readSetting throws")
    assert(s:get("server_url") == "http://192.168.1.100:7860", "Must fallback to safe defaults")

    local ok, err = s:save()
    assert(ok == false, "save() must return false on error")
    assert(type(err) == "string", "save() must return error message string")
end)

-- Test 10: Top menu integration hook
run_test("Hook addToMainMenu registers menu item", function()
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

    assert(menu_items.koreader_tts ~= nil, "menu_items must contain koreader_tts")
    assert(menu_items.koreader_tts.text == "Đọc bằng giọng nói (TTS)")
    assert(type(menu_items.koreader_tts.sub_item_table) == "table")
    assert(#menu_items.koreader_tts.sub_item_table >= 2)
end)

-- Test 11: Settings dialog opening
run_test("showSettingsDialog opens ButtonDialog successfully", function()
    MockKOReader.UIManager:reset()
    local plugin = KoreaderTTS:new{
        ui = { menu = {} }
    }
    plugin.settings = Settings:new(MockKOReader.createMockSettings())

    plugin:showSettingsDialog()

    assert(#MockKOReader.UIManager._shown_widgets == 1, "Must show 1 dialog widget")
    assert(plugin.settings_dialog ~= nil, "plugin.settings_dialog must be set")
    assert(plugin.settings_dialog.title == "Cài đặt TTS Plugin")
end)

-- Test 12: onStartTTS triggering info message
run_test("onStartTTS displays non-blocking InfoMessage", function()
    MockKOReader.UIManager:reset()
    local plugin = KoreaderTTS:new{
        ui = { menu = {} }
    }
    plugin.settings = Settings:new(MockKOReader.createMockSettings())

    plugin:onStartTTS()

    assert(#MockKOReader.UIManager._shown_widgets == 1, "Must show InfoMessage")
    local msg = MockKOReader.UIManager._shown_widgets[1]
    assert(msg.text ~= nil and string.find(msg.text, "TTS Plugin"), "Notice must contain plugin status")
end)

print("==========================================================")
print("  ALL 12 TESTS PASSED SUCCESSFULLY!                      ")
print("==========================================================")
