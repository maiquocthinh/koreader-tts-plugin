--[[
    tts_client.lua - Non-blocking HTTP Client for KOReader TTS Plugin
    OpenAI-compatible TTS API: POST /v1/audio/speech
    Uses Coroutine + Socket Polling with UIManager:scheduleIn() to keep E-ink UI responsive.
--]]

local ok_uimanager, UIManager = pcall(require, "ui/uimanager")
if not ok_uimanager then
    UIManager = {
        scheduleIn = function(self, delay, func)
            if type(func) == "function" then func() end
        end
    }
end

local TTSClient = {}
TTSClient.__index = TTSClient

--- Hash text string using FNV-1a (32-bit) to generate unique cache key
-- @param str String to hash
-- @return string 8-character hex string
local function fnv1a_hash(str)
    local hash = 2166136261
    local len = #str
    for i = 1, len do
        local byte = string.byte(str, i)
        local xor_val = bit and bit.bxor(hash, byte) or ((hash + byte) % 4294967296)
        hash = (xor_val * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

--- Serialize Lua table to JSON (RFC 8259) string in pure Lua with UTF-8 support
-- @param val Table, string, number, or boolean
-- @return string JSON string
local function json_encode(val)
    local t = type(val)
    if t == "string" then
        local s = val:gsub('\\', '\\\\')
                     :gsub('"', '\\"')
                     :gsub('\n', '\\n')
                     :gsub('\r', '\\r')
                     :gsub('\t', '\\t')
        return '"' .. s .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "table" then
        local is_array = true
        local max_idx = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
                is_array = false
                break
            else
                if k > max_idx then max_idx = k end
            end
        end
        if is_array then
            local parts = {}
            for i = 1, max_idx do
                table.insert(parts, json_encode(val[i]))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, string.format("%s:%s", json_encode(tostring(k)), json_encode(v)))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return "null"
    end
end

