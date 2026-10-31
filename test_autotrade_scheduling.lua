-- Scheduling and lifecycle hardening tests for adm_autotrade.lua.
-- Run from the repo root:
--   npx --yes --package fengari-node-cli fengari test_autotrade_scheduling.lua
--
-- These tests use the harness's deferred scheduling model: task.spawn queues a
-- coroutine and task.wait suspends it, so a callback that yields is observable
-- instead of silently running to completion. The other suites keep the
-- synchronous model. io.write is used because the harness replaces print.

local H = dofile("test_autotrade_harness.lua")

local WH = "ReceiverBot_winteraddons.json"
local real_clock = os.clock

local function fresh(opts)
    local h = H.new(opts or { scheduling = "deferred" })
    os.clock = function() return h.state.now end
    h.reset()
    h.state.now = 1000
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = nil
    h.app.state = nil
    h.app.my_offer = H.offer({})
    h.app.partner_offer = H.offer({})
    h.uimanager.apps.TradeApp = h.app
    h.uimanager.apps.DialogApp = h.dialog
    h.state.spawn_errors = {}
    h.state.prints = {}
    -- Log lines are the only record of fail-closed decisions.
    h.api.CONFIG.DEBUG = true
    return h
end

local function open(h, stage, partner)
    h.app.state = H.session(stage, partner)
    h.app.my_offer = H.offer({})
    h.app.partner_offer = H.offer({})
    return h.app.state
end

local function printed(h, needle)
    for _, line in ipairs(h.state.prints) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

local function webhook_titles(h)
    local titles = {}
    for _, req in ipairs(h.state.request_calls) do
        local body = req.Body
        if type(body) == "table" and type(body.embeds) == "table" then
            for _, embed in ipairs(body.embeds) do
                titles[#titles + 1] = embed.title
            end
        end
    end
    return titles
end

local function count_title(h, title)
    local n = 0
    for _, t in ipairs(webhook_titles(h)) do
        if t == title then n = n + 1 end
    end
    return n
end

local function session(h) return h.api.empty_trade.session end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- 1. A cancellation callback that yields must not stall the polling loop, and
--    must not be mistaken for a completed cancellation.
test("a suspended cancellation does not block the loop", function()
    local h = fresh()
    local finished = false
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function(app)
        for _ = 1, 3 do task.wait(0.1) end
        app.state = nil
        finished = true
        return true
    end

    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()          -- dispatch only; the callback is queued

    H.assert_eq(finished, false, "callback has not run yet")
    H.assert_eq(session(h).cancel_inflight, true, "marked in flight")
    H.assert_eq(session(h).cancelling, false, "no closure assumed")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing counted")
    H.assert_eq(h.pending() >= 1, true, "callback is queued")

    -- The loop keeps running while the request is unresolved.
    h.api.step_trade()
    H.assert_eq(h.app.accept_calls, 0, "no accept while unresolved")
    H.assert_eq(h.api.empty_trade.failures, 0, "still nothing counted")

    h.pump(2)
    H.assert_eq(session(h).cancel_inflight, true, "still suspended after 2 passes")
    H.assert_eq(h.api.empty_trade.failures, 0, "suspension is not success")

    h.pump(6)
    H.assert_eq(finished, true, "callback finished")
    H.assert_eq(session(h).cancel_inflight, false, "settled")
    H.assert_eq(session(h).cancelling, true, "awaiting observed close")
    H.assert_eq(h.api.empty_trade.failures, 0, "still not counted before closure")

    h.advance(1)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 1, "counted once the close is observed")
    H.assert_eq(session(h), nil, "session cleared")
    H.assert_eq(h.api.get_trade_count(), 0, "never a successful trade")
end)

-- 2. A callback that never returns is bounded and never counted.
test("a callback that never returns is bounded by the watchdog", function()
    local h = fresh()
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        while true do task.wait(1) end
    end

    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_inflight, true, "in flight")

    h.advance(h.api.EMPTY_CANCEL_CALL_WATCHDOG)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_inflight, true, "still inside the watchdog")

    h.advance(1)
    h.api.step_trade()
    local s = session(h)
    H.assert_eq(s.cancel_inflight, false, "watchdog released the session")
    H.assert_eq(s.cancel_outcome, "unknown", "outcome recorded as unknown")
    H.assert_eq(h.api.empty_trade.stuck, true, "WinterHub rejoin requested")
    H.assert_eq(h.api.empty_trade.stuck_reason, "cancellation_outcome_unknown", "reason")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing counted")

    -- An unknown outcome keeps blocking actions on later polls.
    h.app.accept_calls = 0
    h.advance(2)
    h.api.step_trade()
    H.assert_eq(h.app.accept_calls, 0, "still blocked after the watchdog")
