-- Behavior tests for the ULTRA COMPACT webhook contract.
-- Run from the worktree root with:
--   npx --yes --package fengari-node-cli fengari test_autotrade_webhook_v2.lua
-- io.write is used because the harness replaces print.

local H = dofile("test_autotrade_harness.lua")

local failures, passes = 0, 0

local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passes = passes + 1
        io.write("PASS ", name, "\n")
    else
        failures = failures + 1
        io.write("FAIL ", name, ": ", tostring(err), "\n")
    end
end

local function eq(actual, expected, label)
    if actual ~= expected then
        error(("%s: expected %q, got %q"):format(
            label or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error((label or "value") .. ": expected truthy", 2) end
end

local function falsy(value, label)
    if value then error((label or "value") .. ": expected falsy", 2) end
end

local function split_lines(text)
    local out = {}
    for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

local function new_harness()
    local h = H.new()
    h.api.CONFIG.DEBUG = true
    return h
end

local function request_count(h) return #h.state.request_calls end

local function last_body(h)
    local calls = h.state.request_calls
    truthy(calls[#calls], "a webhook request was made")
    return calls[#calls].Body
end

-- Structural contract shared by all three events.
local function assert_compact_embed(body, title, color)
    eq(body.username, "ADM AutoTrade", "payload username")
    eq(type(body.embeds), "table", "embeds table")
    eq(#body.embeds, 1, "exactly one embed")
    local embed = body.embeds[1]
    eq(embed.title, title, "embed title")
    eq(embed.color, color, "embed color")
    eq(embed.fields, nil, "no fields")
    eq(embed.footer, nil, "no footer")
    eq(type(embed.timestamp), "string", "timestamp string")
    -- Fengari keeps the "!" UTC prefix literally; Roblox strips it.
    local stamp = (embed.timestamp:gsub("^!", ""))
    truthy(stamp:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
        "native ISO-8601 timestamp: " .. tostring(embed.timestamp))
    return embed
end

local function printed_contains(h, needle)
    for _, line in ipairs(h.state.prints or {}) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------- success
check("success received mode is one compact embed", function()
    local h = new_harness()
    h.api.CONFIG.WEBHOOK.report = "received"
    local received = { H.item("cat"), H.item("dog"), H.item("cat") }
    local given = { H.item("crystal_egg") }
    eq(h.api.send_trade_webhook(received, given, "PartnerBot", 7, 20), true, "delivered")
    eq(request_count(h), 1, "one request")

    local call = h.state.request_calls[1]
    eq(call.Url, h.api.CONFIG.WEBHOOK.url, "Saturnity URL routing")
    eq(call.Method, "POST", "POST method")
    eq(call.Headers["Content-Type"], "application/json", "JSON content type")

    local embed = assert_compact_embed(last_body(h), "Trade Complete #7", 5763719)
    local lines = split_lines(embed.description)
    eq(#lines, 3, "three description lines")
    eq(lines[1], "ReceiverBot has received items from PartnerBot", "receiver/partner wording")
    eq(lines[2], "20s · +3 / -1 · Success", "totals and duration")
    eq(lines[3], "2× Cat · 1× Dog", "received item line")
end)

check("success given mode reports given items", function()
    local h = new_harness()
    h.api.CONFIG.WEBHOOK.report = "given"
    h.api.send_trade_webhook({ H.item("cat") }, { H.item("crystal_egg"), H.item("dragonfly") },
        "PartnerBot", 8, 80)
    local embed = assert_compact_embed(last_body(h), "Trade Complete #8", 5763719)
    local lines = split_lines(embed.description)
    eq(#lines, 3, "three description lines")
    eq(lines[1], "ReceiverBot has given items to PartnerBot", "given wording")
    eq(lines[2], "1m 20s · +1 / -2 · Success", "compact duration and totals")
    eq(lines[3], "1× Crystal Egg · 1× Dragonfly", "given item line")
end)

check("success both mode prefixes received and given sections", function()
    local h = new_harness()
    h.api.CONFIG.WEBHOOK.report = "both"
    h.api.send_trade_webhook({ H.item("cat") }, { H.item("crystal_egg") }, "PartnerBot", 9, 3720)
    local embed = assert_compact_embed(last_body(h), "Trade Complete #9", 5763719)
    local lines = split_lines(embed.description)
    eq(#lines, 4, "four description lines")
    eq(lines[1], "ReceiverBot traded with PartnerBot", "both wording")
    eq(lines[2], "1h 2m · +1 / -1 · Success", "hours duration")
    eq(lines[3], "Received: 1× Cat", "received section")
    eq(lines[4], "Given: 1× Crystal Egg", "given section")
end)

check("success both mode uses nothing for empty sections", function()
    local h = new_harness()
    h.api.CONFIG.WEBHOOK.report = "both"
    h.api.send_trade_webhook({}, {}, "PartnerBot", 10, 0)
    local lines = split_lines(last_body(h).embeds[1].description)
    eq(lines[2], "0s · +0 / -0 · Success", "zero totals")
    eq(lines[3], "Received: nothing", "empty received")
    eq(lines[4], "Given: nothing", "empty given")
end)

check("success received mode uses nothing when no items", function()
    local h = new_harness()
    h.api.CONFIG.WEBHOOK.report = "received"
    h.api.send_trade_webhook({}, {}, "PartnerBot", 11, 5)
    local lines = split_lines(last_body(h).embeds[1].description)
    eq(lines[3], "nothing", "empty item line")
end)

check("success is only delivered once per trade number", function()
    local h = new_harness()
    h.api.CONFIG.WEBHOOK.report = "received"
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 12, 1), true, "first delivered")
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 12, 1), false, "duplicate suppressed")
    eq(request_count(h), 1, "duplicate made no request")
    truthy(h.api.is_event_delivered("trade:12"), "trade id marked delivered")
end)

-- ---------------------------------------------------------------- duration
check("compact duration formats", function()
    local d = new_harness().api.format_duration_compact
    eq(d(20), "20s", "seconds")
    eq(d(5), "5s", "single digit seconds")
    eq(d(80), "1m 20s", "minutes and seconds")
    eq(d(3720), "1h 2m", "hours and minutes")
    eq(d(3600), "1h", "whole hours")
    eq(d(0), "0s", "zero")
end)

-- ---------------------------------------------------------------- failed
check("failed event is one compact embed with reason on its own line", function()
    local h = new_harness()
    h.api.empty_trade.session = { id = 4 }
    eq(h.api.send_trade_failed_webhook("PartnerBot", 15, 1, 3, "Empty partner offer"), true, "delivered")
    eq(request_count(h), 1, "one request")

    local embed = assert_compact_embed(last_body(h), "Trade Failed", 15548997)
    local lines = split_lines(embed.description)
    eq(#lines, 3, "three description lines")
    eq(lines[1], "ReceiverBot was waiting for items from PartnerBot", "waiting wording")
    eq(lines[2], "15s · Attempt 1/3", "attempt line")
    eq(lines[3], "Reason: Empty partner offer", "plain reason line")
end)

check("failed event dedupes per empty session id", function()
    local h = new_harness()
    h.api.empty_trade.session = { id = 4 }
    eq(h.api.send_trade_failed_webhook("PartnerBot", 15, 1, 3, "Empty partner offer"), true, "first")
    eq(h.api.send_trade_failed_webhook("PartnerBot", 15, 1, 3, "Empty partner offer"), false, "retry deduped")
    eq(request_count(h), 1, "retry made no request")
    truthy(h.api.is_event_delivered("empty:4"), "empty session id delivered")

    h.api.empty_trade.session = { id = 5 }
    eq(h.api.send_trade_failed_webhook("PartnerBot", 15, 2, 3, "Empty partner offer"), true, "next session")
    eq(request_count(h), 2, "next session is a new event")
    truthy(h.api.is_event_delivered("empty:5"), "second session delivered")
end)

-- ---------------------------------------------------------------- skipped
check("server skipped uses actual trade count and winterhub status", function()
    local h = new_harness()
    eq(h.api.send_server_skipped_webhook(3, 5, "Repeated empty offers", "completed"), true, "delivered")
    eq(request_count(h), 1, "one request")

    local embed = assert_compact_embed(last_body(h), "Server Skipped", 15105570)
    local lines = split_lines(embed.description)
    eq(#lines, 4, "four description lines")
    eq(lines[1], "ReceiverBot received no items after 3 attempts", "attempts wording")
    eq(lines[2], "3/3 failed · Trades 5", "actual trade count")
    eq(lines[3], "Reason: Repeated empty offers", "reason line")
    eq(lines[4], "WinterHub: completed", "winterhub line")
end)

check("server skipped dedupes per server key and never hardcodes a trade count", function()
    local h = new_harness()
    eq(h.api.send_server_skipped_webhook(3, 5, "Repeated empty offers", "active"), true, "first")
    eq(h.api.send_server_skipped_webhook(3, 5, "Repeated empty offers", "active"), false, "retry deduped")
    eq(request_count(h), 1, "retry made no request")
    truthy(h.api.is_event_delivered("skip:" .. h.api.get_server_key()), "skip id delivered")

    h.api.empty_trade.server_key = "job-B"
    eq(h.api.send_server_skipped_webhook(3, nil, "Repeated empty offers", "active"), true, "new server")
    eq(request_count(h), 2, "new server is a new event")
    local lines = split_lines(last_body(h).embeds[1].description)
    eq(lines[2], "3/3 failed · Trades ?", "missing count is unknown, not 0")
    truthy(h.api.is_event_delivered("skip:job-B"), "second skip delivered")
end)

check("failed event falls back to the session partner name", function()
    local h = new_harness()
    h.api.empty_trade.session = { id = 21, partner_name = "GhostBot" }
    eq(h.api.send_trade_failed_webhook(nil, 4, 2, 3, "Empty partner offer"), true, "delivered")
    local lines = split_lines(last_body(h).embeds[1].description)
    eq(lines[1], "ReceiverBot was waiting for items from GhostBot", "session partner fallback")
    truthy(h.api.is_event_delivered("empty:21"), "session id used")
end)

-- ---------------------------------------------------------------- HTTP
check("HTTP 500 is retried three times and never marked delivered", function()
    local h = new_harness()
    h.state.response = { StatusCode = 500 }
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 100, 1), false, "not delivered")
    eq(request_count(h), 3, "three transient attempts")
    falsy(h.api.is_event_delivered("trade:100"), "failure not marked delivered")
    truthy(printed_contains(h, "webhook delivery failed"), "failure logged")
    falsy(printed_contains(h, "webhook sent"), "failure not logged as success")
end)

check("a failed event can be retried after a later 2xx and then dedupes", function()
    local h = new_harness()
    h.state.response = { StatusCode = 500 }
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 101, 1), false, "first fails")
    eq(request_count(h), 3, "three attempts")
    falsy(h.api.is_event_delivered("trade:101"), "not delivered yet")

    h.state.response = { StatusCode = 204 }
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 101, 1), true, "retry delivered")
    eq(request_count(h), 4, "one extra request")
    truthy(h.api.is_event_delivered("trade:101"), "delivered after retry")

    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 101, 1), false, "refire deduped")
    eq(request_count(h), 4, "no request after delivery")
    truthy(printed_contains(h, "webhook sent"), "success logged")
