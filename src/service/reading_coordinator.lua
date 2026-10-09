--[[
    reading_coordinator.lua - Reading Session Coordinator & Playback State Machine
    Project: KOReader TTS Plugin
    Layer: Application Service
    Features:
      - 3-slot Sliding Window (Slot N, N+1, N+2) for zero-gap playback
      - Cross-page preload & auto page-turn
      - Smart seeking (Next/Prev/Seek) with token-based queue invalidation
      - FSM 4 states: IDLE, PREFETCHING, PLAYING, PAUSED
      - Abstract ITtsEngine integration with legacy fallback support
--]]

local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager or not UIManager then
    UIManager = {
        scheduleIn = function(self, delay, func)
            if type(func) == "function" then func() end
        end
    }
end

local ReadingCoordinator = {}
ReadingCoordinator.__index = ReadingCoordinator
local PlaybackQueue = ReadingCoordinator

-- Finite State Machine (FSM) states
ReadingCoordinator.STATE_IDLE        = "IDLE"
ReadingCoordinator.STATE_PREFETCHING = "PREFETCHING"
ReadingCoordinator.STATE_PLAYING     = "PLAYING"
ReadingCoordinator.STATE_PAUSED      = "PAUSED"

--- Initialize ReadingCoordinator
-- @param opts Dependency table:
--   ui              : KOReader self.ui
--   document        : Book document engine (Crengine or MuPDF)
--   chunker         : TextChunker instance
--   engine          : ITtsEngine instance (preferred)
--   tts_service     : Legacy TTSService instance (alias for engine)
--   tts_client      : Legacy TTSClient instance
--   audio_backend   : Legacy AudioBackend instance
--   settings        : Settings instance
--   on_chunk_change : function(chunk, page, index, total_on_page)
--   on_state_change : function(old_state, new_state)
--   on_page_turn    : function(new_page)
--   on_finished     : function()
--   on_error        : function(error_msg)
function ReadingCoordinator:new(opts)
    local instance = setmetatable({}, self)
    opts = opts or {}

    instance.ui = opts.ui
    instance.document = opts.document or (opts.ui and opts.ui.document)
    instance.chunker = opts.chunker
    instance.engine = opts.engine or opts.tts_service
    instance.tts_service = instance.engine
    instance.tts_client = opts.tts_client
    instance.audio_backend = opts.audio_backend
    instance.settings = opts.settings

    -- Callbacks
    instance.on_chunk_change = opts.on_chunk_change
    instance.on_state_change = opts.on_state_change
    instance.on_page_turn = opts.on_page_turn
    instance.on_finished = opts.on_finished
    instance.on_error = opts.on_error
    instance.on_buffer_change = opts.on_buffer_change

    -- FSM state
    instance.state = PlaybackQueue.STATE_IDLE

    -- Generation token to prevent race conditions on seeking or stopping
    instance.queue_generation = 0

    -- Active background fetch slot offset (ensures strictly 1 in-flight network request)
    instance._active_fetch_offset = nil

    -- Current playback position
    instance.current_page = 1
    instance.current_index = 1

    -- Sliding Window 3 slots: [0] = Slot N, [1] = Slot N+1, [2] = Slot N+2
    instance.slots = {
        [0] = nil,
        [1] = nil,
        [2] = nil,
    }

    -- Cache of extracted chunks for nearby pages { [page_num] = chunks }
    instance._page_cache = {}

    return instance
end

--- Transition FSM state safely and notify callback
function PlaybackQueue:_setState(new_state)
    if self.state ~= new_state then
        local old_state = self.state
        self.state = new_state

        -- Standby Lock: Prevent screen sleep while playing audio (Task 6.1)
        pcall(function()
            local ok_d, Device = pcall(require, "device")
            if not ok_d or not Device then Device = _G.Device end
            if Device and type(Device.preventStandby) == "function" then
                Device:preventStandby(new_state == PlaybackQueue.STATE_PLAYING)
            end
        end)

        if self.on_state_change then
            pcall(self.on_state_change, old_state, new_state)
        end
    end
end

--- Get current FSM state
function PlaybackQueue:getState()
    return self.state
end

