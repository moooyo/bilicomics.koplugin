local gettext = require("gettext")

return function(message)
    local language = gettext.current_lang or "C"
    if language:match("^zh") then
        local ok, translations = pcall(require, "l10n/bilicomics_zh_CN")
        if ok and translations[message] then return translations[message] end
    end
    return gettext(message)
end
