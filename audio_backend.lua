--[[
    audio_backend.lua - Multi-platform hardware audio playback adapter
    Supported targets:
      - Android (Boox, Meebook, phones): MediaPlayer JNI or shell player
      - Linux / Kobo / Kindle: mpv, aplay
      - Desktop / Test: System player or accurate duration-based timer playback
--]]

local ok_device, Device = pcall(require, "device")
if not ok_device or not Device then
    Device = {
        isAndroid = function() return false end,
        isLinux = function() return true end,
        isKobo = function() return false end,
        isKindle = function() return false end,
        isDesktop = function() return true end,
    }
end

local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager or not UIManager then
    UIManager = {
        scheduleIn = function(self, delay, func)
            if type(func) == "function" then func() end
        end
    }
end

local AudioBackend = {}
AudioBackend.__index = AudioBackend

--- Read 16-bit little-endian integer from binary string
local function read_uint16_le(str, offset)
    local b1 = string.byte(str, offset) or 0
    local b2 = string.byte(str, offset + 1) or 0
    return b1 + b2 * 256
end

--- Read 32-bit little-endian integer from binary string
local function read_uint32_le(str, offset)
    local b1 = string.byte(str, offset) or 0
    local b2 = string.byte(str, offset + 1) or 0
    local b3 = string.byte(str, offset + 2) or 0
    local b4 = string.byte(str, offset + 3) or 0
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

--- Parse WAV file header to extract duration (seconds), byte rate, and sample rate
-- @param file_path Path to .wav file
-- @return number duration_seconds, number byte_rate, number sample_rate
function AudioBackend.getWavDuration(file_path)
    local f = io.open(file_path, "rb")
    if not f then
        return 0, 0, 0
    end

    local header = f:read(128) -- Read initial header covering RIFF, fmt, and data chunk headers
    f:close()

    if not header or #header < 44 then
        return 0, 0, 0
    end

    if header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        return 0, 0, 0
    end

    -- Locate "fmt " chunk
    local fmt_pos = header:find("fmt ")
    if not fmt_pos then
        return 0, 0, 0
    end

    local channels = read_uint16_le(header, fmt_pos + 10)
    local sample_rate = read_uint32_le(header, fmt_pos + 12)
    local byte_rate = read_uint32_le(header, fmt_pos + 16)

    -- Locate "data" chunk
    local data_pos = header:find("data")
    local data_size = 0
    if data_pos and #header >= data_pos + 7 then
        data_size = read_uint32_le(header, data_pos + 4)
    end

    -- Fallback: if data_size not found in first 128 bytes, estimate from file size minus header
    if data_size == 0 or data_size > 100000000 then
        local f_full = io.open(file_path, "rb")
        if f_full then
            local current = f_full:seek("end")
            f_full:close()
            data_size = math.max(0, (current or 44) - 44)
        end
    end

    local duration = 0
    if byte_rate and byte_rate > 0 then
        duration = data_size / byte_rate
    elseif sample_rate and sample_rate > 0 and channels and channels > 0 then
        duration = data_size / (sample_rate * channels * 2)
    end

    return duration, byte_rate, sample_rate
end

--- Initialize AudioBackend instance
-- @param options Config table: { backend_type, speed }
-- @return AudioBackend instance
function AudioBackend:new(options)
    local instance = setmetatable({}, self)
    options = options or {}

    instance.backend_type = options.backend_type or "auto"
    instance.speed = math.max(0.5, math.min(2.0, options.speed or 1.0))
    instance._is_playing = false
    instance._is_paused = false
    instance._current_token = 0
    instance._active_timer = nil
    instance._active_process = nil

    instance:_detectDriver()
    return instance
end

--- Detect appropriate audio driver based on device platform
function AudioBackend:_detectDriver()
    if self.backend_type ~= "auto" then
        self.driver_name = self.backend_type
        return
    end

    if Device:isAndroid() then
        self.driver_name = "android"
    elseif Device:isKobo() or Device:isKindle() or Device:isLinux() then
        self.driver_name = "linux"
    else
        self.driver_name = "desktop"
    end
