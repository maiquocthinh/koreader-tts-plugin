--[[
    tests/verify_acceptance_phase1.lua
    End-to-End Acceptance Verification script for Phase 1
    Simulates real KOReader lifecycle:
      1. Scan & load plugin via _meta.lua & main.lua (DoD 1.1)
      2. Open book, register ReaderMenu, open settings dialog, edit Server URL (DoD 1.3)
      3. Close app, restart KOReader from persistent storage, verify integrity (DoD 1.2)
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local function step_banner(num, title)
    print(string.format("\n=== [STEP %d] %s ===", num, title))
end

-- =========================================================================
-- VERIFY DoD 1.1: KOReader Plugin Management discovers and loads plugin
-- =========================================================================
step_banner(1, "Verify DoD 1.1: Plugin Discovery & Loading in KOReader")

-- 1. Load metadata file
local meta_chunk, meta_err = loadfile("_meta.lua")
assert(meta_chunk, "ERROR: Cannot read _meta.lua: " .. tostring(meta_err))
local meta = meta_chunk()
assert(type(meta) == "table", "ERROR: _meta.lua did not return table!")
assert(meta.name == "koreader_tts", "ERROR: Invalid plugin name")
assert(meta.category == "read", "ERROR: Plugin category must be 'read'")
print(string.format("  -> Valid metadata: Plugin '%s' | Name: '%s' | Category: '%s'", meta.name, meta.fullname, meta.category))

-- 2. Load main.lua
local main_chunk, main_err = loadfile("main.lua")
assert(main_chunk, "ERROR: Cannot load main.lua: " .. tostring(main_err))
local PluginClass = main_chunk()
assert(type(PluginClass) == "table", "ERROR: main.lua did not return plugin class!")
print("  -> Successfully loaded main.lua, inherits from WidgetContainer.")

-- Initialize mock KOReader Reader UI
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
assert(plugin_instance.settings ~= nil, "ERROR: Plugin failed to initialize settings module!")
print("  [DoD 1.1 RESULT]: PASS - KOReader recognized and initialized plugin successfully.")

-- =========================================================================
-- VERIFY DoD 1.3: Top Menu Integration & Settings Dialog Manipulation
-- =========================================================================
step_banner(2, "Verify DoD 1.3: Tap Menu, Open Dialog, and Edit Configuration")

-- 1. Build KOReader reader menu and call addToMainMenu
local reader_menu = {}
plugin_instance:addToMainMenu(reader_menu)
assert(reader_menu.koreader_tts ~= nil, "ERROR: 'koreader_tts' not added to reader menu!")
print(string.format("  -> Menu item: '%s'", reader_menu.koreader_tts.text))

-- 2. Check sub-menu items
local sub_items = reader_menu.koreader_tts.sub_item_table
assert(#sub_items >= 2, "ERROR: Missing sub-menu items!")
for idx, item in ipairs(sub_items) do
    print(string.format("  -> Sub-item %d: '%s'", idx, item.text))
end

-- 3. Simulate user tapping settings menu item
MockKOReader.UIManager:reset()
local settings_menu_item = nil
for _, item in ipairs(sub_items) do
    if item.text:find("Cài đặt") or item.text:find("Settings") then
        settings_menu_item = item
        break
    end
end
assert(settings_menu_item ~= nil, "ERROR: Settings menu item not found!")
settings_menu_item.callback()

assert(#MockKOReader.UIManager._shown_widgets >= 1, "ERROR: No widget shown via UIManager!")
local settings_dialog = plugin_instance.settings_dialog
assert(settings_dialog ~= nil, "ERROR: settings_dialog not initialized!")
print(string.format("  -> Opened dialog successfully: '%s'", settings_dialog.title))

-- 4. User taps edit Server URL button
local edit_url_button = settings_dialog.buttons[1][1]
print(string.format("  -> User tapped button: '%s'", edit_url_button.text))
MockKOReader.UIManager:reset()
edit_url_button.callback()
MockKOReader.UIManager:runAllScheduled()

-- If button 1 opened the consolidated Server & Voice dialog, click its server url button
if #MockKOReader.UIManager._shown_widgets >= 1 and MockKOReader.UIManager._shown_widgets[1].title:find("Máy chủ") then
    local sv_dialog = MockKOReader.UIManager._shown_widgets[1]
    MockKOReader.UIManager:reset()
    sv_dialog.buttons[1][1].callback()
    MockKOReader.UIManager:runAllScheduled()
end

-- Virtual keyboard opens with InputDialog
assert(#MockKOReader.UIManager._shown_widgets == 1, "ERROR: InputDialog for Server URL not opened!")
local input_dialog = MockKOReader.UIManager._shown_widgets[1]
print(string.format("  -> Input dialog shown: '%s'", input_dialog.title))

-- Simulate user entering new URL and saving
input_dialog.input = "http://192.168.1.222:8000"
local save_button = input_dialog.buttons[1][2]
assert(save_button.text == "Lưu" or save_button.text == "Save", "ERROR: Save button not found in InputDialog!")
save_button.callback()

-- Verify value was updated in memory
assert(plugin_instance.settings:get("server_url") == "http://192.168.1.222:8000",
    "ERROR: Server URL was not updated in settings after saving!")
print(string.format("  -> Updated Server URL to: '%s'", plugin_instance.settings:get("server_url")))
print("  [DoD 1.3 RESULT]: PASS - Menu open, dialog display, and URL update verified.")

-- =========================================================================
-- VERIFY DoD 1.2: Data Persistence across App Restart
-- =========================================================================
step_banner(3, "Verify DoD 1.2: Configuration Persistence across App Restart")

-- 1. Simulate closing KOReader (clear RAM)
print("  -> Simulating app shutdown: clearing RAM instances...")
plugin_instance = nil
PluginClass = nil
_G.G_reader_settings = nil
package.loaded["main"] = nil
package.loaded["settings"] = nil

-- 2. Simulate restarting KOReader
print("  -> Restarting KOReader from storage...")
_G.G_reader_settings = persistent_storage

local reloaded_main = require("main")
local new_plugin_session = reloaded_main:new{
    ui = {
        menu = { registerToMainMenu = function() end }
    }
}
new_plugin_session:init()

-- 3. Verify settings restored after restart
local reloaded_url = new_plugin_session.settings:get("server_url")
print(string.format("  -> Read setting after restart: Server URL = '%s'", reloaded_url))
assert(reloaded_url == "http://192.168.1.222:8000",
    "VERIFICATION ERROR: Server URL did not persist after restart!")

local reloaded_voice = new_plugin_session.settings:get("voice")
assert(reloaded_voice == "vi-VN-NamMinh", "ERROR: Default voice was corrupted!")
print(string.format("  -> Default voice: '%s'", reloaded_voice))
print("  [DoD 1.2 RESULT]: PASS - Saved configuration persisted and restored across restart.")

print("\n=========================================================================")
print("  SUMMARY: ALL 3 ACCEPTANCE CRITERIA VERIFIED 100%!                      ")
print("=========================================================================\n")