end)

-- 3. Heartbeat persistence is independent of a suspended cancellation.
test("the heartbeat keeps writing while cancellation is suspended", function()
    local h = fresh()
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        while true do task.wait(1) end
    end

    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat + 1)
    local wrote = h.api.write_winterhub()
    H.assert_eq(wrote, true, "status written during a suspended call")
    H.assert_true(h.state.writes[WH] ~= nil, "status file exists")
    H.assert_eq(h.state.writes[WH].status, "active", "still an open trade")
    H.assert_eq(h.pending() >= 1, true, "the callback is genuinely still suspended")
end)

-- 4. A throwing state getter is UNKNOWN, not a close.
test("a state getter exception is never treated as a close", function()
    local h = fresh()
    open(h, "negotiation")
    h.api.step_trade()
    local s = session(h)

    local saved = h.app._get_local_trade_state
    h.app._get_local_trade_state = function() error("state boom") end
    h.advance(20)
    h.api.step_trade()          -- must not raise and must not count

    H.assert_eq(session(h), s, "session held")
    H.assert_eq(h.api.empty_trade.failures, 0, "no failure")
    H.assert_eq(h.api.get_trade_count(), 0, "no success")
    H.assert_eq(#h.state.spawn_errors, 0, "no uncaught error escaped")
    H.assert_eq(printed(h, "trade state UNKNOWN this poll"), true, "unreadable logged")

    local probe, readable = h.api.read_state_safe(h.app)
    H.assert_eq(probe, nil, "no state")
    H.assert_eq(readable, false, "not readable")

    h.app._get_local_trade_state = saved
    h.app.state = nil
    h.api.step_trade()
    H.assert_eq(session(h), nil, "a real close still resolves the session")
    H.assert_eq(h.api.empty_trade.failures, 0, "unrelated close is not a failure")
end)

-- 5. A replacement TradeApp closing is not proof for the cancelled session.
test("a replacement TradeApp closing is not counted", function()
    local h = fresh({ scheduling = "sync" })
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function() return true end

    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()          -- accepted, window stays open
    H.assert_eq(session(h).cancelling, true, "awaiting close")

    local other = {}
    function other:_get_local_trade_state() return nil end
    h.uimanager.apps.TradeApp = other
    h.advance(1)
    h.api.step_trade()

    H.assert_eq(h.api.empty_trade.failures, 0, "a different app closing proves nothing")
    H.assert_eq(session(h), nil, "session released without counting")
    H.assert_eq(h.api.get_trade_count(), 0, "not a successful trade")
    H.assert_eq(printed(h, "replaced TradeApp"), true, "replacement explicitly logged")
end)

-- 6. An unreadable replacement does not resolve the session either.
test("an unreadable replacement does not close the session", function()
    local h = fresh({ scheduling = "sync" })
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function() return true end

    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()

    local broken = {}
    function broken:_get_local_trade_state() error("replacement boom") end
    h.uimanager.apps.TradeApp = broken
    h.advance(1)
    h.api.step_trade()

    H.assert_eq(h.api.empty_trade.failures, 0, "unreadable is not closed")
    H.assert_true(session(h) ~= nil, "session still held")
end)

-- 7. Partner items arriving during cancellation uncertainty recover the
--    session instead of leaving it permanently poisoned.
test("partner items during a suspended cancellation recover the session", function()
    local h = fresh()
    local finished = false
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        task.wait(1)
        finished = true
        return true
    end

    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_inflight, true, "request in flight")

    h.app.partner_offer = H.offer({ H.item("cat") })
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.stuck, false, "no rejoin request")
    H.assert_eq(session(h).cancel_outcome, nil, "outcome dropped")
    H.assert_eq(session(h).cancel_attempted, false, "history dropped")

    h.pump(3)
    H.assert_eq(finished, true, "callback finished")
    H.assert_eq(session(h).cancelling, false, "not waiting for a close")
    H.assert_eq(session(h).partner_seen, true, "items remembered")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing counted")

    -- Normal trading continues and a completion is countable.
    h.app.state = H.session("confirmation")
    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({ H.item("cat") }, true)
    h.api.step_trade()
    h.app.state = nil
    h.api.step_trade()
    H.assert_eq(h.api.get_trade_count(), 1, "recovered trade counted")
