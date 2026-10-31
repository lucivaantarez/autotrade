--[[ adm_autotrade.lua - Adopt Me trade automation for Delta.

Accepts incoming trade requests and drives each trade to completion for
accounts you own. The in-game script controls the trade UI and writes local
status and send webhook reports; server hopping is external.

Edit only the CONFIG table below. The rest of the file is load-bearing.

Sections, in file order:
  Configuration           switches and timings
  Initialization          dependencies, anti-AFK, singleton guard, settings
  Trade Request Handling  dialog hook and startup dialog recovery
  Webhook Reporting       compact embeds and delivery rules
  Empty Trade Recovery    deadline, cancellation adapter, failure accounting
  Trade Lifecycle         stage driver and completion capture
  WinterHub Integration   status file consumed by the hop agent
  Main Loop               hook repair, stepping, heartbeat

Cancellation reaches a native entry point whose contract is unverified. A
call is a request only: no trade is counted as cancelled without an observed
close.
--]]

-- Configuration
-- The only section meant to be edited. `true` enables, `false` disables.
local CONFIG = {

    -- Master switch. Set to false and the whole script does nothing.
    MASTER_ENABLED = true,

    FORCE_SETTINGS = {
        -- Sets the in-game Trading option to "Everyone" at startup so peer
        -- accounts may send requests. Some logins reset this to "Friends",
        -- which would otherwise block them.
        enabled = true,
        -- Apply the same change to gifting ("give" requests).
        also_force_giving = true,
    },

    AUTO_ACCEPT = {
        -- The main feature: auto-accept trade requests and finish the trade.
        enabled = true,
        -- How often the script checks the trade, in seconds. Lower = snappier.
        poll = 0.4,
        -- How often it re-taps Accept/Confirm while waiting out the trade
        -- lock timer, in seconds. Don't set this too low.
        refire_every = 3.0,
        negotiation_delay = 1.0,
        confirmation_delay = 3.0,
    },

    EMPTY_TRADE = {
        -- Recover from a farming account that opens a trade but never offers
        -- an item. The timer starts once per trade session.
        enabled = true,
        timeout_seconds = 15,
        -- Consecutive empty-offer failures before WinterHub is told to hop.
        max_consecutive_failures = 3,
        -- When the partner offer is still readable-empty after timeout_seconds,
        -- call the game's own decline entry point (TradeApp:_decline_trade).
        -- The call is only a REQUEST: the trade is never counted as cancelled
        -- until the window is observed closed on the same TradeApp instance.
        -- Set false to restore the old behaviour (publish WinterHub "error"
        -- and never touch the trade).
        auto_decline = true,
    },

    WINTERHUB = {
        -- Let the WinterHub app hop you to the next server automatically.
        -- Leave off if you're not using WinterHub.
        enabled = true,
        -- If no new trade comes in for this many seconds, tell WinterHub the
        -- server is done so it hops. Raise this if it hops before your bots
        -- have finished sending.
        idle_hop_seconds = 12,
        -- How often the status file is rewritten, in seconds. Keep it small
        -- so WinterHub never thinks the account froze.
        heartbeat = 5,
    },

    WEBHOOK = {
        -- Send a Discord message every time a trade finishes.
        enabled = true,
        -- Endpoint that receives trade reports. Keep deployment-specific
        -- values out of version control, and rotate anything that leaks.
        url = "https://saturnity.site/api/tradelogs",
        -- What the message lists: "received" (what you got), "given" (what you
        -- gave), or "both".
        report = "received",
    },

    -- Print progress messages to the Delta console; useful while testing.
    DEBUG = false,
}

-- Initialization
local function log(...) if CONFIG.DEBUG then print("[autotrade]", ...) end end

if not CONFIG.MASTER_ENABLED then
    log("MASTER_ENABLED = false - script is off")
    return
end

local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- Per-account singleton guard. Two clones share one Delta environment and one
-- getgenv, so a plain global would make the second clone abort. Keying on
-- UserId gives each account its own slot while still blocking a genuine
-- double-execute on one account, which would double-report webhooks.
local _guard_key = "__adm_autotrade_" .. tostring(LocalPlayer.UserId)
if getgenv then
    if getgenv()[_guard_key] then
        print("[autotrade] already running for this account - aborting duplicate")
        return
    end
    getgenv()[_guard_key] = true
end