--- Get currently playing chunk table
function PlaybackQueue:getCurrentChunk()
    local slot = self.slots[0]
    return slot and slot.chunk or nil
end

--- Get current page number
function PlaybackQueue:getCurrentPage()
    return self.current_page
end

--- Get current chunk index on page
function PlaybackQueue:getCurrentIndex()
    return self.current_index
end

--- Get slot by offset (0 = Slot N, 1 = Slot N+1, 2 = Slot N+2)
function PlaybackQueue:getSlot(offset)
    return self.slots[offset or 0]
end

--- Get chunks for a specific page (with small LRU cache)
function PlaybackQueue:_getPageChunks(page_num)
    if self._page_cache[page_num] then
        return self._page_cache[page_num]
    end

    if not self.chunker or not self.document then
        return {}
    end

    local chunks = self.chunker:extractPageChunks(self.document, page_num, self.ui) or {}
    self._page_cache[page_num] = chunks

    -- Prune cache if holding more than 5 pages to conserve RAM
    local count = 0
    for _ in pairs(self._page_cache) do count = count + 1 end
    if count > 5 then
        for p, _ in pairs(self._page_cache) do
            if math.abs(p - page_num) > 2 then
                self._page_cache[p] = nil
            end
        end
    end

    return chunks
end

--- Calculate next sentence position after (page_num, chunk_index)
-- Skips empty / illustration pages
-- @return next_page, next_index (or nil, nil if end of document)
function PlaybackQueue:_getNextPosition(page_num, chunk_index)
    local chunks = self:_getPageChunks(page_num)
    local total_chunks = #chunks

    if chunk_index < total_chunks then
        return page_num, chunk_index + 1
    else
        -- End of current page, search subsequent pages skipping blank pages
        local total_pages = 999999
        if self.document and type(self.document.getPageCount) == "function" then
            total_pages = self.document:getPageCount() or total_pages
        end

        local next_page = page_num + 1
        while next_page <= total_pages do
            local next_chunks = self:_getPageChunks(next_page)
            if #next_chunks > 0 then
                return next_page, 1
            end
            next_page = next_page + 1
        end
        return nil, nil
    end
end

--- Calculate previous sentence position before (page_num, chunk_index)
-- Skips empty / illustration pages
-- @return prev_page, prev_index (or nil, nil if at beginning of document)
function PlaybackQueue:_getPrevPosition(page_num, chunk_index)
    if chunk_index > 1 then
        return page_num, chunk_index - 1
    else
        local prev_page = page_num - 1
        while prev_page >= 1 do
            local prev_chunks = self:_getPageChunks(prev_page)
            if #prev_chunks > 0 then
                return prev_page, #prev_chunks
            end
            prev_page = prev_page - 1
        end
        return nil, nil
    end
end

--- Cancel all active fetch tasks in slots
function PlaybackQueue:_cancelActiveFetches()
    self._active_fetch_offset = nil
    for i = 0, 7 do
        local slot = self.slots[i]
        if slot and slot.cancel_fn then
            pcall(slot.cancel_fn)
            slot.cancel_fn = nil
            if slot.status == "FETCHING" then
                slot.status = "EMPTY"
            end
        end
    end
end

--- Create a new SlotItem table
function PlaybackQueue:_createSlotItem(page_num, chunk_index, gen)
    local chunks = self:_getPageChunks(page_num)
    local chunk = chunks[chunk_index]
    if not chunk then
        return nil
    end

    local item = {
        page = page_num,
        chunk_index = chunk_index,
        chunk = chunk,
        status = "EMPTY",
        wav_path = nil,
        generation = gen,
        cancel_fn = nil,
    }

    -- Check if valid cache file already exists on disk
    if self.tts_client then
        local format = (self.settings and self.settings:get("audio_format")) or (self.tts_client and self.tts_client.audio_format) or "wav"
        local cached, cache_path = self.tts_client:hasValidCache(chunk.text, self.tts_client.voice, format)
        if cached then
            item.status = "READY"
            item.wav_path = cache_path
        end
    end

    return item
end

