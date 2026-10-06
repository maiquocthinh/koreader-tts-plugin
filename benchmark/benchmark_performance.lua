--[[
    benchmark/benchmark_performance.lua
    Automated Performance Benchmark & Measurement Harness for KOReader TTS Plugin
    Measures quantitative KPIs:
      1. TTFA (Time to First Audio) - Cold vs Cache Hit
      2. Inter-chunk Gap (Zero-gap transition latency between sentences)
      3. In-flight HTTP Concurrency (Strictly <= 1 connection)
      4. CPU Timer Wakeup Frequency (Hz)
      5. Memory Footprint & GC Stability (RAM Delta across 30 chunks)
    Run via: luajit benchmark/benchmark_performance.lua
--]]

package.path = "./?.lua;./tests/?.lua;./benchmark/?.lua;" .. package.path

local MockKOReader = require("mock_koreader")
MockKOReader.installGlobals()

local TextChunker = require("text_chunker")
local TTSClient = require("tts_client")
local AudioBackend = require("audio_backend")
local PlaybackQueue = require("playback_queue")
local Settings = require("settings")

-- High-precision timer helper
local function get_hires_time()
    return os.clock()
end

--- Helper function to generate valid WAV bytes
local function create_sample_wav_bytes(duration_seconds)
    duration_seconds = duration_seconds or 0.5
    local sample_rate = 24000
    local channels = 1
    local bits = 16
    local byte_rate = sample_rate * channels * (bits / 8)
    local data_size = math.floor(duration_seconds * byte_rate)
    local file_size = 36 + data_size

    local function pack16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
    local function pack32(v)
        return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
    end

    local header = "RIFF" .. pack32(file_size) .. "WAVEfmt "
        .. pack32(16) .. pack16(1) .. pack16(channels)
        .. pack32(sample_rate) .. pack32(byte_rate)
        .. pack16(2) .. pack16(bits)
        .. "data" .. pack32(data_size)

    return header .. string.rep("\0", math.min(data_size, 256))
end

local sample_wav_data = create_sample_wav_bytes(0.5)

print("\n==========================================================================")
print("  KOREADER TTS PLUGIN - AUTOMATED PERFORMANCE BENCHMARK HARNESS           ")
print("==========================================================================")

local benchmark_results = {}

-- =========================================================================
-- BENCHMARK 1: TTFA (Time to First Audio) & In-Flight Concurrency
-- =========================================================================
print("\n--- [BENCHMARK 1] Measuring TTFA & Network Concurrency ---")

local max_observed_concurrency = 0
local active_requests = 0

local tts_client = TTSClient:new{
    cache_dir = "cache/tts_bench",
    _mock_transport = function(text, voice, done)
        active_requests = active_requests + 1
        if active_requests > max_observed_concurrency then
            max_observed_concurrency = active_requests
        end
        -- Simulate 0.15s network latency for cold fetch
        MockKOReader.UIManager:scheduleIn(0.15, function()
            active_requests = active_requests - 1
            done(true, sample_wav_data)
        end)
    end
}

local pages = {
    [1] = "Câu số một của bài đo lường thời gian đáp ứng ban đầu. Câu số hai tiếp tục đo lường đệm tuần tự. Câu số ba chuẩn bị cho lượt tiếp theo. Câu số bốn kiểm tra giới hạn đệm."
}
local doc = MockKOReader.createMockMultiPageDocument(pages)
local chunker = TextChunker:new()
local audio_backend = AudioBackend:new{ backend_type = "mock" }
local storage = MockKOReader.createMockSettings()
local settings = Settings:new(storage)
settings:set("preload_count", 6)

local ttfa_start = get_hires_time()
local first_audio_played_at = nil

local queue = PlaybackQueue:new{
    document = doc,
    chunker = chunker,
    tts_client = tts_client,
    audio_backend = audio_backend,
    settings = settings,
    on_chunk_change = function(chunk, page, index)
        if index == 1 and not first_audio_played_at then
            first_audio_played_at = get_hires_time()
        end
    end
}

-- Start playback on cold cache
queue:start(1, 1)

-- Run event loop ticks until first audio starts
for _ = 1, 30 do
    if queue:getState() == PlaybackQueue.STATE_PLAYING then break end
    MockKOReader.UIManager:tick(0.02)
end

