-- Behaviour tests for the empty-partner-offer recovery state machine.
-- Run from the repo root:
--   npx --yes --package fengari-node-cli fengari test_autotrade_empty_trade.lua
--
-- The harness loads adm_autotrade.lua in its test seam. os.clock is pinned to
-- the harness clock after load so the script's timers are deterministic.
-- Cancellation is injected through getgenv().__ADM_AUTOTRADE_CANCEL_TRADE,
-- exactly as the production adapter expects.

local H = dofile("test_autotrade_harness.lua")
local h = H.new()

local real_clock = os.clock
os.clock = function() return h.state.now end

local function fresh()
    h.reset()
    h.state.now = 1000
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = nil
    h.app.state = nil
    h.app.my_offer = H.offer({})
    h.app.partner_offer = H.offer({})
    h.app.accept_calls = 0
    h.app.confirm_calls = 0
    h.app.on_accept = nil
    h.app.on_confirm = nil
    h.uimanager.apps.TradeApp = h.app
    h.uimanager.apps.DialogApp = h.dialog
    h.state.spawn_errors = {}
    h.state.prints = {}
end

local function count_logs(needle)
    local n = 0
    for _, line in ipairs(h.state.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function open(stage, partner)
    h.app.state = H.session(stage, partner)
    h.app.my_offer = H.offer({})
    h.app.partner_offer = H.offer({})
    return h.app.state
end

local function give(items)
    h.app.partner_offer = H.offer(items)
end

-- Injects a cancellation mock. behavior(app, state, calls) -> ok, err.
local function mock_cancel(behavior)
    local calls = { n = 0, state = nil, app = nil }
    h.env.__ADM_AUTOTRADE_CANCEL_TRADE = function(app, state)
        calls.n = calls.n + 1
        calls.app = app
        calls.state = state
        return behavior(app, state, calls)
    end
    return calls
end

local function sync_close()
    return mock_cancel(function(app)
        app.state = nil
        return true
    end)
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

-- 1. A populated trade is never cancelled, no matter how long it stays open.
test("populated trade is never cancelled", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    give({ H.item("cat") })
    h.api.step_trade()
    H.assert_true(h.api.empty_trade.session ~= nil, "session created")
    H.assert_eq(h.api.empty_trade.session.partner_seen, true, "partner seen")
    h.advance(60)
    h.api.step_trade()
    H.assert_eq(calls.n, 0, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures")
end)

-- 2. The timer/deadline is created once and does not restart on polls.
test("timer starts exactly once per session", function()
    fresh()
    local seq0 = h.api.empty_trade.session_seq
    open("negotiation")
    h.api.step_trade()
    local s = h.api.empty_trade.session
    H.assert_true(s ~= nil, "session created")
    H.assert_eq(s.id, seq0 + 1, "session id")
    H.assert_eq(s.opened_at, 1000, "opened_at")
    H.assert_eq(s.deadline, 1015, "deadline")
    H.assert_eq(s.partner_seen, false, "partner_seen initial")
    H.assert_eq(s.cancel_attempted, false, "cancel_attempted initial")
    H.assert_eq(s.cancelling, false, "cancelling initial")
    H.assert_eq(s.failure_recorded, false, "failure_recorded initial")

    h.advance(1)
    h.api.step_trade()
    h.advance(4)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.session.id, s.id, "id stable")
    H.assert_eq(h.api.empty_trade.session.deadline, 1015, "deadline stable")
    H.assert_eq(h.api.empty_trade.session.opened_at, 1000, "opened_at stable")
end)

-- 3. An item at 5s marks partner_seen permanently.
test("item at 5s stops the countdown", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.api.step_trade()
    h.advance(5)
    give({ H.item("cat") })
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.session.partner_seen, true, "partner seen")
    h.advance(60)
    h.api.step_trade()
    H.assert_eq(calls.n, 0, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures")
end)

-- 4. An item arriving exactly at the boundary is read by the fresh read and
--    cancels the pending cancellation.
test("item at boundary prevents cancellation", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    give({ H.item("dog") })
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.session.partner_seen, true, "partner seen")
    H.assert_eq(calls.n, 0, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures")
    H.assert_true(h.api.empty_trade.session ~= nil, "session kept")
end)

-- 5. Insert then remove: partner_seen is sticky, later removal never cancels.
test("insert then remove is not cancelled", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.api.step_trade()
    h.advance(5)
    give({ H.item("cat") })
    h.api.step_trade()
    h.advance(15)
    give({})
    h.api.step_trade()
    H.assert_eq(calls.n, 0, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures")
    H.assert_eq(h.api.empty_trade.session.partner_seen, true, "partner seen sticky")
end)

-- 6. UNKNOWN offers are never treated as EMPTY.
test("nil offer is never cancelled", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.app.partner_offer = nil
    h.api.step_trade()
    h.advance(20)
    h.api.step_trade()
    h.advance(20)
    h.api.step_trade()
    H.assert_eq(calls.n, 0, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures")
    H.assert_eq(h.api.empty_trade.latched, false, "not latched")
    local count, err = h.api.count_offer_items(nil)
    H.assert_eq(count, nil, "nil count")
    H.assert_eq(err, "offer_unavailable", "nil count error")
end)

test("unreadable items table is UNKNOWN", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.app.partner_offer = { items = nil, confirmed = false }
    h.advance(20)
    h.api.step_trade()
    H.assert_eq(calls.n, 0, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures")
end)

-- 7. TradeApp disappearance: no cancel/failure, counter untouched.
test("short TradeApp disappearance keeps timer and counter", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.api.step_trade()
    local id = h.api.empty_trade.session.id
    local deadline = h.api.empty_trade.session.deadline

    h.advance(2)
    h.uimanager.apps.TradeApp = nil
    h.api.step_trade()
    H.assert_eq(calls.n, 0, "no cancel while app missing")
    H.assert_eq(h.api.empty_trade.failures, 0, "no failure while app missing")

    h.advance(1)
    h.uimanager.apps.TradeApp = h.app
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.session.id, id, "session kept across swap")
    H.assert_eq(h.api.empty_trade.session.deadline, deadline, "timer not restarted")
end)

test("TradeApp disappearance never resets the failure counter", function()
    fresh()
    local calls = mock_cancel(function() return true end)
    open("negotiation")
    h.api.step_trade()
    h.api.empty_trade.failures = 2

    h.advance(6)
    h.uimanager.apps.TradeApp = nil
    h.api.step_trade()  -- starts the replacement grace
    h.advance(6)
    h.api.step_trade()  -- grace expired: clears session, not the counter
    H.assert_eq(h.api.empty_trade.failures, 2, "failures preserved")
    H.assert_eq(h.api.empty_trade.session, nil, "stale session dropped")
    H.assert_eq(calls.n, 0, "cancel calls")
end)

-- 8. Close before timeout without an active cancel is an unrelated close.
test("close before timeout does not count or reset", function()
    fresh()
    open("negotiation")
    h.api.empty_trade.failures = 2
    h.api.step_trade()
    h.advance(5)
    h.app.state = nil
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.session, nil, "session cleared")
    H.assert_eq(h.api.empty_trade.failures, 2, "failures unchanged")
    H.assert_eq(h.api.get_trade_count(), 0, "not a successful trade")
end)

-- 9. Cancel succeeds and the window closes synchronously: one failure.
test("cancel success increments exactly once", function()
    fresh()
    local calls = sync_close()
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls.n, 1, "cancel calls")
    H.assert_eq(h.api.empty_trade.failures, 1, "failures")
    H.assert_eq(h.api.empty_trade.session, nil, "session reset")
    H.assert_eq(h.api.get_trade_count(), 0, "not a successful trade")
    H.assert_eq(h.app.confirm_calls, 0, "never confirmed")
    H.assert_eq(h.app.accept_calls, 0, "never accepted at deadline")

    -- Later polls cannot emit or count this session again.
    h.advance(30)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 1, "still one failure")
    H.assert_eq(h.api.empty_trade.session, nil, "no session resurrected")
end)

