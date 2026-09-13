local Errors = {}

function Errors.new(kind, message, fields)
    local err = { kind = kind, message = message, retryable = false }
    for key, value in pairs(fields or {}) do err[key] = value end
    return err
end

function Errors.capability(name, message)
    return Errors.new("capability", message or "This protocol capability is not available in this installation.", {
        capability = name,
        transmitted = false,
    })
end

function Errors.business(code, endpoint)
    code = tonumber(code) or code
    if code == -101 or code == -111 or code == 401 then
        return Errors.new("authentication", "The imported session is missing, expired, or rejected.", { code = code })
    end
    if endpoint == "GetImageIndex" then
        if code == 1 then return Errors.new("locked", "This episode requires confirmed access.", { code = code }) end
        if code == 501 then return Errors.new("unavailable", "This episode is unavailable.", { code = code }) end
    end
    if endpoint == "BuyEpisode" then
        local reasons = {
            [1] = "The selected coupons are insufficient.",
            [2] = "The available currency is insufficient.",
            [3] = "The server rejected the current purchase settings.",
            [4] = "The payable amount changed. Request a new quote.",
            [5] = "The selected coupons are not eligible for this episode.",
        }
        if reasons[code] then
            return Errors.new("purchase_rejected", reasons[code], { code = code, definitive = true, transmitted = true })
        end
        return Errors.new("purchase_unknown", "The service returned an unrecognized purchase result. Refresh episode access before retrying.", {
            code = code, definitive = false, transmitted = true,
        })
    end
    return Errors.new("business", "The service rejected this request.", { code = code })
end

return Errors
