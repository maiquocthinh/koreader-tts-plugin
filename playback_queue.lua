--[[
    playback_queue.lua - Preload Buffer Queue & Playback State Machine for KOReader
    Features:
      - 3-slot Sliding Window (Slot N, N+1, N+2) for zero-gap playback (< 100ms)
      - Cross-page preload & auto page-turn
      - Smart seeking (Next/Prev/Seek) with token-based queue invalidation
      - FSM 4 states: IDLE, PREFETCHING, PLAYING, PAUSED
--]]

local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager or not UIManager then
    UIManager = {
        scheduleIn = function(self, delay, func)
            if type(func) == "function" then func() end
        end
    }
end

local PlaybackQueue = {}
PlaybackQueue.__index = PlaybackQueue

-- Finite State Machine (FSM) states
PlaybackQueue.STATE_IDLE        = "IDLE"
PlaybackQueue.STATE_PREFETCHING = "PREFETCHING"
PlaybackQueue.STATE_PLAYING     = "PLAYING"
PlaybackQueue.STATE_PAUSED      = "PAUSED"

--- Initialize PlaybackQueue
-- @param opts Dependency table:
--   ui              : KOReader self.ui
--   document        : Book document engine (Crengine or MuPDF)
--   chunker         : TextChunker instance
--   tts_client      : TTSClient instance
--   audio_backend   : AudioBackend instance
--   settings        : Settings instance
--   on_chunk_change : function(chunk, page, index, total_on_page)
--   on_state_change : function(old_state, new_state)
--   on_page_turn    : function(new_page)
--   on_finished     : function()
--   on_error        : function(error_msg)
function PlaybackQueue:new(opts)
    local instance = setmetatable({}, self)
    opts = opts or {}

    instance.ui = opts.ui
    instance.document = opts.document or (opts.ui and opts.ui.document)
    instance.chunker = opts.chunker
    instance.tts_client = opts.tts_client
    instance.audio_backend = opts.audio_backend
    instance.settings = opts.settings

    -- Callbacks
    instance.on_chunk_change = opts.on_chunk_change
    instance.on_state_change = opts.on_state_change
    instance.on_page_turn = opts.on_page_turn
    instance.on_finished = opts.on_finished
    instance.on_error = opts.on_error

    -- FSM state
    instance.state = PlaybackQueue.STATE_IDLE

    -- Generation token to prevent race conditions on seeking or stopping
    instance.queue_generation = 0

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

    local chunks = self.chunker:extractPageChunks(self.document, page_num) or {}
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
    for i = 0, 2 do
        local slot = self.slots[i]
        if slot and slot.cancel_fn then
            pcall(slot.cancel_fn)
            slot.cancel_fn = nil
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
        local cached, cache_path = self.tts_client:hasValidCache(chunk.text, self.tts_client.voice)
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
    local expected_gen = self.queue_generation
    local this = self

    slot.cancel_fn = self.tts_client:fetchSpeechAsync(slot.chunk.text, function(success, result)
        -- Invalidate if queue generation has changed
        if this.queue_generation ~= expected_gen then
            return
        end

        -- Verify where this slot currently resides in the window (handles promotion from 1/2 to 0)
        local slot_current_offset = nil
        for i = 0, 2 do
            if this.slots[i] == slot then
                slot_current_offset = i
                break
            end
        end

        if not slot_current_offset then
            return
        end

        slot.cancel_fn = nil

        if success then
            slot.status = "READY"
            slot.wav_path = result

            -- If this slot is now Slot 0 and FSM is awaiting PREFETCHING, trigger playback immediately
            if slot_current_offset == 0 and this.state == PlaybackQueue.STATE_PREFETCHING then
                this:_playSlot(0)
            end
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
                end
            else
                -- Temporary network issue: retry up to 3 times with backoff
                slot.retries = (slot.retries or 0) + 1
                if slot.retries <= 3 then
                    UIManager:scheduleIn(1.5, function()
                        if this.queue_generation == expected_gen and slot.status == "FETCHING" then
                            slot.status = "EMPTY"
                            this:_fetchSlot(slot_current_offset)
                        end
                    end)
                else
                    slot.status = "ERROR"
                    if slot_current_offset == 0 and this.state == PlaybackQueue.STATE_PREFETCHING then
                        this:_setState(PlaybackQueue.STATE_PAUSED)
                        if this.on_error then
                            pcall(this.on_error, _("⚠️ Mất mạng. Đang tạm dừng phát, vui lòng kiểm tra kết nối."))
                        end
                    end
                end
            end
        end
    end)
end