end

--- Update playback speed (0.5x - 2.0x)
-- @param speed New speed multiplier
function AudioBackend:setSpeed(speed)
    if type(speed) == "number" then
        self.speed = math.max(0.5, math.min(2.0, speed))
    end
end

--- Check if audio is currently playing
-- @return boolean
function AudioBackend:isPlaying()
    return self._is_playing and not self._is_paused
end

--- Stop audio playback immediately
function AudioBackend:stop()
    -- Increment token to invalidate any pending playback callbacks
    self._current_token = self._current_token + 1
    self._is_playing = false
    self._is_paused = false

    -- Cancel timer if scheduled
    if self._active_timer and UIManager.unschedule then
        UIManager:unschedule(self._active_timer)
    end
    self._active_timer = nil

    -- Terminate external player process if running
    if self._active_process then
        pcall(function()
            if os and os.execute then
                if package.config:sub(1, 1) ~= "\\" then
                    pcall(os.execute, "killall -9 mpv aplay 2>/dev/null")
                end
            end
        end)
        self._active_process = nil
    end
end

--- Pause audio playback
function AudioBackend:pause()
    if self._is_playing then
        self._is_paused = true
    end
end

--- Resume audio playback
function AudioBackend:resume()
    if self._is_playing and self._is_paused then
        self._is_paused = false
    end
end

--- Start playing a .wav audio file
-- @param file_path Path to .wav file
-- @param on_finished Callback invoked when playback completes on_finished(success)
-- @param opts Optional overrides: speed
function AudioBackend:play(file_path, on_finished, opts)
    opts = opts or {}
    local speed = opts.speed or self.speed

    if not file_path or file_path == "" then
        if on_finished then on_finished(false) end
        return false, "Empty file path"
    end

    -- Stop any previous playback
    self:stop()

    -- Generate new session token
    self._current_token = self._current_token + 1
    local session_token = self._current_token
    self._is_playing = true
    self._is_paused = false

    -- Calculate file duration
    local duration, byte_rate, sample_rate = AudioBackend.getWavDuration(file_path)
    if duration <= 0 then
        duration = 1.0
    end
    local actual_play_time = math.max(0.2, duration / speed)

    -- Dispatch to platform driver
    local driver_dispatched = false
    if self.driver_name == "linux" then
        driver_dispatched = self:_playLinux(file_path, speed)
    elseif self.driver_name == "android" then
        driver_dispatched = self:_playAndroid(file_path, speed)
    end

    -- Schedule completion timer (used for Desktop/Test and driver fallback)
    self._active_timer = UIManager:scheduleIn(actual_play_time, function()
        -- Ensure session token is still valid and was not cancelled by stop()
        if self._current_token == session_token and self._is_playing then
            self._is_playing = false
            self._is_paused = false
            self._active_timer = nil
            if on_finished then
                pcall(on_finished, true)
            end
        end
    end)

    return true
end

--- Play audio on Linux e-reader platforms (Kobo, Kindle, Linux)
function AudioBackend:_playLinux(file_path, speed)
    local ok = pcall(function()
        -- Priority 1: mpv with speed control
        local cmd = string.format('mpv --no-video --really-quiet --speed=%.2f "%s" >/dev/null 2>&1 &', speed, file_path)
        local ret = os.execute(cmd)
        if ret == 0 then
            self._active_process = "mpv"
            return true
        end

        -- Priority 2: aplay (ALSA native)
        local aplay_cmd = string.format('aplay -q "%s" >/dev/null 2>&1 &', file_path)
        ret = os.execute(aplay_cmd)
        if ret == 0 then
            self._active_process = "aplay"
            return true
        end
        return false
    end)
    return ok
end

--- Play audio on Android (via JNI MediaPlayer or intent)
function AudioBackend:_playAndroid(file_path, speed)
    local ok, res = pcall(function()
        local ok_android, android = pcall(require, "android")
        if ok_android and android and android.playAudio then
            return android.playAudio(file_path, speed)
        end
        return false
    end)
    return ok and res
end

return AudioBackend
