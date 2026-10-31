-- WinterHub empty-offer latch contract tests (adm_autotrade.lua).
-- Run from the repo root under Fengari:
--   npx --yes --package fengari-node-cli fengari test_autotrade_winterhub_v2.lua
-- Output uses io.write because the harness overrides print.

package.path = package.path .. ";./?.lua"
local H = require("test_autotrade_harness")

-- The script reads the global os.clock at call time, so a single fake clock
-- installed before load stays in control of all runtime timing.
local clock = { now = 1000 }
os.clock = function() return clock.now end

local function advance(seconds) clock.now = clock.now + (seconds or 0) end

local WH_FILE = "ReceiverBot_winteraddons.json"

local function new_harness()
    clock.now = 1000
    local h = H.new()
    return h
end

-- Drive one real trade to completion so trade_count/last_items are genuine
-- (no fabricated state): confirm both offers, then close the trade.
local function complete_one_trade(h)
    h.app.state = H.session("confirmation", { Name = "PartnerBot" })
    h.app.my_offer = H.offer({ H.item("cat"), H.item("dog") }, true)
    h.app.partner_offer = H.offer({ H.item("crystal_egg") }, true)
    h.api.step_trade()
    h.app.state = nil
    h.api.step_trade()
end

local function fail_latch(h)
    h.api.empty_trade.failures = h.api.CONFIG.EMPTY_TRADE.max_consecutive_failures
    h.api.latch_empty_trade_limit()
end

local function item_qty(payload, name)
    for _, entry in ipairs(payload.items or {}) do
        if entry.name == name then return entry.qty end
    end
    return nil
end

local tests = {}

tests["latch writes completed with count 0 and no fabricated items"] = function()
    local h = new_harness()
    fail_latch(h)
    H.assert_eq(h.api.empty_trade.latched, true, "latched")

    local wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "write succeeded")
    H.assert_eq(dispatched, true, "skip webhook dispatched")

    local payload = h.state.writes[WH_FILE]
    H.assert_true(payload ~= nil, "winterhub file written")
    H.assert_eq(payload.status, "completed", "status")
    H.assert_eq(payload.count, 0, "count")
    H.assert_eq(#payload.items, 0, "items empty")
    H.assert_true(type(payload.ts) == "number", "ts present")
    H.assert_eq(h.api.empty_trade.skip_notified, true, "skip_notified")
end

tests["latched heartbeat keeps count and last_items"] = function()
    local h = new_harness()
    complete_one_trade(h)
    H.assert_eq(h.api.get_trade_count(), 1, "trade counted")
    H.assert_true(h.api.get_last_items() ~= nil, "last_items captured")

    fail_latch(h)
    local wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "write succeeded")
    H.assert_eq(dispatched, true, "skip webhook dispatched")

    local payload = h.state.writes[WH_FILE]
    H.assert_eq(payload.status, "completed", "status")
    H.assert_eq(payload.count, 1, "count preserved")
    H.assert_eq(item_qty(payload, "Crystal Egg"), 1, "received item preserved")
end

tests["status never reverts while latched; heartbeat repeat"] = function()
    local h = new_harness()
    fail_latch(h)
    h.api.write_winterhub()

    for _ = 1, 3 do
        advance(h.api.CONFIG.WINTERHUB.heartbeat)
        local wrote, dispatched = h.api.write_winterhub()
        H.assert_eq(wrote, true, "heartbeat write")
        H.assert_eq(dispatched, false, "skip webhook not repeated")
        H.assert_eq(h.state.writes[WH_FILE].status, "completed", "status stays completed")
        H.assert_eq(h.api.empty_trade.skip_notified, true, "skip_notified stays true")
    end
end