--- Ensure all 3 slots (N, N+1, N+2) are populated and preloading
function PlaybackQueue:_ensureWindow()
    local gen = self.queue_generation

    -- Slot 0: N
    if not self.slots[0] then
        self.slots[0] = self:_createSlotItem(self.current_page, self.current_index, gen)
    end

    -- Slot 1: N+1
    local p1, i1 = self:_getNextPosition(self.current_page, self.current_index)
    if p1 and i1 then
        if not self.slots[1] or self.slots[1].page ~= p1 or self.slots[1].chunk_index ~= i1 then
            if self.slots[1] and self.slots[1].cancel_fn then pcall(self.slots[1].cancel_fn) end
            self.slots[1] = self:_createSlotItem(p1, i1, gen)
        end
    else
        self.slots[1] = nil
    end

    -- Slot 2: N+2
    local p2, i2 = nil, nil
    if p1 and i1 then
        p2, i2 = self:_getNextPosition(p1, i1)
    end
    if p2 and i2 then
        if not self.slots[2] or self.slots[2].page ~= p2 or self.slots[2].chunk_index ~= i2 then
            if self.slots[2] and self.slots[2].cancel_fn then pcall(self.slots[2].cancel_fn) end
            self.slots[2] = self:_createSlotItem(p2, i2, gen)
        end
    else
        self.slots[2] = nil
    end

    -- Trigger fetches for unready slots
    if self.slots[0] and self.slots[0].status == "EMPTY" then
        self:_fetchSlot(0)
    end
    if self.slots[1] and self.slots[1].status == "EMPTY" then
        self:_fetchSlot(1)
    end
    if self.slots[2] and self.slots[2].status == "EMPTY" then
        self:_fetchSlot(2)
    end
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
        self:_fetchSlot(offset)
        return
    end

    self:_setState(PlaybackQueue.STATE_PLAYING)

    -- Update current position
    self.current_page = slot.page
    self.current_index = slot.chunk_index

    -- Save reading session progress to Settings (Task 6.2)
    if self.settings and self.document then
        local book_id = nil
        if type(self.document.getMD5) == "function" then
            local ok, md5 = pcall(self.document.getMD5, self.document)
            if ok and md5 and md5 ~= "" then book_id = tostring(md5) end
        end
        if not book_id then
            book_id = self.document.file or self.document.path or "current_book"
        end
        self.settings:set("last_book_id", tostring(book_id))
        self.settings:set("last_page", slot.page)
        self.settings:set("last_chunk_index", slot.chunk_index)
        self.settings:save()
    end

    -- Notify chunk change for UI update & sentence highlighting
    local chunks_on_page = self:_getPageChunks(self.current_page)
    if self.on_chunk_change then
        pcall(self.on_chunk_change, slot.chunk, self.current_page, self.current_index, #chunks_on_page)
    end

    local expected_gen = self.queue_generation
    local this = self

    -- Trigger audio playback
    local speed = self.settings and self.settings:get("speed") or 1.0
    self.audio_backend:play(slot.wav_path, function(finished)
        -- Ignore callback if queue generation has changed
        if this.queue_generation ~= expected_gen then
            return
        end

        if finished then
            this:_advanceWindow()
        end
    end, { speed = speed })
end

--- Advance Sliding Window when sentence N finishes (Zero-gap transition)
function PlaybackQueue:_advanceWindow()
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

    -- Shift slots: Slot 1 -> Slot 0; Slot 2 -> Slot 1
    self.slots[0] = self.slots[1]
    self.slots[1] = self.slots[2]
    self.slots[2] = nil

    self.current_page = self.slots[0].page
    self.current_index = self.slots[0].chunk_index

    -- Auto turn page when advancing to a new page
    if new_page > old_page then
        self:_turnPage(new_page)
    end

    -- Populate new Slot 2 (N+2) and prefetch
    local p2, i2 = nil, nil
    if self.slots[1] then
        p2, i2 = self:_getNextPosition(self.slots[1].page, self.slots[1].chunk_index)
    end
    if p2 and i2 then
        self.slots[2] = self:_createSlotItem(p2, i2, self.queue_generation)
        if self.slots[2] and self.slots[2].status == "EMPTY" then
            self:_fetchSlot(2)
        end
    end

    -- ZERO-GAP: Play Slot 0 immediately if READY, or skip if ERROR_SKIP
    if self.slots[0].status == "READY" then
        self:_playSlot(0)
    elseif self.slots[0].status == "ERROR_SKIP" then
        self:_advanceWindow()
    else
        self:_setState(PlaybackQueue.STATE_PREFETCHING)
        self:_fetchSlot(0)
    end
end

--- Auto-turn page in KOReader
function PlaybackQueue:_turnPage(new_page)
    if self.ui then
        pcall(function()
            if type(self.ui.onNextPage) == "function" then
                self.ui:onNextPage()
            elseif type(self.ui.gotoPage) == "function" then
                self.ui:gotoPage(new_page)
            elseif type(self.ui.handleEvent) == "function" then
                self.ui:handleEvent({ name = "GotoPage", page = new_page })
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
        if self.audio_backend then
            self.audio_backend:pause()
        end
    end
end

--- Resume audio playback
function PlaybackQueue:resume()
    if self.state == PlaybackQueue.STATE_PAUSED then
        if self.audio_backend and self.audio_backend:isPlaying() then
            self.audio_backend:resume()
            self:_setState(PlaybackQueue.STATE_PLAYING)
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

    self.slots = { [0] = nil, [1] = nil, [2] = nil }
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
    self.slots = { [0] = nil, [1] = nil, [2] = nil }

    -- 5. Rebuild 3-slot window
    self:_ensureWindow()

    -- 6. If Slot 0 is ready, play immediately; otherwise start prefetching
    if self.slots[0] and self.slots[0].status == "READY" then
        self:_playSlot(0)
    else
        self:_setState(PlaybackQueue.STATE_PREFETCHING)
        self:_fetchSlot(0)
    end
end

return PlaybackQueue
