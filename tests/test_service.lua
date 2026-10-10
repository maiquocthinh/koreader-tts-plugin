--[[
    tests/test_service.lua - Unit tests for Application Service layer
    Tests:
      - src.service.settings_manager
      - src.service.document_chunker
      - src.service.sleep_timer
      - src.service.reading_coordinator
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local total_tests = 0
local passed_tests = 0

local function run_test(name, fn)
    total_tests = total_tests + 1
    local ok, err = pcall(fn)
    if ok then
        passed_tests = passed_tests + 1
        print(string.format("[TEST] %-52s ... PASS", name))
    else
        print(string.format("[TEST] %-52s ... FAIL", name))
        print("       Error: " .. tostring(err))
    end
end

print("==========================================================")
print("  UNIT TEST SUITE: APPLICATION SERVICE (src/service/)")
print("==========================================================")

local SettingsManager = require("src.service.settings_manager")
local DocumentChunker = require("src.service.document_chunker")
local SleepTimer = require("src.service.sleep_timer")
local ReadingCoordinator = require("src.service.reading_coordinator")

-- 1. SettingsManager Tests
run_test("SettingsManager: default schema and bounds clamping", function()
    local sm = SettingsManager:new()
    assert(sm:get("server_url") == "https://api.openai.com/v1/audio/speech")
    assert(sm:get("speed") == 1.0)
    assert(sm:get("model") == "tts-1")
    assert(sm:get("voice") == "alloy")
    assert(sm:get("preload_count") == 1, "Default preload_count must be 1 (sequential single request)")
    assert(sm:get("min_chunk_chars") == 120, "Default min_chunk_chars must be 120 for natural grouping")

    sm:set("server_url", "http://192.168.1.50:8000")
    assert(sm:get("server_url") == "http://192.168.1.50:8000/v1/audio/speech", "Base URL must normalize to standard speech endpoint")

    sm:set("speed", 3.0)
    assert(sm:get("speed") == 2.0, "Speed must clamp to max 2.0")

    sm:set("speed", 0.1)
    assert(sm:get("speed") == 0.5, "Speed must clamp to min 0.5")

    sm:set("preload_count", 15)
    assert(sm:get("preload_count") == 7, "Preload count must clamp to max 7")

    sm:set("preload_count", -2)
    assert(sm:get("preload_count") == 1, "Preload count must clamp to min 1")

    sm:set("min_chunk_chars", 10)
    assert(sm:get("min_chunk_chars") == 30, "min_chunk_chars must clamp to min 30")

    sm:set("min_chunk_chars", 500)
    assert(sm:get("min_chunk_chars") == 250, "min_chunk_chars must clamp to max 250")
end)

run_test("SettingsManager: pronunciation dictionary CRUD", function()
    local sm = SettingsManager:new()
    sm:resetWordMappings()
    assert(sm:setWordMapping("AI", "Trí tuệ nhân tạo") == true)
    local mappings = sm:getCustomMappings()
    assert(mappings["AI"] == "Trí tuệ nhân tạo")

    assert(sm:removeWordMapping("AI") == true)
    mappings = sm:getCustomMappings()
    assert(mappings["AI"] == nil)
end)

run_test("SettingsManager: persistence across simulated reload", function()
    local mock_storage = {
        _data = {},
        readSetting = function(self, key) return self._data[key] end,
        saveSetting = function(self, key, val) self._data[key] = val end,
    }
    local sm1 = SettingsManager:new(mock_storage)
    sm1:set("voice", "test_persisted_voice")
    sm1:save()

    local sm2 = SettingsManager:new(mock_storage)
    assert(sm2:get("voice") == "test_persisted_voice", "Saved setting must reload from storage")
end)

-- 2. DocumentChunker Tests
run_test("DocumentChunker: text sanitization (footnotes, hyphens, numbers)", function()
    local chunker = DocumentChunker:new()
    local raw = " 42 \nMột đoạn văn bản chứa chú thích[1] và dấu sao* cùng từ ngắt\194\173dòng mềm.\n 42 "
    local cleaned = chunker:sanitize(raw)

    assert(not cleaned:find("%[1%]"), "Must not contain footnote [1]")
    assert(not cleaned:find("%*"), "Must not contain asterisk")
    assert(not cleaned:find("\194\173"), "Must not contain soft hyphen")
    assert(not cleaned:find("^42"), "Must not contain header page number")
    assert(not cleaned:find("42$"), "Must not contain footer page number")
    assert(cleaned:find("Một đoạn văn bản chứa chú thích"), "Body text must be preserved")
end)

run_test("DocumentChunker: pronunciation normalization", function()
    local chunker = DocumentChunker:new()
    local custom = { ["AI"] = "Trí tuệ nhân tạo" }
    local norm = chunker:normalizePronunciation("Công nghệ AI tại TP. Hồ Chí Minh.", custom)
    assert(norm:find("Trí tuệ nhân tạo"), "Must expand custom mapping AI")
    assert(norm:find("Thành phố"), "Must expand standard abbreviation TP.")
end)

run_test("DocumentChunker: 3-tier sentence chunking rules", function()
    local chunker = DocumentChunker:new({ min_chars = 30, max_chars = 300 })

    -- Preserve decimal numbers (3.14 must not split)
    local chunks_dec = chunker:splitSentences("Tỷ lệ thành công là 99.5% trong thử nghiệm khoa học này.")
    assert(#chunks_dec == 1, "Decimal number must not cause sentence split")

    -- Dialogue quotes and questions
    local raw_dialogue = "Anh ấy hỏi: 'Hôm nay bạn có khỏe không?' Tôi trả lời: 'Tôi rất khỏe! Cảm ơn bạn.'"
    local chunks_dia = chunker:splitSentences(raw_dialogue)
    assert(#chunks_dia >= 1, "Must produce valid dialogue chunks")

    -- Safety splitting of very long paragraph > 300 chars
    local long_text = string.rep("Từ này rất dài và lặp đi lặp lại nhiều lần trong một đoạn văn bản tiếng Việt. ", 10)
    local chunks_long = chunker:splitSentences(long_text)
    for _, s in ipairs(chunks_long) do
        assert(#s <= 300, "Safety split must cap chunks under 300 characters")
    end

    -- Smart grouping of short sentences with default min_chars (120) to prevent buffer starvation
    local default_chunker = DocumentChunker:new()
    local short_narrative = "Trời hôm nay nhiều mây. Gió thổi nhẹ qua con đường nhỏ. Một chú mèo nằm sưởi nắng. Tiếng lá xào xạc rơi."
    local chunks_grouped = default_chunker:splitSentences(short_narrative)
    assert(#chunks_grouped < 4, "Short sentences must be grouped into natural larger chunks")
    for idx = 1, #chunks_grouped - 1 do
        assert(#chunks_grouped[idx] >= 100, "Grouped chunk should meet natural audio length threshold")
    end
end)

run_test("DocumentChunker: extraction with bounding boxes from mock doc", function()
    local sample_text = "Hôm nay là một ngày tuyệt vời để đọc sách trên máy đọc sách E-ink chất lượng cao."
    local mock_doc = MockKOReader.createMockCrengineDocument(sample_text)
    local chunker = DocumentChunker:new()
    local chunks = chunker:extractPageChunks(mock_doc, 1, nil)
    assert(#chunks > 0, "Must extract chunks from document")
    assert(chunks[1].bboxes ~= nil, "Chunks must contain bounding boxes for highlight")
end)

-- 3. SleepTimer Tests
run_test("SleepTimer: mode transitions and countdown", function()
    local timed_out = false
    local timer = SleepTimer:new({
        on_timeout = function(reason)
            timed_out = true
        end,
    })
    assert(timer:getMode() == "0")

    timer:setMode("page")
    assert(timer:getMode() == "page")
    timer:onPageTurn(2)
    assert(timed_out == true, "Page mode must trigger on_timeout when page turns")

    timer:setMode("0")
    assert(timer:getMode() == "0")
end)

-- 4. ReadingCoordinator Tests
run_test("ReadingCoordinator: FSM states and 3-slot sliding window", function()
    local sample_text = "Câu số một buổi sáng. Câu số hai buổi trưa. Câu số ba buổi tối đọc sách."
    local mock_doc = MockKOReader.createMockCrengineDocument(sample_text)
    local chunker = DocumentChunker:new()
    local sm = SettingsManager:new()

    local state_history = {}
    local coordinator = ReadingCoordinator:new({
        document = mock_doc,
        chunker = chunker,
        settings = sm,
        on_state_change = function(old_s, new_s)
            table.insert(state_history, new_s)
        end,
    })

    assert(coordinator:getState() == ReadingCoordinator.STATE_IDLE)

    local mock_engine = {
        loadPage = function(self) return true end,
        enqueueNextPage = function(self) return true end,
        seekChunk = function(self) return true end,
        play = function(self) return true end,
        pause = function(self) return true end,
        resume = function(self) return true end,
        stop = function(self) return true end,
        getSlotPath = function(self) return "mock.wav" end,
        getSlotStatus = function(self, idx) return { chunk_index = idx, is_cached = true } end,
        pollEvents = function(self, cb) end,
    }
    local mock_backend = {
        _paused = false,
        _finish_cb = nil,
        play = function(self, path, cb)
            self._finish_cb = cb
        end,
        triggerFinish = function(self)
            if self._finish_cb then
                local cb = self._finish_cb
                self._finish_cb = nil
                cb(true)
            end
        end,
        stop = function(self) self._paused = false; self._finish_cb = nil end,
        pause = function(self) self._paused = true end,
        resume = function(self) self._paused = false end,
        isPaused = function(self) return self._paused end,
    }

    coordinator.engine = mock_engine
    coordinator.audio_backend = mock_backend

    coordinator:start(1, 1)
    assert(coordinator:getState() == ReadingCoordinator.STATE_PLAYING)
    assert(coordinator:getCurrentPage() == 1)
    assert(coordinator:getCurrentIndex() == 1)

    coordinator:pause()
    assert(coordinator:getState() == ReadingCoordinator.STATE_PAUSED)

    coordinator:resume()
    assert(coordinator:getState() == ReadingCoordinator.STATE_PLAYING)

    coordinator:stop()
    assert(coordinator:getState() == ReadingCoordinator.STATE_IDLE)
end)

run_test("ReadingCoordinator: Smart seeking invalidates generation token", function()
    local sample_text = "Câu một thử nghiệm. Câu hai tìm kiếm."
    local mock_doc = MockKOReader.createMockCrengineDocument(sample_text)
    local mock_engine = {
        loadPage = function() return true end,
        enqueueNextPage = function() return true end,
        seekChunk = function() return true end,
        getSlotPath = function() return "mock.wav" end,
    }
    local coordinator = ReadingCoordinator:new({
        document = mock_doc,
        chunker = DocumentChunker:new(),
        settings = SettingsManager:new(),
        engine = mock_engine,
    })

    local gen1 = coordinator.queue_generation
    coordinator:seekChunk(2, 1)
    local gen2 = coordinator.queue_generation
    assert(gen2 > gen1, "Seeking must advance queue_generation token to abort in-flight tasks")
    assert(coordinator:getCurrentPage() == 2)
    assert(coordinator:getCurrentIndex() == 1)
end)

run_test("ReadingCoordinator: Native Rust Engine delegation & event-driven playback", function()
    local sample_text = "Câu một thử nghiệm kiến trúc Native. Câu hai kiểm tra chuyển câu nhanh."
    local mock_doc = MockKOReader.createMockCrengineDocument(sample_text)
    local chunker = DocumentChunker:new()
    local sm = SettingsManager:new()

    local load_page_called = false
    local enqueue_called = false

    local mock_native_engine = {
        isNative = function(self) return true end,
        loadPage = function(self, gen, texts)
            load_page_called = true
            assert(#texts > 0)
            return true
        end,
        enqueueNextPage = function(self, gen, texts)
            enqueue_called = true
            return true
        end,
        seekChunk = function(self, gen, idx) return true end,
        play = function(self) return true end,
        pause = function(self) return true end,
        resume = function(self) return true end,
        stop = function(self) return true end,
        getSlotPath = function(self, idx)
            return "cache/tts/mock_native_" .. tostring(idx) .. ".wav"
        end,
        getSlotStatus = function(self, idx)
            return { chunk_index = idx, is_cached = true, is_fetching = false, duration_seconds = 2.0 }
        end,
        pollEvents = function(self, cb)
            cb({ event_type = 4, chunk_index = 0, generation = 1 })
        end,
    }

    local audio_played_path = nil
    local mock_backend = {
        play = function(self, path, cb, opts)
            audio_played_path = path
            self._cb = cb
        end,
        stop = function(self) self._cb = nil end,
        pause = function(self) end,
        resume = function(self) end,
    }

    local coordinator = ReadingCoordinator:new({
        document = mock_doc,
        chunker = chunker,
        settings = sm,
        engine = mock_native_engine,
        audio_backend = mock_backend,
    })

    coordinator:start(1, 1)
    assert(load_page_called == true, "Native engine loadPage must be called")
    assert(coordinator:getState() == ReadingCoordinator.STATE_PLAYING)
    assert(audio_played_path ~= nil, "Audio backend must play path from getSlotPath")
    assert(audio_played_path:find("mock_native_0.wav"), "Must play chunk 0")

    -- Check virtual getSlot in native mode
    local s0 = coordinator:getSlot(0)
    assert(s0.status == "READY")
    assert(s0.wav_path ~= nil)

    -- Test pause and resume
    coordinator:pause()
    assert(coordinator:getState() == ReadingCoordinator.STATE_PAUSED)
    coordinator:resume()
    assert(coordinator:getState() == ReadingCoordinator.STATE_PLAYING)

    -- Test clean stop
    coordinator:stop()
    assert(coordinator:getState() == ReadingCoordinator.STATE_IDLE)
end)

print("==========================================================")
print(string.format("  ALL %d/%d SERVICE TESTS PASSED!", passed_tests, total_tests))
print("==========================================================")

if passed_tests < total_tests then os.exit(1) end
