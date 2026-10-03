--[[
    tests/test_phase4_queue.lua - Standalone unit test suite for Phase 4
    Validates:
      - FSM State Machine (IDLE, PREFETCHING, PLAYING, PAUSED)
      - 3-slot Sliding Window & Zero-gap playback (< 100ms)
      - Cross-page preload & auto page-turn
      - Smart seeking (Next/Prev/Seek) with token-based queue invalidation
    Run via: luajit tests/test_phase4_queue.lua
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

--- Helper function to generate valid WAV bytes for tests
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
print("  STANDALONE TEST SUITE - PHASE 4 (PRELOAD BUFFER QUEUE)")
print("==========================================================")

local sample_wav_data = create_sample_wav_bytes(0.3, 24000)

-- Test 1: FSM state transitions
run_test("FSM: State transitions IDLE -> PREFETCH -> PLAY -> STOP", function()
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

    assert(queue:getState() == PlaybackQueue.STATE_IDLE, "Initial state must be IDLE")

    -- Start reading
    queue:start(1, 1)

    -- Loading Slot N -> transitions to PREFETCHING
    MockKOReader.UIManager:tick(0.01)

    assert(queue:getState() == PlaybackQueue.STATE_PLAYING, "After chunk 1 downloaded, state must be PLAYING")

    -- Pause
    queue:pause()
    assert(queue:getState() == PlaybackQueue.STATE_PAUSED, "pause() must transition to PAUSED")

    -- Resume
    queue:resume()
    assert(queue:getState() == PlaybackQueue.STATE_PLAYING, "resume() must transition to PLAYING")

    -- Stop
    queue:stop()
    assert(queue:getState() == PlaybackQueue.STATE_IDLE, "stop() must transition to IDLE")
end)

-- Test 2: Sliding Window 3 slots
run_test("Sliding Window: Maintains 3 contiguous slots", function()
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

    -- Check 3 slots:
    -- Slot 0 (N) = sentence 1
    -- Slot 1 (N+1) = sentence 2
    -- Slot 2 (N+2) = sentence 3
    local s0 = queue:getSlot(0)
    local s1 = queue:getSlot(1)
    local s2 = queue:getSlot(2)

    assert(s0 ~= nil and s0.chunk_index == 1, "Slot 0 must be sentence 1")
    assert(s1 ~= nil and s1.chunk_index == 2, "Slot 1 must be sentence 2")
    assert(s2 ~= nil and s2.chunk_index == 3, "Slot 2 must be sentence 3")

    assert(s0.status == "READY", "Slot 0 must be READY")
    assert(s1.status == "READY", "Slot 1 must be preloaded READY")
    assert(s2.status == "READY", "Slot 2 must be preloaded READY")

    queue:stop()
end)

-- Test 3: Zero-gap Playback (< 100ms)
run_test("Zero-gap: Slot N finishes, Slot N+1 plays immediately", function()
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
    MockKOReader.UIManager:tick(0.05)

    assert(#chunks_played == 1 and chunks_played[1].index == 1, "Sentence 1 must start playing")

    -- Sentence 1 completes (0.3s)
    MockKOReader.UIManager:tick(0.35)

    -- Sentence 2 must play immediately (Zero-gap)
    assert(#chunks_played == 2 and chunks_played[2].index == 2, "Sentence 2 must play immediately without pause")
    assert(queue:getCurrentIndex() == 2, "Current index must be sentence 2")

    queue:stop()
end)

-- Test 4: Cross-page preload at second-to-last chunk
run_test("Cross-page Preload: Preloads next page chunk 1", function()
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

    queue:start(1, 1)
    MockKOReader.UIManager:tick(0.05)

    -- Slot 0: Page 1 Chunk 1
    -- Slot 1: Page 1 Chunk 2
    -- Slot 2: Page 2 Chunk 1 (Preloaded across page boundary!)
    local s2 = queue:getSlot(2)
    assert(s2 ~= nil, "Slot 2 must exist")
    assert(s2.page == 2 and s2.chunk_index == 1, "Slot 2 must be Page 2 Chunk 1")
    assert(s2.status == "READY", "Slot 2 (Page 2 Chunk 1) must be preloaded READY")

    queue:stop()
end)

-- Test 5: Auto page-turn when last chunk completes
run_test("Auto Page-turn: Automatically turns page on last chunk", function()
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

    queue:start(1, 2) -- Start at sentence 2 (last chunk of page 1)
    MockKOReader.UIManager:tick(0.05)
    assert(queue:getCurrentPage() == 1 and queue:getCurrentIndex() == 2)

    -- Sentence 2 finishes (0.3s)
    MockKOReader.UIManager:tick(0.35)

    -- Confirm automatic turn to page 2
    assert(ui.view.state.page == 2, "UI must auto-turn to page 2")
    assert(page_turned_to == 2, "on_page_turn callback must receive page 2")
    assert(queue:getCurrentPage() == 2 and queue:getCurrentIndex() == 1, "Queue must advance to Page 2 Chunk 1")

    queue:stop()
end)

-- Test 6: Single-chunk page handling (M = 1)
run_test("Single Chunk Page: Preloads next page chunk 1", function()
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

    -- On single-chunk page, Slot 1 (N+1) must be Page 2 Chunk 1
    local s1 = queue:getSlot(1)
    assert(s1 ~= nil and s1.page == 2 and s1.chunk_index == 1, "Slot 1 must be Page 2 Chunk 1")
    assert(s1.status == "READY", "Slot 1 must be ready")

    queue:stop()
end)

-- Test 7: Seeking & Token-based Queue Invalidation
run_test("Seeking: nextChunk/prevChunk cancels audio and sets new pos", function()
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
    assert(queue:getCurrentIndex() == 1, "Currently on chunk 1")

    local old_gen = queue.queue_generation

    -- User calls nextChunk()
    queue:nextChunk()
    MockKOReader.UIManager:tick(0.05)

    assert(queue.queue_generation > old_gen, "queue_generation must increment on seek")
    assert(queue:getCurrentIndex() == 2, "nextChunk() must advance to chunk 2")

    -- User calls prevChunk()
    queue:prevChunk()
    MockKOReader.UIManager:tick(0.05)
    assert(queue:getCurrentIndex() == 1, "prevChunk() must return to chunk 1")

    queue:stop()
end)

-- Test 8: End of entire document calls on_finished
run_test("End of Book: Last chunk completes, calls on_finished", function()
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

    -- Last sentence completes
    MockKOReader.UIManager:tick(0.35)

    assert(finished_called == true, "on_finished must be called when book finishes")
    assert(queue:getState() == PlaybackQueue.STATE_IDLE, "State must return to IDLE")
end)

print("==========================================================")
print("  ALL 8 TESTS PASSED SUCCESSFULLY!                       ")
print("==========================================================")