end)

check("HTTP 400 is not retried", function()
    local h = new_harness()
    h.state.response = { StatusCode = 400 }
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 102, 1), false, "not delivered")
    eq(request_count(h), 1, "permanent failure is not retried")
    falsy(h.api.is_event_delivered("trade:102"), "permanent failure not delivered")
end)

check("HTTP 204 is a success with one request", function()
    local h = new_harness()
    h.state.response = { StatusCode = 204 }
    eq(h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 103, 1), true, "204 delivered")
    eq(request_count(h), 1, "one request")
    truthy(h.api.is_event_delivered("trade:103"), "204 marked delivered")
end)

check("HTTP 429 and missing status are transient", function()
    local h = new_harness()
    h.state.response = { StatusCode = 429 }
    eq(h.api.send_trade_webhook({}, {}, "P", 104, 1), false, "429 fails")
    eq(request_count(h), 3, "429 retried")

    h.state.request_calls = {}
    h.state.response = {}
    eq(h.api.send_trade_webhook({}, {}, "P", 105, 1), false, "missing status fails")
    eq(request_count(h), 3, "missing status retried")
    falsy(h.api.is_event_delivered("trade:105"), "missing status not delivered")
end)

check("a refire during an in-flight retry does not post a second copy", function()
    local h = new_harness()
    local real_request = _G.request
    local reentered, posted = false, 0
    _G.request = function(req)
        posted = posted + 1
        if not reentered then
            reentered = true
            h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 106, 1)
        end
        return { StatusCode = 500 }
    end
    local ok = h.api.send_trade_webhook({ H.item("cat") }, {}, "PartnerBot", 106, 1)
    _G.request = real_request
    eq(ok, false, "outer delivery failed")
    eq(posted, 3, "only the outer retry loop posted")
    falsy(h.api.is_event_delivered("trade:106"), "failed event not delivered")
end)

check("transport error and non-table response are not success", function()
    local h = new_harness()
    local real_request = _G.request
    _G.request = function() error("network down") end
    local ok, status, err = h.api.http_post("https://example.invalid", "{}")
    _G.request = real_request
    eq(ok, false, "transport error is not ok")
    eq(status, nil, "no status")
    truthy(err and err:find("network down"), "transport error surfaced")

    _G.request = function() return "not a response" end
    ok, status, err = h.api.http_post("https://example.invalid", "{}")
    _G.request = real_request
    eq(ok, false, "non-table response is not ok")
    eq(status, nil, "non-table has no status")
    eq(err, "no_response", "non-table error")
end)

io.write(("\n%d passed, %d failed\n"):format(passes, failures))
if failures > 0 then
    error(("%d webhook test(s) failed"):format(failures))
end
