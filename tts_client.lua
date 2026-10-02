--[[
    tts_client.lua - Non-blocking HTTP Client cho KOReader TTS Plugin
    Tương thích chuẩn OpenAI / VieNeu API: POST /v1/audio/speech
    Sử dụng Coroutine + Socket Polling với UIManager:scheduleIn() để không chặn giao diện E-ink.
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

--- Băm chuỗi văn bản theo thuật toán FNV-1a (32-bit) để tạo khóa cache duy nhất
-- @param str Chuỗi cần băm
-- @return string Mã hex 8 ký tự
local function fnv1a_hash(str)
    local hash = 2166136261
    local len = #str
    for i = 1, len do
        local byte = string.byte(str, i)
        -- hash = (hash XOR byte) * 16777619 (mod 2^32)
        local xor_val = bit and bit.bxor(hash, byte) or ((hash + byte) % 4294967296)
        hash = (xor_val * 16777619) % 4294967296
    end
    return string.format("%08x", hash)
end

--- Tuần tự hóa bảng dữ liệu sang chuỗi JSON (RFC 8259) thuần Lua, hỗ trợ tiếng Việt UTF-8
-- @param val Bảng, chuỗi, số, boolean
-- @return string Chuỗi JSON
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

--- Phân tích URL thành các thành phần: scheme, host, port, path
-- @param url Chuỗi URL (VD: http://192.168.1.100:7860/v1/audio/speech)
-- @return table { scheme, host, port, path }
local function parse_url(url)
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

    -- Nếu path chỉ là "/" và endpoint chưa trỏ tới speech, tự động thêm đường dẫn chuẩn
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

--- Khởi tạo đối tượng TTSClient
-- @param options Bảng tùy chọn: server_url, voice, api_key, request_timeout, cache_dir
-- @return TTSClient instance
function TTSClient:new(options)
    local instance = setmetatable({}, self)
    options = options or {}

    instance.server_url = options.server_url or "http://192.168.1.100:7860"
    instance.voice = options.voice or "vi-VN-NamMinh"
    instance.api_key = options.api_key or ""
    instance.timeout = options.request_timeout or 15
    instance.cache_dir = options.cache_dir or "cache/tts"
    instance._mock_transport = options._mock_transport -- Dành cho unit test

    -- Đảm bảo thư mục cache tồn tại
    instance:_ensureCacheDir()

    return instance
end

--- Tạo thư mục cache nếu chưa có
function TTSClient:_ensureCacheDir()
    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and lfs.mkdir then
        -- Tạo thư mục cha và thư mục con
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
        -- Fallback dùng os.execute mkdir nếu cần
        if os and os.execute then
            local cmd = (package.config:sub(1, 1) == "\\")
                and string.format('mkdir "%s" 2>nul', self.cache_dir:gsub("/", "\\"))
                or string.format('mkdir -p "%s" 2>/dev/null', self.cache_dir)
            pcall(os.execute, cmd)
        end
    end
end

--- Sinh đường dẫn file cache tuyệt đối cho cặp (text, voice)
-- @param text Chuỗi nội dung câu
-- @param voice ID giọng đọc
-- @return string Đường dẫn file .wav
function TTSClient:getCacheFilePath(text, voice)
    voice = voice or self.voice
    local key = string.format("%s:%s", text or "", voice or "")
    local hash = fnv1a_hash(key)
    return string.format("%s/chunk_%s.wav", self.cache_dir, hash)
end

--- Kiểm tra xem file cache đã có sẵn và hợp lệ chưa (phải có header RIFF của WAV)
-- @param text Chuỗi nội dung câu
-- @param voice ID giọng đọc
-- @return boolean, string (true, filepath nếu hợp lệ; ngược lại false, nil)
function TTSClient:hasValidCache(text, voice)
    local path = self:getCacheFilePath(text, voice)
    local f = io.open(path, "rb")
    if not f then
        return false, nil
    end

    local header = f:read(12)
    f:close()

    -- Kiểm tra 4 bytes đầu là "RIFF" và bytes 9-12 là "WAVE"
    if header and #header >= 12 and header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WAVE" then
        return true, path
    end
    return false, nil
end

--- Dọn dẹp cache cũ hơn một số giây quy định
-- @param max_age_seconds Thời gian tồn tại tối đa của file tính bằng giây (mặc định 86400 = 1 ngày)
function TTSClient:clearCache(max_age_seconds)
    max_age_seconds = max_age_seconds or 86400
    local now = os.time()

    local ok, lfs = pcall(require, "lfs")
    if ok and lfs and lfs.dir then
        pcall(function()
            for file in lfs.dir(self.cache_dir) do
                if file:match("%.wav$") or file:match("%.tmp$") then
                    local full_path = self.cache_dir .. "/" .. file
                    local attrs = lfs.attributes(full_path)
                    if attrs and attrs.modification and (now - attrs.modification > max_age_seconds) then
                        os.remove(full_path)
                    end
                end
            end
        end)
    end
end

--- Tải file âm thanh bất đồng bộ (Non-blocking HTTP Client)
-- @param text Chuỗi văn bản tiếng Việt cần đọc
-- @param callback Hàm phản hồi callback(success, result_or_err): success=true thì result là path file .wav
-- @param opts Bảng tùy chọn ghi đè: voice, speed, timeout, server_url, api_key
-- @return function Hàm hủy tác vụ tải (cancel handle)
function TTSClient:fetchSpeechAsync(text, callback, opts)
    opts = opts or {}
    local voice = opts.voice or self.voice
    local speed = opts.speed or 1.0
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

    -- 1. Kiểm tra cache đĩa trước
    local cached, cache_path = self:hasValidCache(text, voice)
    if cached then
        if callback then callback(true, cache_path) end
        return cancel_handle
    end

    local final_wav_path = self:getCacheFilePath(text, voice)
    local temp_wav_path = final_wav_path .. ".tmp"

    -- 2. Mock transport (phục vụ unit test độc lập)
    if self._mock_transport then
        self._mock_transport(text, voice, function(ok, data_or_err)
            if is_cancelled then return end
            if not ok then
                if callback then callback(false, data_or_err) end
                return
            end
            local f = io.open(final_wav_path, "wb")
            if f then
                f:write(data_or_err)
                f:close()
                if not is_cancelled and callback then callback(true, final_wav_path) end
            else
                if not is_cancelled and callback then callback(false, "Không thể ghi file cache") end
            end
        end)
        return cancel_handle
    end

    -- 3. Chuẩn bị payload và headers
    local payload = json_encode({
        input = text,
        voice = voice,
        speed = speed,
    })

    local url_info = parse_url(server_url)
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

    -- 4. Kiểm tra thư viện socket của KOReader
    local ok_socket, socket = pcall(require, "socket")
    if not ok_socket or not socket or not socket.tcp then
        -- Fallback qua curl nếu không có socket nhị phân (môi trường standalone test)
        self:_fetchViaCurl(server_url, payload, api_key, timeout, temp_wav_path, final_wav_path, callback)
        return
    end

    -- 5. Thực hiện Non-blocking I/O qua Coroutine + Socket Polling
    local co = coroutine.create(function()
        local tcp = socket.tcp()
        tcp:settimeout(0) -- Chế độ không khóa luồng (Non-blocking)

        local start_time = os.time()

        -- Bước 5.1: Kết nối tới server
        local conn_ok, conn_err = tcp:connect(url_info.host, url_info.port)
        while not conn_ok and conn_err == "timeout" do
            if os.time() - start_time > timeout then
                tcp:close()
                return false, "Hết thời gian kết nối (Connection timeout)"
            end
            coroutine.yield()
            conn_ok, conn_err = tcp:connect(url_info.host, url_info.port)
            if conn_err == "already connected" then
                conn_ok = 1
                break
            end
        end

        if not conn_ok and conn_err ~= "already connected" then
            tcp:close()
            return false, "Lỗi kết nối tới " .. url_info.host .. ":" .. url_info.port .. " (" .. tostring(conn_err) .. ")"
        end

        -- Nếu là HTTPS, bọc qua luasec
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
                tcp:settimeout(0)
                local hs_ok, hs_err = tcp:dohandshake()
                while not hs_ok and (hs_err == "timeout" or hs_err == "wantread" or hs_err == "wantwrite") do
                    if os.time() - start_time > timeout then
                        tcp:close()
                        return false, "Hết thời gian bắt tay SSL (Handshake timeout)"
                    end
                    coroutine.yield()
                    hs_ok, hs_err = tcp:dohandshake()
                end
                if not hs_ok then
                    tcp:close()
                    return false, "Lỗi bắt tay SSL: " .. tostring(hs_err)
                end
            else
                tcp:close()
                return false, "HTTPS yêu cầu thư viện LuaSec (ssl) nhưng không tìm thấy"
            end
        end

        -- Bước 5.2: Gửi Request Headers và Body
        local full_request = request_header_str .. payload
        local total_sent = 0
        while total_sent < #full_request do
            local sent, send_err, last_byte = tcp:send(full_request, total_sent + 1)
            if sent then
                total_sent = sent
            elseif send_err == "timeout" then
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

        -- Bước 5.3: Đọc Header phản hồi từ máy chủ
        local response_buffer = ""
        local header_end = nil
        while not header_end do
            local chunk, recv_err, partial = tcp:receive("*l")
            if chunk then
                response_buffer = response_buffer .. chunk .. "\n"
                if chunk == "" or chunk == "\r" then
                    header_end = true
                end
            elseif recv_err == "timeout" then
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

        -- Phân tích Status Code
        local status_code = tonumber(response_buffer:match("HTTP/%d*%.?%d*%s+(%d+)"))
        if not status_code or status_code < 200 or status_code >= 300 then
            -- Đọc thêm phần body lỗi (nếu có), hỗ trợ cả kết quả trong partial khi socket non-blocking
            local chunk, _, partial = tcp:receive("*a")
            local err_body = chunk or partial or ""
            tcp:close()
            return false, string.format("Máy chủ TTS phản hồi lỗi HTTP %s: %s", tostring(status_code or "Unknown"), tostring(err_body))
        end

        -- Bước 5.4: Đọc luồng nhị phân WAV và ghi atomic vào file đệm .tmp
        local out_file, file_err = io.open(temp_wav_path, "wb")
        if not out_file then
            tcp:close()
            return false, "Không thể mở file tạm để ghi: " .. tostring(file_err)
        end

        local total_bytes = 0
        while true do
            local chunk, recv_err, partial = tcp:receive(4096)
            local data = chunk or partial
            if data and #data > 0 then
                out_file:write(data)
                total_bytes = total_bytes + #data
            end

            if chunk == nil and recv_err == "closed" then
                -- Kết nối đã đóng hoàn tất
                break
            elseif chunk == nil and recv_err == "timeout" then
                coroutine.yield()
            elseif chunk == nil and recv_err ~= "timeout" then
                out_file:close()
                os.remove(temp_wav_path)
                tcp:close()
                return false, "Mất kết nối khi đang tải file âm thanh: " .. tostring(recv_err)
            end

            if os.time() - start_time > timeout then
                out_file:close()
                os.remove(temp_wav_path)
                tcp:close()
                return false, "Hết thời gian tải file âm thanh"
            end
        end

        out_file:close()
        tcp:close()

        -- Bước 5.5: Xác thực file WAV (Kiểm tra 4 bytes đầu là 'RIFF')
        local verify_file = io.open(temp_wav_path, "rb")
        if not verify_file then
            return false, "Không tìm thấy file sau khi tải"
        end
        local magic = verify_file:read(4)
        verify_file:close()

        if magic ~= "RIFF" then
            os.remove(temp_wav_path)
            return false, "Dữ liệu máy chủ trả về không phải định dạng WAV hợp lệ (thiếu header RIFF)"
        end

        -- Đổi tên nguyên tử từ .tmp sang .wav
        os.remove(final_wav_path) -- Xóa file cũ nếu có
        os.rename(temp_wav_path, final_wav_path)

        return true, final_wav_path
    end)

    -- Runner bơm coroutine với UIManager:scheduleIn() nhường luồng cho UI
    local function pump()
        if is_cancelled then
            os.remove(temp_wav_path)
            return
        end

        local ok, success_or_cont, result_or_err = coroutine.resume(co)
        if not ok then
            -- Lỗi ngoại lệ trong coroutine
            os.remove(temp_wav_path)
            if not is_cancelled and callback then callback(false, "Lỗi thực thi coroutine: " .. tostring(success_or_cont)) end
            return
        end

        if coroutine.status(co) == "dead" then
            -- Coroutine hoàn thành
            local is_success = success_or_cont
            local res = result_or_err
            if not is_cancelled and callback then callback(is_success, res) end
        else
            -- Coroutine đang yield, hẹn lịch kiểm tra tiếp sau 20ms nếu chưa bị hủy
            if not is_cancelled then
                UIManager:scheduleIn(0.02, pump)
            else
                os.remove(temp_wav_path)
            end
        end
    end

    -- Kích hoạt nhịp bơm đầu tiên
    pump()
    return cancel_handle
end

--- Cơ chế fallback sử dụng curl (khi chạy trên môi trường test không có socket nhị phân)
function TTSClient:_fetchViaCurl(server_url, payload, api_key, timeout, temp_wav_path, final_wav_path, callback)
    local tmp_json = temp_wav_path .. ".json"
    local jf = io.open(tmp_json, "w")
    if jf then
        jf:write(payload)
        jf:close()
    end

    local url_info = parse_url(server_url)
    local full_endpoint = string.format("%s://%s:%d%s", url_info.scheme, url_info.host, url_info.port, url_info.path)

    local auth_header = (api_key and api_key ~= "") and string.format('-H "Authorization: Bearer %s"', api_key) or ""
    local curl_cmd = string.format(
        'curl -s -X POST "%s" -H "Content-Type: application/json" %s -d @"%s" -o "%s" --max-time %d',
        full_endpoint, auth_header, tmp_json, temp_wav_path, timeout
    )

    -- Chạy curl qua UIManager:scheduleIn để mô phỏng tính chất async
    UIManager:scheduleIn(0.05, function()
        local ok_exec = os.execute(curl_cmd)
        os.remove(tmp_json)

        local verify_file = io.open(temp_wav_path, "rb")
        if verify_file then
            local magic = verify_file:read(4)
            verify_file:close()
            if magic == "RIFF" then
                os.remove(final_wav_path)
                os.rename(temp_wav_path, final_wav_path)
                if callback then callback(true, final_wav_path) end
                return
            end
        end
        os.remove(temp_wav_path)
        if callback then callback(false, "Lỗi tải âm thanh từ server qua cURL") end
    end)
end

-- Export helper functions for testing
TTSClient._fnv1a_hash = fnv1a_hash
TTSClient._json_encode = json_encode
TTSClient._parse_url = parse_url

return TTSClient