-- 10. Cancel failure: no count, no emit, no confirm; bounded backoff retry.
test("cancel failure does not count and retries after backoff", function()
    fresh()
    local calls = mock_cancel(function() return false, "native_cancel_failed" end)
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls.n, 1, "first attempt")
    H.assert_eq(h.api.empty_trade.failures, 0, "no failure")
    H.assert_eq(h.api.empty_trade.session.cancelling, false, "not cancelling")
    H.assert_eq(h.api.empty_trade.session.cancel_attempted, true, "attempt recorded")
    H.assert_eq(h.app.confirm_calls, 0, "never confirmed")

    h.advance(3)
    h.api.step_trade()
    H.assert_eq(calls.n, 1, "backoff suppresses retry")

    h.advance(2)
    h.api.step_trade()
    H.assert_eq(calls.n, 2, "retry after backoff")
    H.assert_eq(h.api.empty_trade.failures, 0, "still no failure")
end)

-- 11. Cancellation was accepted but the window did not close within 5s.
test("cancel success without close is not counted", function()
    fresh()
    -- Returns true but leaves the window open.
    local calls = mock_cancel(function() return true end)
    local state = open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls.n, 1, "cancel attempted")
    H.assert_eq(h.api.empty_trade.session.cancelling, true, "cancelling")
    H.assert_eq(h.api.empty_trade.failures, 0, "not counted yet")

    h.advance(5)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 0, "at the 5s edge still not counted")

    h.advance(1)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 0, "window expired without close")
    H.assert_eq(h.api.empty_trade.session.cancelling, false, "cancelling cleared")

    -- The session must not fall through to accept/confirm afterwards, even
    -- if the game advances the trade to confirmation.
    state.current_stage = "confirmation"
    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({}, true)
    h.advance(3)
    h.api.step_trade()
    H.assert_eq(h.app.confirm_calls, 0, "never confirmed after unconfirmed cancel")
    H.assert_eq(h.api.get_completing(), false, "completion not cached")

    -- The eventual close is now outside the confirmation window: still zero.
    h.app.state = nil
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 0, "late close not counted")
    H.assert_eq(h.api.get_trade_count(), 0, "late close not a success")
    H.assert_eq(h.api.empty_trade.session, nil, "session reset")
