local _ = require("bilicomics/ui/i18n")
local Model = {}

function Model.array(value)
    if type(value) ~= "table" then return {} end
    return value.items or value.comics or value.episodes or value.jobs or value
end

function Model.readable(episode)
    return episode.access == "free" or episode.access == "owned" or episode.access == "temporary"
end

function Model.downloadable(episode)
    if type(episode.offline_allowed) == "boolean" then return episode.offline_allowed end
    if type((episode.extra or {}).offline_allowed) == "boolean" then return episode.extra.offline_allowed end
    return episode.access == "free" or episode.access == "owned"
end

function Model.currentEpisode(comic, episodes)
    local extra = comic.extra or {}
    local id = comic.current_episode_id or comic.last_episode_id or extra.current_episode_id or extra.last_episode_id
    if id then return tostring(id) end
    for _index, episode in ipairs(episodes or {}) do
        if episode.current or episode.read == "reading" then return tostring(episode.id) end
    end
end

function Model.reading(episode, current_id)
    if tostring(episode.id) == tostring(current_id) then return _("Reading") end
    if episode.read == true or episode.read == "read" or episode.read == "complete" then return _("Read") end
    return _("Unread")
end

function Model.entitlement(episode)
    local labels = { free = _("Free"), owned = _("Purchased"), temporary = _("Temporary access"),
        locked = _("Locked"), unavailable = _("Unavailable"), unknown = _("Check access") }
    return labels[episode.access] or labels.unknown
end

function Model.entitlementExpiry(episode)
    if episode.access ~= "temporary" then return nil end
    local expiry = episode.expires_at
    if type(expiry) ~= "number" or expiry ~= expiry or expiry <= 0 or expiry > 253402300799 or expiry % 1 ~= 0 then
        return _("Temporary access expiry is unknown.")
    end
    local ok, formatted = pcall(function()
        local utc = os.date("!*t", expiry)
        if type(utc) ~= "table" or utc.year < 1970 or utc.year > 9999 then return nil end
        local function beforeYear(year)
            local previous = year - 1
            return previous * 365 + math.floor(previous / 4) - math.floor(previous / 100) + math.floor(previous / 400)
        end
        local month_days = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }
        local days = beforeYear(utc.year) - beforeYear(1970) + month_days[utc.month] + utc.day - 1
        if utc.month > 2 and utc.year % 4 == 0 and (utc.year % 100 ~= 0 or utc.year % 400 == 0) then days = days + 1 end
        -- Reject platform time-range wrapping instead of displaying a different instant.
        if days * 86400 + utc.hour * 3600 + utc.min * 60 + utc.sec ~= expiry then return nil end
        return string.format("%04d-%02d-%02d %02d:%02d:%02d", utc.year, utc.month, utc.day, utc.hour, utc.min, utc.sec)
    end)
    if not ok or not formatted then return _("Temporary access expiry is unknown.") end
    return string.format(_("Temporary access expires: %s (UTC)"), formatted)
end

function Model.storage(episode)
    local extra = episode.extra or {}
    local state = episode.download_state or extra.download_state
    if episode.downloaded or extra.downloaded or state == "complete" then return _("Downloaded") end
    if state == "paused" then return _("Paused") end
    if state == "running" or state == "queued" then return _("Downloading") end
    if state == "failed" then return _("Download failed") end
    local ready = episode.cached_pages or extra.cached_pages or 0
    local total = episode.total_pages or extra.total_pages or 0
    if ready > 0 and total > 0 then return string.format(_("Cached %d/%d"), ready, total) end
    return ready > 0 and _("Partly cached") or _("Not downloaded")
end

function Model.bytes(value)
    value = tonumber(value) or 0
    if value >= 1073741824 then return string.format("%.1f GiB", value / 1073741824) end
    return string.format("%.1f MiB", value / 1048576)
end

