--[[
    reading_coordinator.lua - Clean Architecture Reading Session Coordinator
    Project: KOReader TTS Plugin
    Layer: Application Service
    Features:
      - 4-state Finite State Machine (IDLE, PREFETCHING, PLAYING, PAUSED)
      - Pure Dependency Inversion: drives reading exclusively via abstract ITtsEngine contract
      - Hardware Audio Output via AudioBackend
      - Zero-gap sentence and cross-page playback transitions
      - E-ink native dirty rect highlighting and automatic page turns
      - Standby screen lock management
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
--   engine          : ITtsEngine implementation (NativeEngine or FallbackEngine)
--   audio_backend   : AudioBackend instance
--   settings        : Settings instance
--   on_chunk_change : function(chunk, page, index, total_on_page)
--   on_state_change : function(old_state, new_state)
--   on_page_turn    : function(new_page)
--   on_finished     : function()
--   on_error        : function(error_msg)
--   on_buffer_change: function()
function ReadingCoordinator:new(opts)
    local instance = setmetatable({}, self)
    opts = opts or {}

    instance.ui = opts.ui
    instance.document = opts.document or (opts.ui and opts.ui.document)
    instance.chunker = opts.chunker
    instance.engine = opts.engine or opts.tts_service
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
    instance.queue_generation = 0
    instance.current_page = 1
    instance.current_index = 1
    instance._page_cache = {}
    instance._poll_active = false

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

--- Get current page number
function PlaybackQueue:getCurrentPage()
    return self.current_page
end

--- Get current chunk index on page
function PlaybackQueue:getCurrentIndex()
    return self.current_index
end

--- Get currently playing chunk table
function PlaybackQueue:getCurrentChunk()
    local chunks = self:_getPageChunks(self.current_page)
    return chunks and chunks[self.current_index] or nil
end

--- Retrieves buffer/playback status for a given slot offset (0 = current, 1..k = upcoming)
-- Used by PlayerWidget buffer indicator dots (●●○○)
function PlaybackQueue:getSlot(offset)
    offset = offset or 0
    local idx0 = (self.current_index - 1) + offset
    local chunks = self:_getPageChunks(self.current_page)
    local chunk = chunks and chunks[idx0 + 1]

    local status = "EMPTY"
    local path = self.engine and self.engine:getSlotPath(idx0)
    if path then
        status = "READY"
    elseif self.engine then
        local st = self.engine:getSlotStatus(idx0)
        if st and st.is_cached then
            status = "READY"
        elseif st and st.is_fetching then
            status = "FETCHING"
        end
    end

    return {
        status = status,
        chunk = chunk,
        wav_path = path,
        page = self.current_page,
        chunk_index = idx0 + 1,
    }
end

--- Get chunks for a specific page (with LRU memory cache)
function PlaybackQueue:_getPageChunks(page_num)
    if self._page_cache[page_num] then
        return self._page_cache[page_num]
    end
    if not self.chunker or not self.document then
        return {}
    end
    local chunks = self.chunker:extractPageChunks(self.document, page_num, self.ui) or {}
    self._page_cache[page_num] = chunks

    -- Prune distant pages from cache to avoid unbounded memory growth on e-ink devices
    local prune_keys = {}
    local count = 0
    for p in pairs(self._page_cache) do
        count = count + 1
        if math.abs(p - page_num) > 3 then
            table.insert(prune_keys, p)
        end
    end
    if count > 6 then
        for _, p in ipairs(prune_keys) do
            self._page_cache[p] = nil
        end
    end

    return chunks
end

--- Turn page on ReaderUI view
function PlaybackQueue:_turnPage(new_page)
    if self.ui and self.ui.paging and type(self.ui.gotoPage) == "function" then
        pcall(self.ui.gotoPage, self.ui, new_page)
    elseif self.ui then
        pcall(function()
            local ok_ev, Event = pcall(require, "ui/event")
            if self.ui.rolling and ok_ev and Event then
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
    if not page_num then
        local on_screen = self.ui and type(self.ui.getCurrentPage) == "function" and self.ui:getCurrentPage()
        page_num = on_screen or self.current_page or 1
    end
    chunk_index = chunk_index or 1
    self:seekChunk(page_num, chunk_index)
end

--- Seek directly to specified sentence (Smart Seeking & Queue Invalidation)
function PlaybackQueue:seekChunk(page_num, chunk_index, auto_play)
    if not self.engine then return end

    local old_page = self.current_page
    self.queue_generation = self.queue_generation + 1
    local gen = self.queue_generation

    -- Stop active audio playback immediately
    if self.audio_backend then
        self.audio_backend:stop()
    end

    if old_page ~= page_num then
        self._page_cache[page_num] = nil
    end

    self.current_page = page_num
    self.current_index = chunk_index

    -- Turn page on ReaderUI only if screen is not already showing this page
    local on_screen = self.ui and type(self.ui.getCurrentPage) == "function" and self.ui:getCurrentPage()
    if not on_screen or on_screen ~= page_num then
        self:_turnPage(page_num)
    end

    -- 1. Extract and load chunks for current page into engine
    local chunks = self:_getPageChunks(page_num)
    local texts = {}
    for _, c in ipairs(chunks) do table.insert(texts, c.text) end
    self.engine:loadPage(gen, texts)

    if chunk_index > 1 then
        self.engine:seekChunk(gen, chunk_index - 1)
    end

    -- 2. Enqueue next page chunks for speculative background prefetching
    local next_page, _ = self:_getNextPosition(page_num, #chunks)
    if next_page and next_page ~= page_num then
        local next_chunks = self:_getPageChunks(next_page)
        local next_texts = {}
        for _, c in ipairs(next_chunks) do table.insert(next_texts, c.text) end
        self.engine:enqueueNextPage(gen + 1, next_texts)
    end

    -- 3. Check if target chunk is already ready on disk (instant 0ms playback)
    if auto_play ~= false then
        local ready_path = self.engine:getSlotPath(chunk_index - 1)
        if ready_path then
            self:_playChunk(ready_path)
        else
            self:_setState(PlaybackQueue.STATE_PREFETCHING)
        end
    else
        self:_setState(PlaybackQueue.STATE_PAUSED)
        if self.on_chunk_change and chunks and chunks[chunk_index] then
            pcall(self.on_chunk_change, chunks[chunk_index], page_num, chunk_index, #chunks)
        end
        if self.on_buffer_change then
            pcall(self.on_buffer_change)
        end
    end

    -- 4. Start non-blocking event polling loop
    self:_startEventLoop()
end

--- Pause audio playback
function PlaybackQueue:pause()
    if self.state == PlaybackQueue.STATE_PLAYING or self.state == PlaybackQueue.STATE_PREFETCHING then
        self:_setState(PlaybackQueue.STATE_PAUSED)
        if self.engine then self.engine:pause() end
        if self.audio_backend then self.audio_backend:pause() end
    end
end

--- Resume audio playback
function PlaybackQueue:resume()
    if self.state == PlaybackQueue.STATE_PAUSED then
        -- Check if user moved page on the reader while paused
        local on_screen = self.ui and type(self.ui.getCurrentPage) == "function" and self.ui:getCurrentPage()
        if on_screen and on_screen > 0 and on_screen ~= self.current_page then
            self:seekChunk(on_screen, 1)
            return
        end

        self:_setState(PlaybackQueue.STATE_PLAYING)
        if self.engine then self.engine:resume() end

        if self.audio_backend and self.audio_backend.isPaused and self.audio_backend:isPaused() then
            self.audio_backend:resume()
        else
            local path = self.engine and self.engine:getSlotPath(self.current_index - 1)
            if path then
                self:_playChunk(path)
            else
                self:_setState(PlaybackQueue.STATE_PREFETCHING)
            end
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
    self._poll_active = false

    if self.engine then self.engine:stop() end
    if self.audio_backend then self.audio_backend:stop() end

    if self.settings then
        self.settings:set("last_page", self.current_page)
        self.settings:set("last_chunk_index", self.current_index)
        self.settings:save()
    end
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

--- Start non-blocking cooperative event polling loop
function PlaybackQueue:_startEventLoop()
    if self._poll_active then return end
    self._poll_active = true
    self:_schedulePollTick()
end

--- Schedule next 50ms cooperative event poll tick
function PlaybackQueue:_schedulePollTick()
    if not self._poll_active or self.state == PlaybackQueue.STATE_IDLE then
        self._poll_active = false
        return
    end

    local this = self
    UIManager:scheduleIn(0.05, function()
        if not this._poll_active or this.state == PlaybackQueue.STATE_IDLE then
            this._poll_active = false
            return
        end
        this:_onPollTick()
        this:_schedulePollTick()
    end)
end

--- Non-blocking event poll tick: consumes events from engine event queue / ringbuffer
function PlaybackQueue:_onPollTick()
    if not self.engine then return end
    local this = self
    local cur_gen = self.queue_generation

    self.engine:pollEvents(function(ev)
        if ev.generation and ev.generation > 0 and ev.generation ~= cur_gen then
            return
        end

        if ev.event_type == 4 then -- EVENT_BUFFER_UPDATED
            if this.on_buffer_change then pcall(this.on_buffer_change) end

            if this.state == PlaybackQueue.STATE_PREFETCHING then
                local current_idx0 = this.current_index - 1
                local path = this.engine:getSlotPath(current_idx0)
                if path then
                    this:_playChunk(path)
                end
            end
        elseif ev.event_type == 5 then -- EVENT_LATENCY_REPORT
            if this.ui_player and this.ui_player.setLatency then
                this.ui_player:setLatency(ev.latency_ms)
            end
        elseif ev.event_type == 6 then -- EVENT_ERROR
            if this.state == PlaybackQueue.STATE_PREFETCHING then
                this:_setState(PlaybackQueue.STATE_PAUSED)
                if this.on_error then
                    pcall(this.on_error, ev.error_message or "Lỗi tải âm thanh từ máy chủ")
                end
            end
        end
    end)
end

--- Dispatch audio playback for a ready chunk
function PlaybackQueue:_playChunk(path)
    self:_setState(PlaybackQueue.STATE_PLAYING)

    local chunks = self:_getPageChunks(self.current_page)
    local chunk = chunks and chunks[self.current_index]
    local speed = self.settings and self.settings:get("speed") or 1.0
    local expected_gen = self.queue_generation
    local this = self

    if self.audio_backend then
        self.audio_backend:play(path, function(finished)
            if this.queue_generation ~= expected_gen then return end
            if finished then
                this:_advanceChunk()
            end
        end, { speed = speed })
    end

    if self.on_chunk_change and chunk then
        pcall(self.on_chunk_change, chunk, self.current_page, self.current_index, #chunks)
    end
    if self.on_buffer_change then
        pcall(self.on_buffer_change)
    end
    if self.settings then
        self.settings:set("last_page", self.current_page)
        self.settings:set("last_chunk_index", self.current_index)
        self.settings:save()
    end
end

--- Advance to next chunk upon playback completion (Zero-gap transition)
function PlaybackQueue:_advanceChunk()
    local chunks = self:_getPageChunks(self.current_page)
    local total_chunks = #chunks

    if self.current_index < total_chunks then
        -- Same page next chunk
        self.current_index = self.current_index + 1
        self.engine:seekChunk(self.queue_generation, self.current_index - 1)

        local next_path = self.engine:getSlotPath(self.current_index - 1)
        if next_path then
            self:_playChunk(next_path)
        else
            self:_setState(PlaybackQueue.STATE_PREFETCHING)
        end
    else
        -- End of current page: advance to next page
        local next_page, next_idx = self:_getNextPosition(self.current_page, self.current_index)
        if not next_page then
            self:stop()
            if self.on_finished then pcall(self.on_finished) end
            return
        end

        self:_turnPage(next_page)
        self.current_page = next_page
        self.current_index = next_idx or 1
        self.queue_generation = self.queue_generation + 1

        local next_chunks = self:_getPageChunks(next_page)
        local next_texts = {}
        for _, c in ipairs(next_chunks) do table.insert(next_texts, c.text) end

        -- Promote prefetched slots in engine
        self.engine:loadPage(self.queue_generation, next_texts)

        -- Speculatively enqueue page after next_page
        local p_after, _ = self:_getNextPosition(next_page, #next_chunks)
        if p_after and p_after ~= next_page then
            local after_chunks = self:_getPageChunks(p_after)
            local after_texts = {}
            for _, c in ipairs(after_chunks) do table.insert(after_texts, c.text) end
            self.engine:enqueueNextPage(self.queue_generation + 1, after_texts)
        end

        local path0 = self.engine:getSlotPath(0)
        if path0 then
            self:_playChunk(path0)
        else
            self:_setState(PlaybackQueue.STATE_PREFETCHING)
        end
    end
end

--- Calculates next reading position, skipping empty illustration/blank pages
function PlaybackQueue:_getNextPosition(page_num, chunk_index)
    local chunks = self:_getPageChunks(page_num)
    if chunk_index < #chunks then
        return page_num, chunk_index + 1
    end
    local total_pages = (self.document and type(self.document.getPageCount) == "function" and self.document:getPageCount()) or 999999
    local next_p = page_num + 1
    while next_p <= total_pages and next_p <= page_num + 10 do
        local next_chunks = self:_getPageChunks(next_p)
        if next_chunks and #next_chunks > 0 then
            return next_p, 1
        end
        next_p = next_p + 1
    end
    return nil, nil
end

--- Calculates previous reading position, skipping empty illustration/blank pages
function PlaybackQueue:_getPrevPosition(page_num, chunk_index)
    if chunk_index > 1 then
        return page_num, chunk_index - 1
    end
    local prev_p = page_num - 1
    while prev_p >= 1 and prev_p >= page_num - 10 do
        local prev_chunks = self:_getPageChunks(prev_p)
        if prev_chunks and #prev_chunks > 0 then
            return prev_p, #prev_chunks
        end
        prev_p = prev_p - 1
    end
    return nil, nil
end

-- Backward compatibility alias
ReadingCoordinator.PlaybackQueue = ReadingCoordinator

return ReadingCoordinator