--- Parse URL into components: scheme, host, port, path
-- @param url URL string (e.g. http://192.168.1.100:7860/v1/audio/speech)
-- @return table { scheme, host, port, path }
local function parse_url(url)
    if not url or url == "" then
        url = "https://api.openai.com/v1/audio/speech"
    end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")

    local scheme, rest = url:match("^(https?)://(.*)$")
    scheme = scheme or "http"
    rest = rest or url

    local host_port, path = rest:match("^([^/]+)(/?.*)$")
    host_port = host_port or rest
    path = (path and path ~= "") and path or "/"

    local host, port = host_port:match("^([^:]+):?(%d*)$")
    host = host or host_port
    if port and port ~= "" then
        port = tonumber(port)
    else
        port = (scheme == "https") and 443 or 80
    end

    -- Strip trailing slashes from path if length > 1
    if #path > 1 then
        path = path:gsub("/+$", "")
    end

    -- If path is root "/" and endpoint doesn't point to speech, append default path
    if path == "/" or path == "" then
        path = "/v1/audio/speech"
    end

    return {
        scheme = scheme,
        host = host,
        port = port,
        path = path,
    }
end

--- Initialize TTSClient instance
-- @param options Table: server_url, voice, api_key, request_timeout, cache_dir
-- @return TTSClient instance
function TTSClient:new(options)
    local instance = setmetatable({}, self)
    options = options or {}

    instance.server_url = options.server_url or "https://api.openai.com/v1/audio/speech"
    instance.model = options.model or "tts-1"
    instance.voice = options.voice or "alloy"
    instance.audio_format = options.audio_format or "wav"
    instance.api_key = options.api_key or ""
    instance.timeout = options.request_timeout or 15
    instance.cache_dir = options.cache_dir or "cache/tts"
    instance._mock_transport = options._mock_transport -- Used for unit testing

    -- Ensure cache directory exists
    instance:_ensureCacheDir()

    return instance
end

--- Ensure cache directory exists on filesystem
function TTSClient:_ensureCacheDir()
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and lfs.mkdir then
        local parts = {}
        for part in self.cache_dir:gmatch("[^/\\]+") do
            table.insert(parts, part)
        end
        local current = ""
        for _, p in ipairs(parts) do
            current = (current == "") and p or (current .. "/" .. p)
            lfs.mkdir(current)
        end
    else
        if os and os.execute then
            local cmd = (package.config:sub(1, 1) == "\\")
                and string.format('mkdir "%s" 2>nul', self.cache_dir:gsub("/", "\\"))
                or string.format('mkdir -p "%s" 2>/dev/null', self.cache_dir)
            pcall(os.execute, cmd)
        end
    end
end

--- Verify format magic bytes in file header
local function verify_audio_header(header, format)
    if not header or #header < 2 then return false end
    format = format or "wav"
    if format == "flac" then
        return (#header >= 4 and header:sub(1, 4) == "fLaC")
    elseif format == "mp3" then
        local b1, b2 = header:byte(1, 2)
        return ((b1 == 0xFF and (b2 >= 0xE0 or b2 == 0xFB or b2 == 0xF3 or b2 == 0xF2)) or header:sub(1, 3) == "ID3")
    elseif format == "opus" then
        return (#header >= 4 and header:sub(1, 4) == "OggS")
    elseif format == "pcm" then
        return (#header > 0)
    else
        return (#header >= 12 and header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WAVE")
    end
end

--- Generate deterministic cache file path for (text, voice, format)
-- @param text Sentence text string
-- @param voice Voice ID
-- @param format Audio format ("wav" | "flac" | "mp3" | "opus")
-- @return string Absolute or relative file path
function TTSClient:getCacheFilePath(text, voice, format)
    voice = voice or self.voice
    format = format or self.audio_format or "wav"
    local key = string.format("%s:%s:%s", text or "", voice or "", format or "wav")
    local hash = fnv1a_hash(key)
    return string.format("%s/chunk_%s.%s", self.cache_dir, hash, format)
end

--- Check if a valid audio cache file exists on disk (verifies format magic bytes)
-- @param text Sentence text string
-- @param voice Voice ID
-- @param format Audio format ("wav" | "flac" | "mp3" | "opus")
-- @return boolean is_valid, string file_path
function TTSClient:hasValidCache(text, voice, format)
    format = format or self.audio_format or "wav"
    local path = self:getCacheFilePath(text, voice, format)
    local f = io.open(path, "rb")
    if not f then
        return false, nil
    end

    local header = f:read(12)
    f:close()

    if verify_audio_header(header, format) then
        return true, path
    end
    return false, nil
end

--- Prune cached files older than max_age_seconds
-- @param max_age_seconds Maximum file age in seconds (default 86400 = 1 day)
function TTSClient:clearCache(max_age_seconds)
    max_age_seconds = max_age_seconds or 86400
    local now = os.time()

    local is_audio_cache = function(fname)
        return fname:match("%.wav$") or fname:match("%.flac$")
            or fname:match("%.mp3$") or fname:match("%.opus$")
            or fname:match("%.tmp$")
    end

    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and lfs.dir then
        pcall(function()
            for file in lfs.dir(self.cache_dir) do
                if is_audio_cache(file) then
                    local full_path = self.cache_dir .. "/" .. file
                    local attrs = lfs.attributes(full_path)
                    if attrs and attrs.modification and (now - attrs.modification > max_age_seconds) then
                        os.remove(full_path)
                    end
                end
            end
        end)
    else
        -- Fallback when lfs is not available (using native list command)
        pcall(function()
            local is_win = (package.config:sub(1, 1) == "\\")
            local list_cmd = is_win and string.format('dir /B "%s\\*.*" 2>nul', self.cache_dir:gsub("/", "\\"))
                                    or string.format('find "%s" -maxdepth 1 -type f 2>/dev/null', self.cache_dir)
            local handle = io.popen(list_cmd)
            if handle then
                for line in handle:lines() do
                    line = line:gsub("[\r\n]", "")
                    if line ~= "" and is_audio_cache(line) then
                        local full_path = is_win and (self.cache_dir .. "/" .. line) or line
                        os.remove(full_path)
                    end
                end
                handle:close()
            end
        end)
    end
end

--- Fetch speech audio asynchronously (Non-blocking HTTP Client)
-- @param text Text string to synthesize
-- @param callback Callback function(success, result_or_err)
-- @param opts Optional overrides: voice, speed, timeout, server_url, api_key
-- @return function Cancel handle function
function TTSClient:fetchSpeechAsync(text, callback, opts)
    opts = opts or {}
    local voice = opts.voice or self.voice
    local speed = opts.speed or 1.0
    local format = opts.response_format or opts.format or self.audio_format or "wav"
    local timeout = opts.timeout or self.timeout
    local server_url = opts.server_url or self.server_url
    local api_key = opts.api_key or self.api_key

    local is_cancelled = false
    local function cancel_handle()
        is_cancelled = true
    end

    if not text or text == "" then
        if callback then callback(false, "Văn bản rỗng") end
        return cancel_handle
    end

    local req_start_time = (UIManager and UIManager.getTime and UIManager:getTime()) or os.time()
    local function finish_callback(ok, res)
        local req_end_time = (UIManager and UIManager.getTime and UIManager:getTime()) or os.time()
        self.last_latency_ms = math.max(1, math.floor((req_end_time - req_start_time) * 1000))
        if callback then callback(ok, res) end
    end

    -- 1. Check disk cache first
    local cached, cache_path = self:hasValidCache(text, voice, format)
    if cached then
        self.last_latency_ms = 0
        if callback then callback(true, cache_path) end
        return cancel_handle
    end

    local final_wav_path = self:getCacheFilePath(text, voice, format)
    local temp_wav_path = final_wav_path .. ".tmp"

    -- 2. Mock transport (for standalone unit tests)
    if self._mock_transport then
        self._mock_transport(text, voice, function(ok, data_or_err)
            if is_cancelled then return end
            if not ok then
                finish_callback(false, data_or_err)
                return
            end
            local f = io.open(final_wav_path, "wb")
            if f then
                f:write(data_or_err)
                f:close()
                if not is_cancelled then finish_callback(true, final_wav_path) end
            else
                if not is_cancelled then finish_callback(false, "Không thể ghi file cache") end
            end
        end)
        return cancel_handle
    end

    -- 3. Prepare OpenAI-compatible payload and headers
    local payload = json_encode({
        model = self.model or "tts-1",
        input = text,
        voice = voice,
        speed = speed,
        response_format = format,
    })

    local url_info = parse_url(server_url)

    -- 4. Tier 1: Prioritize in-process LuaSocket (+ LuaSec for HTTPS) with non-blocking coroutines
    -- This runs in cooperative 20ms slices without blocking the main UI thread or spawning subprocesses,
    -- completely preventing Android ANRs ("KOReader isn't responding").
    local ok_socket, socket = pcall(require, "socket")
    local ok_ssl = true
    if url_info.scheme == "https" then
        local has_ssl, ssl = pcall(require, "ssl")
        ok_ssl = has_ssl and ssl and type(ssl.wrap) == "function"
    end

    if ok_socket and socket and socket.tcp and ok_ssl then
        self:_fetchViaSocket(url_info, payload, api_key, timeout, temp_wav_path, final_wav_path, format, function(ok, res)
            if is_cancelled then return end
            if ok then
                finish_callback(true, res)
            else
                local ok_l, log = pcall(require, "logger")
                if ok_l and log and log.err then
                    log.err("TTSClient: _fetchViaSocket failed:", tostring(res))
                end
                -- If socket fetch failed, fallback to curl
                self:_fetchViaCurl(server_url, payload, api_key, timeout, temp_wav_path, final_wav_path, format, finish_callback)
            end
        end, function() return is_cancelled end)
        return cancel_handle
    end

    -- 5. Tier 2: Fallback to curl when LuaSocket/LuaSec is unavailable
    self:_fetchViaCurl(server_url, payload, api_key, timeout, temp_wav_path, final_wav_path, format, finish_callback)
    return cancel_handle
end

--- Internal socket fetch implementation with coroutine non-blocking streaming
function TTSClient:_fetchViaSocket(url_info, payload, api_key, timeout, temp_wav_path, final_wav_path, format, callback, is_cancelled_fn)
    local socket = require("socket")

    local headers = {
        string.format("POST %s HTTP/1.1", url_info.path),
        string.format("Host: %s", url_info.host),
        "Content-Type: application/json",
        string.format("Content-Length: %d", #payload),
        "User-Agent: KOReader-TTS/1.0",
        "Connection: close",
    }
    if api_key and api_key ~= "" then
        table.insert(headers, string.format("Authorization: Bearer %s", api_key))
    end
    local request_header_str = table.concat(headers, "\r\n") .. "\r\n\r\n"

    local co = coroutine.create(function()
        local tcp = socket.tcp()
        local start_time = os.time()

        -- DNS Caching: Cache resolved IP to eliminate repeated getaddrinfo blocking latency
        TTSClient._dns_cache = TTSClient._dns_cache or {}
        local target_host = url_info.host
        local is_ip = target_host:match("^%d+%.%d+%.%d+%.%d+$")
        local connect_host = target_host
        if not is_ip then
            if TTSClient._dns_cache[target_host] then
                connect_host = TTSClient._dns_cache[target_host]
            elseif socket.dns and socket.dns.toip then
                local resolved = socket.dns.toip(target_host)
                if resolved then
                    TTSClient._dns_cache[target_host] = resolved
                    connect_host = resolved
                end
            end
        end

        -- Connect with a sensible timeout (2.5s) to avoid UI lockup
        tcp:settimeout(math.min(timeout, 2.5))
        local conn_ok, conn_err = tcp:connect(connect_host, url_info.port)
        if not conn_ok then
            if TTSClient._dns_cache then TTSClient._dns_cache[target_host] = nil end
            tcp:close()
            return false, "Lỗi kết nối tới " .. url_info.host .. ":" .. url_info.port .. " (" .. tostring(conn_err) .. ")"
        end
        tcp:settimeout(0) -- Switch to non-blocking mode for I/O

        -- Wrap in SSL if HTTPS
        if url_info.scheme == "https" then
            local ok_ssl, ssl = pcall(require, "ssl")
            if ok_ssl and ssl and ssl.wrap then
                local ssl_params = {
                    mode = "client",
                    protocol = "any",
                    verify = "none",
                    options = "all",
                }
                tcp = ssl.wrap(tcp, ssl_params)
                tcp:sni(url_info.host)
                tcp:settimeout(math.min(timeout, 3.0))
                local hs_ok, hs_err = tcp:dohandshake()
                tcp:settimeout(0)
                if not hs_ok then
                    tcp:close()
                    return false, "Lỗi bắt tay SSL: " .. tostring(hs_err)
                end
            else
                tcp:close()
                return false, "HTTPS yêu cầu thư viện LuaSec (ssl) nhưng không tìm thấy"
            end
        end

        -- Send headers and payload
        local full_request = request_header_str .. payload
        local total_sent = 0
        while total_sent < #full_request do
            local sent, send_err, last_byte = tcp:send(full_request, total_sent + 1)
            if sent then
                total_sent = sent
            elseif send_err == "timeout" or send_err == "wantwrite" or send_err == "wantread" then
                total_sent = last_byte or total_sent
                coroutine.yield()
            else
                tcp:close()
                return false, "Lỗi gửi dữ liệu HTTP: " .. tostring(send_err)
            end
            if os.time() - start_time > timeout then
                tcp:close()
                return false, "Hết thời gian gửi dữ liệu HTTP"
            end
        end

        -- Read HTTP response headers
        local response_buffer = ""
        local header_end = nil
        while not header_end do
            local chunk, recv_err, partial = tcp:receive("*l")
            if chunk then
                response_buffer = response_buffer .. chunk .. "\n"
                if chunk == "" or chunk == "\r" then
                    header_end = true
                end
            elseif recv_err == "timeout" or recv_err == "wantread" then
                if partial and partial ~= "" then
                    response_buffer = response_buffer .. partial
                end
                coroutine.yield()
            else
                tcp:close()
                return false, "Lỗi nhận phản hồi HTTP: " .. tostring(recv_err)
            end
            if os.time() - start_time > timeout then
                tcp:close()
                return false, "Hết thời gian chờ nhận phản hồi từ server"
            end
        end

        -- Parse Status Code
        local status_code = tonumber(response_buffer:match("HTTP/%d*%.?%d*%s+(%d+)"))
        if not status_code or status_code < 200 or status_code >= 300 then
            local chunk, _, partial = tcp:receive("*a")
            local err_body = chunk or partial or ""
            tcp:close()
            if err_body:find("Unknown voice") or err_body:find("voice") then
                return false, string.format("Lỗi giọng đọc: Máy chủ không hỗ trợ giọng này.\nChi tiết: %s\nVui lòng kiểm tra lại cấu hình giọng đọc trong Cài đặt.", err_body)
            end
            return false, string.format("Máy chủ TTS phản hồi lỗi HTTP %s: %s", tostring(status_code or "Unknown"), tostring(err_body))
        end

        -- Read binary stream into file with batching to avoid coroutine thrashing
        local out_file, file_err = io.open(temp_wav_path, "wb")
        if not out_file then
            tcp:close()
            return false, "Không thể mở file tạm để ghi: " .. tostring(file_err)
        end

        while true do
            local bytes_in_tick = 0
            local eof = false
            local socket_err = nil

            while bytes_in_tick < 65536 do
                local chunk, recv_err, partial = tcp:receive(16384)
                local data = chunk or partial
                if data and #data > 0 then
                    out_file:write(data)
                    bytes_in_tick = bytes_in_tick + #data
                end

                if chunk == nil and recv_err == "closed" then
                    eof = true
                    break
                elseif chunk == nil and (recv_err == "timeout" or recv_err == "wantread") then
                    break
                elseif chunk == nil and (recv_err ~= "timeout" and recv_err ~= "wantread") then
                    socket_err = recv_err
                    break
                end
            end

            if eof then
                break
            end

            if socket_err then
                out_file:close()
                os.remove(temp_wav_path)
                tcp:close()
                return false, "Mất kết nối khi đang tải file âm thanh: " .. tostring(socket_err)
            end

            if os.time() - start_time > timeout then
                out_file:close()
                os.remove(temp_wav_path)
                tcp:close()
                return false, "Hết thời gian tải file âm thanh"
            end

            coroutine.yield("downloading")
        end

        out_file:close()
        tcp:close()

        -- Verify audio header based on format
        local verify_file = io.open(temp_wav_path, "rb")
        if not verify_file then return false, "Không tìm thấy file sau khi tải" end
        local header = verify_file:read(12)
        verify_file:close()

        if not verify_audio_header(header, format) then
            os.remove(temp_wav_path)
            return false, string.format("Dữ liệu trả về không phải âm thanh %s hợp lệ", tostring(format or "wav"):upper())
        end

        os.remove(final_wav_path)
        os.rename(temp_wav_path, final_wav_path)
        return true, final_wav_path
    end)

    local function pump()
        if is_cancelled_fn and is_cancelled_fn() then
            os.remove(temp_wav_path)
            return
        end

        local ok, status_tag, result_or_err = coroutine.resume(co)
        if not ok then
            os.remove(temp_wav_path)
            if callback then callback(false, "Lỗi coroutine: " .. tostring(status_tag)) end
            return
        end

        if coroutine.status(co) == "dead" then
            if callback then callback(status_tag, result_or_err) end
        else
            -- Adaptive scheduling: 20ms during active download, 80ms while awaiting server synthesis
            -- This eliminates 75% of CPU timer wakeups on Android/E-ink devices, preventing UI lag.
            local delay = (status_tag == "downloading") and 0.02 or 0.08
            if UIManager and type(UIManager.scheduleIn) == "function" then
                UIManager:scheduleIn(delay, pump)
            end
        end
    end

    pump()
end

--- Fallback implementation using curl (handles TLS, SNI, self-signed certs, redirects)
function TTSClient:_fetchViaCurl(server_url, payload, api_key, timeout, temp_wav_path, final_wav_path, format, callback)
    local tmp_json = temp_wav_path .. ".json"
    local jf = io.open(tmp_json, "wb")
    if jf then
        jf:write(payload)
        jf:close()
    end

    local url_info = parse_url(server_url)
    local full_endpoint = string.format("%s://%s:%d%s", url_info.scheme, url_info.host, url_info.port, url_info.path)

    local auth_header = (api_key and api_key ~= "") and string.format('-H "Authorization: Bearer %s"', api_key) or ""
    -- Flags:
    --   -s: silent
    --   -k: insecure (skip CA cert verification for device environments)
    --   -L: follow HTTP redirects (301, 302, 307)
    --   --data-binary: send exact UTF-8 payload with newlines preserved
    local effective_timeout = math.max(timeout or 15, 30)
    local curl_cmd = string.format(
        'curl -s -k -L -X POST "%s" -H "Content-Type: application/json" -H "User-Agent: KOReader-TTS/1.0" %s --data-binary @"%s" -o "%s" --max-time %d >/dev/null 2>&1',
        full_endpoint, auth_header, tmp_json, temp_wav_path, effective_timeout
    )

    local exit_marker = temp_wav_path .. ".exit"
    os.remove(exit_marker)

    local function checkResult()
        os.remove(tmp_json)
        os.remove(exit_marker)

        local verify_file = io.open(temp_wav_path, "rb")
        if verify_file then
            local header = verify_file:read(12)
            verify_file:close()
            if header and verify_audio_header(header, format) then
                os.remove(final_wav_path)
                os.rename(temp_wav_path, final_wav_path)
                if callback then callback(true, final_wav_path) end
                return
            end

            -- Not a valid WAV file: read server error response body
            local ef = io.open(temp_wav_path, "r")
            local err_body = ef and ef:read(500) or ""
            if ef then ef:close() end
            os.remove(temp_wav_path)

            if err_body:find("Unknown voice") or err_body:find("voice") then
                if callback then
                    callback(false, string.format("Lỗi giọng đọc: Máy chủ không hỗ trợ giọng này.\nChi tiết: %s\nVui lòng vào 'Cài đặt máy chủ & Giọng đọc' để chọn lại giọng phù hợp.", err_body))
                end
                return
            end

            if callback then
                callback(false, string.format("Máy chủ phản hồi lỗi: %s", err_body ~= "" and err_body or "Dữ liệu trả về không phải âm thanh WAV"))
            end
            return
        end

        os.remove(temp_wav_path)
        if callback then
            callback(false, "Không thể kết nối đến máy chủ TTS (kết nối thất bại hoặc hết thời gian)")
        end
    end

    if package.config:sub(1, 1) == "\\" then
        -- Windows desktop fallback (synchronous for local unit tests)
        if UIManager and type(UIManager.scheduleIn) == "function" then
            UIManager:scheduleIn(0.02, function()
                pcall(os.execute, curl_cmd)
                checkResult()
            end)
        else
            pcall(os.execute, curl_cmd)
            checkResult()
        end
    else
        -- Unix / Linux / Android / E-ink: completely detached background subshell
        -- </dev/null >/dev/null 2>&1 & severs all pipe descriptors so os.execute returns in 0ms,
        -- completely preventing UI thread freezes, fread blocking, and Android OS ANRs.
        local bg_cmd = string.format('sh -c \'(%s; echo $? > "%s") </dev/null >/dev/null 2>&1 &\'', curl_cmd, exit_marker)
        pcall(os.execute, bg_cmd)

        local start_poll = (UIManager and UIManager.getTime and UIManager:getTime()) or os.time()
        local function poll()
            local ef = io.open(exit_marker, "r")
            if ef then
                ef:close()
                checkResult()
                return
            end

            local now = (UIManager and UIManager.getTime and UIManager:getTime()) or os.time()
            if (now - start_poll) > (timeout + 2) then
                os.remove(exit_marker)
                os.remove(temp_wav_path)
                os.remove(tmp_json)
                if callback then callback(false, "Hết thời gian tải file âm thanh (timeout)") end
                return
            end

            if UIManager and type(UIManager.scheduleIn) == "function" then
                UIManager:scheduleIn(0.05, poll)
            else
                checkResult()
            end
        end

        if UIManager and type(UIManager.scheduleIn) == "function" then
            UIManager:scheduleIn(0.05, poll)
        else
            checkResult()
        end
    end
end

-- Export helper functions for testing
TTSClient._fnv1a_hash = fnv1a_hash
TTSClient._json_encode = json_encode
TTSClient._parse_url = parse_url

return TTSClient
