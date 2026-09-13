local Platform = {}

function Platform.nativeTarget()
    local ffi = require("ffi")
    if ffi.os ~= "Linux" then return nil end
    local android = package.loaded.android
    local is_android = (android ~= nil and android ~= false)
        or os.getenv("ANDROID_ROOT") ~= nil or os.getenv("ANDROID_DATA") ~= nil
    if is_android then
        return ffi.arch == "arm64" and "android-arm64-v8a"
            or ffi.arch == "arm" and "android-armeabi-v7a"
            or ffi.arch == "x64" and "android-x86_64"
            or ffi.arch == "x86" and "android-x86"
            or nil
    end
    return ffi.arch == "x64" and "linux-x86_64"
        or ffi.arch == "arm64" and "linux-aarch64"
        or (ffi.arch == "arm" and ffi.abi("hardfp")) and "linux-armhf"
        or nil
end

return Platform