end)

-- 8. A legitimate completion after a FAILED cancellation is still counted.
test("success after a failed cancellation attempt is counted", function()
    local h = fresh({ scheduling = "sync" })
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        return false, "adapter_refused"
    end

    open(h, "confirmation")
    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({}, true)
    h.api.step_trade()          -- caches the completion

    h.advance(15)
    h.api.step_trade()          -- deadline: adapter refuses
    H.assert_eq(session(h).cancel_outcome, "failed", "failure recorded")
    H.assert_eq(h.api.empty_trade.stuck, true, "rejoin requested")
    H.assert_eq(h.api.empty_trade.failures, 0, "failure is not an empty-trade count")

    h.app.partner_offer = H.offer({ H.item("dog") })
    h.api.step_trade()          -- partner fills: recovery
    H.assert_eq(session(h).cancel_outcome, nil, "cancellation abandoned")
    H.assert_eq(session(h).cancel_attempted, false, "history cleared")
    H.assert_eq(h.api.empty_trade.stuck, false, "rejoin cleared")

    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({ H.item("dog") }, true)
    h.api.step_trade()          -- re-cache with both confirmed
    h.app.state = nil
    h.api.step_trade()

    H.assert_eq(h.api.get_trade_count(), 1, "recovered success counted")
    H.assert_eq(h.api.empty_trade.failures, 0, "streak reset by the success")
end)

-- 9. Confirmation cannot fire while a cancellation is unresolved.
test("confirmation cannot race an unresolved cancellation", function()
    local h = fresh()
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        while true do task.wait(1) end
    end

    open(h, "confirmation")
    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({}, true)
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_inflight, true, "in flight")

    h.app.confirm_calls, h.app.accept_calls = 0, 0
    for _ = 1, 6 do
        h.advance(2)
        h.api.step_trade()
    end
    H.assert_eq(h.app.confirm_calls, 0, "never confirmed")
    H.assert_eq(h.app.accept_calls, 0, "never accepted")
    H.assert_eq(h.api.get_completing(), false, "no cached success survives")
end)

-- 10. A slow webhook endpoint must not block the heartbeat write.
test("server-skipped delivery is queued off the heartbeat path", function()
    local h = fresh()
    h.api.empty_trade.failures = 3
    h.api.latch_empty_trade_limit()

    local real_request = _G.request
    _G.request = function(req)
        task.wait(0.5)          -- a slow endpoint
        return real_request(req)
    end

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat + 1)
    local wrote, dispatched = h.api.write_winterhub()

    H.assert_eq(wrote, true, "status written")
    H.assert_eq(dispatched, true, "webhook scheduled")
    H.assert_eq(#h.state.request_calls, 0, "no HTTP inside the heartbeat call")
    H.assert_eq(h.state.writes[WH].status, "completed", "completed persisted")

    h.pump(4)
    _G.request = real_request
    H.assert_eq(#h.state.request_calls, 1, "delivered after the pump")
    H.assert_eq(count_title(h, "Server Skipped"), 1, "one skip webhook")
end)

-- 11. The latch never reverts and keeps the real trade count.
test("the completion latch survives repeated heartbeats", function()
    local h = fresh()
    h.api.set_trade_count(7)
    h.api.empty_trade.failures = 3
    h.api.latch_empty_trade_limit()

    for i = 1, 3 do
        h.advance(h.api.CONFIG.WINTERHUB.heartbeat + 1)
        local wrote = h.api.write_winterhub()
        H.assert_eq(wrote, true, "write " .. i)
        H.assert_eq(h.state.writes[WH].status, "completed", "still completed " .. i)
        H.assert_eq(h.state.writes[WH].count, 7, "real count preserved " .. i)
    end
    H.assert_eq(h.api.empty_trade.latched, true, "latch held")
    h.pump(3)
    H.assert_eq(count_title(h, "Server Skipped"), 1, "skip notification not duplicated")
end)

-- 12. Full three-failure accounting path, end to end through the mocks.
test("three qualifying failures latch and notify exactly once", function()
    local h = fresh({ scheduling = "sync" })
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function(app)
        app.state = nil
        return true
    end

    for i = 1, 3 do
        open(h, "negotiation")
        h.api.step_trade()
        h.advance(15)
        h.api.step_trade()
        H.assert_eq(h.api.empty_trade.failures, i, "failure " .. i)
    end

    H.assert_eq(h.api.empty_trade.latched, true, "latched after three")
    H.assert_eq(h.api.empty_trade.latch_reason, "empty_trade_limit", "latch reason")
    H.assert_eq(h.api.get_trade_count(), 0, "no fabricated trade")

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat + 1)
    local wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "status written")
    H.assert_eq(dispatched, true, "skip webhook dispatched")
    H.assert_eq(h.state.writes[WH].status, "completed", "completed")
    H.assert_eq(count_title(h, "Trade Failed"), 3, "one failed webhook per failure")
    H.assert_eq(count_title(h, "Server Skipped"), 1, "exactly one skip webhook")

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat + 1)
    h.api.write_winterhub()
    H.assert_eq(count_title(h, "Server Skipped"), 1, "still one skip webhook")
