local gettext = require("gettext")
local chinese

local function translations()
    if chinese then return chinese end
    chinese = {}
    for _, name in ipairs({ "bilicomics_zh_CN", "bilicomics_navigation_zh_CN", "bilicomics_catalog_zh_CN",
        "bilicomics_downloads_zh_CN", "bilicomics_account_zh_CN", "bilicomics_purchase_zh_CN", "bilicomics_recharge_zh_CN" }) do
        local ok, values = pcall(require, "l10n/" .. name)
        if ok then for key, value in pairs(values) do chinese[key] = value end end
    end
    return chinese
end

return function(message)
    local language = gettext.current_lang or "C"
    if language:match("^zh") then
        local value = translations()[message]
        if value then return value end
    end
    return gettext(message)
end