function Model.error(error)
    error = type(error) == "table" and error or { message = tostring(error or "") }
    local kind = error.kind
    if kind == "selection_changed" then
        return _("Purchase selection changed"), _("The available range or payment option changed. Review the retained selection and request a new quote before confirming.")
    elseif kind == "invalid_selection" or kind == "invalid_scope" or kind == "invalid_payment" then
        return _("Purchase selection is unavailable"), _("Choose a supported range and payment option. No purchase was submitted for this selection.")
    elseif kind == "quote_unverified" then
        return _("Purchase quote is not verified"), _("The exact chapter set, final charge or payment asset is not confirmed. This selection cannot be submitted; choose another option or return to a single chapter.")
    elseif kind == "version_replaced" then
        return _("Older version is retained"), _("Only already cached pages can be read in this older version. Open the chapter catalog or download the new version to continue.")
    elseif kind == "source_unavailable" then
        return _("Image sources are unavailable"), _("The saved chapter has no usable source for the missing pages. Open Downloads and choose a recovery option before continuing.")
    elseif kind == "version_replacement_interrupted" then
        return _("New version preparation was interrupted"), _("The retained version and its reading position are unchanged. Choose Redownload as new version again when ready.")
    elseif kind == "content_changed" then
        return _("Chapter content differs"), _("The refreshed content does not match this chapter. Existing cache and reading progress are retained; the new image sources were not applied.")
    elseif kind == "unknown_history" then
        return _("Image history cannot be verified"), _("This chapter lacks trustworthy image history. Existing cache and reading progress are retained; the new image sources were not applied.")
    elseif kind == "unverified_position" then
        return _("Reading position cannot be verified"), _("The saved position cannot be safely matched to verified images. Existing cache and reading progress are retained; the new image sources were not applied.")
    elseif kind == "reference_changed" then
        return _("Saved images changed during verification"), _("A saved image changed while it was being checked. Source refresh was not applied and did not replace the cache or move your reading position.")
    elseif kind == "stale_source_refresh" then
        return _("Source verification became outdated"), _("The chapter state changed during verification. Source refresh was not applied. Close the chapter and review its download state before trying again.")
    elseif kind == "source_refresh_interrupted" then
        return _("Source verification was interrupted"), _("Existing cache and reading progress are retained. Close the chapter, then explicitly refresh its image sources again when ready.")
    elseif kind == "busy" and error.code == "chapter_active" then
        return _("Close the chapter first"), _("Close this chapter in the native reader before recovering its download. Existing cache and reading progress are retained.")
    elseif kind == "invalid_comic_id" then
        return _("Comic ID is invalid"), _("Enter a positive ID of up to 15 digits. The optional mc prefix is accepted.")
    elseif kind == "no_next_chapter" then
        return _("No more chapters"), _("Refresh the comic details to check for new chapters.")
    elseif kind == "session_changed" then
        return _("Session changed"), _("Your sign-in was renewed. Refresh the operation result before trying again."), "account"
    elseif kind == "session_refresh" or kind == "refresh_unknown" or kind == "refresh_rejected" or kind == "confirmation_unknown"
        or kind == "refresh_pending" or kind == "refresh_unavailable" or kind == "request_authentication" then
        return _("Session renewal needs attention"), _("Check your connection and try again. If renewal remains unavailable, sign in with a QR code from Account."), "account"
    elseif kind == "auth" or kind == "authentication" or kind == "login_required" or kind == "unauthorized" or kind == "session" then
        return _("Sign in required"), _("Import a valid Bilibili web session from Account, then refresh."), "account"
    elseif kind == "invalid_session" or kind == "account_mismatch" then
        return _("Session could not be imported"), _("Use an unmodified Cookie header from the account you want to sign in with."), "account"
    elseif kind == "capability" or kind == "unsupported" then
        return _("Service capability unavailable"), _("This operation is not supported by the current service connection. Update the plugin when support is available.")
    elseif kind == "locked" or kind == "access" then
        return _("Chapter is locked"), _("Review a purchase quote before reading or downloading this chapter.")
    elseif kind == "outcome_unknown" or kind == "purchase_unknown" then
        return _("Purchase result pending"), _("Refresh the purchase result. Do not submit another purchase while the result is unknown.")
    elseif kind == "network" or kind == "connectivity" or kind == "timeout" or kind == "transport" then
        return _("Connection failed"), _("Check the connection and try again. Downloaded chapters are available offline.")
    elseif kind == "active_content" or kind == "in_use" then
        return _("Chapter is open"), _("Close the current chapter before removing its downloaded images.")
    elseif kind == "low_space" then
        return _("Storage is nearly full"), _("Remove downloaded chapters or clear automatic cache, then resume the download.")
    elseif kind == "unsupported_image_size" then
        return _("Image is too large for this device"), _("This image needs a smaller or segmented source before it can be read safely.")
    end
    return _("Operation failed"), _("The operation could not be completed. Refresh the page and try again.")