-- Anti-AFK: prevents the 20-minute idle kick. Side effects are installed
-- only after the singleton guard, so a rejected duplicate adds no listeners.
pcall(function()
    local VirtualUser = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

local fsys_ok, Fsys = pcall(function()
    return require(game.ReplicatedStorage:WaitForChild("Fsys"))
end)
if not fsys_ok or not Fsys then
    if getgenv then getgenv()[_guard_key] = nil end
    error("[autotrade] failed to load Fsys: " .. tostring(Fsys))
end
local load = Fsys.load

-- Load ONLY UIManager eagerly - it's all the accept hook needs, and getting
-- the hook in fast is what prevents the first-request race. Everything else
-- (settings DB, KindDB) is loaded lazily AFTER the hook is in.
local UIManager
local function ensure_ui_manager()
    if not UIManager then
        pcall(function() UIManager = load("UIManager") end)
    end
    return UIManager
end
ensure_ui_manager()

local SettingsHelper, SettingsDB, KindDB
local function ensure_deps()
    -- Load each dependency independently. A partial startup failure must not
    -- permanently suppress retries for whichever module was still unavailable.
    if not SettingsHelper then
        pcall(function() SettingsHelper = load("SettingsHelper") end)
    end
    if not SettingsDB then
        pcall(function() SettingsDB = require(game.ReplicatedStorage.ClientDB.SettingsDB) end)
    end
    if not KindDB then
        pcall(function() KindDB = load("KindDB") end)   -- kind -> display name
    end
end

-- idle state (declared early so the accept hook + driver can use it)
local last_activity = os.clock()
local function mark_activity() last_activity = os.clock() end

-- Settings forcing. Writes trade and give visibility as "Everyone" and
-- persists it, so peer accounts are allowed to send requests.
local function force_everyone(id)
    ensure_deps()
    local changed = false
    local ok = pcall(function()
        if not SettingsHelper or not SettingsDB then return end
        local def = SettingsDB.by_id[id]
        if not def then return end
        local idx = table.find(def.element_options.choices, "Everyone")
        if not idx then return end
        SettingsHelper.set_setting_client({ setting_id = id, value = idx })
        changed = true
        log("setting", id, "-> Everyone")
    end)
    return ok and changed
end

local trade_setting_done = not CONFIG.FORCE_SETTINGS.enabled
local giving_setting_done = not CONFIG.FORCE_SETTINGS.enabled
    or not CONFIG.FORCE_SETTINGS.also_force_giving
local function force_trade_settings()
    if not CONFIG.FORCE_SETTINGS.enabled then return true end
    if not trade_setting_done then
        trade_setting_done = force_everyone("trade_requests")
    end
    if not giving_setting_done then
        giving_setting_done = force_everyone("give_item_requests")
    end
    return trade_setting_done and giving_setting_done
end

-- Trade Request Handling
-- The game keeps ownership of the accept path: its own handler performs the
-- server call and the handshake that opens the trade window. This section
-- stops the auto-decline on join, answers the dialog with "Accept", and
-- neutralizes the captcha and scam popups that would otherwise stall the
-- flow. install_accept_hook returns true once the hook is in place.
-- Neutralize every blocking popup in the trade flow on the TradeApp instance.
-- All are method calls (self:method()), so instance overrides shadow the class.
local function patch_trade_app(app)
    if not app or app.__autotrade_patched then return end
    -- suspicious-player captcha ("not your friend!")
    app._confirm_player_if_suspicious = function() return true end
    -- unbalanced-trade warnings ("seems unbalanced", "BANNABLE!", victim warning)
    app._evaluate_trade_fairness     = function() end
    app._show_scam_perpetrator_warning = function() end
    app._show_scam_victim_warning      = function() end
    app._show_experimental_warning     = function() end
    app.show_scam_warning              = function() end
    -- pet-paint-will-be-cleared confirm
    app._confirm_clear_colored_pets    = function() end
    app.__autotrade_patched = true
    log("trade warnings neutralized")
end

local hooked_dialog_class, hooked_dialog_fn
-- Declared early: the dialog hook, clear_open_request and the webhook builders
-- must share the same empty-trade table and successful-trade counter. The
-- table itself is defined by the Empty Trade Recovery section.
local empty_trade
local trade_count
local invite_guard_ready, exclusion_guard_ready = false, false
local invite_guard_module, exclusion_guard_module
local function allow_invites() return true end
local function allow_player() return false end
local function install_accept_hook()
    if not CONFIG.AUTO_ACCEPT.enabled then return false end
    if not ensure_ui_manager() then return false end

    local apps = UIManager.apps
    if not apps then return false end

    -- (a) don't let the game auto-decline before showing the dialog
    if not invite_guard_ready or not invite_guard_module
        or invite_guard_module.can_receive_invites ~= allow_invites then
        pcall(function()
            invite_guard_module = load("MinigameForcedState")
            invite_guard_module.can_receive_invites = allow_invites
            invite_guard_ready = invite_guard_module.can_receive_invites == allow_invites
        end)
    end
    if not exclusion_guard_ready or not exclusion_guard_module
        or exclusion_guard_module.is_player_excluded ~= allow_player then
        pcall(function()
            exclusion_guard_module = load("TradeExcluder")
            exclusion_guard_module.is_player_excluded = allow_player
            exclusion_guard_ready = exclusion_guard_module.is_player_excluded == allow_player
        end)
    end

    local DialogApp = apps.DialogApp
    if not DialogApp then return false end

    -- (b) hook the REAL dialog method. It lives on the CLASS (via metatable
    -- __index), not the instance, and it returns a Promise (not a string).
    -- For a trade_request we short-circuit with a resolved promise carrying
    -- "Accept" - exactly what the waiting TradeApp handler expects.
    DialogApp.__autotrade_hooked = false
    -- Adopt Me's promise module is "package:Promise" (NOT "Promise")
    local Promise
    pcall(function() Promise = load("package:Promise") end)
    local cls = getmetatable(DialogApp)
    cls = cls and cls.__index
    if cls and cls.dialog and Promise then
        -- DialogApp instances can be replaced while retaining the same
        -- class. Reuse our existing class hook instead of wrapping it once
        -- more on every instance swap; reinstall only if the class or
        -- method was genuinely replaced.
        if cls ~= hooked_dialog_class or cls.dialog ~= hooked_dialog_fn then
            local orig = cls.dialog
            hooked_dialog_fn = function(self, opts)
                if opts and opts.handle == "trade_request" then
                    -- Empty-offer limit reached: stop taking new trades so
                    -- the server can be left. Let the native dialog path run.
                    if empty_trade and empty_trade.latched then
                        return orig(self, opts)
                    end
                    mark_activity()
                    log("auto-accepting trade request (hooked dialog)")
                    local p = Promise.resolve("Accept")
                    if opts.yields or opts.yields == nil then return p:expect() end
                    return p
                end
                return orig(self, opts)
            end
            cls.dialog = hooked_dialog_fn
            hooked_dialog_class = cls
        end
        DialogApp.__autotrade_hooked = true
    elseif cls and cls.dialog and not Promise then
        log("WARN: promise module not found; relying on open-dialog force-answer only")
    end

    -- (c) neutralize suspicious-captcha, scam warnings, unbalanced warnings, etc.
    local TradeApp = apps.TradeApp
    if TradeApp then patch_trade_app(TradeApp) end

    return DialogApp.__autotrade_hooked == true
end

-- The hook above only sees future dialogs. A request that is already waiting
-- when the script starts is visible only as ticket_count > completed_ticket,
-- because is_dialog_open reads false while a request is on screen. The
-- in-flight ticket is completed_ticket + 1; push "Accept" into it.
local last_forced_dialog, last_forced_ticket = nil, 0
local function clear_open_request()
    if empty_trade and empty_trade.latched then return end
    if not UIManager or not UIManager.apps then return end
    local D = UIManager.apps.DialogApp
    if not D or not D.force_response_signal then return end
    if D ~= last_forced_dialog then
        last_forced_dialog = D
        last_forced_ticket = 0
    end
    local count = D.ticket_count or 0
    local done  = D.completed_ticket or 0
    if count <= done then return end                 -- nothing waiting
    local ticket = done + 1
    if ticket == last_forced_ticket then return end  -- don't spam the same one
    local fired = pcall(function()
        D.force_response_signal:Fire(ticket, table.pack("Accept"))
    end)
    if fired then
        last_forced_ticket = ticket
        mark_activity()
        log("force-answered waiting dialog (ticket " .. ticket .. ")")
    end
end

-- Webhook Reporting
-- Each item's `kind` is resolved through KindDB and grouped by display name
-- so the embed carries real names and quantities. A completion event is
-- emitted only when both sides confirmed, never for a cancel.
-- Returns ok, status, err. A 2xx response is a delivered webhook; 429, 5xx and
-- a missing status (request error / executor without StatusCode) are transient;
-- any other 4xx is permanent. A transport failure is NEVER reported as ok.
local function http_post(url, body)
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    if not req then return false, nil, "no_http_function" end
    local called, response = pcall(req, {
        Url = url, Method = "POST",
        Headers = { ["Content-Type"] = "application/json" }, Body = body,
    })
    if not called then return false, nil, tostring(response) end
    if type(response) ~= "table" then return false, nil, "no_response" end
    local status = tonumber(response.StatusCode or response.status or response.statusCode)
    if not status then return false, nil, "missing_status" end
    if status >= 200 and status < 300 then return true, status, nil end
    return false, status, "http_" .. tostring(status)
end

local WEBHOOK_DELIVERY_ATTEMPTS = 3
local WEBHOOK_RETRY_BACKOFF = 0.5

local function webhook_status_transient(status)
    if status == nil then return true end          -- no response / no status
    if status == 429 then return true end
    return status >= 500 and status <= 599
end

local function deliver_webhook(url, body)
    local last_status, last_err
    for attempt = 1, WEBHOOK_DELIVERY_ATTEMPTS do
        local ok, status, err = http_post(url, body)
        if ok then return true, status end
        last_status, last_err = status, err
        if not webhook_status_transient(status) then
            return false, status, err
        end
        if attempt < WEBHOOK_DELIVERY_ATTEMPTS then
            task.wait(WEBHOOK_RETRY_BACKOFF * attempt)
        end
    end
    return false, last_status, last_err or "webhook_delivery_failed"
end

local function pet_label(item)
    if not KindDB then ensure_deps() end
    local def  = KindDB and KindDB[item.kind]
    local name = (def and def.name) or item.kind
    local p    = item.properties or {}
    local pre  = p.mega_neon and "Mega Neon " or (p.neon and "Neon " or "")
    local tag  = ""
    if p.rideable then tag = tag .. "R" end
    if p.flyable  then tag = tag .. "F" end
    if tag ~= "" then tag = " [" .. tag .. "]" end
    return pre .. name .. tag
end

-- Iterate offer items whether they are a sequential array or a UID-keyed
-- dictionary. A missing/non-table collection contributes no items.
local function each_trade_item(items, fn)
    if type(items) ~= "table" then return 0 end
    local ordered = {}
    for key, item in pairs(items) do
        if type(item) == "table" then
            ordered[#ordered + 1] = { key = key, item = item }
        end
    end
    -- Arrays keep their natural order; dictionary keys get a stable order so
    -- repeated webhook/report renders do not shuffle item lines.
    table.sort(ordered, function(a, b)
        if type(a.key) == "number" and type(b.key) == "number" then
            return a.key < b.key
        end
        return tostring(a.key) < tostring(b.key)
    end)
    for _, entry in ipairs(ordered) do fn(entry.item) end
    return #ordered
end

local function summarize(items)
    local counts, order = {}, {}
    local total = each_trade_item(items, function(item)
        local lbl = pet_label(item)
        if not counts[lbl] then order[#order+1] = lbl end
        counts[lbl] = (counts[lbl] or 0) + 1
    end)
    local lines = {}
    for _, lbl in ipairs(order) do lines[#lines+1] = ("%d× %s"):format(counts[lbl], lbl) end
    return lines, total
end

local function copy_trade_items(items)
    local out = {}
    each_trade_item(items, function(item)
        local props, src = {}, item.properties or {}
        props.neon      = src.neon == true
        props.mega_neon = src.mega_neon == true
        props.rideable  = src.rideable == true
        props.flyable   = src.flyable == true
        out[#out+1] = { kind = item.kind, properties = props }
    end)
    return out
end

local session_started_at = os.clock()
local function format_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    local remaining = seconds % 60
    return hours > 0 and string.format("%dh %dm %ds", hours, minutes, remaining)
        or string.format("%dm %ds", minutes, remaining)
end

-- Compact Discord duration: 20s / 1m 20s / 1h 2m.
local function format_duration_compact(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    local remaining = seconds % 60
    if hours > 0 then
        if minutes > 0 then return string.format("%dh %dm", hours, minutes) end
        return string.format("%dh", hours)
    end
    if minutes > 0 then return string.format("%dm %ds", minutes, remaining) end
    return string.format("%ds", remaining)
end

-- Delivered event ids. An id is recorded only after a 2xx response, so a
-- transient failure can be retried while a delivered event is never re-sent.
-- In-flight ids are suppressed too: a retry yields between attempts, and a
-- concurrent refire must not post the same event twice.
local delivered_events = {}
local sending_events = {}

local function webhook_enabled()
    return CONFIG.WEBHOOK.enabled and CONFIG.WEBHOOK.url ~= ""
end

local function item_lines_or_nothing(lines)
    if lines and #lines > 0 then return table.concat(lines, " · ") end
    return "nothing"
end

local function now_iso8601()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function emit_webhook(event_id, embed)
    if not webhook_enabled() then return false end
    if event_id ~= nil and delivered_events[event_id] then
        log("webhook duplicate suppressed:", tostring(event_id))
        return false
    end
    if event_id ~= nil and sending_events[event_id] then
        log("webhook already sending:", tostring(event_id))
        return false
    end
    local payload = {
        username = "ADM AutoTrade",
        embeds = { embed },
    }
    local encoded, body = pcall(function()
        return game:GetService("HttpService"):JSONEncode(payload)
    end)
    if not encoded then
        log("webhook encode failed:", tostring(body))
        return false
    end
    if event_id ~= nil then sending_events[event_id] = true end
    local delivered, status, err = deliver_webhook(CONFIG.WEBHOOK.url, body)
    if event_id ~= nil then sending_events[event_id] = nil end
    if not delivered then
        log("webhook delivery failed:", tostring(event_id or "?"),
            tostring(status or "no_status"), tostring(err or ""))
        return false
    end
    if event_id ~= nil then delivered_events[event_id] = true end
    log("webhook sent:", tostring(event_id or "?"), tostring(status))
    return true
end

local function send_trade_webhook(received, given, partner_name, trade_number, elapsed)
    if not webhook_enabled() then return false end
    local number_label = tostring(trade_number or "?")
    local partner = tostring(partner_name or "unknown")
    local received_lines, received_total = summarize(received)
    local given_lines, given_total = summarize(given)
    local report = CONFIG.WEBHOOK.report
    local verb, item_text
    if report == "both" then
        verb = "traded with"
        item_text = "Received: " .. item_lines_or_nothing(received_lines)
            .. "\nGiven: " .. item_lines_or_nothing(given_lines)
    elseif report == "given" then
        verb = "has given items to"
        item_text = item_lines_or_nothing(given_lines)
    else
        verb = "has received items from"
        item_text = item_lines_or_nothing(received_lines)
    end
    local description = table.concat({
        ("%s %s %s"):format(LocalPlayer.Name, verb, partner),
        ("%s · +%d / -%d · Success"):format(
            format_duration_compact(elapsed), received_total, given_total),
        item_text,
    }, "\n")
    return emit_webhook("trade:" .. number_label, {
        title = ("Trade Complete #%s"):format(number_label),
        description = description,
        color = 5763719,
        timestamp = now_iso8601(),
    })
end

-- One stable id per empty-offer session; retries/refires reuse it. The
-- session id is passed explicitly so an async webhook still has the right id
-- after the live session state is torn down.
local function empty_trade_event_id(session_id)
    local id = session_id
    if id == nil then
        local session = empty_trade and empty_trade.session
        if type(session) == "table" then
            id = session.id or session.session_id or session.seq
        end
    end
    if id == nil then id = empty_trade and empty_trade.session_seq end
    return "empty:" .. tostring(id or "?")
end

local function send_trade_failed_webhook(partner_name, elapsed, attempt, max_attempts, reason, session_id)
    if not webhook_enabled() then return false end
    if partner_name == nil and empty_trade and empty_trade.session then
        partner_name = empty_trade.session.partner_name
    end
    local description = table.concat({
        ("%s was waiting for items from %s"):format(
            LocalPlayer.Name, tostring(partner_name or "unknown")),
        ("%s · Attempt %s/%s"):format(
            format_duration_compact(elapsed),
            tostring(attempt or "?"),
            tostring(max_attempts or (empty_trade and empty_trade.max_failures) or "?")),
        "Reason: " .. tostring(reason or "Empty partner offer"),
    }, "\n")
    return emit_webhook(empty_trade_event_id(session_id), {
        title = "Trade Failed",
        description = description,
        color = 15548997,
        timestamp = now_iso8601(),
    })
end

local function send_server_skipped_webhook(attempts, trade_count_value, reason, winterhub_status)
    if not webhook_enabled() then return false end
    local max_attempts = (empty_trade and tonumber(empty_trade.max_failures))
        or CONFIG.EMPTY_TRADE.max_consecutive_failures
    local tries = tonumber(attempts) or 0
    local count = tonumber(trade_count_value)
    -- An omitted count is unknown, not a fabricated zero. The production
    -- caller always passes trade_count explicitly.
    local count_text = count ~= nil and tostring(count) or "?"
    local winterhub = tostring(winterhub_status or "unknown")
    local description = table.concat({
        ("%s received no items after %d attempts"):format(LocalPlayer.Name, tries),
        ("%d/%d failed · Trades %s"):format(tries, max_attempts, count_text),
        "Reason: " .. tostring(reason or "Repeated empty offers"),
        "WinterHub: " .. winterhub,
    }, "\n")
    local server_key = (empty_trade and empty_trade.server_key) or "unknown"
    return emit_webhook("skip:" .. tostring(server_key), {
        title = "Server Skipped",
        description = description,
        color = 15105570,
        timestamp = now_iso8601(),
    })
end

local app_cache = nil
local function get_trade_app()
    if not ensure_ui_manager() then return nil end
    local ok, app = pcall(function() return UIManager.apps.TradeApp end)
    if ok and app then
        if app ~= app_cache then app_cache = app patch_trade_app(app) end
        return app
    end
    app_cache = nil
    return nil
end

local last_stage, last_fire, stage_since = nil, 0, 0
local action_busy, confirmation_fired = false, false
local in_trade = false
local initializing = true
-- completion tracking for the webhook + WinterHub
local completing = false
local pending_received, pending_given, pending_partner = nil, nil, nil
trade_count = 0            -- completed trades this session (WinterHub count)
local last_items = nil          -- items from the most recent completed trade
local TRADE_APP_REPLACEMENT_GRACE = 5
local trade_app_missing_since = nil

-- Empty Trade Recovery
-- A partner that offers nothing is put on a per-session deadline. A session
-- is created when a trade first becomes visible and closed only when the
-- trade state goes nil. The failure counter is deliberately not reset by
-- TradeApp disappearance or by an unrelated cancellation: only a verified
-- successful trade or a server transition resets it.
empty_trade = {
    session_seq = 0,
    session = nil,
    failures = 0,
    max_failures = CONFIG.EMPTY_TRADE.max_consecutive_failures,
    latched = false,
    latch_reason = nil,
    skip_notified = false,
    server_key = nil,
    -- Set when an empty trade cannot be cancelled because no verified native
    -- API is available. WinterHub is asked to rejoin the same server ("error")
    -- instead of leaving the account frozen or falsely reporting completion.
    stuck = false,
    stuck_reason = nil,
}

local function get_server_key()
    local job = game and game.JobId
    if type(job) == "string" and job ~= "" then return job end
    local place = game and game.PlaceId
    return "place:" .. tostring(place or "unknown")
end

empty_trade.server_key = get_server_key()

-- Read the trade state without letting a throwing getter escape. Returns
-- state, readable. readable=false means the read FAILED, which is UNKNOWN:
-- never evidence that the window closed, and never permission to act.
local function read_state_safe(app)
    if not app then return nil, false end
    local ok, state = pcall(function() return app:_get_local_trade_state() end)
    if not ok then return nil, false end
    return state, true
end

-- Return the number of entries in an offer, or nil when the offer is not
-- readable. Supports both sequential arrays and UID-keyed dictionaries.
--
-- The predicate is deliberately broad. The live read-only diagnostic counted
-- every entry of the real offer table (0 -> 1 -> 2 during a populated trade),
-- while this function previously required kind/id/uid on each entry. An
-- unrecognised entry shape would then be counted as zero and cancel a trade
-- that actually holds items. Counting any present entry errs toward NOT
-- cancelling, which is the only safe direction here; a genuinely empty offer
-- still reads as 0 because it has no entries at all.
local function count_offer_items(offer)
    if type(offer) ~= "table" then return nil, "offer_unavailable" end
    local items = offer.items
    if type(items) ~= "table" then return nil, "items_unavailable" end
    local count = 0
    for _ in pairs(items) do count = count + 1 end
    return count, nil
end

local function read_partner_offer_count(app)
    if not app then return nil, "trade_app_unavailable" end
    local ok, offer = pcall(function() return app:_get_partner_offer() end)
    if not ok or not offer then return nil, "partner_offer_unavailable" end
    return count_offer_items(offer)
end

local function latch_empty_trade_limit()
    if empty_trade.latched then return end
    if not CONFIG.WINTERHUB.enabled then
        -- Without a status consumer, latching would stop trading forever with
        -- no hop/rejoin path. Keep counting and leave the decision to the
        -- operator instead of silently freezing the account.
        log("empty-trade: limit reached but WinterHub is disabled; not latching")
        return
    end
    empty_trade.latched = true
    empty_trade.latch_reason = "empty_trade_limit"
    empty_trade.skip_notified = false
end

-- A server change means a brand new failure budget: the previous server's
-- empty-offer streak says nothing about this one. Only a genuine server key
-- change clears the counter/latch - TradeApp disappearance and ordinary UI
-- replacement must not, or a flaky UI would hand a farming server endless
-- retries.
local function check_server_transition()
    local key = get_server_key()
    if key == empty_trade.server_key then return false end

    log("server changed:", tostring(empty_trade.server_key), "->", tostring(key),
        "| resetting empty-offer budget")
    empty_trade.server_key = key
    empty_trade.failures = 0
    empty_trade.latched = false
    empty_trade.latch_reason = nil
    empty_trade.skip_notified = false
    empty_trade.session = nil
    empty_trade.stuck = false
    empty_trade.stuck_reason = nil
    return true
end

-- Adapter outcomes that mean "there is no usable cancellation path" rather
-- than "the cancellation attempt failed". Only these publish the gentler
-- "cancellation_unavailable" reason.
local CANCEL_UNAVAILABLE_REASONS = {
    unverified_cancellation_api = true,
    auto_decline_disabled = true,
    native_cancel_unavailable = true,
    trade_app_unavailable = true,
}

-- Isolated cancellation adapter. Two implementations, in priority order:
--
--   1. getgenv().__ADM_AUTOTRADE_CANCEL_TRADE(app, state) - an operator
--      override, expected to return literal true when the request was made.
--   2. The game's own decline entry point, TradeApp:_decline_trade.
--
-- Neither is verified against a live client. The built-in is called with NO
-- extra arguments precisely because its parameter list is unknown: guessing
-- an argument would be worse than a call that simply does nothing. A return
-- of true means "the request did not throw", never "the trade was cancelled" -
-- the caller still requires an observed closure before counting anything.
local function cancel_trade_adapter(app, state)
    local env = getgenv and getgenv() or nil
    local impl = env and env.__ADM_AUTOTRADE_CANCEL_TRADE
    if type(impl) == "function" then
        local ok, result, err = pcall(impl, app, state)
        if not ok then return false, tostring(result) end
        return result == true, err
    end

    if not CONFIG.EMPTY_TRADE.auto_decline then
        return false, "auto_decline_disabled"
    end
    if not app then return false, "trade_app_unavailable" end

    local ok_index, method = pcall(function() return app._decline_trade end)
    if not ok_index then
        return false, "native_decline_unreadable:" .. tostring(method)
    end
    if type(method) ~= "function" then return false, "native_cancel_unavailable" end

    local called, err = pcall(method, app)
    if not called then
        return false, "native_decline_error:" .. tostring(err)
    end
    return true
end

-- How long a cancellation may take to actually close the trade window, the
-- backoff between cancellation attempts when the adapter cannot cancel, and
-- the longest a dispatched cancellation call may stay unsettled before its
-- outcome is declared unknown. The last one bounds an adapter that yields or
-- never returns, so a stuck call cannot wedge the polling loop forever.
local EMPTY_CLOSE_WINDOW = 5
local EMPTY_CANCEL_BACKOFF = 5
local EMPTY_CANCEL_CALL_WATCHDOG = 15

-- Partner display name, when the trade state exposes one. Used for the
-- failure webhook and to ensure only the session that owns the timer is
-- cancelled.
local function empty_trade_partner_name(state)
    if type(state) ~= "table" then return nil end
    local pp
    if state.sender == LocalPlayer then
        pp = state.recipient
    else
        pp = state.sender
    end
    if type(pp) == "table" and pp.Name ~= nil then return tostring(pp.Name) end
    if typeof and typeof(pp) == "Instance" and pp.Name then return tostring(pp.Name) end
    return nil
end

-- Create the one session object for a trade. Called only while
-- empty_trade.session is nil, so the deadline never restarts on a poll.
local function begin_empty_session(state)
    local now = os.clock()
    empty_trade.session_seq = empty_trade.session_seq + 1
    empty_trade.session = {
        id = empty_trade.session_seq,
        opened_at = now,
        deadline = now + CONFIG.EMPTY_TRADE.timeout_seconds,
        partner_seen = false,
        cancel_attempted = false,
        cancelling = false,
        failure_recorded = false,
        cancel_started = nil,
        cancel_unconfirmed = false,
        last_cancel_at = nil,
        partner_name = empty_trade_partner_name(state),
        saw_confirmation = false,
        -- Cancellation lifecycle. `cancel_outcome` is one of:
        --   nil/"requested" -> dispatched, closure not yet observed
        --   "unavailable"   -> no verified adapter to call
        --   "failed"        -> adapter refused or threw
        --   "unknown"       -> call never settled inside the watchdog
        -- Only an observed closure may advance the failure counter, so no
        -- state here ever means "cancelled".
        cancel_outcome = nil,
        cancel_inflight = false,
        cancel_dispatched_at = nil,
        cancel_error = nil,
        cancel_app = nil,
        stuck_warned = false,
    }
    log("empty-trade: session", empty_trade.session.id, "started")
    return empty_trade.session
end

-- Dispatch the cancellation adapter OFF the polling loop.
--
-- The adapter is arbitrary injected code: it may return instantly, yield for
-- seconds, or never return. Running it inline would suspend the only loop that
-- drives the trade and refreshes the WinterHub heartbeat, so the call happens
-- in a spawned task and the session records that it is in flight. Exactly one
-- call may be outstanding per session; a second dispatch cannot start until
-- the first settles or the watchdog declares its outcome unknown.
--
-- Session ownership is re-checked when the call settles: a session that was
-- abandoned or replaced while the call was suspended is never written to.
local function dispatch_cancellation(session, app, state)
    session.cancel_attempted = true
    session.last_cancel_at = os.clock()
    session.cancel_inflight = true
    session.cancel_outcome = "requested"
    session.cancel_dispatched_at = os.clock()
    -- The closure window starts when the request is dispatched, not when it
    -- returns: a suspended call must not extend the window.
    session.cancel_started = os.clock()
    -- The instance the request was dispatched against. A nil state read from
    -- any other instance is not evidence that THIS session closed.
    session.cancel_app = app
    local session_id = session.id

    task.spawn(function()
        local ok, err = cancel_trade_adapter(app, state)
        if empty_trade.session ~= session then
            log("empty-trade: cancellation settled for abandoned session", session_id)
            return
        end
        session.cancel_inflight = false
        session.cancel_settled_at = os.clock()
        if ok and not session.partner_seen then
            -- A returned value is a REQUEST, never a closure. The counter
            -- waits for an observed nil state.
            session.cancel_outcome = "requested"
            session.cancelling = true
            session.cancel_error = nil
            empty_trade.stuck = false
            empty_trade.stuck_reason = nil
            log("empty-trade: cancellation requested for session", session_id)
            return
        end
        if ok and session.partner_seen then
            -- The offer filled while the request was in flight; the trade is
            -- no longer empty, so treat this as a normal trade again.
            session.cancel_outcome = nil
            session.cancel_attempted = false
            session.cancel_unconfirmed = false
            session.cancel_app = nil
            session.last_cancel_at = nil
            session.cancelling = false
            session.cancel_started = nil
            log("empty-trade: partner offered items during cancellation; session", session_id,
                "resumes normal trading")
            return
        end
        session.cancelling = false
        session.cancel_started = nil
        session.cancel_error = tostring(err)
        -- The partner may have filled the offer while this call was running.
        -- Recovery wins: a late failure must not re-poison a live trade, or
        -- the next heartbeat would publish "error" and ask for a rejoin
        -- in the middle of a normal trade.
        if session.partner_seen then
            session.cancel_outcome = nil
            session.cancel_attempted = false
            session.last_cancel_at = nil
            session.cancel_app = nil
            log("empty-trade: late cancellation failure ignored; session", session_id,
                "had already recovered")
            return
        end
        session.cancel_outcome = CANCEL_UNAVAILABLE_REASONS[tostring(err)]
            and "unavailable" or "failed"
        empty_trade.stuck = true
        empty_trade.stuck_reason = (session.cancel_outcome == "unavailable")
            and "cancellation_unavailable" or "cancellation_failed"
        log("empty-trade: cancellation not applied (", tostring(err),
            "); trade left open, nothing counted")
    end)
end

-- Exactly one failure/emission per session. Only called after the trade
-- window was confirmed closed following a successful cancellation.
local function record_empty_failure(session)
    if not session or session.failure_recorded then return end
    session.failure_recorded = true
    empty_trade.failures = empty_trade.failures + 1
    local failures = empty_trade.failures
    local max_failures = empty_trade.max_failures
    local elapsed = os.clock() - (session.opened_at or os.clock())
    log("empty-trade: failure", failures, "of", max_failures,
        "after", string.format("%.1fs", elapsed))
    -- Finalize the latch before any HTTP yield. Otherwise a slow webhook can
    -- leave the accept hook live and accept a new trade mid-skip.
    if failures >= max_failures then
        latch_empty_trade_limit()
    end
    local partner_name, session_id = session.partner_name, session.id
    task.spawn(function()
        pcall(send_trade_failed_webhook, partner_name, elapsed, failures,
            max_failures, "Empty partner offer", session_id)
    end)
end

-- Trade state went nil. Returns (counted_failure, cancellation_context).
-- counted_failure=true means a confirmed empty cancellation was recorded, so
-- the caller must not also account it as a successful trade. The second value
-- is true whenever a cancellation was requested for this session, even if the
-- close arrived too late or the adapter failed; the caller must invalidate
-- cached completion in that case. An unrelated close leaves the failure
-- counter untouched.
local function resolve_empty_session_on_close(observer_app)
    local session = empty_trade.session
    if not session then return false, false end
    local cancellation_context = session.cancelling
        or session.cancel_unconfirmed == true
        or session.cancel_attempted == true
    -- A dispatched request counts as pending even before the adapter
    -- returns: an adapter that yields can close the window while it is still
    -- suspended, and that close must not be thrown away.
    if session.cancelling or session.cancel_outcome == "requested" then
        local started = session.cancel_started
        -- Same-session evidence is required. A nil state read from a
        -- different TradeApp instance proves only that some app is closed,
        -- not that the session we cancelled ended, so it is never counted.
        local same_session = session.cancel_app == nil or observer_app == session.cancel_app
        if not same_session then
            log("empty-trade: closure seen on a replaced TradeApp; not counted for session",
                session.id)
        elseif started and (os.clock() - started) <= EMPTY_CLOSE_WINDOW
            and not session.partner_seen then
            -- Pass the session id through the async webhook before teardown.
            record_empty_failure(session)
            empty_trade.session = nil
            empty_trade.stuck = false
            empty_trade.stuck_reason = nil
            return true, true
        else
            log("empty-trade: cancelled but window close was not confirmed in time; not counted")
        end
    end
    empty_trade.session = nil
    empty_trade.stuck = false
    empty_trade.stuck_reason = nil
    return false, cancellation_context
end

-- Per-poll empty-offer handling. Returns true when normal accept/confirm
-- processing must be skipped.
--
-- Order matters. A populated partner offer recovers the session first, since
-- that is the one signal which ends the empty-trade problem. After that, an
-- unresolved cancellation blocks every action no matter what the offer reads
-- like: an UNKNOWN offer must never become permission to confirm.
local function process_empty_trade(app, state)
    if not CONFIG.EMPTY_TRADE.enabled then return false end

    local partner_name = empty_trade_partner_name(state)
    local stage = state.current_stage
    local session = empty_trade.session

    -- A trade can close and another open between polls. Without a game-side
    -- trade id, use the strongest observable signals: a different partner, or
    -- a stage that regressed from confirmation back to negotiation. Reset the
    -- timer/flags in those cases instead of reusing an expired session.
    if session then
        local partner_changed = session.partner_name ~= nil and partner_name ~= nil
            and session.partner_name ~= partner_name
        local stage_regressed = stage == "negotiation" and session.saw_confirmation == true
        if partner_changed or stage_regressed then
            log("empty-trade: new trade session detected; abandoning session", session.id)
            empty_trade.session = nil
            empty_trade.stuck = false
            empty_trade.stuck_reason = nil
            session = nil
        end
    end

    session = session or begin_empty_session(state)
    if session.partner_name == nil and partner_name ~= nil then
        session.partner_name = partner_name
    end
    if stage == "confirmation" then session.saw_confirmation = true end
    local now = os.clock()

    local count = read_partner_offer_count(app)
    if count ~= nil and count > 0 then
        session.partner_seen = true
    end

    -- RECOVERY. Once the partner has offered anything, this session is an
    -- ordinary trade: every cancellation flag is dropped so a later genuine
    -- completion is counted, reported, and resets the consecutive streak.
    -- Retaining the cancellation history here would silently swallow real
    -- successes after an unavailable or failed attempt.
    if session.partner_seen then
        if session.cancel_attempted or session.cancelling or session.cancel_unconfirmed then
            log("empty-trade: populated offer ends cancellation for session", session.id)
        end
        session.cancelling = false
        session.cancel_started = nil
        session.cancel_unconfirmed = false
        session.cancel_attempted = false
        session.cancel_outcome = nil
        session.cancel_inflight = false
        session.cancel_dispatched_at = nil
        session.cancel_error = nil
        session.cancel_app = nil
        session.last_cancel_at = nil
        empty_trade.stuck = false
        empty_trade.stuck_reason = nil
        return false
    end

    -- Blocking return for every unresolved-cancellation path. It also drops
    -- any cached completion, so a success sampled before the deadline can
    -- never be reported once the outcome became uncertain. Recovery re-caches
    -- it on the next poll if the trade really is still completable.
    local function block()
        completing = false
        pending_received, pending_given, pending_partner = nil, nil, nil
        return true
    end

    -- Every unresolved outcome below freezes accept/confirm. With WinterHub
    -- enabled that freeze is published as "error"; with it disabled nothing
    -- consumes the state, so the operator gets exactly one console line.
    -- Deliberately NOT log(): that is DEBUG-gated and off by default.
    local function warn_if_unconsumed(target)
        if CONFIG.WINTERHUB.enabled or target.stuck_warned then return end
        target.stuck_warned = true
        print("[autotrade] WARN: empty trade in session " .. tostring(target.id)
            .. " cannot be cancelled and WinterHub is disabled - close the trade window manually")
    end

    -- A dispatched call that never settles is bounded, is never retried on
    -- top of itself, and never implies that anything was cancelled.
    if session.cancel_inflight then
        local since = session.cancel_dispatched_at or now
        if (now - since) <= EMPTY_CANCEL_CALL_WATCHDOG then return block() end
        session.cancel_inflight = false
        session.cancel_outcome = "unknown"
        session.cancel_started = since
        session.cancelling = true
        log("empty-trade: cancellation call unsettled after "
            .. tostring(EMPTY_CANCEL_CALL_WATCHDOG) .. "s; outcome unknown")
    end

    if session.cancel_outcome == "unknown" then
        empty_trade.stuck = true
        empty_trade.stuck_reason = "cancellation_outcome_unknown"
        warn_if_unconsumed(session)
        return block()
    end

    -- failed / unavailable: the trade stays unconfirmed for as long as the
    -- outcome is unresolved. This is the flag the accept and confirm paths
    -- must see, not a one-poll return value.
    local uncertain = (session.cancel_outcome == "failed")
        or (session.cancel_outcome == "unavailable")
    if uncertain then
        empty_trade.stuck = true
        empty_trade.stuck_reason = (session.cancel_outcome == "unavailable")
            and "cancellation_unavailable" or "cancellation_failed"
        -- Keep blocking accept/confirm regardless: confirming an empty trade
        -- to escape a freeze would trade a stall for a fake success.
        warn_if_unconsumed(session)
    end

    -- An accepted cancellation is waiting for the window to actually close.
    -- While it is pending nothing may be accepted or confirmed.
    if session.cancelling then
        if session.cancel_started and (now - session.cancel_started) <= EMPTY_CLOSE_WINDOW then
            return block()
        end
        -- The window did not close in time: never count, never emit, and
        -- never fall through to confirm this session.
        log("empty-trade: cancel window not closed within "
            .. tostring(EMPTY_CLOSE_WINDOW) .. "s; leaving trade open")
        session.cancelling = false
        session.cancel_started = nil
        session.cancel_unconfirmed = true
        empty_trade.stuck = true
        empty_trade.stuck_reason = "cancellation_unconfirmed"
        warn_if_unconsumed(session)
        return block()
    end
    if session.cancel_unconfirmed then return block() end

    -- UNKNOWN is not EMPTY: there is nothing to cancel. While a previous
    -- cancellation is unresolved it is also not permission to act.
    if count ~= 0 then
        if uncertain then return block() end
        return false
    end

    if now < session.deadline then
        if uncertain then return block() end
        return false
    end

    -- Boundary: re-read the app, the trade state and the offer before
    -- cancelling. Stale poll data is never enough to cancel.
    local fresh_app = get_trade_app()
    if not fresh_app then
        log("empty-trade: TradeApp unavailable at deadline; not cancelling")
        return block()
    end
    local fresh_state, fresh_readable = read_state_safe(fresh_app)
    if not fresh_readable then
        log("empty-trade: trade state UNKNOWN at deadline; not cancelling")
        return block()
    end
    if not fresh_state then
        -- Window already closed; the close handler resolves the session.
        return block()
    end
    local fresh_partner = empty_trade_partner_name(fresh_state)
    if fresh_partner and session.partner_name and fresh_partner ~= session.partner_name then
        log("empty-trade: partner changed; abandoning session", session.id)
        empty_trade.session = nil
        -- The new partner gets its own deadline. A stuck flag left by the
        -- previous session must not keep publishing "error" over a fresh
        -- trade and ask WinterHub to rejoin mid-negotiation.
        empty_trade.stuck = false
        empty_trade.stuck_reason = nil
        return false
    end
    local fresh_count, fresh_err = read_partner_offer_count(fresh_app)
    if fresh_count == nil then
        log("empty-trade: offer UNKNOWN at deadline (" .. tostring(fresh_err) .. "); not cancelling")
        if uncertain then return block() end
        return false
    end
    if fresh_count > 0 then
        session.partner_seen = true
        empty_trade.stuck = false
        empty_trade.stuck_reason = nil
        return false
    end

    -- Bounded backoff between cancellation attempts (never duplicate events).
    if session.last_cancel_at and (now - session.last_cancel_at) < EMPTY_CANCEL_BACKOFF then
        return block()
    end

    dispatch_cancellation(session, fresh_app, fresh_state)

    -- If the adapter returned without yielding, the window may already be
    -- closed. Only a readable nil state from the SAME app instance counts:
    -- a replacement app or a failed read is UNKNOWN, left to the delayed
    -- close handler, which applies the same window and partner checks.
    if not session.cancel_inflight and session.cancelling then
        local after_app = get_trade_app()
        if after_app == fresh_app then
            local after_state, after_readable = read_state_safe(after_app)
            if after_readable and not after_state then
                if resolve_empty_session_on_close(fresh_app) then
                    completing = false
                    pending_received, pending_given, pending_partner = nil, nil, nil
                    last_stage = nil
                    in_trade = false  -- window is closed; let the idle/hop logic run
                    log("empty-trade: window confirmed closed after cancellation")
                end
            end
        end
    end
    return block()
end
-- Trade Lifecycle
-- Drives a live trade from negotiation to confirmation, and books a
-- completion only when both offers were confirmed before the state went nil.

local function capture_completion(app, state)
    if not state or state.current_stage ~= "confirmation" then return false end
    local mine    = app:_get_my_offer()
    local partner = app:_get_partner_offer()
    if not (mine and partner and mine.confirmed and partner.confirmed) then return false end

    completing       = true
    pending_received = copy_trade_items(partner.items)
    pending_given    = copy_trade_items(mine.items)
    local pp
    if state.sender == LocalPlayer then
        pp = state.recipient
    else
        pp = state.sender
    end
    pending_partner = (typeof(pp) == "Instance" and pp.Name) or nil
    return true
end

local function step_trade()
    if not CONFIG.AUTO_ACCEPT.enabled then in_trade = false return end
    -- Empty-offer limit reached: stop processing (and taking) trades.
    if empty_trade and empty_trade.latched then return end

    local app = get_trade_app()
    -- A UI instance can disappear for a poll while the game replaces it.
    -- Preserve lifecycle state briefly, but never leave WinterHub active
    -- forever if the app does not return.
    if not app then
        if not in_trade and not last_stage then return end
        trade_app_missing_since = trade_app_missing_since or os.clock()
        if os.clock() - trade_app_missing_since < TRADE_APP_REPLACEMENT_GRACE then return end
        log("TradeApp unavailable after replacement grace; clearing stale trade state")
        last_stage, in_trade, completing = nil, false, false
        pending_received, pending_given, pending_partner = nil, nil, nil
        -- Drop the session, but never the failure counter: an unverifiable
        -- disappearance is not an empty offer, and not a success either.
        empty_trade.session = nil
        empty_trade.stuck = false
        empty_trade.stuck_reason = nil
        trade_app_missing_since = nil
        return
    end
    trade_app_missing_since = nil

    local state, state_readable = read_state_safe(app)
    if not state_readable then
        -- A throwing state getter is UNKNOWN, not a close. Treat it like a
        -- transient UI problem: keep the session, skip actions this poll.
        log("trade state UNKNOWN this poll; holding session")
        return
    end
    if not state then
        -- A confirmed empty cancellation is accounted here, exactly once.
        -- Any cancellation context also invalidates a cached completion: a
        -- late close must never be reported as a successful trade.
        local empty_closed, cancel_context = resolve_empty_session_on_close(app)
        if empty_closed or cancel_context then
            completing = false
            pending_received, pending_given, pending_partner = nil, nil, nil
            last_stage = nil
        end
        if last_stage == "confirmation" then
            if completing then
                trade_count = trade_count + 1
                last_items  = pending_received
                -- A real completed trade clears consecutive empty failures.
                empty_trade.failures = 0
                empty_trade.stuck = false
                empty_trade.stuck_reason = nil
                -- Network requests can stall; keep trade polling and the
                -- WinterHub heartbeat independent from webhook latency.
                task.spawn(send_trade_webhook, pending_received, pending_given, pending_partner,
                    trade_count, os.clock() - session_started_at)
            end
            log("trade complete")
        end
        completing = false
        pending_received, pending_given, pending_partner = nil, nil, nil
        last_stage = nil
        in_trade = false
        return
    end

    in_trade = true
    mark_activity()  -- reset the idle-hop timer while a trade is open

    local stage = state.current_stage
    if stage ~= last_stage then
        log("stage:", stage)
        last_stage = stage
        stage_since = os.clock()
        confirmation_fired = false
    end

    -- Empty-offer recovery. Runs before capture_completion/actions so a
    -- pending cancellation can never be confirmed as a successful trade.
    if process_empty_trade(app, state) then return end

    -- detect real completion: both sides confirmed (cache items before close)
    pcall(capture_completion, app, state)

    local delay = stage == "confirmation" and CONFIG.AUTO_ACCEPT.confirmation_delay or CONFIG.AUTO_ACCEPT.negotiation_delay
    if os.clock() - stage_since < delay then return end
    if os.clock() - last_fire < CONFIG.AUTO_ACCEPT.refire_every then return end
    if action_busy or (stage == "confirmation" and confirmation_fired) then return end

    -- Re-read both the app instance and stage immediately before acting.
    -- Any unreadable state aborts the action for this poll.
    local current_app = get_trade_app()
    local current_state, current_readable = read_state_safe(current_app)
    if current_app ~= app or not current_readable or not current_state
        or current_state.current_stage ~= stage then
        return
    end

    action_busy = true
    last_fire = os.clock()

    if stage == "negotiation" then
        local ok, err = pcall(function() current_app:_on_accept_pressed() end)
        if not ok then log("accept error:", err) end
    elseif stage == "confirmation" then
        confirmation_fired = true
        local ok, err = pcall(function() current_app:_on_confirm_pressed() end)
        if not ok then
            log("confirm error:", err)
            confirmation_fired = false
        else
            -- Some trades close before the next poll. Sample the offers again
            -- immediately after the confirm handler while they are readable.
            pcall(capture_completion, current_app, current_state)
        end
    end
    action_busy = false
end

-- WinterHub Integration
-- Writes <username>_winteraddons.json for the external hop agent.
-- Contract:
--   status  "completed"              agent hops to the next server
--           "disconnected"/"error"   agent rejoins the same server
--           anything else            keep going
--   ts      os.time(); the agent treats a file older than roughly 40s as
--           dead and relaunches the account
--   count   completed trades, for dashboard progress
--   items   { { name=, qty= }, ... } from the latest completed trade
--
-- "completed" is reported when no trade arrived for idle_hop_seconds and no
-- trade is open, so the agent never hops mid-trade. Otherwise "active" is
-- refreshed on a heartbeat. A latched empty-offer server keeps reporting
-- "completed" until the server changes, so the agent stops farming it.
local wh_file = LocalPlayer.Name .. "_winteraddons.json"
local wh_last_write = 0

local function summarize_items_for_wh(items)
    -- group by display name -> { {name=, qty=}, ... }
    local counts, order = {}, {}
    each_trade_item(items, function(item)
        if not KindDB then ensure_deps() end
        local def  = KindDB and KindDB[item.kind]
        local name = (def and def.name) or item.kind
        if not counts[name] then order[#order + 1] = name end
        counts[name] = (counts[name] or 0) + 1
    end)
    local out = {}
    for _, name in ipairs(order) do out[#out + 1] = { name = name, qty = counts[name] } end
    return out
end

local function write_winterhub()
    if not CONFIG.WINTERHUB.enabled then return false, false end
    if os.clock() - wh_last_write < CONFIG.WINTERHUB.heartbeat then return false, false end

    -- decide status: a latched empty-offer server is done for good, so it must
    -- stay "completed" on every later heartbeat. Otherwise never hop mid-trade;
    -- hop only after the idle window.
    local status
    if empty_trade.latched then
        status = "completed"
    elseif empty_trade.stuck then
        -- No verified cancellation API: ask the agent to rejoin this server
        -- rather than leaving the account frozen or faking completion.
        status = "error"
    else
        status = "active"
        if not initializing and not in_trade
            and (os.clock() - last_activity) > CONFIG.WINTERHUB.idle_hop_seconds then
            status = "completed"
        end
    end

    local payload = {
        status = status,
        ts     = os.time(),
        count  = trade_count,
        items  = summarize_items_for_wh(last_items),
    }
    local wrote = pcall(function()
        writefile(wh_file, game:GetService("HttpService"):JSONEncode(payload))
    end)
    if not wrote then
        -- Do NOT advance wh_last_write and do NOT notify: the next poll has to
        -- retry the write, and the skip webhook may only fire once the file
        -- actually says "completed".
        log("winterhub: status write failed; retrying next poll")
        return false, false
    end

    wh_last_write = os.clock()
    if status == "completed" then log("winterhub: status=completed (hop)") end

    -- Tell the skip webhook exactly once per latch, and only after a
    -- successful write proves the agent will really see "completed".
    --
    -- Delivery runs in a spawned task: an unresponsive endpoint must not
    -- stall the heartbeat or trade polling. The flag is set before dispatch
    -- so a re-entrant heartbeat cannot queue a second copy. That is local
    -- event suppression only - it is NOT server-enforced exactly-once
    -- delivery, and a lost response can still duplicate or lose the message.
    local dispatched = false
    if empty_trade.latched and not empty_trade.skip_notified then
        empty_trade.skip_notified = true
        dispatched = true
        local failures, trades = empty_trade.failures, trade_count
        task.spawn(function()
            local ok, err = pcall(send_server_skipped_webhook,
                failures, trades, "Repeated empty offers", "completed")
            if not ok then log("winterhub: server-skipped webhook error:", err) end
        end)
    end
    return true, dispatched
end

-- Main Loop
log("starting | accept:", CONFIG.AUTO_ACCEPT.enabled,
    "| settings:", CONFIG.FORCE_SETTINGS.enabled,
    "| winterhub:", CONFIG.WINTERHUB.enabled)

-- is the CURRENT DialogApp instance actually hooked? (catches instance swaps
-- where the UI replaces DialogApp after a cold load, leaving a stale hook)
local function hook_ready()
    local ok, ready = pcall(function()
        if not UIManager or not UIManager.apps then return false end
        local d = UIManager.apps.DialogApp
        local cls = d and getmetatable(d)
        cls = cls and cls.__index
        return d ~= nil and d.__autotrade_hooked == true
            and cls ~= nil and cls == hooked_dialog_class
            and cls.dialog == hooked_dialog_fn
            and invite_guard_ready and exclusion_guard_ready
            and invite_guard_module.can_receive_invites == allow_invites
            and exclusion_guard_module.is_player_excluded == allow_player
    end)
    return ok and ready
end

local settings_done = not CONFIG.FORCE_SETTINGS.enabled

-- Deterministic local-test seam. Never active in a normal Delta run.
if getgenv and getgenv().__ADM_AUTOTRADE_TEST_MODE then
    print("[autotrade] TEST MODE - no trading loop started")
    -- Do not leave the per-account singleton guard behind: a later real
    -- execution must be able to start instead of silently aborting.
    if getgenv then getgenv()[_guard_key] = nil end
    getgenv().__ADM_AUTOTRADE_TEST_API = {
        CONFIG = CONFIG,
        empty_trade = empty_trade,
        step_trade = step_trade,
        write_winterhub = write_winterhub,
        install_accept_hook = install_accept_hook,
        clear_open_request = clear_open_request,
        capture_completion = capture_completion,
        send_trade_webhook = send_trade_webhook,
        send_trade_failed_webhook = send_trade_failed_webhook,
        send_server_skipped_webhook = send_server_skipped_webhook,
        http_post = http_post,
        deliver_webhook = deliver_webhook,
        format_duration = format_duration,
        format_duration_compact = format_duration_compact,
        get_delivered_events = function() return delivered_events end,
        is_event_delivered = function(id) return delivered_events[id] == true end,
        count_offer_items = count_offer_items,
        read_partner_offer_count = read_partner_offer_count,
        read_state_safe = read_state_safe,
        resolve_empty_session_on_close = resolve_empty_session_on_close,
        EMPTY_CLOSE_WINDOW = EMPTY_CLOSE_WINDOW,
        EMPTY_CANCEL_BACKOFF = EMPTY_CANCEL_BACKOFF,
        EMPTY_CANCEL_CALL_WATCHDOG = EMPTY_CANCEL_CALL_WATCHDOG,
        get_server_key = get_server_key,
        latch_empty_trade_limit = latch_empty_trade_limit,
        check_server_transition = check_server_transition,
        cancel_trade_adapter = cancel_trade_adapter,
        get_trade_app = get_trade_app,
        get_trade_count = function() return trade_count end,
        set_trade_count = function(v) trade_count = v end,
        get_last_items = function() return last_items end,
        get_last_stage = function() return last_stage end,
        get_in_trade = function() return in_trade end,
        get_completing = function() return completing end,
        get_hooked_fn = function() return hooked_dialog_fn end,
        get_hooked_class = function() return hooked_dialog_class end,
        reset_runtime = function()
            last_stage, last_fire, stage_since = nil, 0, 0
            action_busy, confirmation_fired = false, false
            in_trade, initializing = false, false
            completing = false
            pending_received, pending_given, pending_partner = nil, nil, nil
            trade_count, last_items = 0, nil
            trade_app_missing_since = nil
            wh_last_write = 0
            delivered_events = {}
            sending_events = {}
            last_forced_dialog, last_forced_ticket = nil, 0
            empty_trade.session = nil
            empty_trade.failures = 0
            empty_trade.latched = false
            empty_trade.latch_reason = nil
            empty_trade.skip_notified = false
            empty_trade.stuck = false
            empty_trade.stuck_reason = nil
            empty_trade.server_key = get_server_key()
        end,
    }
    -- Do not leave the test flag sticky: the next real execution in this
    -- executor must run normally instead of silently skipping the loop.
    getgenv().__ADM_AUTOTRADE_TEST_MODE = nil
    return
end

-- Settings-only mode has no long-running loop to retry from. Give late game
-- modules a bounded chance to load before exiting.
if not CONFIG.AUTO_ACCEPT.enabled and not CONFIG.WINTERHUB.enabled then
    for _ = 1, 30 do
        settings_done = force_trade_settings()
        if settings_done then break end
        task.wait(1)
    end
    log(settings_done and "only settings enabled - done" or "settings unavailable after 30s")
    if getgenv then getgenv()[_guard_key] = nil end
    return
end

-- SPIN-WAIT: install the hook the instant the apps exist, before the first
-- request can land. Fast retry (per-frame), not the slow 0.4s poll.
pcall(write_winterhub)
if CONFIG.AUTO_ACCEPT.enabled then
    local t0 = os.clock()
    repeat
        pcall(install_accept_hook)
        pcall(write_winterhub)
        if hook_ready() then break end
        task.wait()
    until os.clock() - t0 > 30
    log(hook_ready() and "accept hook ready (spin)" or "hook not ready after 30s - will keep retrying")
end
initializing = false

while true do
    -- A new server gets a fresh empty-offer budget; the previous server's
    -- streak and latch must not leak across the hop. This only reacts to a
    -- server key change, never to TradeApp disappearance or UI replacement.
    if check_server_transition() then
        -- Publish the new server's status immediately instead of leaving the
        -- old server's "completed" marker in place until the next heartbeat.
        wh_last_write = 0
    end

    -- re-verify the hook every poll; re-install if DialogApp was swapped
    if CONFIG.AUTO_ACCEPT.enabled and not hook_ready() then
        pcall(install_accept_hook)
    end

    -- catch a trade-request dialog that was already open before we started
    if CONFIG.AUTO_ACCEPT.enabled then pcall(clear_open_request) end

    -- Install the accept hook first, but do not withhold the independently
    -- configured settings if the hook cannot load.
    if not settings_done and (not CONFIG.AUTO_ACCEPT.enabled or hook_ready() or not initializing) then
        settings_done = force_trade_settings()
    end

    local ok, err = pcall(step_trade)
    if not ok then log("step error:", err) end

    -- write the WinterHub status file (heartbeat + hop signal)
    pcall(write_winterhub)

    task.wait(CONFIG.AUTO_ACCEPT.poll)
end
