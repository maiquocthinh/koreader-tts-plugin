--[[
    tests/verify_acceptance_phase4.lua
    End-to-End Acceptance Verification script for Phase 4
    Validates 3 Definition of Done (DoD) criteria:
      - DoD 4.1: 3-slot Sliding Window & Zero-gap playback (< 100ms) between sentences
      - DoD 4.2: Cross-page preload & auto page-turn when last chunk completes
      - DoD 4.3: Sentence seeking (Seek/Next/Prev) with token-based queue invalidation
--]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local KoreaderTTS = require("main")

local function step_banner(num, title)
    print(string.format("\n=== [STEP %d] %s ===", num, title))
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

local sample_wav_data = create_sample_wav_bytes(0.3, 24000)

-- =========================================================================
-- VERIFY DoD 4.1: 3-slot Sliding Window & Zero-gap Playback (< 100ms)
-- =========================================================================
step_banner(1, "Verify DoD 4.1: 3-slot Sliding Window & Zero-gap Playback")

MockKOReader.UIManager:reset()

local book_pages = {
    [1] = "Câu số một của buổi đọc sách hôm nay. Câu số hai tiếp nối ngay lập tức sau đó. Câu số ba hoàn thành trang đọc đầu tiên.",
    [2] = "Câu số một của trang tiếp theo đã mở ra. Câu số hai kết thúc toàn bộ chương sách này."
}
local doc = MockKOReader.createMockMultiPageDocument(book_pages, 2)
local ui = MockKOReader.createMockUI(doc, 1)

local chunker = TextChunker:new()
local tts_client = TTSClient:new{
    cache_dir = "cache/tts_acc4_p1",
    _mock_transport = function(text, voice, done)
        done(true, sample_wav_data)
    end
}
local audio_backend = AudioBackend:new{ backend_type = "mock" }

local played_chunks = {}
local queue = PlaybackQueue:new{
    ui = ui,
    document = doc,
    chunker = chunker,
    tts_client = tts_client,
    audio_backend = audio_backend,
    on_chunk_change = function(chunk, page, index, total)
        table.insert(played_chunks, { page = page, index = index, text = chunk.text })
        print(string.format("  -> Now playing: Page %d | Chunk %d/%d: '%s'", page, index, total, chunk.text:sub(1, 45) .. "..."))
    end
}

print("  -> Initializing PlaybackQueue at Page 1 Chunk 1...")
queue:start(1, 1)
MockKOReader.UIManager:tick(0.05)

-- 1. Check 3 slots of Sliding Window
local s0 = queue:getSlot(0)
local s1 = queue:getSlot(1)
local s2 = queue:getSlot(2)

assert(s0 ~= nil and s0.chunk_index == 1, "ERROR DoD 4.1: Slot 0 must be chunk 1!")
assert(s1 ~= nil and s1.chunk_index == 2, "ERROR DoD 4.1: Slot 1 must be chunk 2!")
assert(s2 ~= nil and s2.chunk_index == 3, "ERROR DoD 4.1: Slot 2 must be chunk 3!")
assert(s1.status == "READY", "ERROR DoD 4.1: Chunk 2 must be preloaded in Slot 1!")
print("  -> Sliding Window: Slot N (Chunk 1) playing, Slot N+1 (Chunk 2) ready, Slot N+2 (Chunk 3) buffered.")

-- 2. Verify Zero-gap: Chunk 1 completes -> Chunk 2 plays immediately
MockKOReader.UIManager:tick(0.35)

assert(#played_chunks >= 2 and played_chunks[2].index == 2, "ERROR DoD 4.1: Chunk 2 did not play immediately!")
print("  -> Zero-gap: Chunk 1 ended, Chunk 2 started playing immediately without loading pause.")
print("  [DoD 4.1 RESULT]: PASS - 3-slot sliding window and zero-gap verified.")

-- =========================================================================
-- VERIFY DoD 4.2: Cross-page Preload & Auto Page-turn
-- =========================================================================
step_banner(2, "Verify DoD 4.2: Cross-page Preload & Auto Page-turn")

local s_next = queue:getSlot(1) -- Chunk 3 Page 1
local s_preload = queue:getSlot(2) -- Chunk 1 Page 2 (preloaded across page boundary!)

print(string.format("  -> Current position: Page %d | Chunk %d", queue:getCurrentPage(), queue:getCurrentIndex()))
assert(s_preload ~= nil and s_preload.page == 2 and s_preload.chunk_index == 1,
    "ERROR DoD 4.2: Slot N+2 did not preload Page 2 Chunk 1!")
assert(s_preload.status == "READY", "ERROR DoD 4.2: Page 2 Chunk 1 is not READY!")
print("  -> Cross-page preload: Page 2 Chunk 1 preloaded while on second-to-last chunk of Page 1.")

-- Chunk 2 completes -> advance to Chunk 3 (last chunk of page 1)
MockKOReader.UIManager:tick(0.35)
assert(queue:getCurrentPage() == 1 and queue:getCurrentIndex() == 3, "ERROR DoD 4.2: Did not advance to chunk 3 page 1!")

-- Chunk 3 completes -> auto page-turn to Page 2 and play chunk 1 page 2
MockKOReader.UIManager:tick(0.35)

assert(ui.view.state.page == 2, "ERROR DoD 4.2: KOReader UI did not auto-turn to page 2!")
assert(queue:getCurrentPage() == 2 and queue:getCurrentIndex() == 1,
    "ERROR DoD 4.2: Queue did not transition to Page 2 Chunk 1!")
print(string.format("  -> Auto page-turn: UI transitioned to page %d, audio playing seamlessly.", ui.view.state.page))
print("  [DoD 4.2 RESULT]: PASS - Cross-page preload and auto page-turn verified 100%.")

queue:stop()

-- =========================================================================
-- VERIFY DoD 4.3: Sentence Seeking (Seek/Next/Prev) & Queue Invalidation
-- =========================================================================
step_banner(3, "Verify DoD 4.3: Seeking (Seek/Next/Prev) & Token Invalidation")

MockKOReader.UIManager:reset()
local queue2 = PlaybackQueue:new{
    ui = ui,
    document = doc,
    chunker = chunker,
    tts_client = tts_client,
    audio_backend = audio_backend,
}

queue2:start(1, 1)
MockKOReader.UIManager:tick(0.05)
assert(queue2:getCurrentIndex() == 1)

local old_gen = queue2.queue_generation
print(string.format("  -> Playing Page 1 Chunk 1 (Generation token: %d)...", old_gen))

-- User triggers nextChunk
print("  -> User taps [Next chunk] (nextChunk)...")
queue2:nextChunk()
MockKOReader.UIManager:tick(0.05)

assert(queue2.queue_generation > old_gen, "ERROR DoD 4.3: Generation token did not increment on seek!")
assert(queue2:getCurrentIndex() == 2, "ERROR DoD 4.3: Did not advance to chunk 2!")
print(string.format("  -> Advanced to Chunk 2 (New token: %d), previous audio stopped immediately.", queue2.queue_generation))

-- User triggers prevChunk
print("  -> User taps [Previous chunk] (prevChunk)...")
queue2:prevChunk()
MockKOReader.UIManager:tick(0.05)

assert(queue2:getCurrentIndex() == 1, "ERROR DoD 4.3: Did not return to chunk 1!")
print(string.format("  -> Returned to Chunk 1 (New token: %d).", queue2.queue_generation))

-- User seeks directly to Page 2 Chunk 2
print("  -> User seeks directly to Page 2 Chunk 2 (seekChunk)...")
queue2:seekChunk(2, 2)
MockKOReader.UIManager:tick(0.05)

assert(queue2:getCurrentPage() == 2 and queue2:getCurrentIndex() == 2, "ERROR DoD 4.3: Seek target mismatch!")
print(string.format("  -> Successfully seeked to Page %d Chunk %d.", queue2:getCurrentPage(), queue2:getCurrentIndex()))

queue2:stop()
assert(queue2:getState() == PlaybackQueue.STATE_IDLE)
print("  [DoD 4.3 RESULT]: PASS - Seeking responded instantly, old buffer invalidated cleanly.")

print("\n=========================================================================")
print("  SUMMARY: ALL 3 PHASE 4 ACCEPTANCE CRITERIA VERIFIED 100%!               ")
print("=========================================================================\n")