end

function Model.pending(controller)
    if controller.getPendingPurchases then return Model.array(controller:getPendingPurchases()) end
    local account = controller:getAccount() or {}
    return account.pending_purchases or {}
end

function Model.quoteAmount(quote)
    if quote.submittable == false then return _("Not confirmed"), quote.method or "coin" end
    local amount = quote.amount or quote.total or quote.price
    if type(amount) == "table" then amount = amount.value or amount.amount end
    return tostring(amount or "?"), quote.currency or quote.asset or quote.payment or quote.method or "coins"
end

function Model.purchaseScope(scope)
    scope = type(scope) == "table" and scope or { kind = "single" }
    local result = {}
    for _index, key in ipairs({ "kind", "offer_index", "batch_limit", "start_ord", "order" }) do
        result[key] = scope[key]
    end
    result.kind, result.order = result.kind or "single", result.order or 1
    return result
end

function Model.purchaseRangeLabel(scope)
    if type(scope) ~= "table" or scope.kind ~= "batch" then return nil end
    local limit = scope.batch_limit
    if type(limit) ~= "number" or limit ~= limit or limit < 0 or limit > 9007199254740991
        or limit % 1 ~= 0 then return nil end
    if limit == 0 then return _("Remaining from this chapter") end
    return string.format(_("From this chapter: first %d locked chapters"), limit)
end

function Model.ordinalRange(quote)
    if type(quote) ~= "table" or quote.submittable == false or not Model.purchaseRangeLabel(quote.scope) then return false end
    local proof = quote.range_proof
    return type(proof) == "table" and proof.contract == "bilibili_pc_ordinal_range_v1"
        and proof.provenance == "primary_sdk_ordinal_contract_and_quote_catalog_consistency"
end

function Model.purchasePayment(payment)
    payment = type(payment) == "table" and payment or { method = "coin" }
    local result = { method = payment.method or "coin" }
    if type(payment.discount) == "table" then
        result.discount = { kind = payment.discount.kind, id = payment.discount.id }
    elseif result.method == "coin" then
        result.discount = { kind = "none" }
    end
    if type(payment.coupon_ids) == "table" then
        result.coupon_ids = {}
        for index, id in ipairs(payment.coupon_ids) do result.coupon_ids[index] = id end
    end
    return result
end

function Model.samePurchaseSelection(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not Model.samePurchaseSelection(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

function Model.purchaseNumber(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local number = tonumber(value)
    if not number or number ~= number or math.abs(number) == math.huge then return nil end
    return tostring(number)
end

function Model.couponIdentifiers(quote)
    if type(quote) ~= "table" or quote.submittable == false or type(quote.payment) ~= "table"
        or quote.payment.method ~= "coupon" then return nil end
    local ids = quote.payment.coupon_ids
    if type(ids) ~= "table" or #ids == 0 or #ids > 1024 then return nil end
    local count, result = 0, {}
    for key in pairs(ids) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #ids then return nil end
        count = count + 1
    end
    if count ~= #ids then return nil end
    for index, id in ipairs(ids) do
        if type(id) ~= "string" or #id == 0 or #id > 256 or id:find("[%c]") then return nil end
        result[index] = id
    end
    return result
end

return Model