tests["write failure defers the skip webhook until a later success"] = function()
    local h = new_harness()
    fail_latch(h)

    local real_writefile = _G.writefile
    _G.writefile = function() error("disk full") end
    local wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, false, "failed write reported")
    H.assert_eq(dispatched, false, "no webhook on failed write")
    H.assert_eq(h.api.empty_trade.skip_notified, false, "skip_notified untouched")
    H.assert_eq(h.state.writes[WH_FILE], nil, "nothing written")

    -- wh_last_write must not advance on failure, so the very next poll retries.
    _G.writefile = real_writefile
    wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "retry succeeded")
    H.assert_eq(dispatched, true, "webhook after successful retry")
    H.assert_eq(h.api.empty_trade.skip_notified, true, "skip_notified set")
    H.assert_eq(h.state.writes[WH_FILE].status, "completed", "completed after retry")

    advance(h.api.CONFIG.WINTERHUB.heartbeat)
    wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "later heartbeat write")
    H.assert_eq(dispatched, false, "webhook not duplicated")
    H.assert_eq(h.api.empty_trade.skip_notified, true, "skip_notified still true")
end

tests["server change resets failures, latch and skip notification"] = function()
    local h = new_harness()
    fail_latch(h)
    h.api.write_winterhub()
    H.assert_eq(h.api.empty_trade.skip_notified, true, "notified on server 1")

    h.api.empty_trade.session = { seq = 7 }
    _G.game.JobId = "test-job-2"
    local changed = h.api.check_server_transition()
    H.assert_eq(changed, true, "transition detected")
    H.assert_eq(h.api.empty_trade.failures, 0, "failures reset")
    H.assert_eq(h.api.empty_trade.latched, false, "latch cleared")
    H.assert_eq(h.api.empty_trade.latch_reason, nil, "latch_reason cleared")
    H.assert_eq(h.api.empty_trade.skip_notified, false, "skip_notified cleared")
    H.assert_eq(h.api.empty_trade.session, nil, "session cleared")
    H.assert_eq(h.api.empty_trade.server_key, "test-job-2", "server key updated")

    -- Same server key again is not a transition.
    H.assert_eq(h.api.check_server_transition(), false, "no repeat transition")

    -- New server reports normal status again, and can notify on a new latch.
    advance(h.api.CONFIG.WINTERHUB.heartbeat)
    local wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "write after transition")
    H.assert_eq(dispatched, false, "no skip webhook without a latch")
    H.assert_eq(h.state.writes[WH_FILE].status, "active", "status back to active")
end

tests["TradeApp disappearance does not reset the latch"] = function()
    local h = new_harness()
    fail_latch(h)
    local failures = h.api.empty_trade.failures

    h.uimanager.apps.TradeApp = nil
    h.api.step_trade()
    H.assert_eq(h.api.check_server_transition(), false, "no transition without key change")
    H.assert_eq(h.api.empty_trade.latched, true, "latch preserved")
    H.assert_eq(h.api.empty_trade.failures, failures, "failures preserved")
    H.assert_eq(h.api.empty_trade.skip_notified, false, "still unsent")

    local wrote = h.api.write_winterhub()
    H.assert_eq(wrote, true, "write still works")
    H.assert_eq(h.state.writes[WH_FILE].status, "completed", "status completed")
end

tests["unlatched servers never report a fabricated completion"] = function()
    local h = new_harness()
    advance(h.api.CONFIG.WINTERHUB.heartbeat)
    local wrote, dispatched = h.api.write_winterhub()
    H.assert_eq(wrote, true, "write succeeded")
    H.assert_eq(dispatched, false, "no skip webhook")
    H.assert_eq(h.state.writes[WH_FILE].status, "active", "status active")
    H.assert_eq(h.api.empty_trade.skip_notified, false, "skip_notified false")
end

local passed, failed = 0, 0
for name, fn in pairs(tests) do
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("PASS  " .. name .. "\n")
    else
        failed = failed + 1
        io.write("FAIL  " .. name .. "\n      " .. tostring(err) .. "\n")
    end
end

io.write(("%d passed, %d failed\n"):format(passed, failed))
if failed > 0 then error(("%d winterhub test(s) failed"):format(failed)) end
