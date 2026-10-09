--[[
    ffi_loader.lua - Platform & Architecture detection and safe library loader
    Project: KOReader TTS Plugin
    Layer: Bridge / FFI
--]]

local ffi = require("ffi")

local FfiLoader = {}

--- Returns candidate library paths based on target OS and architecture.
-- @param base_dir Base plugin directory path
-- @return table Array of candidate file paths
function FfiLoader.getCandidatePaths(base_dir)
    base_dir = base_dir or ""
    if base_dir ~= "" and not base_dir:match("[/\\]$") then
        base_dir = base_dir .. "/"
    end

    local os_name = ffi.os
    local arch_name = ffi.arch
    local paths = {}

    if os_name == "Windows" then
        -- Windows host development testing only
        table.insert(paths, base_dir .. "rust_core/target/release/tts_core.dll")
        table.insert(paths, base_dir .. "rust_core/target/debug/tts_core.dll")
    elseif os_name == "Linux" or os_name == "POSIX" or os_name == "Android" then
        if arch_name == "arm64" or arch_name == "aarch64" then
            table.insert(paths, base_dir .. "libs/arm64-v8a/libtts_core.so")
        elseif arch_name == "arm" then
            table.insert(paths, base_dir .. "libs/armeabi-v7a/libtts_core.so")
            table.insert(paths, base_dir .. "libs/kindle-armhf/libtts_core.so")
            table.insert(paths, base_dir .. "libs/kobo-armv7l/libtts_core.so")
        else
            table.insert(paths, base_dir .. "libs/x86_64/libtts_core.so")
        end
        table.insert(paths, base_dir .. "rust_core/target/release/libtts_core.so")
        table.insert(paths, base_dir .. "rust_core/target/debug/libtts_core.so")
        table.insert(paths, "libtts_core.so")
    end

    return paths
end

--- Attempts to safely load the native library across candidate paths.
-- @param base_dir Base plugin directory path
-- @return lib Handle to loaded shared library, or nil
-- @return path Path of successfully loaded library, or nil
function FfiLoader.load(base_dir)
    local candidates = FfiLoader.getCandidatePaths(base_dir)
    for _, path in ipairs(candidates) do
        local ok, lib = pcall(ffi.load, path)
        if ok and lib then
            return lib, path
        end
    end
    return nil, nil
end

return FfiLoader
