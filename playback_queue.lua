--[[
    playback_queue.lua - Quản lý Hàng đợi Đệm & Máy trạng thái phát TTS cho KOReader
    Triển khai:
      - Sliding Window 3 vị trí (Slot N, N+1, N+2) cho độ trễ giữa 2 câu < 100ms (Zero-gap)
      - Tải trước xuyên trang (Cross-page Preload) & Tự động lật trang (Auto Page-turn)
      - Điều hướng câu (Next/Prev/Seek) kèm hủy đệm thông minh (Queue Invalidation theo token)
      - FSM 4 trạng thái: IDLE, PREFETCHING, PLAYING, PAUSED
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

-- Các trạng thái của Máy trạng thái hữu hạn (FSM)
PlaybackQueue.STATE_IDLE        = "IDLE"
PlaybackQueue.STATE_PREFETCHING = "PREFETCHING"
PlaybackQueue.STATE_PLAYING     = "PLAYING"
PlaybackQueue.STATE_PAUSED      = "PAUSED"

--- Khởi tạo PlaybackQueue
-- @param opts Bảng các thành phần phụ thuộc:
--   ui              : đối tượng self.ui của KOReader
--   document        : đối tượng tài liệu sách (Crengine hoặc MuPDF)
--   chunker         : instance TextChunker
--   tts_client      : instance TTSClient
--   audio_backend   : instance AudioBackend
--   settings        : instance Settings
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

    -- Trạng thái FSM
    instance.state = PlaybackQueue.STATE_IDLE

    -- Token thế hệ hàng đợi chống race condition khi tua câu hoặc dừng
    instance.queue_generation = 0

    -- Vị trí câu hiện tại
    instance.current_page = 1
    instance.current_index = 1

    -- Sliding Window 3 slots: [0] = Slot N, [1] = Slot N+1, [2] = Slot N+2
    instance.slots = {
        [0] = nil,
        [1] = nil,
        [2] = nil,
    }

    -- Cache câu của các trang gần kề { [page_num] = chunks }
    instance._page_cache = {}

    return instance
end

--- Chuyển đổi trạng thái FSM an toàn và gọi callback
function PlaybackQueue:_setState(new_state)
    if self.state ~= new_state then
        local old_state = self.state
        self.state = new_state
        if self.on_state_change then
            pcall(self.on_state_change, old_state, new_state)
        end
    end
end

--- Lấy trạng thái hiện tại
function PlaybackQueue:getState()
    return self.state
end

--- Lấy đối tượng chunk câu đang phát
function PlaybackQueue:getCurrentChunk()
    local slot = self.slots[0]
    return slot and slot.chunk or nil
end

--- Lấy số trang hiện tại
function PlaybackQueue:getCurrentPage()
    return self.current_page
end

--- Lấy thứ tự câu hiện tại trên trang
function PlaybackQueue:getCurrentIndex()
    return self.current_index
end

--- Lấy thông tin slot theo offset (0 = Slot N, 1 = Slot N+1, 2 = Slot N+2)
function PlaybackQueue:getSlot(offset)
    return self.slots[offset or 0]
end

--- Lấy danh sách câu của một trang (có cache bộ nhớ nhỏ)
function PlaybackQueue:_getPageChunks(page_num)
    if self._page_cache[page_num] then
        return self._page_cache[page_num]
    end

    if not self.chunker or not self.document then
        return {}
    end

    local chunks = self.chunker:extractPageChunks(self.document, page_num) or {}
    self._page_cache[page_num] = chunks

    -- Dọn dẹp cache nếu lưu quá 5 trang để tiết kiệm RAM
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

--- Tính toán vị trí kế tiếp sau (page_num, chunk_index)
-- @return next_page, next_index (hoặc nil, nil nếu hết sách)
function PlaybackQueue:_getNextPosition(page_num, chunk_index)
    local chunks = self:_getPageChunks(page_num)
    local total_chunks = #chunks

    if chunk_index < total_chunks then
        return page_num, chunk_index + 1
    else
        -- Hết trang hiện tại, duyệt các trang tiếp theo (bỏ qua các trang trống/hình ảnh)
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

--- Tính toán vị trí trước đó trước (page_num, chunk_index)
-- @return prev_page, prev_index (hoặc nil, nil nếu đang ở đầu sách)
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

--- Hủy bỏ mọi tác vụ tải đang diễn ra trong các slots
function PlaybackQueue:_cancelActiveFetches()
    for i = 0, 2 do
        local slot = self.slots[i]
        if slot and slot.cancel_fn then
            pcall(slot.cancel_fn)
            slot.cancel_fn = nil
        end
    end
end

--- Tạo một SlotItem mới
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

    -- Kiểm tra cache đĩa đã có sẵn chưa
    if self.tts_client then
        local cached, cache_path = self.tts_client:hasValidCache(chunk.text, self.tts_client.voice)
        if cached then
            item.status = "READY"
            item.wav_path = cache_path
        end
    end

    return item
end

--- Kích hoạt tải âm thanh ngầm cho một slot cụ thể
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
        -- Kiểm tra nếu thế hệ đã đổi thì bỏ qua kết quả
        if this.queue_generation ~= expected_gen then
            return
        end

        -- Kiểm tra xem slot này còn tồn tại trong window không (có thể đã được thăng hạng từ slot 1/2 lên slot 0)
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

            -- Nếu slot hiện đang ở vị trí Slot N (offset 0) và FSM đang chờ PREFETCHING -> Kích hoạt phát ngay
            if slot_current_offset == 0 and this.state == PlaybackQueue.STATE_PREFETCHING then
                this:_playSlot(0)
            end
        else
            slot.status = "ERROR"
            if slot_current_offset == 0 and this.state == PlaybackQueue.STATE_PREFETCHING then
                this:_setState(PlaybackQueue.STATE_IDLE)
                if this.on_error then
                    pcall(this.on_error, "Lỗi tải âm thanh: " .. tostring(result))
                end
            end
        end
    end)
end

--- Đảm bảo cả 3 slots (N, N+1, N+2) được cấu hình và kích hoạt tải trước
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

    -- Kích hoạt tải nếu slot chưa sẵn sàng
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

--- Thực hiện phát âm thanh tại Slot N (offset 0)
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

    -- Cập nhật trang và câu hiện tại
    self.current_page = slot.page
    self.current_index = slot.chunk_index

    -- Thông báo thay đổi câu để cập nhật UI & Highlight
    local chunks_on_page = self:_getPageChunks(self.current_page)
    if self.on_chunk_change then
        pcall(self.on_chunk_change, slot.chunk, self.current_page, self.current_index, #chunks_on_page)
    end

    local expected_gen = self.queue_generation
    local this = self

    -- Kích hoạt phát qua AudioBackend
    local speed = self.settings and self.settings:get("speed") or 1.0
    self.audio_backend:play(slot.wav_path, function(finished)
        -- Kiểm tra nếu thế hệ hàng đợi đã bị thay đổi thì bỏ qua callback
        if this.queue_generation ~= expected_gen then
            return
        end

        if finished then
            this:_advanceWindow()
        end
    end, { speed = speed })
end

--- Thăng hạng Sliding Window khi câu N phát xong (Zero-gap transition)
function PlaybackQueue:_advanceWindow()
    -- Kiểm tra Slot 1 (N+1)
    local next_slot = self.slots[1]
    if not next_slot then
        -- Đã đọc hết câu cuối cùng của tài liệu
        self:stop()
        if self.on_finished then pcall(self.on_finished) end
        return
    end

    local old_page = self.current_page
    local new_page = next_slot.page

    -- Thăng hạng: Slot 1 -> Slot 0; Slot 2 -> Slot 1
    self.slots[0] = self.slots[1]
    self.slots[1] = self.slots[2]
    self.slots[2] = nil

    self.current_page = self.slots[0].page
    self.current_index = self.slots[0].chunk_index

    -- Nếu sang trang mới: tự động lật trang
    if new_page > old_page then
        self:_turnPage(new_page)
    end

    -- Bổ sung Slot 2 mới (N+2) và nạp tiếp
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

    -- ZERO-GAP: Phát ngay lập tức Slot 0 nếu đã READY
    if self.slots[0].status == "READY" then
        self:_playSlot(0)
    else
        self:_setState(PlaybackQueue.STATE_PREFETCHING)
        self:_fetchSlot(0)
    end
end

--- Tự động lật trang KOReader
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

--- Bắt đầu phiên đọc từ một trang và câu cụ thể
function PlaybackQueue:start(page_num, chunk_index)
    page_num = page_num or self.current_page or 1
    chunk_index = chunk_index or 1

    self:seekChunk(page_num, chunk_index)
end

--- Tạm dừng âm thanh
function PlaybackQueue:pause()
    if self.state == PlaybackQueue.STATE_PLAYING or self.state == PlaybackQueue.STATE_PREFETCHING then
        self:_setState(PlaybackQueue.STATE_PAUSED)
        if self.audio_backend then
            self.audio_backend:pause()
        end
    end
end

--- Tiếp tục phát âm thanh
function PlaybackQueue:resume()
    if self.state == PlaybackQueue.STATE_PAUSED then
        if self.audio_backend and self.audio_backend:isPlaying() then
            self.audio_backend:resume()
            self:_setState(PlaybackQueue.STATE_PLAYING)
        else
            -- Phát lại slot 0 hiện tại
            self:_playSlot(0)
        end
    end
end

--- Chuyển đổi giữa Tạm dừng và Tiếp tục
function PlaybackQueue:togglePlayPause()
    if self.state == PlaybackQueue.STATE_PLAYING then
        self:pause()
    elseif self.state == PlaybackQueue.STATE_PAUSED then
        self:resume()
    elseif self.state == PlaybackQueue.STATE_IDLE then
        self:start()
    end
end

--- Dừng hoàn toàn phiên đọc
function PlaybackQueue:stop()
    self.queue_generation = self.queue_generation + 1
    self:_cancelActiveFetches()

    if self.audio_backend then
        self.audio_backend:stop()
    end

    self.slots = { [0] = nil, [1] = nil, [2] = nil }
    self:_setState(PlaybackQueue.STATE_IDLE)
end

--- Chuyển tới câu tiếp theo
function PlaybackQueue:nextChunk()
    local next_page, next_index = self:_getNextPosition(self.current_page, self.current_index)
    if next_page and next_index then
        self:seekChunk(next_page, next_index)
    else
        self:stop()
        if self.on_finished then pcall(self.on_finished) end
    end
end

--- Quay lại câu trước đó
function PlaybackQueue:prevChunk()
    local prev_page, prev_index = self:_getPrevPosition(self.current_page, self.current_index)
    if prev_page and prev_index then
        self:seekChunk(prev_page, prev_index)
    end
end

--- Nhảy tới một câu cụ thể (Smart Seeking & Queue Invalidation)
function PlaybackQueue:seekChunk(page_num, chunk_index)
    -- 1. Tăng thế hệ hàng đợi để hủy hoàn toàn tác vụ cũ
    self.queue_generation = self.queue_generation + 1
    local gen = self.queue_generation

    -- 2. Dừng phát âm thanh hiện tại
    if self.audio_backend then
        self.audio_backend:stop()
    end

    -- 3. Hủy bỏ tác vụ tải ngầm cũ
    self:_cancelActiveFetches()

    -- 4. Đặt vị trí mới
    self.current_page = page_num
    self.current_index = chunk_index
    self.slots = { [0] = nil, [1] = nil, [2] = nil }

    -- 5. Thiết lập lại Sliding Window 3 slots
    self:_ensureWindow()

    -- 6. Nếu slot 0 đã có sẵn -> phát ngay, ngược lại -> prefetching
    if self.slots[0] and self.slots[0].status == "READY" then
        self:_playSlot(0)
    else
        self:_setState(PlaybackQueue.STATE_PREFETCHING)
        self:_fetchSlot(0)
    end
end

return PlaybackQueue