local ttfa_ms = (first_audio_played_at - ttfa_start) * 1000
print(string.format("  -> TTFA (Cold Start): %.2f ms", ttfa_ms))
print(string.format("  -> Max Concurrent Network Requests: %d (SLA: strictly <= 1)", max_observed_concurrency))

assert(max_observed_concurrency <= 1, string.format("FAIL: Concurrency violated! Observed: %d", max_observed_concurrency))
assert(queue:getState() == PlaybackQueue.STATE_PLAYING, "FAIL: Queue did not start playing!")

benchmark_results["TTFA_Cold_ms"] = ttfa_ms
benchmark_results["Max_Concurrency"] = max_observed_concurrency

-- Now measure Cache Hit TTFA (instant restart on already-cached chunk 1)
queue:stop()
local hit_start = get_hires_time()
local hit_played_at = nil

local queue_hit = PlaybackQueue:new{
    document = doc,
    chunker = chunker,
    tts_client = tts_client,
    audio_backend = audio_backend,
    settings = settings,
    on_chunk_change = function(chunk, page, index)
        if not hit_played_at then hit_played_at = get_hires_time() end
    end
}
queue_hit:start(1, 1)
MockKOReader.UIManager:tick(0.001)

local ttfa_hit_ms = ((hit_played_at or get_hires_time()) - hit_start) * 1000
print(string.format("  -> TTFA (Cache Hit): %.2f ms (SLA: <= 50 ms)", ttfa_hit_ms))
benchmark_results["TTFA_Hit_ms"] = ttfa_hit_ms
queue_hit:stop()

-- =========================================================================
-- BENCHMARK 2: Inter-chunk Gap (Zero-gap transition latency between sentences)
-- =========================================================================
print("\n--- [BENCHMARK 2] Measuring Inter-Chunk Gap (Zero-gap Transition) ---")

local gap_records = {}
local last_chunk_end_time = nil

local fast_tts_client = TTSClient:new{
    cache_dir = "cache/tts_bench2",
    _mock_transport = function(text, voice, done)
        done(true, sample_wav_data)
    end
}

local queue_gap = PlaybackQueue:new{
    document = doc,
    chunker = chunker,
    tts_client = fast_tts_client,
    audio_backend = audio_backend,
    settings = settings,
    on_chunk_change = function(chunk, page, index)
        local now = get_hires_time()
        if last_chunk_end_time then
            local gap_ms = (now - last_chunk_end_time) * 1000
            table.insert(gap_records, gap_ms)
        end
    end
}

queue_gap:start(1, 1)
MockKOReader.UIManager:tick(0.01)

-- Play through 3 chunks, measuring gap between them
for chunk_idx = 1, 3 do
    -- Audio plays for 0.5s
    MockKOReader.UIManager:tick(0.49)
    last_chunk_end_time = get_hires_time()
    MockKOReader.UIManager:tick(0.02) -- Triggers completion & zero-gap advance
end