--- Trigger background fetch for a specific slot offset
function PlaybackQueue:_fetchSlot(offset)
    local slot = self.slots[offset]
    if not slot or slot.status == "READY" or slot.status == "FETCHING" then
        return
    end

    if not self.tts_client then
        slot.status = "ERROR"
        return
    end

    slot.status = "FETCHING"
    self._active_fetch_offset = offset
    local expected_gen = self.queue_generation
    local this = self

    local format = (self.settings and self.settings:get("audio_format")) or (self.tts_client and self.tts_client.audio_format) or "wav"
    slot.cancel_fn = self.tts_client:fetchSpeechAsync(slot.chunk.text, function(success, result)
        -- Invalidate if queue generation has changed
        if this.queue_generation ~= expected_gen then
            return
        end

        -- Verify where this slot currently resides in the window (handles promotion from tail to 0)
        local slot_current_offset = nil
        for i = 0, 7 do
            if this.slots[i] == slot then
                slot_current_offset = i
                break
            end
        end

        if not slot_current_offset then
            if this._active_fetch_offset == offset then
                this._active_fetch_offset = nil
            end
            this:_pumpPrefetchQueue()
            return
        end

        slot.cancel_fn = nil
        if this._active_fetch_offset == slot_current_offset or this._active_fetch_offset == offset then
            this._active_fetch_offset = nil
        end

        if success then
            slot.status = "READY"
            slot.wav_path = result

            -- Check if prefetch buffer has enough cushion to begin playback from PREFETCHING state
            if this.state == PlaybackQueue.STATE_PREFETCHING then
                local k = (this.settings and this.settings:get("preload_count")) or 2
                local need_cushion = (k >= 2 and this.slots[1] ~= nil)
                local cushion_ready = (not need_cushion) or (this.slots[1] and this.slots[1].status == "READY")

                if this.slots[0] and this.slots[0].status == "READY" and cushion_ready then
                    this:_playSlot(0)
                end
            end

            -- Notify buffer status update
            if this.on_buffer_change then
                pcall(this.on_buffer_change)
            end

            -- Continue next sequential prefetch in queue
            this:_pumpPrefetchQueue()
        else
            -- Network error classification and resilience handling (Task 6.3)
            local err_str = tostring(result or "")
            local is_permanent_error = err_str:find("HTTP 4") or err_str:find("HTTP 5") or err_str:find("Văn bản rỗng") or err_str:find("RIFF")

            if is_permanent_error then
                -- Permanent server or content error: skip this chunk
                slot.status = "ERROR_SKIP"
                if slot_current_offset == 0 and this.state == PlaybackQueue.STATE_PREFETCHING then
                    if this.on_error then
                        pcall(this.on_error, _("Bỏ qua câu bị lỗi máy chủ..."))
                    end
                    this:nextChunk()
                else
                    this:_pumpPrefetchQueue()
                end
            else
                -- Temporary network issue: retry up to 3 times with backoff
                slot.retries = (slot.retries or 0) + 1
                if slot.retries <= 3 then
                    UIManager:scheduleIn(1.5, function()
                        if this.queue_generation == expected_gen and slot.status == "FETCHING" then
                            slot.status = "EMPTY"
                            this:_pumpPrefetchQueue()
                        end
                    end)
                else
                    slot.status = "ERROR"
                    if slot_current_offset == 0 and this.state == PlaybackQueue.STATE_PREFETCHING then
                        this:_setState(PlaybackQueue.STATE_PAUSED)
                        if this.on_error then
                            pcall(this.on_error, _("⚠️ Mất mạng. Đang tạm dừng phát, vui lòng kiểm tra kết nối."))
                        end
                    else
                        this:_pumpPrefetchQueue()
                    end
                end
            end
        end
    end, { format = format, response_format = format })
end