end)

-- 13. Offer counting must never call a populated, unrecognised offer empty.
test("unrecognised offer entries still count as items", function()
    local h = fresh()
    local count, err = h.api.count_offer_items({ items = { { unknown_shape = true } } })
    H.assert_eq(count, 1, "table entry counts")
    H.assert_eq(err, nil, "no error")

    local strings = h.api.count_offer_items({ items = { "uid-1", "uid-2" } })
    H.assert_eq(strings, 2, "non-table entries count too")

    local empty = h.api.count_offer_items({ items = {} })
    H.assert_eq(empty, 0, "an empty offer is still empty")

    local nil_items, nil_err = h.api.count_offer_items({})
    H.assert_eq(nil_items, nil, "missing items is UNKNOWN")
    H.assert_eq(nil_err, "items_unavailable", "reason")

    local nil_offer = h.api.count_offer_items(nil)
    H.assert_eq(nil_offer, nil, "missing offer is UNKNOWN")
end)

-- 14. An unreadable offer never triggers a cancellation.
test("an unreadable offer never cancels even past the deadline", function()
    local h = fresh({ scheduling = "sync" })
    local calls = 0
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function() calls = calls + 1 return true end

    open(h, "negotiation")
    h.api.step_trade()
    h.app.partner_offer = nil
    h.advance(20)
    h.api.step_trade()
    H.assert_eq(calls, 0, "no cancellation on UNKNOWN")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing counted")

    h.app.partner_offer = { items = nil, confirmed = false }
    h.advance(5)
    h.api.step_trade()
    H.assert_eq(calls, 0, "still no cancellation")
end)

-- 15. Without WinterHub nobody consumes the status, so an uncancellable empty
--     trade must still refuse to confirm - and say so once, not spam.
test("no WinterHub: still blocked, warned exactly once", function()
    local h = fresh({ scheduling = "sync" })
    h.api.CONFIG.WINTERHUB.enabled = false
    -- The warning must survive the default DEBUG=false setting.
    h.api.CONFIG.DEBUG = false
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_outcome, "unavailable", "outcome")

    h.app.accept_calls = 0
    for _ = 1, 4 do
        h.advance(6)
        h.api.step_trade()
    end
    H.assert_eq(h.app.accept_calls, 0, "never accepts an empty trade")
    H.assert_eq(h.app.confirm_calls, 0, "never confirms an empty trade")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing fabricated")

    local warnings = 0
    for _, line in ipairs(h.state.prints) do
        if line:find("cannot be cancelled and WinterHub is disabled", 1, true) then
            warnings = warnings + 1
        end
    end
    H.assert_eq(warnings, 1, "exactly one operator warning")
end)

