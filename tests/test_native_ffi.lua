--[[
    tests/test_native_ffi.lua - Unit tests for TTSService FFI bridge and fallback
--]]

local TTSService = require("tts_service")

local function run_tests()
    print("=== RUNNING TEST_NATIVE_FFI ===")

    -- 1. Test Native Mode initialization
    local service = TTSService:new{
        server_url = "http://127.0.0.1:8000/v1/audio/speech",
        voice = "duc_tri",
        audio_format = "wav",
        preload_count = 3,
        plugin_dir = "./",
    }

    assert(service ~= nil, "TTSService must be created")
    print("Service initialized. Native mode: " .. tostring(service:isNative()))

    if service:isNative() then
        print("  -> Testing Native Mode operations...")

        -- 2. Test loadPageChunks
        local texts = { "Hôm nay trời rất đẹp.", "Tôi đang đọc sách trên máy e-ink.", "KOReader hoạt động rất mượt mà." }
        local ok_load = service:loadPageChunks(1, texts)
        assert(ok_load == true, "loadPageChunks must succeed")

        -- 3. Test enqueueNextPage
        local next_texts = { "Trang tiếp theo bắt đầu ở đây.", "Câu thứ hai của trang mới." }
        local ok_next = service:enqueueNextPage(2, next_texts)
        assert(ok_next == true, "enqueueNextPage must succeed")

        -- 4. Test slot status
        local status0 = service:getSlotStatus(0)
        assert(status0 ~= nil, "Slot status 0 must not be nil")
        assert(status0.chunk_index == 0, "Chunk index must match")

        -- 5. Test playback controls
        assert(service:play() == true, "play must succeed")
        assert(service:pause() == true, "pause must succeed")
        assert(service:resume() == true, "resume must succeed")
        assert(service:seekChunk(1, 2) == true, "seekChunk must succeed")
        assert(service:stop() == true, "stop must succeed")

        -- 6. Test pollEvents (empty poll must not error)
        local event_count = 0
        service:pollEvents(function(evt)
            event_count = event_count + 1
        end)
        print("  -> Polled events without error (count: " .. event_count .. ")")

        -- 7. Test destroy
        service:destroy()
        print("  -> Native Mode tests PASSED.")
    else
        print("  -> Native library not found in local path (skipping native calls).")
    end

    -- 8. Test Forced Fallback Mode
    print("  -> Testing Fallback Mode...")
    local fallback_service = TTSService:new{
        _force_fallback = true,
        server_url = "http://127.0.0.1:8000/v1/audio/speech",
        voice = "duc_tri",
    }
    assert(fallback_service:isNative() == false, "Fallback service must report isNative() == false")

    local ok_fb_load = fallback_service:loadPageChunks(1, { "Câu 1", "Câu 2" })
    assert(ok_fb_load == true, "Fallback loadPageChunks must succeed")
    assert(fallback_service:play() == true, "Fallback play must succeed")
    assert(fallback_service:pause() == true, "Fallback pause must succeed")
    assert(fallback_service:stop() == true, "Fallback stop must succeed")

    local fb_status = fallback_service:getSlotStatus(0)
    assert(fb_status ~= nil, "Fallback slot status must not be nil")

    fallback_service:destroy()
    print("  -> Fallback Mode tests PASSED.")

    print("=== ALL TEST_NATIVE_FFI PASSED 100% ===")
end

run_tests()