end)

-- 12. Cancel/confirm race: even in confirmation stage the empty trade is
--     cancelled, never confirmed, and not counted as a successful trade.
test("cancel and confirm never race into a success", function()
    fresh()
    local calls = sync_close()
    open("confirmation")
    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({}, true)  -- empty but confirmed
    h.api.step_trade()
    H.assert_eq(h.api.get_completing(), true, "completion cached before cancel")

    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls.n, 1, "cancel calls")
    H.assert_eq(h.app.confirm_calls, 0, "confirm suppressed")
    H.assert_eq(h.api.empty_trade.failures, 1, "empty failure recorded")
    H.assert_eq(h.api.get_trade_count(), 0, "not counted as success")
    H.assert_eq(h.api.get_completing(), false, "completion cleared")
    H.assert_eq(h.api.get_last_stage(), nil, "stage cleared")
end)

-- 13. No cancellation API: the counter stays unchanged after the timeout.
test("count unchanged after timeout without adapter", function()
    fresh()
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 0, "no failure")
    H.assert_eq(h.app.confirm_calls, 0, "never confirmed")
    H.assert_eq(h.api.empty_trade.session.cancel_attempted, true, "attempt recorded")
    h.advance(20)
    h.api.step_trade()
    h.advance(20)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 0, "still no failure")
    H.assert_eq(h.api.empty_trade.latched, false, "not latched")
end)

-- 13b. Without a verified cancellation API, the account must not freeze
--      silently: WinterHub receives "error" so it can rejoin the same server.
test("unverified cancellation publishes WinterHub error", function()
    fresh()
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.stuck, true, "stuck flagged")
    H.assert_eq(h.api.empty_trade.stuck_reason, "cancellation_unavailable", "reason")

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat)
    local wrote = h.api.write_winterhub()
    H.assert_eq(wrote, true, "status written")
    local payload = h.state.writes["ReceiverBot_winteraddons.json"]
    H.assert_true(payload ~= nil, "file written")
    H.assert_eq(payload.status, "error", "rejoin status, not completed")
    H.assert_eq(h.api.empty_trade.failures, 0, "no fabricated failure")

    _G.game.JobId = "test-job-2"
    H.assert_eq(h.api.check_server_transition(), true, "server transition")
    H.assert_eq(h.api.empty_trade.stuck, false, "stuck cleared on new server")