-- 15b. The same one-time warning must cover the watchdog outcome, which is a
--      different branch from unavailable/failed.
test("no WinterHub: watchdog outcome also warns once", function()
    local h = fresh()
    h.api.CONFIG.WINTERHUB.enabled = false
    h.api.CONFIG.DEBUG = false
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        while true do task.wait(1) end
    end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    h.advance(h.api.EMPTY_CANCEL_CALL_WATCHDOG + 1)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_outcome, "unknown", "watchdog outcome")
    h.advance(2)
    h.api.step_trade()

    local warnings = 0
    for _, line in ipairs(h.state.prints) do
        if line:find("cannot be cancelled and WinterHub is disabled", 1, true) then
            warnings = warnings + 1
        end
    end
    H.assert_eq(warnings, 1, "exactly one warning for the watchdog path")
    H.assert_eq(h.app.accept_calls, 0, "still blocked")
end)

-- 16. A late adapter failure must not re-poison-- 16. A late adapter failure must not re-poison a session that already
--     recovered when the partner offered items.
test("a late cancellation failure does not re-stick a recovered session", function()
    local h = fresh()
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        task.wait(1)
        return false, "late_boom"
    end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_inflight, true, "in flight")

    h.app.partner_offer = H.offer({ H.item("cat") })
    h.api.step_trade()                       -- recovery happens first
    H.assert_eq(h.api.empty_trade.stuck, false, "recovered")

    h.pump(3)                                -- the failed call settles late
    H.assert_eq(session(h).cancel_outcome, nil, "late failure discarded")
    H.assert_eq(h.api.empty_trade.stuck, false, "not re-stuck")

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat + 1)
    h.api.write_winterhub()
    H.assert_eq(h.state.writes[WH].status, "active", "no rejoin request mid-trade")
end)

-- 17. The deferred scheduler must not yield from the main thread.
test("a top-level task.wait is a no-op under deferred scheduling", function()
    local h = fresh()
    local ok, err = pcall(function() task.wait(1) end)
    H.assert_eq(ok, true, "no yield error: " .. tostring(err))
    H.assert_eq(h.pending(), 0, "nothing queued")
end)

-- 18. The built-in decline path calls the game entry point past the deadline
--     and counts exactly one failure only after the close is observed.
test("built-in decline fires on an empty offer and counts once", function()
    local h = fresh({ scheduling = "sync" })
    local calls = 0
    h.app._decline_trade = function(self)
        calls = calls + 1
        self.state = nil
    end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls, 1, "decline invoked once")
    H.assert_eq(h.api.empty_trade.failures, 1, "counted after observed close")
    H.assert_eq(h.api.get_trade_count(), 0, "never a successful trade")
    H.assert_eq(h.app.confirm_calls, 0, "never confirmed")
end)

-- 19. A populated trade must never reach the decline call.
test("built-in decline never fires on a populated trade", function()
    local h = fresh({ scheduling = "sync" })
    local calls = 0
    h.app._decline_trade = function() calls = calls + 1 end
    open(h, "negotiation")
    h.app.partner_offer = H.offer({ H.item("cat") })
    h.api.step_trade()
    h.advance(60)
    h.api.step_trade()
    H.assert_eq(calls, 0, "no decline while items are on the table")
end)

-- 20. An unreadable offer never reaches the decline call either.
test("built-in decline never fires on an unreadable offer", function()
    local h = fresh({ scheduling = "sync" })
    local calls = 0
    h.app._decline_trade = function() calls = calls + 1 end
    open(h, "negotiation")
    h.app.partner_offer = nil
    h.api.step_trade()
    h.advance(20)
    h.api.step_trade()
    H.assert_eq(calls, 0, "UNKNOWN is not a reason to decline")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing counted")
end)

-- 21. A throwing native entry point is reported, never counted, never fatal.
test("a throwing built-in decline is not counted", function()
    local h = fresh({ scheduling = "sync" })
    h.app._decline_trade = function() error("native boom") end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    local s = session(h)
    H.assert_eq(s.cancel_outcome, "failed", "reported as failed")
    H.assert_eq(h.api.empty_trade.stuck_reason, "cancellation_failed", "reason")
    H.assert_eq(h.api.empty_trade.failures, 0, "not counted")
    H.assert_eq(h.api.get_trade_count(), 0, "not a success")
    H.assert_eq(#h.state.spawn_errors, 0, "no uncaught error")
    H.assert_eq(h.app.accept_calls, 0, "still blocked")
end)

-- 22. A client without the method keeps the previous safe behaviour.
test("a missing built-in decline stays unavailable", function()
    local h = fresh({ scheduling = "sync" })
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_outcome, "unavailable", "unavailable")
    H.assert_eq(h.api.empty_trade.stuck_reason, "cancellation_unavailable", "reason")
    H.assert_eq(h.api.empty_trade.failures, 0, "not counted")
end)

