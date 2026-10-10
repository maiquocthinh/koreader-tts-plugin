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

local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger then
    logger = {
        warn = function(...) end,
        info = function(...) end,
        err = function(...) end,
        dbg = function(...) end,
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

local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi and ffi then
    pcall(function()
        ffi.cdef[[
            typedef uint16_t SDL_AudioFormat;
            typedef struct SDL_AudioSpec {
                int freq;
                SDL_AudioFormat format;
                uint8_t channels;
                uint8_t silence;
                uint16_t samples;
                uint16_t padding;
                uint32_t size;
                void (*callback)(void *userdata, uint8_t *stream, int len);
                void *userdata;
            } SDL_AudioSpec;

            int SDL_InitSubSystem(uint32_t flags);
            uint32_t SDL_OpenAudioDevice(const char *device, int iscapture, const SDL_AudioSpec *desired, SDL_AudioSpec *obtained, int allowed_changes);
            int SDL_QueueAudio(uint32_t dev, const void *data, uint32_t len);
            void SDL_PauseAudioDevice(uint32_t dev, int pause_on);
            void SDL_ClearQueuedAudio(uint32_t dev);
            void SDL_CloseAudioDevice(uint32_t dev);
            const char *SDL_GetError(void);
        ]]
    end)
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

--- Parse FLAC file header to extract exact duration (seconds)
-- @param file_path Path to .flac file
-- @return number duration_seconds, number sample_rate, number channels
function AudioBackend.getFlacDuration(file_path)
    local f = io.open(file_path, "rb")
    if not f then return 0, 0, 0 end
    local header = f:read(42)
    f:close()
    if not header or #header < 26 or header:sub(1, 4) ~= "fLaC" then
        return 0, 0, 0
    end
    -- STREAMINFO metadata block (bytes 19..26, 1-indexed in Lua string)
    local b1 = header:byte(19) or 0
    local b2 = header:byte(20) or 0
    local b3 = header:byte(21) or 0
    local b4 = header:byte(22) or 0
    local b5 = header:byte(23) or 0
    local b6 = header:byte(24) or 0
    local b7 = header:byte(25) or 0
    local b8 = header:byte(26) or 0

    local sr = (b1 * 4096) + (b2 * 16) + math.floor(b3 / 16)
    local ch = math.floor((b3 % 16) / 2) + 1
    local total_samples = (b4 % 16) * 4294967296 + (b5 * 16777216) + (b6 * 65536) + (b7 * 256) + b8
    local duration = (sr > 0) and (total_samples / sr) or 0
    return duration, sr, ch
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
    instance._active_poll_timer = nil
    instance._active_process = nil
    instance._sdl_device = nil
    instance._android_player = nil

    instance:_detectDriver()

    if instance.driver_name == "android" then
        local ok_ap, AP = pcall(require, "src.bridge.fallback.android_player")
        if not ok_ap or not AP then
            ok_ap, AP = pcall(require, "android_player")
        end
        if ok_ap and AP then
            instance._android_player = AP:new()
            pcall(function() instance._android_player:init() end)
        end
    end

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
        if self._android_player then
            pcall(function() self._android_player:setSpeed(self.speed) end)
        end
    end
end

--- Check if audio is currently playing
-- @return boolean
function AudioBackend:isPlaying()
    return self._is_playing and not self._is_paused
end

--- Check if audio is currently paused
-- @return boolean
function AudioBackend:isPaused()
    return self._is_playing and self._is_paused
end

--- Stop audio playback immediately
function AudioBackend:stop()
    -- Increment token to invalidate any pending playback callbacks
    self._current_token = self._current_token + 1
    self._is_playing = false
    self._is_paused = false
    self._play_end_time = nil
    self._remaining_play_time = nil
    self._on_finished_cb = nil

    -- Cancel timers if scheduled
    if self._active_timer and UIManager.unschedule then
        UIManager:unschedule(self._active_timer)
    end
    self._active_timer = nil
    if self._active_poll_timer and UIManager.unschedule then
        UIManager:unschedule(self._active_poll_timer)
    end
    self._active_poll_timer = nil

    -- Stop Android MediaPlayer if active
    if self._android_player then
        pcall(function() self._android_player:stop() end)
    end

    -- Stop in-process SDL2 audio if active
    if self._sdl_device and self._sdl_device > 0 then
        pcall(function()
            if ok_ffi and ffi and ffi.C.SDL_ClearQueuedAudio and ffi.C.SDL_CloseAudioDevice then
                ffi.C.SDL_ClearQueuedAudio(self._sdl_device)
                ffi.C.SDL_CloseAudioDevice(self._sdl_device)
            end
        end)
        self._sdl_device = nil
    end

    -- Terminate external player process if running (non-Android desktop/Linux only)
    if self._active_process and self.driver_name ~= "android" then
        pcall(function()
            if os and os.execute then
                if package.config:sub(1, 1) ~= "\\" then
                    pcall(os.execute, "killall -9 tinyplay mpv aplay stagefright 2>/dev/null")
                end
            end
        end)
    end
    self._active_process = nil
end

--- Pause audio playback
function AudioBackend:pause()
    if self._is_playing and not self._is_paused then
        self._is_paused = true

        -- Record remaining play time and cancel completion timer while paused
        local now = (UIManager.getTime and UIManager:getTime()) or os.time()
        if self._play_end_time then
            self._remaining_play_time = math.max(0.1, self._play_end_time - now)
        end
        if self._active_timer and UIManager.unschedule then
            UIManager:unschedule(self._active_timer)
            self._active_timer = nil
        end
        if self._active_poll_timer and UIManager.unschedule then
            UIManager:unschedule(self._active_poll_timer)
            self._active_poll_timer = nil
        end

        if self._android_player then
            pcall(function() self._android_player:pause() end)
        end
        if self._sdl_device and self._sdl_device > 0 then
            pcall(function()
                if ok_ffi and ffi and ffi.C.SDL_PauseAudioDevice then
                    ffi.C.SDL_PauseAudioDevice(self._sdl_device, 1)
                end
            end)
        end
    end
end

--- Resume audio playback
function AudioBackend:resume()
    if self._is_playing and self._is_paused then
        self._is_paused = false
        if self._android_player then
            pcall(function() self._android_player:resume() end)
        end
        if self._sdl_device and self._sdl_device > 0 then
            pcall(function()
                if ok_ffi and ffi and ffi.C.SDL_PauseAudioDevice then
                    ffi.C.SDL_PauseAudioDevice(self._sdl_device, 0)
                end
            end)
        end

        -- Resume completion timer for remaining duration
        local remaining = self._remaining_play_time or 1.0
        local now = (UIManager.getTime and UIManager:getTime()) or os.time()
        self._play_end_time = now + remaining
        local session_token = self._current_token
        local on_finished = self._on_finished_cb
        local this = self
        self._active_timer = UIManager:scheduleIn(remaining, function()
            if this._current_token == session_token and this._is_playing and not this._is_paused then
                this._is_playing = false
                this._active_timer = nil
                if on_finished then
                    pcall(on_finished, true)
                end
            end
        end)
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

    -- Ensure file_path is resolved to an absolute path for platform audio drivers
    if not file_path:match("^/") and not file_path:match("^%a:[/\\]") then
        local ok_ds, DataStorage = pcall(require, "datastorage")
        if ok_ds and DataStorage and type(DataStorage.getDataDir) == "function" then
            local data_dir = DataStorage:getDataDir()
            if data_dir and data_dir ~= "" then
                local candidate = data_dir .. "/" .. file_path
                local f = io.open(candidate, "rb")
                if f then
                    f:close()
                    file_path = candidate
                end
            end
        end
        if not file_path:match("^/") and not file_path:match("^%a:[/\\]") then
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
            if ok_lfs and lfs and type(lfs.currentdir) == "function" then
                local cwd = lfs.currentdir()
                if cwd and cwd ~= "" then
                    local candidate = cwd .. "/" .. file_path
                    local f = io.open(candidate, "rb")
                    if f then
                        f:close()
                        file_path = candidate
                    end
                end
            end
        end
    end

    -- Stop any previous playback
    self:stop()

    -- Generate new session token
    self._current_token = self._current_token + 1
    local session_token = self._current_token
    self._is_playing = true
    self._is_paused = false

    -- Dispatch to platform driver first so native player initializes and gets metadata
    local driver_dispatched = false
    if self.driver_name == "linux" then
        driver_dispatched = self:_playLinux(file_path, speed)
    elseif self.driver_name == "android" then
        driver_dispatched = self:_playAndroid(file_path, speed)
    end

    -- Calculate file duration
    local duration = 0
    -- 1. On Android: MediaPlayer natively knows the EXACT duration for all formats (WAV, FLAC, MP3, OPUS)
    if self.driver_name == "android" and self._android_player and self._android_player.getDurationMs then
        local d_ms = self._android_player:getDurationMs()
        if d_ms and d_ms > 0 then
            duration = d_ms / 1000.0
        end
    end

    -- 2. If duration not known from driver, parse headers
    if duration <= 0 then
        local dur_wav = AudioBackend.getWavDuration(file_path)
        if dur_wav and dur_wav > 0 then
            duration = dur_wav
        else
            local dur_flac = AudioBackend.getFlacDuration(file_path)
            if dur_flac and dur_flac > 0 then
                duration = dur_flac
            end
        end
    end

    -- 3. Fallback estimation if still unknown
    if duration <= 0 then
        local f = io.open(file_path, "rb")
        if f then
            local sz = f:seek("end") or 0
            f:close()
            if file_path:match("%.opus$") then
                duration = math.max(0.5, sz / 3500)
            elseif file_path:match("%.mp3$") then
                duration = math.max(0.5, sz / 8000)
            elseif file_path:match("%.flac$") then
                duration = math.max(0.5, sz / 24000)
            else
                duration = math.max(0.5, sz / 48000)
            end
        else
            duration = 1.0
        end
    end

    local actual_play_time = math.max(0.2, duration / speed)

    local now = (UIManager.getTime and UIManager:getTime()) or os.time()
    self._play_end_time = now + actual_play_time
    self._remaining_play_time = actual_play_time
    self._on_finished_cb = on_finished

    -- Schedule completion callback
    local this = self

    -- On Android: Actively poll isPlaybackDone() for instantaneous zero-gap transition!
    if self.driver_name == "android" and self._android_player and driver_dispatched then
        local function check_done()
            if this._current_token ~= session_token or not this._is_playing or this._is_paused then
                return
            end
            local is_done = this._android_player:isPlaybackDone()
            if is_done then
                if ok_log and logger and logger.warn then
                    logger.warn("AudioBackend: check_done true! duration=", duration, "calling on_finished")
                end
                this._is_playing = false
                this._is_paused = false
                this._active_poll_timer = nil
                if this._active_timer and UIManager.unschedule then
                    UIManager:unschedule(this._active_timer)
                    this._active_timer = nil
                end
                if on_finished then
                    pcall(on_finished, true)
                end
                return
            end
            this._active_poll_timer = UIManager:scheduleIn(0.04, check_done)
        end

        -- Start polling nearing end of playback (0.2s before estimated end)
        local poll_start = math.max(0.05, actual_play_time - 0.2)
        this._active_poll_timer = UIManager:scheduleIn(poll_start, check_done)

        -- Completion timer based on exact audio duration
        self._active_timer = UIManager:scheduleIn(actual_play_time, function()
            if this._current_token == session_token and this._is_playing and not this._is_paused then
                this._is_playing = false
                this._is_paused = false
                this._active_timer = nil
                if this._active_poll_timer and UIManager.unschedule then
                    UIManager:unschedule(this._active_poll_timer)
                    this._active_poll_timer = nil
                end
                if on_finished then
                    pcall(on_finished, true)
                end
            end
        end)
    else
        self._active_timer = UIManager:scheduleIn(actual_play_time, function()
            if this._current_token == session_token and this._is_playing and not this._is_paused then
                this._is_playing = false
                this._is_paused = false
                this._active_timer = nil
                if on_finished then
                    pcall(on_finished, true)
                end
            end
        end)
    end

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

--- Play PCM audio via native in-process SDL2 Audio subsystem
function AudioBackend:_playSDL2(file_path)
    if not ok_ffi or not ffi then return false, "FFI not available" end

    local ok, res = pcall(function()
        if not ffi.C.SDL_InitSubSystem or not ffi.C.SDL_OpenAudioDevice or not ffi.C.SDL_QueueAudio then
            return false, "SDL2 symbols not found"
        end

        -- Initialize SDL_INIT_AUDIO (0x00000010)
        local init_ok = pcall(function()
            return ffi.C.SDL_InitSubSystem(0x00000010)
        end)
        if not init_ok then return false, "SDL_InitSubSystem failed" end

        local f = io.open(file_path, "rb")
        if not f then return false, "Cannot open WAV file" end
        local header = f:read(44)
        if not header or #header < 44 or header:sub(1, 4) ~= "RIFF" then
            f:close()
            return false, "Invalid WAV header"
        end

        local channels = read_uint16_le(header, 23)
        channels = (channels and channels > 0) and channels or 1
        local sample_rate = read_uint32_le(header, 25)
        sample_rate = (sample_rate and sample_rate > 0) and sample_rate or 24000
        local bits = read_uint16_le(header, 35)
        bits = (bits and bits > 0) and bits or 16

        local pcm_data = f:read("*a")
        f:close()
        if not pcm_data or #pcm_data == 0 then return false, "Empty PCM data" end

        -- Close any previous active SDL device
        if self._sdl_device and self._sdl_device > 0 then
            pcall(ffi.C.SDL_ClearQueuedAudio, self._sdl_device)
            pcall(ffi.C.SDL_CloseAudioDevice, self._sdl_device)
            self._sdl_device = nil
        end

        local spec = ffi.new("SDL_AudioSpec")
        spec.freq = sample_rate
        spec.format = (bits == 8) and 0x0008 or 0x8010 -- AUDIO_U8 or AUDIO_S16LSB
        spec.channels = channels
        spec.samples = 1024
        spec.callback = nil
        spec.userdata = nil

        local dev = ffi.C.SDL_OpenAudioDevice(nil, 0, spec, nil, 0)
        if dev == 0 then
            local err_msg = "SDL_OpenAudioDevice returned 0"
            if ffi.C.SDL_GetError then
                pcall(function() err_msg = ffi.string(ffi.C.SDL_GetError()) end)
            end
            return false, err_msg
        end

        self._sdl_device = dev
        ffi.C.SDL_QueueAudio(dev, pcm_data, #pcm_data)
        ffi.C.SDL_PauseAudioDevice(dev, 0) -- 0 = play (unpause)
        return true
    end)

    return ok and res
end

--- Play audio on Android (via android_player MediaPlayer JNI, SDL2, or Linux fallback)
function AudioBackend:_playAndroid(file_path, speed)
    -- Priority 1: Official Android MediaPlayer via android_player (audiobook.koplugin reference)
    if self._android_player and self._android_player._initialized then
        self._android_player:setSpeed(speed)
        local ok = self._android_player:play(file_path, 0)
        if ok then
            self._active_process = "MediaPlayer"
            return true
        end
    end

    -- Priority 2: SDL2 in-process native audio
    local ok_sdl, res_sdl = self:_playSDL2(file_path)
    if ok_sdl and res_sdl then
        self._active_process = "SDL2"
        return true
    end

    -- Priority 3: Device:playSound
    if Device and type(Device.playSound) == "function" then
        local ok_snd, res_snd = pcall(Device.playSound, Device, file_path)
        if ok_snd and res_snd ~= false then
            self._active_process = "Device:playSound"
            return true
        end
    end

    -- Priority 4: Linux ALSA / mpv fallback
    return self:_playLinux(file_path, speed)
end

return AudioBackend