end)

-- 13c. A failed cancellation attempt still invalidates cached completion:
--      a later close must not be counted as a successful trade.
test("failed cancel then close is not a success", function()
    fresh()
    mock_cancel(function() return false, "cancel_failed" end)
    open("confirmation")
    h.app.my_offer = H.offer({}, true)
    h.app.partner_offer = H.offer({}, true)
    h.api.step_trade()
    H.assert_eq(h.api.get_completing(), true, "completion cached")

    h.advance(15)
    h.api.step_trade()
    h.app.state = nil
    h.api.step_trade()
    H.assert_eq(h.api.get_trade_count(), 0, "not a success")
    H.assert_eq(h.api.empty_trade.failures, 0, "not an empty failure")
end)

test("session replacement clears a stale stuck flag", function()
    fresh()
    open("negotiation", { Name = "AlphaBot" })
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.stuck, true, "stuck after unverified cancel")

    open("negotiation", { Name = "BetaBot" })
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.stuck, false, "stuck cleared for new trade")
end)

test("items after a stuck empty trade clear the rejoin request", function()
    fresh()
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.stuck, true, "stuck")

    give({ H.item("cat") })
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.stuck, false, "stuck cleared by populated offer")

    h.advance(h.api.CONFIG.WINTERHUB.heartbeat)
    h.api.write_winterhub()
    H.assert_eq(h.state.writes["ReceiverBot_winteraddons.json"].status, "active", "no rejoin")
end)

-- 14. One failure event per timeout, and the counter accumulates across
--     distinct sessions until it latches.
test("one failure per timeout and latch at max", function()
    fresh()
    local old_debug = h.api.CONFIG.DEBUG
    h.api.CONFIG.DEBUG = true
    local calls = sync_close()
    for i = 1, 3 do
        open("negotiation")
        h.api.step_trade()  -- starts the timer
        h.advance(15)
        h.api.step_trade()
        H.assert_eq(h.api.empty_trade.failures, i, "failure count " .. i)
        H.assert_eq(calls.n, i, "one cancel per session")
        -- The single emission gate runs exactly once per timeout; extra
        -- polls below must not add a record (and therefore no webhook).
        h.advance(10)
        h.api.step_trade()
        H.assert_eq(count_logs("empty-trade: failure"), i, "one failure record per timeout")
    end
    h.api.CONFIG.DEBUG = old_debug
    H.assert_eq(h.api.empty_trade.latched, true, "latched")
    H.assert_eq(h.api.empty_trade.latch_reason, "empty_trade_limit", "latch reason")
    H.assert_eq(h.api.get_in_trade(), false, "closed trade not left active")
end)

-- 15. Latched: step_trade, the dialog hook and clear_open_request all stop.
test("latch blocks new trades and auto-accept", function()
    fresh()
    sync_close()
    for i = 1, 3 do
        open("negotiation")
        h.api.step_trade()  -- starts the timer
        h.advance(15)
        h.api.step_trade()
    end
    H.assert_eq(h.api.empty_trade.latched, true, "latched")

    -- step_trade processes nothing and creates no session.
    open("negotiation")
    h.app.accept_calls = 0
    h.advance(30)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.session, nil, "no session while latched")
    H.assert_eq(h.app.accept_calls, 0, "no accept while latched")
    H.assert_eq(h.api.get_trade_count(), 0, "no progress while latched")

    -- Hook installs but a trade_request goes to the native path.
    H.assert_eq(h.api.install_accept_hook(), true, "hook installed")
    local result = h.dialog:dialog({ handle = "trade_request" })
    H.assert_eq(result, "native:trade_request", "latched dialog calls orig")

    -- A waiting ticket is not force-answered.
    h.dialog.ticket_count = 1
    h.dialog.completed_ticket = 0
    h.dialog.forced = {}
    h.api.clear_open_request()
    H.assert_eq(#h.dialog.forced, 0, "clear_open_request skipped when latched")

    -- Sanity: without the latch the same hook auto-accepts.
    h.api.empty_trade.latched = false
    H.assert_eq(h.dialog:dialog({ handle = "trade_request" }), "Accept", "hook accepts when unlatched")
end)