-- 23. The config switch disables the call entirely.
test("auto_decline = false never calls the native entry point", function()
    local h = fresh({ scheduling = "sync" })
    local calls = 0
    h.app._decline_trade = function() calls = calls + 1 end
    h.api.CONFIG.EMPTY_TRADE.auto_decline = false
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls, 0, "not called")
    H.assert_eq(session(h).cancel_outcome, "unavailable", "unavailable")
end)

-- 24. An injected override still wins over the built-in.
test("the getgenv override beats the built-in decline", function()
    local h = fresh({ scheduling = "sync" })
    local native_calls, override_calls = 0, 0
    h.app._decline_trade = function() native_calls = native_calls + 1 end
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        override_calls = override_calls + 1
        return true
    end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(override_calls, 1, "override used")
    H.assert_eq(native_calls, 0, "built-in not reached")
end)

-- 25. A decline that does not close the window is never retried blindly.
test("a decline that leaves the window open is not repeated", function()
    local h = fresh({ scheduling = "sync" })
    local calls = 0
    h.app._decline_trade = function() calls = calls + 1 end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls, 1, "one attempt")

    for _ = 1, 5 do
        h.advance(10)
        h.api.step_trade()
    end
    H.assert_eq(calls, 1, "no additional attempts on an unresolved window")
    H.assert_eq(h.api.empty_trade.failures, 0, "nothing counted")
    H.assert_eq(h.api.get_trade_count(), 0, "not a success")
end)

-- 26. A close observed while the decline adapter is still suspended must
--     still be counted (the yield case the async dispatch exists for).
test("a close during a suspended decline is counted", function()
    local h = fresh()
    local finished = false
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function()
        task.wait(1)
        finished = true
        return true
    end
    open(h, "negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(session(h).cancel_inflight, true, "in flight")

    -- The window closes while the request is still unresolved, from the same
    -- TradeApp instance and with no partner items.
    h.app.state = nil
    h.advance(1)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 1, "counted despite in-flight adapter")
    H.assert_eq(session(h), nil, "session resolved")
    H.assert_eq(h.api.get_trade_count(), 0, "never a success")

    h.pump(3)
    H.assert_eq(finished, true, "adapter eventually settled")
    H.assert_eq(h.api.empty_trade.failures, 1, "still exactly one")
end)

-- 27. A partner change at the deadline starts a clean session, not an error one.
test("a partner change at the deadline clears a stale stuck flag", function()
    local h = fresh({ scheduling = "sync" })
    open(h, "negotiation", { Name = "AlphaBot" })
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()                 -- no adapter: unavailable
    H.assert_eq(h.api.empty_trade.stuck, true, "stuck from the first session")

    -- The partner swaps between the poll read and the deadline re-read, which
    -- is the only path that reaches this branch.
    local alpha = H.session("negotiation", { Name = "AlphaBot" })
    local beta = H.session("negotiation", { Name = "BetaBot" })
    local reads = 0
    h.app.state = alpha
    h.app._get_local_trade_state = function()
        reads = reads + 1
        if reads == 1 then return alpha end
        return beta
    end

    h.advance(20)
    h.api.step_trade()
    H.assert_eq(reads >= 2, true, "boundary re-read happened")
    H.assert_eq(h.api.empty_trade.session, nil, "old session abandoned")
    H.assert_eq(h.api.empty_trade.stuck, false, "rejoin request cleared")
    H.assert_eq(h.api.empty_trade.stuck_reason, nil, "reason cleared")
end)

local passed, failed = 0, 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        io.write("PASS ", t.name, "\n")
    else
        failed = failed + 1
        io.write("FAIL ", t.name, ": ", tostring(err), "\n")
    end
end

os.clock = real_clock
io.write(("RESULT %d passed, %d failed\n"):format(passed, failed))
if failed > 0 then os.exit(1) end