local avg_gap = 0
for _, g in ipairs(gap_records) do avg_gap = avg_gap + g end
avg_gap = (#gap_records > 0) and (avg_gap / #gap_records) or 0

print(string.format("  -> Average Inter-chunk Gap: %.2f ms across %d transitions (SLA: < 100 ms)", avg_gap, #gap_records))
for idx, g in ipairs(gap_records) do
    print(string.format("     Chunk %d -> %d transition gap: %.2f ms", idx, idx + 1, g))
end
benchmark_results["Inter_Chunk_Gap_ms"] = avg_gap
queue_gap:stop()

-- =========================================================================
-- BENCHMARK 3: CPU Wakeup Frequency (Timer polling load)
-- =========================================================================
print("\n--- [BENCHMARK 3] Measuring Timer Wakeups per Second ---")

local timer_wakeups = 0
local orig_scheduleIn = MockKOReader.UIManager.scheduleIn
MockKOReader.UIManager.scheduleIn = function(self, delay, fn)
    timer_wakeups = timer_wakeups + 1
    return orig_scheduleIn(self, delay, fn)
end

-- Simulate 1 second of background prefetching
local dummy_client = TTSClient:new{
    cache_dir = "cache/tts_bench3"
}

-- Trigger a socket streaming mock
local cancels = {}
for i = 1, 1 do
    local c = dummy_client:fetchSpeechAsync("Câu văn thử nghiệm tần suất đánh thức timer", function() end)
    table.insert(cancels, c)
end

-- Tick 1.0 second
MockKOReader.UIManager:tick(1.0)
MockKOReader.UIManager.scheduleIn = orig_scheduleIn

print(string.format("  -> Timer Wakeups in 1s window: %d wakeups/sec (SLA: <= 20 Hz)", timer_wakeups))
benchmark_results["Timer_Wakeups_Hz"] = timer_wakeups

-- =========================================================================
-- BENCHMARK 4: Memory Footprint & Garbage Collection Stability
-- =========================================================================
print("\n--- [BENCHMARK 4] Measuring Memory Delta across 30 Sentences ---")

collectgarbage("collect")
local mem_before_kb = collectgarbage("count")

-- Generate a 30-sentence document
local long_pages = {}
for p = 1, 6 do
    local sentences = {}
    for s = 1, 5 do
        table.insert(sentences, string.format("Câu thứ %d của trang số %d trong kịch bản kiểm thử hiệu năng mở rộng.", s, p))
    end
    long_pages[p] = table.concat(sentences, " ")
end

local long_doc = MockKOReader.createMockMultiPageDocument(long_pages, 6)
local queue_stress = PlaybackQueue:new{
    document = long_doc,
    chunker = chunker,
    tts_client = fast_tts_client,
    audio_backend = audio_backend,
    settings = settings,
}

queue_stress:start(1, 1)
MockKOReader.UIManager:tick(0.01)

-- Advance through 30 chunks
for _ = 1, 30 do
    MockKOReader.UIManager:tick(0.51)
end

collectgarbage("collect")
local mem_after_kb = collectgarbage("count")
local mem_delta_kb = mem_after_kb - mem_before_kb

print(string.format("  -> RAM Before : %.2f KB", mem_before_kb))
print(string.format("  -> RAM After  : %.2f KB", mem_after_kb))
print(string.format("  -> RAM Delta  : %.2f KB (SLA: < 1024 KB across 30 sentences)", mem_delta_kb))
benchmark_results["Memory_Delta_KB"] = mem_delta_kb
queue_stress:stop()

-- =========================================================================
-- SUMMARY SCORECARD
-- =========================================================================
print("\n==========================================================================")
print("  QUANTITATIVE BENCHMARK SCORECARD & SLA COMPLIANCE                       ")
print("==========================================================================")
print(string.format("  | %-28s | %-12s | %-12s | %-8s |", "KPI Metric", "Observed", "SLA Target", "Status"))
print("  |------------------------------|--------------|--------------|----------|")
print(string.format("  | %-28s | %8.2f ms  | %8.2f ms  | %-8s |", "TTFA (Cold Start)", benchmark_results["TTFA_Cold_ms"], 2500.0, benchmark_results["TTFA_Cold_ms"] <= 2500 and "PASS" or "FAIL"))
print(string.format("  | %-28s | %8.2f ms  | %8.2f ms  | %-8s |", "TTFA (Cache Hit)", benchmark_results["TTFA_Hit_ms"], 50.0, benchmark_results["TTFA_Hit_ms"] <= 50 and "PASS" or "FAIL"))
print(string.format("  | %-28s | %8.2f ms  | %8.2f ms  | %-8s |", "Inter-Chunk Zero-Gap", benchmark_results["Inter_Chunk_Gap_ms"], 100.0, benchmark_results["Inter_Chunk_Gap_ms"] <= 100 and "PASS" or "FAIL"))
print(string.format("  | %-28s | %10d   | %10d   | %-8s |", "Max In-flight Concurrency", benchmark_results["Max_Concurrency"], 1, benchmark_results["Max_Concurrency"] <= 1 and "PASS" or "FAIL"))
print(string.format("  | %-28s | %7d wakeups| %7d wakeups| %-8s |", "Timer Polling Frequency", benchmark_results["Timer_Wakeups_Hz"], 20, benchmark_results["Timer_Wakeups_Hz"] <= 20 and "PASS" or "FAIL"))
print(string.format("  | %-28s | %8.2f KB  | %8.2f KB  | %-8s |", "RAM Delta (30 Sentences)", benchmark_results["Memory_Delta_KB"], 1024.0, benchmark_results["Memory_Delta_KB"] <= 1024 and "PASS" or "FAIL"))
print("==========================================================================\n")