--- Prioritized Sequential Prefetch Worker
-- Ensures strictly 1 network fetch runs at any time, prioritizing Slot 0, then Slot 1..k in order.
function PlaybackQueue:_pumpPrefetchQueue()
    if self.state == PlaybackQueue.STATE_IDLE then
        return
    end

    local k = (self.settings and self.settings:get("preload_count")) or 2
    k = math.max(1, math.min(7, k))

    -- 1. Slot 0 priority: If Slot 0 is EMPTY, it must be fetched first!
    if self.slots[0] and self.slots[0].status == "EMPTY" then
        -- If a background prefetch is running, cancel it to prioritize Slot 0 immediately
        if self._active_fetch_offset and self._active_fetch_offset ~= 0 then
            local active_slot = self.slots[self._active_fetch_offset]
            if active_slot and active_slot.cancel_fn then
                pcall(active_slot.cancel_fn)
                active_slot.cancel_fn = nil
                active_slot.status = "EMPTY"
            end
            self._active_fetch_offset = nil
        end

        if not self._active_fetch_offset then
            self:_fetchSlot(0)
        end
        return
    end

    -- 2. If a fetch is already in flight, let it complete
    if self._active_fetch_offset ~= nil then
        return
    end

    -- 3. Sequentially find the lowest unready slot from 1 to k
    for offset = 1, k do
        local slot = self.slots[offset]
        if slot and slot.status == "EMPTY" then
            self:_fetchSlot(offset)
            return
        end
    end
end

--- Ensure all slots (Slot 0 + up to K preload slots) are populated and preloading
function PlaybackQueue:_ensureWindow()
    local gen = self.queue_generation
    local k = (self.settings and self.settings:get("preload_count")) or 2
    k = math.max(1, math.min(7, k))

    -- Slot 0: N
    if not self.slots[0] then
        self.slots[0] = self:_createSlotItem(self.current_page, self.current_index, gen)
    end

    -- Slots 1 .. k
    local cur_p = self.current_page
    local cur_i = self.current_index
    for offset = 1, k do
        local next_p, next_i = self:_getNextPosition(cur_p, cur_i)
        if next_p and next_i then
            if not self.slots[offset] or self.slots[offset].page ~= next_p or self.slots[offset].chunk_index ~= next_i then
                if self.slots[offset] and self.slots[offset].cancel_fn then pcall(self.slots[offset].cancel_fn) end
                self.slots[offset] = self:_createSlotItem(next_p, next_i, gen)
            end
            cur_p = next_p
            cur_i = next_i
        else
            self.slots[offset] = nil
        end
    end

    -- Clean up any extra slots beyond k
    for offset = k + 1, 7 do
        if self.slots[offset] then
            if self.slots[offset].cancel_fn then pcall(self.slots[offset].cancel_fn) end
            self.slots[offset] = nil
        end
    end

    -- Start prioritized sequential prefetching (strictly 1 connection at a time)
    self:_pumpPrefetchQueue()
end