-- 16. A verified successful trade resets consecutive empty failures.
test("successful trade resets empty failures", function()
    fresh()
    open("confirmation")
    h.api.empty_trade.failures = 2
    h.app.my_offer = H.offer({ H.item("cat") }, true)
    h.app.partner_offer = H.offer({ H.item("dog") }, true)
    h.api.step_trade()          -- caches completion
    h.advance(3)
    h.api.step_trade()          -- confirms
    H.assert_eq(h.app.confirm_calls, 1, "confirm fired once")
    h.app.state = nil
    h.api.step_trade()
    H.assert_eq(h.api.get_trade_count(), 1, "success counted")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures reset")
end)

-- 17. Dictionary-shaped offers are counted.
test("UID-keyed offer dictionary counts items", function()
    local count, err = h.api.count_offer_items({
        items = { ["uid-1"] = H.item("cat"), ["uid-2"] = H.item("dog") },
    })
    H.assert_eq(count, 2, "dictionary count")
    H.assert_eq(err, nil, "dictionary error")
    local empty, empty_err = h.api.count_offer_items({ items = {} })
    H.assert_eq(empty, 0, "empty offer count")
    H.assert_eq(empty_err, nil, "empty offer error")
end)

-- 18. A cancellation that removes the app must not be mistaken for a closed
--     window. Missing TradeApp is UNKNOWN, so no failure is recorded.
test("cancel accepted but app disappears is UNKNOWN, not a failure", function()
    fresh()
    local calls = mock_cancel(function()
        h.uimanager.apps.TradeApp = nil
        return true
    end)
    open("negotiation")
    h.api.step_trade()
    h.advance(15)
    h.api.step_trade()
    H.assert_eq(calls.n, 1, "cancel attempted")
    H.assert_eq(h.api.empty_trade.failures, 0, "missing app is not a close")
    H.assert_eq(h.api.empty_trade.session.cancelling, true, "still waiting")

    h.uimanager.apps.TradeApp = h.app
    h.advance(6)
    h.api.step_trade()
    H.assert_eq(h.api.empty_trade.failures, 0, "still not counted")
    H.assert_eq(h.api.empty_trade.session.cancel_unconfirmed, true, "unconfirmed")
end)

-- 19. A different partner between polls starts a new session and deadline
--     instead of retaining the old partner's sticky flags.
test("new partner starts a new timer session", function()
    fresh()
    mock_cancel(function() return true end)
    open("negotiation", { Name = "AlphaBot" })
    h.api.step_trade()
    local first = h.api.empty_trade.session
    H.assert_true(first ~= nil, "first session")
    give({ H.item("cat") })
    h.api.step_trade()
    H.assert_eq(first.partner_seen, true, "first partner seen")

    h.advance(100)
    open("negotiation", { Name = "BetaBot" })
    h.api.step_trade()
    local second = h.api.empty_trade.session
    H.assert_true(second ~= first, "new session object")
    H.assert_eq(second.partner_name, "BetaBot", "new partner")
    H.assert_eq(second.partner_seen, false, "flags reset")
    H.assert_eq(second.deadline, h.state.now + 15, "deadline reset")
end)

-- 20. A stage regression (confirmation -> negotiation) between polls also
--     starts a new session instead of reusing an expired one.
test("stage regression starts a new timer session", function()
    fresh()
    mock_cancel(function() return true end)
    open("confirmation", { Name = "AlphaBot" })
    h.api.step_trade()
    local first = h.api.empty_trade.session
    H.assert_eq(first.saw_confirmation, true, "confirmation observed")

    h.advance(100)
    h.app.state = H.session("negotiation", { Name = "AlphaBot" })
    h.app.partner_offer = H.offer({})
    h.api.step_trade()
    local second = h.api.empty_trade.session
    H.assert_true(second ~= first, "new session object")
    H.assert_eq(second.saw_confirmation, false, "stage reset")
    H.assert_eq(second.deadline, h.state.now + 15, "deadline reset")
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
