local _ = require("bilicomics/ui/i18n")

local Helpers = {}

function Helpers.title(record)
    return record.title or record.short_title or tostring(record.id or "")
end

function Helpers.count(values)
    local total = 0
    for _ in pairs(values) do total = total + 1 end
    return total
end

function Helpers.asset(method)
    return method == "coupon" and _("coupons") or _("coins")
end

function Helpers.copy(items)
    local result = {}
    for _, item in ipairs(items) do result[#result + 1] = item end
    return result
end

function Helpers.accountKey(controller)
    local account = controller:getAccount() or {}
    return account.account_key or account.id
end

function Helpers.purchasePurpose(intent, fallback)
    local purpose = intent and intent.purpose or fallback
    return purpose == "download" and "download" or "read"
end

return Helpers