--- Play audio at Slot N (offset 0)
function PlaybackQueue:_playSlot(offset)
    offset = offset or 0
    local slot = self.slots[offset]
    if not slot then
        self:stop()
        if self.on_finished then pcall(self.on_finished) end
        return
    end

    if slot.status ~= "READY" or not slot.wav_path then
        self:_setState(PlaybackQueue.STATE_PREFETCHING)
        self:_pumpPrefetchQueue()
        return
    end

    self:_setState(PlaybackQueue.STATE_PLAYING)

    -- Update current position
    self.current_page = slot.page
    self.current_index = slot.chunk_index

    -- CRITICAL: Trigger audio playback immediately so native player starts with 0ms delay!
    local speed = self.settings and self.settings:get("speed") or 1.0
    local expected_gen = self.queue_generation
    local this = self

    self.audio_backend:play(slot.wav_path, function(finished)
        -- Ignore callback if queue generation has changed
        if this.queue_generation ~= expected_gen then
            return
        end

        if finished then
            this:_advanceWindow()
        end
    end, { speed = speed })

    -- In background while audio plays: Cache book ID (avoid recalculating MD5 on every sentence)
    if not self._book_id and self.document then
        local book_id = nil
        if type(self.document.getMD5) == "function" then
            local ok, md5 = pcall(self.document.getMD5, self.document)
            if ok and md5 and md5 ~= "" then book_id = tostring(md5) end
        end
        self._book_id = book_id or self.document.file or self.document.path or "current_book"
    end
    if self.settings and self._book_id then
        self.settings:set("last_book_id", tostring(self._book_id))
        self.settings:set("last_page", slot.page)
        self.settings:set("last_chunk_index", slot.chunk_index)
    end

    -- Notify chunk change for UI update & sentence highlighting (rendered concurrently with audio)
    local chunks_on_page = self:_getPageChunks(self.current_page)
    if self.on_chunk_change then
        pcall(self.on_chunk_change, slot.chunk, self.current_page, self.current_index, #chunks_on_page)
    end

    -- Keep background prefetch worker running during playback
    self:_pumpPrefetchQueue()
end

--- Advance Sliding Window when sentence N finishes (Zero-gap transition)
function PlaybackQueue:_advanceWindow()
    local k = (self.settings and self.settings:get("preload_count")) or 2
    k = math.max(1, math.min(7, k))

    -- Check Slot 1 (N+1)
    local next_slot = self.slots[1]
    if not next_slot then
        -- End of entire book reached
        self:stop()
        if self.on_finished then pcall(self.on_finished) end
        return
    end

    local old_page = self.current_page
    local new_page = next_slot.page

    -- Shift slots down by 1: slots[i] = slots[i+1]
    for i = 0, k - 1 do
        self.slots[i] = self.slots[i + 1]
    end
    self.slots[k] = nil

    self.current_page = self.slots[0].page
    self.current_index = self.slots[0].chunk_index

    -- ZERO-GAP CRITICAL PATH:
    -- Dispatch audio for new Slot 0 IMMEDIATELY upon shifting, before any tail loading or page layout!
    local slot_ready = (self.slots[0] and self.slots[0].status == "READY")
    if slot_ready then
        self:_playSlot(0)
    elseif self.slots[0] and self.slots[0].status == "ERROR_SKIP" then
        self:_advanceWindow()
        return
    else
        self:_setState(PlaybackQueue.STATE_PREFETCHING)
        self:_pumpPrefetchQueue()
    end

    -- Background housekeeping while audio is already playing:
    -- 1. If an active background fetch was in flight on slot i > 0, adjust its tracked offset
    if self._active_fetch_offset then
        if self._active_fetch_offset > 0 then
            self._active_fetch_offset = self._active_fetch_offset - 1
        else
            self._active_fetch_offset = nil
        end
    end

    -- 2. Populate the new tail slot (Slot k)
    if self.slots[k - 1] then
        local pk, ik = self:_getNextPosition(self.slots[k - 1].page, self.slots[k - 1].chunk_index)
        if pk and ik then
            self.slots[k] = self:_createSlotItem(pk, ik, self.queue_generation)
        end
    end

    -- 3. Notify buffer update for UI indicator
    if self.on_buffer_change then
        pcall(self.on_buffer_change)
    end

    -- 4. Auto turn page when advancing to a new page
    if new_page ~= old_page then
        self:_turnPage(new_page)
    end
end

--- Auto-turn page in KOReader
function PlaybackQueue:_turnPage(new_page)
    if self.ui and new_page then
        pcall(function()
            local ok_ev, Event = pcall(require, "ui/event")
            if self.ui.paging and type(self.ui.paging.onGotoPage) == "function" then
                self.ui.paging:onGotoPage(new_page)
            elseif type(self.ui.gotoPage) == "function" then
                self.ui:gotoPage(new_page)
            elseif ok_ev and Event then
                self.ui:handleEvent(Event:new("GotoPage", new_page))
            elseif type(self.ui.onGotoPage) == "function" then
                self.ui:onGotoPage(new_page)
            elseif self.ui.rolling and ok_ev and Event then
                self.ui:handleEvent(Event:new("GotoViewRel", 1))
            elseif type(self.ui.onNextPage) == "function" then
                self.ui:onNextPage()
            end
        end)
    end
    if self.on_page_turn then
        pcall(self.on_page_turn, new_page)
    end
end

--- Start reading session from specified page and chunk
function PlaybackQueue:start(page_num, chunk_index)
    page_num = page_num or self.current_page or 1
    chunk_index = chunk_index or 1

    self:seekChunk(page_num, chunk_index)
end

--- Pause audio playback
function PlaybackQueue:pause()
    if self.state == PlaybackQueue.STATE_PLAYING or self.state == PlaybackQueue.STATE_PREFETCHING then
        self:_setState(PlaybackQueue.STATE_PAUSED)
        if self.tts_service and self.tts_service:isNative() then
            self.tts_service:pause()
        end
        if self.audio_backend then
            self.audio_backend:pause()
        end
        pcall(function()
            local ok_d, Device = pcall(require, "device")
            if not ok_d or not Device then Device = _G.Device end
            if Device and type(Device.preventStandby) == "function" then
                Device:preventStandby(false)
            end
        end)
    end
end

--- Resume audio playback
function PlaybackQueue:resume()
    if self.state == PlaybackQueue.STATE_PAUSED then
        pcall(function()
            local ok_d, Device = pcall(require, "device")
            if not ok_d or not Device then Device = _G.Device end
            if Device and type(Device.preventStandby) == "function" then
                Device:preventStandby(true)
            end
        end)

        if self.tts_service and self.tts_service:isNative() then
            self:_setState(PlaybackQueue.STATE_PLAYING)
            self.tts_service:resume()
        elseif self.audio_backend and self.audio_backend.isPaused and self.audio_backend:isPaused() then
            self:_setState(PlaybackQueue.STATE_PLAYING)
            self.audio_backend:resume()
        else
            self:_playSlot(0)
        end
    end
end

--- Toggle between Play and Pause
function PlaybackQueue:togglePlayPause()
    if self.state == PlaybackQueue.STATE_PLAYING then
        self:pause()
    elseif self.state == PlaybackQueue.STATE_PAUSED then
        self:resume()
    elseif self.state == PlaybackQueue.STATE_IDLE then
        self:start()
    end
end

--- Stop reading session completely
function PlaybackQueue:stop()
    self.queue_generation = self.queue_generation + 1
    self:_cancelActiveFetches()

    if self.tts_service and self.tts_service:isNative() then
        self.tts_service:stop()
    end

    if self.audio_backend then
        self.audio_backend:stop()
    end

    -- Release standby lock
    pcall(function()
        local ok_d, Device = pcall(require, "device")
        if not ok_d or not Device then Device = _G.Device end
        if Device and type(Device.preventStandby) == "function" then
            Device:preventStandby(false)
        end
    end)

    if self.settings then
        self.settings:save()
    end

    self.slots = {}
    self:_setState(PlaybackQueue.STATE_IDLE)
end

--- Navigate to next chunk
function PlaybackQueue:nextChunk()
    local next_page, next_index = self:_getNextPosition(self.current_page, self.current_index)
    if next_page and next_index then
        self:seekChunk(next_page, next_index)
    else
        self:stop()
        if self.on_finished then pcall(self.on_finished) end
    end
end

--- Navigate to previous chunk
function PlaybackQueue:prevChunk()
    local prev_page, prev_index = self:_getPrevPosition(self.current_page, self.current_index)
    if prev_page and prev_index then
        self:seekChunk(prev_page, prev_index)
    end
end

--- Seek directly to specified sentence (Smart Seeking & Queue Invalidation)
function PlaybackQueue:seekChunk(page_num, chunk_index)
    local old_page = self.current_page

    -- 1. Increment queue generation token to invalidate prior tasks
    self.queue_generation = self.queue_generation + 1
    local gen = self.queue_generation

    -- 2. Stop active audio playback
    if self.audio_backend then
        self.audio_backend:stop()
    end

    -- 3. Cancel active in-flight fetches
    self:_cancelActiveFetches()

    -- 4. Set new target position
    self.current_page = page_num
    self.current_index = chunk_index
    self.slots = {}

    -- Turn page on ReaderUI if page changed
    if old_page and old_page ~= page_num then
        self:_turnPage(page_num)
    end

    -- 5. Rebuild sliding window & start sequential prefetch
    self:_ensureWindow()

    -- 6. If Slot 0 is ready and cushion is satisfied, play immediately; otherwise state is PREFETCHING
    local k = (self.settings and self.settings:get("preload_count")) or 2
    local need_cushion = (k >= 2 and self.slots[1] ~= nil)
    local cushion_ready = (not need_cushion) or (self.slots[1] and self.slots[1].status == "READY")

    if self.slots[0] and self.slots[0].status == "READY" and cushion_ready then
        self:_playSlot(0)
    else
        self:_setState(ReadingCoordinator.STATE_PREFETCHING)
        self:_pumpPrefetchQueue()
    end
end

-- Backward compatibility alias
ReadingCoordinator.PlaybackQueue = ReadingCoordinator

return ReadingCoordinator
