-- Audit all chosen bookshelf, bookstore, and search artboards in the real UI.
-- Imported by the native handoff harness; every controller record is synthetic.
return function(ctx)
    local c, W, T = ctx.controller, ctx.W, ctx.T
    local function screens() return ctx.screens() end
    local function capture(id, name) ctx.capture(id .. "-" .. name, { design_id = id }) end
    local function line(label, surface)
        return ctx.visit(surface or screens().widget, function(item)
            return item.text == label and type(item.getSize) == "function"
        end)[1]
    end
    local function measure(name, item, expected)
        if not ctx.scribe then return end
        local actual = ctx.rectangle(assert(item, name .. " requires a painted widget"))
        for key, value in pairs(expected) do
            ctx.check(name .. "_" .. key, math.abs(actual[key] - W.dp(value)) <= 1,
                { actual_px = actual[key], expected_dp = value })
        end
    end
    local function allActionsFit(name, surface)
        local overflow = {}
        for _, item in ipairs(ctx.visit(surface or screens().dialog or screens().widget, function(widget)
            return type(widget.callback) == "function" and type(widget.getSize) == "function"
        end)) do
            local r = ctx.rectangle(item)
            if r.w > 0 and r.h > 0 and (r.x < -1 or r.y < -1 or r.x + r.w > ctx.width + 1 or r.y + r.h > ctx.height + 1) then
                overflow[#overflow + 1] = r
            end
        end
        ctx.check(name .. "_all_native_action_bounds_fit", #overflow == 0, #overflow > 0 and overflow or nil)
    end
    local function readyEpisodes()
        for _, episode in ipairs(c.episodes) do
            episode.access, episode.offline_allowed, episode.downloaded = "owned", true, true
        end
    end
    ctx.scenario("all-bookshelf-artboards", function()
        local s = screens()
        s:showLibrary(); capture("A1", "default")
        measure("A1_hero", s.resume_card, { x = 56, y = 150, w = 216, h = 288 })
        measure("A1_first_grid", s.cards[1], { x = 56, y = 555 })
        if ctx.scribe then ctx.check("A1_ten_grid_cards", #s.cards == 10) end
        local expected = s:getInitialBookshelfCoverIDs(c.comics)
        local painted = { tostring(s.resume_comic.id) }
        for _, card in ipairs(s.cards) do painted[#painted + 1] = tostring(card.comic.id) end
        ctx.check("A6_first_sync_cover_ids_match_rendered_view", table.concat(expected, ",") == table.concat(painted, ","))
        s:_bookshelfMore(); capture("A2", "more")
        if ctx.scribe then
            local r = s.dialog.panel_dimen
            ctx.check("A2_panel_440dp_right40_top104", r and r.w == W.dp(440) and r.x == ctx.width - W.dp(480) and r.y == W.dp(104), r)
        end
        allActionsFit("A2"); ctx.closeDialog()
        s:_bookshelfFilter(); capture("A2", "filter-options"); allActionsFit("bookshelf_filter")
        ctx.pressDialog("Updated"); capture("A3", "filtered")
        ctx.check("A3_condition_includes_true_match_count", ctx.shownText(s.widget):find(string.format(T(" · %d comics have new chapters"), 12), 1, true) ~= nil)
        local last_grid = ctx.rectangle(s.cards[#s.cards])
        ctx.check("A3_grid_metadata_stays_above_navigation", last_grid.y + last_grid.h <= ctx.height - W.dp(88), last_grid)
        ctx.check("A3_clear_action_stays_inside_condition_border", ctx.button(s.widget, T("Clear filter") .. " ×"):getSize().h == W.dp(59))
        s:_bookshelfSort(); capture("A2", "sort-options"); allActionsFit("bookshelf_sort"); ctx.closeDialog()
        s:_bookshelfHelp(); capture("A2", "usage-help"); allActionsFit("bookshelf_help"); ctx.closeDialog()
        s.filter = "all"
        local saved = ctx.copy(c.episodes)
        readyEpisodes(); c.comics[2].cover_path = nil; c.comics[3].finished, c.comics[3].latest_order = true, #c.episodes
        c.sync.offline = true; s:refresh(); capture("A4", "offline")
        ctx.check("A4_full_downloaded_series_is_reported", ctx.hasText(s.widget, "Offline · Complete series"))
        ctx.check("A4_uncached_cover_is_explicit", ctx.hasText(s.widget, "Cover not cached"))
        c.episodes = saved
        ctx.populate(0, false); c.signed_in, c.sync.authenticated, c.sync.offline = false, false, false
        s:refresh(); capture("A5", "signed-out")
        measure("A5_sign_in", ctx.button(s.widget, "Sign in with QR code"), { w = 360, h = 68 })
        ctx.check("A5_explore_copy_is_restored", ctx.hasText(s.widget, "Explore Bookstore"))
        allActionsFit("A5")
        ctx.activate(ctx.button(s.widget, "Sign in with QR code"))
        ctx.check("A5_qr_keeps_bookshelf_origin", s.route == "favorites" and s.qr_login ~= nil)
        ctx.closeDialog()
        c.signed_in, c.sync.authenticated = true, true
        c.sync.has_cache, c.sync.syncing, c.sync.first_sync, c.sync.phase = true, true, true, "covers"
        c.sync.comics_count, c.sync.covers_ready, c.sync.covers_total, c.sync.progress = 23, 6, 10, 0.6
        ctx.populate(23, false); s:refresh(); capture("A6", "first-sync-covers")
        ctx.check("A6_saved_list_is_not_a_partial_grid", #s.cards == 0 and s.resume_comic == nil)
        ctx.check("A6_true_cover_counter_is_visible", ctx.shownText(s.widget):find("6 / 10", 1, true) ~= nil)
        ctx.check("A6_actual_fetched_count_is_visible", ctx.hasText(s.widget, string.format(T("Fetched %d comics · Preparing visible covers"), 23)))
        measure("A6_heading", line(T("Syncing bookshelf…")), { x = 56, y = 180 })
        allActionsFit("A6")
        c.sync.phase, c.sync.comics_count = "library", 0; s:refresh(); capture("A6", "first-sync-library")
        ctx.check("A6_library_phase_does_not_claim_cover_work", not ctx.hasText(s.widget, string.format(T("Fetched %d comics · Preparing visible covers"), 0)))
        ctx.check("A6_library_phase_is_explicit", ctx.hasText(s.widget, "Fetching your bookshelf and reading progress…"))
        c.sync.syncing, c.sync.first_sync = false, false; s:refresh(); capture("A6", "completed-once")
        ctx.check("A6_completion_reveals_grid_together", #s.cards > 0)
    end)
    ctx.scenario("all-bookstore-artboards", function()
        local s = screens()
        s:showBookstore(); capture("B1", "recommendations")
        measure("B1_first_cover", s.cards[1], { x = 56, y = 204 })
        if ctx.scribe then ctx.check("B1_twelve_cards", #s.cards == 12 and s.cards[1].cover_height == W.dp(240)) end
        local native_categories = c.getBookstoreCategories
        local category_items = {}
        for index = 1, 17 do category_items[index] = { id = tostring(index), name = "Subject " .. index } end
        c.getBookstoreCategories = function() return { stale = false, updated_at = 1801326000, items = category_items } end
        s:_bookstoreCategoryPicker(); capture("B2", "category-picker")
        if ctx.scribe then
            local r = s.dialog.panel_dimen
            ctx.check("B2_panel_margins72_top176", r and r.x == W.dp(72) and r.y == W.dp(176) and r.w == ctx.width - W.dp(144), r)
        end
        allActionsFit("B2")
        ctx.check("B2_update_time_visible_with_pagination", ctx.shownText(s.dialog):find("18:20", 1, true) ~= nil
            or ctx.shownText(s.dialog):find("20:20", 1, true) ~= nil or ctx.shownText(s.dialog):find("%d%d:%d%d") ~= nil)
        s.dialog:onNextPage(); capture("B2", "category-page-two"); allActionsFit("B2_page_two")
        ctx.closeDialog(); c.getBookstoreCategories = native_categories
        local comic = c.comics[2]
        comic.latest_order = 76
        comic.extra = { tags = { "Adventure", "Growth", "Drama" }, recommendation_section = "recommendation" }
        comic.description = "The last lighthouse keeper travels beyond a quiet harbor, carrying half an old map and searching for a light that can guide everyone home."
        s:_bookstoreSynopsis(comic); capture("B3", "synopsis")
        local cover = ctx.visit(s.dialog, function(item) return item.outer_width == W.dp(150) and item.outer_height == W.dp(200) end)[1]
        measure("B3_cover", cover, { x = 56, w = 150, h = 200 })
        ctx.check("B3_source_is_present", ctx.hasText(s.dialog, "Official recommendation"))
        ctx.check("B3_publication_count_is_present", ctx.hasText(s.dialog, string.format(T("Serialized through %s chapters"), "76")))
        local chips = ctx.visit(s.dialog, function(item) return item.bordersize == W.dp(1.5) and item:getSize().h == W.dp(31.8) end)
        ctx.check("B3_tags_are_framed_native_chips", #chips == 3)
        allActionsFit("B3"); ctx.closeDialog()
        comic.description = string.rep("A complete long synopsis remains readable across native pages. ", 60)
        s:_bookstoreSynopsis(comic); capture("B3", "long-synopsis-first")
        local first = ctx.shownText(s.dialog)
        s.dialog:onNextPage(); capture("B3", "long-synopsis-next")
        ctx.check("B3_long_synopsis_has_paged_content", ctx.shownText(s.dialog) ~= first)
        allActionsFit("B3_long"); ctx.closeDialog()
        c.feed_items, c.feed_stale, c.sync.offline = {}, true, true
        s.bookstore_category, s.bookstore_query = { id = "1", name = "Adventure" }, { kind = "category", category_id = "1", sort = 0 }
        s:showBookstore(); ctx.finish("refreshBookstore", nil, { kind = "network" }); capture("B4", "offline-no-cache")
        ctx.check("B4_has_cached_alternative", ctx.hasText(s.widget, "View all recommendations"))
        ctx.check("B4_has_honest_no_cache_explanation", ctx.hasText(s.widget, "This category has no saved content. Saved recommendations remain available offline."))
        measure("B4_retry", ctx.button(s.widget, "Retry"), { w = 320, h = 68 })
        allActionsFit("B4")
    end)
    ctx.scenario("all-search-artboards", function()
        local s = screens()
        c.settings.search_history = { "Horizon", "Harbor", "Paper", "Crane", "Map" }
        s:showSearch(); capture("C1", "initial")
        measure("C1_field", s.search_field, { y = 151.5 })
        allActionsFit("C1")
        c.settings.search_history = { "Horizon", "Harbor", "Paper", "Crane", "Map", "Night", "Light", "Rain" }
        s:refresh(); capture("C1", "history-first-page")
        local first_page = s.page
        s.widget:onNextPage(); capture("C1", "history-next-page")
        ctx.check("C1_all_recent_searches_remain_reachable", s.pages > 1 and s.page == first_page + 1)
        while s.page < s.pages do s.widget:onNextPage() end
        capture("C1", "history-last-page")
        ctx.check("C1_last_recent_search_is_present", ctx.hasText(s.widget, "Rain"))
        allActionsFit("C1_history_last")
        s:_lookupComicID(); capture("C1", "comic-id-native-input"); allActionsFit("comic_id"); ctx.closeDialog()
        s:_editSearch()
        if s.dialog.skip_first_show_keyboard then s.dialog.skip_first_show_keyboard = false end
        if not s.dialog:isKeyboardVisible() then s.dialog:onShowKeyboard() end
        capture("C2", "native-input-keyboard")
        ctx.check("C2_native_keyboard_is_visible", s.dialog:isKeyboardVisible())
        measure("C2_dialog", s.dialog.dialog_frame, { x = 56, y = 160, w = 818 })
        allActionsFit("C2"); ctx.closeDialog()
        c.comics[1].latest_order = 128
        s:_runSearch("Horizon"); ctx.finish("search", { c.comics[1], c.comics[2], c.comics[3], c.comics[4], c.comics[5], c.comics[6] })
        capture("C3", "results")
        measure("C3_result_row", s.search_cards[1], { x = 56, y = 312, h = 130 })
        ctx.check("C3_author_and_metadata_present", ctx.hasText(s.widget, "Synthetic author"))
        ctx.check("C3_publication_count_is_present", ctx.hasText(s.widget, string.format(T("Serialized through %s chapters"), "128")))
        allActionsFit("C3")
        s:_searchFilter(); capture("C3", "result-filter-options"); allActionsFit("search_filter"); ctx.closeDialog()
        s:_runSearch("Missing"); ctx.finish("search", {}); capture("C4", "no-results")
        ctx.check("C4_preserves_query", s.query == "Missing" and s.search_field.text == "Missing")
        ctx.check("C4_does_not_show_result_summary_chips", not ctx.button(s.widget, "Ongoing", true))
        measure("C4_change_search", ctx.button(s.widget, "Change search"), { w = 320, h = 68 })
        allActionsFit("C4")
        s:_runSearch("Network"); ctx.finish("search", nil, { kind = "network" }); capture("C4", "search-error")
        ctx.check("search_error_has_retry", ctx.hasText(s.widget, "Retry search"))
    end)
end
