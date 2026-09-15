local Recharge = require("bilicomics/protocol/recharge")
local Service = require("bilicomics/recharge/service")
local Util = require("bilicomics/util")

local CONFIG_TTL = 300
local PAGE_SIZE, MAX_PAGES = 50, 10

local function copy(value)
    return value ~= nil and Util.copy(value) or nil
end

local function rejected(kind, message)
    return Util.error(kind, message, { transmitted = false, definitive = true })
end

local function available(controller, account)
    if controller.closed or not account or controller.account ~= account then
        return rejected("closed", "The recharge account is no longer active.")
    end
    if not account.session or not account.session_valid or account.authentication_invalidated then
        return rejected("authentication", "Sign in before recharging this account.")
    end
    if controller.suspended or not controller:_connected() then
        return rejected("network", "Connect before using online recharge.")
    end
end

return function(Controller)
    function Controller:_rechargeService(account)
        account = account or self.account
        if not account then return nil, rejected("closed", "The recharge account is closed.") end
        if not account.recharge_service then
            local service = Service.new{ store = account.store, account_key = account.key, clock = self.clock }
            local recovered, err = service:recover()
            if not recovered then return nil, err end
            account.recharge_service = service
        end
        return account.recharge_service
    end

    function Controller:getRechargeOrders()
        local service, err = self:_rechargeService()
        if not service then return {}, err end
        local orders
        orders, err = service:list()
        return orders or {}, err
    end

    function Controller:getRechargeConfigSnapshot()
        return self.account and copy(self.account.recharge_config) or nil
    end

    function Controller:getRechargeConfig(callback)
        local account = self.account
        local err = available(self, account)
        if err then self:_later(callback, nil, err); return end
        if account.recharge_config_waiters then
            account.recharge_config_waiters[#account.recharge_config_waiters + 1] = callback
            return account.recharge_config_request
        end
        account.recharge_config_waiters = { callback }
        local function finish(config, failure)
            local waiters = account.recharge_config_waiters or {}
            account.recharge_config_waiters, account.recharge_config_request = nil, nil
            account.recharge_config = nil
            if config then
                config = Util.copy(config)
                config.confirmation_token, config.account_key = Util.id("recharge-confirm"), account.key
                config.loaded_at = self.clock()
                account.recharge_config = Util.copy(config)
            end
            for _, waiter in ipairs(waiters) do Util.callback(waiter, copy(config), failure) end
        end
        local ok, task = pcall(self._client, self, "getRechargeConfig", {}, finish,
            { resource = "recharge_read", priority = -5, cancelable = true })
        if not ok then finish(nil, rejected("worker", "Recharge options could not be requested."))
        elseif account.recharge_config_waiters then account.recharge_config_request = task end
        return ok and task or nil
    end

    function Controller:createRechargeOrder(input, callback, confirmation_token)
        local account = self.account
        local err = available(self, account)
        if err then self:_later(callback, nil, err); return end
        local config, now = account.recharge_config, self.clock()
        if not config or config.account_key ~= account.key or type(confirmation_token) ~= "string"
            or confirmation_token ~= config.confirmation_token or not config.loaded_at
            or now < config.loaded_at or now - config.loaded_at > CONFIG_TTL then
            self:_later(callback, nil, rejected("confirmation_required", "Reload recharge options and confirm the amount again."))
            return
        end
        local cents, option = Recharge.parseAmount(input, config)
        if not cents then self:_later(callback, nil, option); return end
        local fingerprint = Recharge.optionFingerprint(option, config)
        if not fingerprint or fingerprint ~= option.fingerprint then
            self:_later(callback, nil, rejected("recharge_config_changed", "Reload the changed recharge options before confirming."))
            return
        end
        local service
        service, err = self:_rechargeService(account)
        if not service then self:_later(callback, nil, err); return end
        local record
        record, err = service:prepare(cents, { confirmation_token = confirmation_token, account_key = account.key,
            config_snapshot = { option = option, notice = config.notice, fingerprint = fingerprint }, confirmed_at = now })
        if not record then
            local existing = err and err.local_id and service:get(err.local_id) or nil
            self:_later(callback, existing, err)
            return
        end
        -- The persisted confirmation is consumed before a worker can transmit anything.
        account.recharge_config.confirmation_token = nil
        account.recharge_creating = record.id
        local observed, observed_error, observation_done
        local function observe(value, failure)
            if observation_done then return end
            observation_done = true
            observed, observed_error = service:completeCreation(record.id, value, failure)
            account.recharge_creating = nil
        end
        local function finish(value, failure)
            observe(value, failure)
            Util.callback(callback, observed, observed_error or failure)
            self:_notify()
        end
        local generation = self.generation
        local ok, task = pcall(self._submit, self,
            { kind = "recharge", local_id = record.id, amount_cents = cents, option_fingerprint = fingerprint },
            { resource = "recharge", priority = -10, cancelable = false, timeout = 120,
                on_observed = observe,
                before_start = function()
                    local failure = available(self, account)
                    if failure then return nil, failure end
                    if generation ~= self.generation then
                        return nil, rejected("account_mismatch", "The recharge confirmation belongs to an earlier account session.")
                    end
                    local saved, read_error = service:get(record.id)
                    if not saved or read_error or saved.state ~= "creating" or saved.persistence_pending then
                        return nil, rejected("persistence_pending", "The recharge intent is not durably ready for submission.")
                    end
                    return true
                end }, finish)
        if not ok then
            -- An exception may happen after dispatch. Preserve uncertainty and never replay.
            finish(nil, Util.error("recharge_unknown", "The worker outcome is unknown; check recharge records."))
        end
        self:_notify()
        return ok and task or nil
    end

    function Controller:refreshRechargeOrder(local_id, callback)
        local account = self.account
        local service, err = self:_rechargeService(account)
        if not service then self:_later(callback, nil, err); return end
        local record
        record, err = service:get(local_id)
        if not record then self:_later(callback, nil, err); return end
        if record.persistence_pending then
            local flushed
            flushed, err = service:flush()
            record = service:get(local_id) or record
            if not flushed then self:_later(callback, record, err); return end
        end
        if record.state == "credited" then self:_later(callback, record); return end
        err = available(self, account)
        if err then self:_later(callback, record, err); return end
        if not record.order_id then
            self:_later(callback, record, Util.error(record.state == "creating" and "recharge_busy" or "recharge_unknown",
                "This recharge has no exact server order identity to reconcile."))
            return
        end
        account.recharge_checks = account.recharge_checks or {}
        local existing = account.recharge_checks[local_id]
        if existing then existing.waiters[#existing.waiters + 1] = callback; return existing.task_id end
        local check = { waiters = { callback }, seen = {}, year_index = 1, page = 1 }
        account.recharge_checks[local_id] = check
        local years, included = {}, {}
        local function addYear(timestamp)
            -- The service is based in China; include UTC as well at year boundaries.
            for _, offset in ipairs({ 28800, 0 }) do
                local year = tonumber(os.date("!%Y", timestamp + offset))
                if not included[year] then included[year] = true; years[#years + 1] = year end
            end
        end
        addYear(self.clock()); addYear(record.created_at)
        local function finish(value, failure)
            if account.recharge_checks[local_id] ~= check then return end
            account.recharge_checks[local_id] = nil
            for _, waiter in ipairs(check.waiters) do Util.callback(waiter, Util.copy(value or record), failure) end
            if value and value.state == "credited" and not value.persistence_pending then self:refreshWallet(function() end) end
            self:_notify()
        end
        local fetch
        local function nextYear()
            check.year_index, check.page, check.seen = check.year_index + 1, 1, {}
            if not years[check.year_index] then
                local updated, failure = service:applyHistory(local_id, {})
                finish(updated, failure or check.limit_error)
            else fetch() end
        end
        fetch = function()
            local completed = false
            local task = self:_client("rechargeHistory", { { page_num = check.page, page_size = PAGE_SIZE,
                order_year = years[check.year_index], order_month = 0 } }, function(history, failure)
                completed = true
                if failure or type(history) ~= "table" or type(history.records) ~= "table" then
                    finish(nil, failure or Util.error("protocol", "The recharge history response is incomplete.")); return
                end
                local fresh = false
                for _, item in ipairs(history.records) do
                    if item.order_id == record.order_id then
                        local updated, save_error = service:applyHistory(local_id, { item })
                        finish(updated, save_error); return
                    end
                    if item.order_id and not check.seen[item.order_id] then fresh = true; check.seen[item.order_id] = true end
                end
                if #history.records < PAGE_SIZE then nextYear()
                elseif check.page >= MAX_PAGES or not fresh then
                    check.limit_error = Util.error("recharge_history_limit", "The bounded history search did not confirm this order; check again later.")
                    nextYear()
                else check.page = check.page + 1; fetch() end
            end, { resource = "recharge_read", priority = -5, cancelable = true })
            if not completed then check.task_id = task end
        end
        local ok = pcall(fetch)
        if not ok then finish(nil, Util.error("worker", "Recharge history could not be requested.")) end
        return check.task_id
    end
end
