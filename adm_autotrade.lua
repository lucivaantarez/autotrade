--[[=====================================================================
    adm_autotrade.lua  -  Adopt Me auto-trader (for Delta)

    What it does: your account automatically accepts incoming trades and
    clicks through them to the end. Made for moving pets between your own
    accounts.

    HOW TO USE: you only ever edit the CONFIG block right below. Turn each
    feature on or off with its "enabled" line, save, and push to GitHub.
    Nothing else in the file needs touching.

    What each part does:
      1. CONFIG        - all your on/off switches and settings (edit this)
      2. SETUP         - loads the game's own code so the script can use it
      3. FORCE SETTINGS- sets your Trading option to "Everyone" so bots can
                         send you trades
      4. AUTO-ACCEPT   - taps "Accept" on the trade request pop-up for you
      5. TRADE DRIVER  - walks the trade through Accept then Confirm to finish
      6. WINTERHUB     - writes a small status file that tells the WinterHub
                         app when to hop to the next server
      7. MAIN LOOP     - runs everything on repeat and never crashes out
=======================================================================]]

--[[=====================================================================
    1. CONFIG  -  THIS IS THE ONLY PART YOU NEED TO EDIT
       Change the values below. true = on, false = off.
=======================================================================]]
local CONFIG = {

    -- Master switch. Set to false and the whole script does nothing.
    MASTER_ENABLED = true,

    FORCE_SETTINGS = {
        -- Sets your in-game Trading option to "Everyone" on startup, so your
        -- bot accounts are actually allowed to send you trades. (StarPets and
        -- other logins reset this to "Friends", which blocks the bots.)
        enabled = true,
        -- Also do the same for gifting ("give" requests), not just trades.
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
        -- Paste your Discord webhook link here (between the quotes).
        -- SECURITY: keep this OUT of a public repo. Regenerate if leaked.
        url = "",
        -- What the message lists: "received" (what you got), "given" (what you
        -- gave), or "both".
        report = "received",
    },

    -- Print progress messages in the Delta console. Handy while testing;
    -- set to false for a quiet run.
    DEBUG = false,
}

--[[=====================================================================
    2. SETUP
=======================================================================]]
local function log(...) if CONFIG.DEBUG then print("[autotrade]", ...) end end

if not CONFIG.MASTER_ENABLED then
    log("MASTER_ENABLED = false - script is off")
    return
end

local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

-- ANTI-AFK: stop Roblox's 20-min idle kick. Fires VirtualUser on Idled.
pcall(function()
    local VirtualUser = game:GetService("VirtualUser")
    LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- SINGLETON GUARD (per-account): two clones share one Delta env + getgenv,
-- so a single global flag would make clone 2 abort. Key it on UserId instead:
-- each account gets its own slot, but a real double-execute on the SAME
-- account still aborts (prevents doubled webhooks).
local _guard_key = "__adm_autotrade_" .. tostring(LocalPlayer.UserId)
if getgenv then
    if getgenv()[_guard_key] then
        print("[autotrade] already running for this account - aborting duplicate")
        return
    end
    getgenv()[_guard_key] = true
end

local Fsys = require(game.ReplicatedStorage:WaitForChild("Fsys"))
local load = Fsys.load

-- Load ONLY UIManager eagerly - it's all the accept hook needs, and getting
-- the hook in fast is what prevents the first-request race. Everything else
-- (settings DB, KindDB) is loaded lazily AFTER the hook is in.
local UIManager
pcall(function() UIManager = load("UIManager") end)

local SettingsHelper, SettingsDB, KindDB
local deps_ready = false
local function ensure_deps()
    if deps_ready then return end
    pcall(function()
        SettingsHelper = load("SettingsHelper")
        SettingsDB     = require(game.ReplicatedStorage.ClientDB.SettingsDB)
        KindDB         = load("KindDB")   -- kind -> display name
    end)
    deps_ready = (SettingsDB ~= nil)
end

-- idle state (declared early so the accept hook + driver can use it)
local last_activity = os.clock()
local function mark_activity() last_activity = os.clock() end

--[[=====================================================================
    3. FORCE SETTINGS  -  Trading -> Everyone (saves to server immediately)
=======================================================================]]
local function force_everyone(id)
    ensure_deps()
    pcall(function()
        local def = SettingsDB.by_id[id]
        if not def then return end
        local idx = table.find(def.element_options.choices, "Everyone")
        if not idx then return end
        SettingsHelper.set_setting_client({ setting_id = id, value = idx })
        log("setting", id, "-> Everyone")
    end)
end

local function force_trade_settings()
    if not CONFIG.FORCE_SETTINGS.enabled then return end
    force_everyone("trade_requests")
    if CONFIG.FORCE_SETTINGS.also_force_giving then
        force_everyone("give_item_requests")
    end
end

--[[=====================================================================
    4. AUTO-ACCEPT  -  auto-answer Adopt Me's own trade-request dialog
       We let the game's native accept path run (it does the real
       InvokeServer + the trade-start handshake that opens the window).
       We just (a) stop it auto-declining on join, (b) answer its dialog
       with "Accept", (c) skip the suspicious-captcha / scam popups so
       nothing can hang. Returns true once the dialog hook is in place.
=======================================================================]]
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

local function install_accept_hook()
    if not CONFIG.AUTO_ACCEPT.enabled then return false end
    if not UIManager then return false end

    local apps = UIManager.apps
    if not apps then return false end

    -- (a) don't let the game auto-decline before showing the dialog
    pcall(function() load("MinigameForcedState").can_receive_invites = function() return true end end)
    pcall(function() load("TradeExcluder").is_player_excluded = function() return false end end)

    local DialogApp = apps.DialogApp
    if not DialogApp then return false end

    -- (b) hook the REAL dialog method. It lives on the CLASS (via metatable
    -- __index), not the instance, and it returns a Promise (not a string).
    -- For a trade_request we short-circuit with a resolved promise carrying
    -- "Accept" - exactly what the waiting TradeApp handler expects.
    if not DialogApp.__autotrade_hooked then
        -- Adopt Me's promise module is "package:Promise" (NOT "Promise")
        local Promise
        pcall(function() Promise = load("package:Promise") end)
        if not Promise then pcall(function() Promise = load("Promise") end) end
        local cls = getmetatable(DialogApp)
        cls = cls and cls.__index
        if cls and cls.dialog and Promise then
            local orig = cls.dialog
            cls.dialog = function(self, opts)
                if opts and opts.handle == "trade_request" then
                    mark_activity()
                    log("auto-accepting trade request (hooked dialog)")
                    local p = Promise.resolve("Accept")
                    if opts.yields or opts.yields == nil then return p:expect() end
                    return p
                end
                return orig(self, opts)
            end
            DialogApp.__autotrade_hooked = true
        elseif cls and cls.dialog and not Promise then
            log("WARN: promise module not found; relying on open-dialog force-answer only")
        end
    end

    -- (c) neutralize suspicious-captcha, scam warnings, unbalanced warnings, etc.
    local TradeApp = apps.TradeApp
    if TradeApp then patch_trade_app(TradeApp) end

    return DialogApp.__autotrade_hooked == true
end

-- If a trade-request dialog is ALREADY waiting when we start (your bot sends
-- before the script executes), the hook above only catches FUTURE dialogs.
-- A waiting dialog shows up as ticket_count > completed_ticket (is_dialog_open
-- is unreliable - it reads false even while a request is on screen). The
-- in-flight ticket is completed_ticket + 1; push "Accept" into it.
local last_forced_ticket = 0
local function clear_open_request()
    if not UIManager or not UIManager.apps then return end
    local D = UIManager.apps.DialogApp
    if not D or not D.force_response_signal then return end
    local count = D.ticket_count or 0
    local done  = D.completed_ticket or 0
    if count <= done then return end                 -- nothing waiting
    local ticket = done + 1
    if ticket == last_forced_ticket then return end  -- don't spam the same one
    last_forced_ticket = ticket
    pcall(function()
        D.force_response_signal:Fire(ticket, table.pack("Accept"))
        log("force-answered waiting dialog (ticket " .. ticket .. ")")
    end)
end

--[[=====================================================================
    8. WEBHOOK  -  Discord notify on completed trade (real display names)
       Translates each item's `kind` -> KindDB[kind].name in-game, groups
       by name + form, and posts quantities. Fires only when BOTH sides
       confirmed (a real completion, not a cancel).
=======================================================================]]
local function http_post(url, body)
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    if not req then log("no HTTP function (request) available") return end
    pcall(function()
        req({ Url = url, Method = "POST",
              Headers = { ["Content-Type"] = "application/json" }, Body = body })
    end)
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

local function summarize(items)
    local counts, order = {}, {}
    for _, item in ipairs(items or {}) do
        local lbl = pet_label(item)
        if not counts[lbl] then order[#order+1] = lbl end
        counts[lbl] = (counts[lbl] or 0) + 1
    end
    local lines = {}
    for _, lbl in ipairs(order) do lines[#lines+1] = ("%dx %s"):format(counts[lbl], lbl) end
    return lines, #(items or {})
end

local last_sig, last_sig_time = nil, 0
local function send_trade_webhook(received, given, partner_name)
    if not CONFIG.WEBHOOK.enabled or CONFIG.WEBHOOK.url == "" then return end

    -- dedup: a real second trade can't complete within a few seconds (lock
    -- timers), so an identical signature inside the window is a double-fire.
    local sig = tostring(partner_name) .. "|" .. tostring(#(received or {})) .. "|" .. tostring(#(given or {}))
    for _, it in ipairs(received or {}) do sig = sig .. it.kind end
    if sig == last_sig and (os.clock() - last_sig_time) < 6 then
        log("duplicate trade suppressed")
        return
    end
    last_sig, last_sig_time = sig, os.clock()

    local fields = {}
    local rep = CONFIG.WEBHOOK.report
    if rep ~= "given" then
        local lines, n = summarize(received)
        fields[#fields+1] = { name = ("Received (%d)"):format(n),
            value = (#lines>0 and table.concat(lines, "\n") or "nothing"), inline = false }
    end
    if rep == "given" or rep == "both" then
        local lines, n = summarize(given)
        fields[#fields+1] = { name = ("Given (%d)"):format(n),
            value = (#lines>0 and table.concat(lines, "\n") or "nothing"), inline = false }
    end
    local payload = {
        username = "ADM AutoTrade",
        embeds = {{
            title = "Trade complete",
            description = partner_name and ("with **" .. partner_name .. "**") or nil,
            color = 5763719,
            fields = fields,
            footer = { text = LocalPlayer.Name },
        }},
    }
    local ok, body = pcall(function() return game:GetService("HttpService"):JSONEncode(payload) end)
    if ok then http_post(CONFIG.WEBHOOK.url, body) log("webhook sent") end
end


local app_cache = nil
local function get_trade_app()
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
-- completion tracking for the webhook + WinterHub
local completing = false
local pending_received, pending_given, pending_partner = nil, nil, nil
local trade_count = 0            -- completed trades this session (WinterHub count)
local last_items = nil          -- items from the most recent completed trade

local function step_trade()
    if not CONFIG.AUTO_ACCEPT.enabled then in_trade = false return end

    local app = get_trade_app()
    if not app then last_stage = nil in_trade = false return end

    local state = app:_get_local_trade_state()
    if not state then
        if last_stage == "confirmation" then
            if completing then
                trade_count = trade_count + 1
                last_items  = pending_received
                send_trade_webhook(pending_received, pending_given, pending_partner)
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

    -- detect real completion: both sides confirmed (cache items before close)
    if stage == "confirmation" then
        local mine    = app:_get_my_offer()
        local partner = app:_get_partner_offer()
        if mine and partner and mine.confirmed and partner.confirmed then
            completing       = true
            pending_received = partner.items
            pending_given    = mine.items
            local me   = LocalPlayer
            local pp   = (state.sender == me) and state.recipient or state.sender
            pending_partner = (typeof(pp) == "Instance" and pp.Name) or nil
        end
    end

    local delay = stage == "confirmation" and CONFIG.AUTO_ACCEPT.confirmation_delay or CONFIG.AUTO_ACCEPT.negotiation_delay
    if os.clock() - stage_since < delay then return end
    if os.clock() - last_fire < CONFIG.AUTO_ACCEPT.refire_every then return end
    if action_busy or (stage == "confirmation" and confirmation_fired) then return end

    -- Re-read both the app instance and stage immediately before acting.
    local current_app = get_trade_app()
    local current_state = current_app and current_app:_get_local_trade_state()
    if current_app ~= app or not current_state or current_state.current_stage ~= stage then return end

    action_busy = true
    last_fire = os.clock()

    if stage == "negotiation" then
        local ok, err = pcall(function() current_app:_on_accept_pressed() end)
        if not ok then log("accept error:", err) end
    elseif stage == "confirmation" then
        confirmation_fired = true
        local ok, err = pcall(function() current_app:_on_confirm_pressed() end)
        if not ok then log("confirm error:", err) confirmation_fired = false end
    end
    action_busy = false
end

--[[=====================================================================
    6. WINTERHUB  -  write <username>_winteraddons.json so the agent hops
       Contract (game-agnostic):
         status : "completed"           -> agent hops to next server
                  "disconnected"/"error"-> agent rejoins same server
                  anything else          -> keep going
         ts     : os.time() (Unix sec). File older than ~40s = dead -> relaunch.
         count  : trades done (dashboard progress)
         items  : { { name=, qty= }, ... } (live on dashboard)
       We report "completed" when no trade has been received for
       idle_hop_seconds AND no trade is currently open (never hop mid-trade).
       Otherwise "active", refreshed on a heartbeat so we never look dead.
=======================================================================]]
local wh_file = LocalPlayer.Name .. "_winteraddons.json"
local wh_last_write = 0

local function summarize_items_for_wh(items)
    -- group by display name -> { {name=, qty=}, ... }
    local counts, order = {}, {}
    for _, item in ipairs(items or {}) do
        if not KindDB then ensure_deps() end
        local def  = KindDB and KindDB[item.kind]
        local name = (def and def.name) or item.kind
        if not counts[name] then order[#order + 1] = name end
        counts[name] = (counts[name] or 0) + 1
    end
    local out = {}
    for _, name in ipairs(order) do out[#out + 1] = { name = name, qty = counts[name] } end
    return out
end

local function write_winterhub()
    if not CONFIG.WINTERHUB.enabled then return end
    if os.clock() - wh_last_write < CONFIG.WINTERHUB.heartbeat then return end
    wh_last_write = os.clock()

    -- decide status: never hop mid-trade; hop only after the idle window
    local status = "active"
    if not in_trade and (os.clock() - last_activity) > CONFIG.WINTERHUB.idle_hop_seconds then
        status = "completed"
    end

    local payload = {
        status = status,
        ts     = os.time(),
        count  = trade_count,
        items  = summarize_items_for_wh(last_items),
    }
    pcall(function()
        writefile(wh_file, game:GetService("HttpService"):JSONEncode(payload))
    end)
    if status == "completed" then log("winterhub: status=completed (hop)") end
end

--[[=====================================================================
    7. MAIN LOOP
=======================================================================]]
log("starting | accept:", CONFIG.AUTO_ACCEPT.enabled,
    "| settings:", CONFIG.FORCE_SETTINGS.enabled,
    "| winterhub:", CONFIG.WINTERHUB.enabled)

-- is the CURRENT DialogApp instance actually hooked? (catches instance swaps
-- where the UI replaces DialogApp after a cold load, leaving a stale hook)
local function hook_ready()
    if not UIManager or not UIManager.apps then return false end
    local d = UIManager.apps.DialogApp
    return d ~= nil and d.__autotrade_hooked == true
end

-- settings-only mode: nothing races, just force once and (maybe) exit
if not CONFIG.AUTO_ACCEPT.enabled then
    force_trade_settings()
    if not CONFIG.WINTERHUB.enabled then
        log("only settings enabled - done")
        if getgenv then getgenv()[_guard_key] = nil end
        return
    end
end

-- SPIN-WAIT: install the hook the instant the apps exist, before the first
-- request can land. Fast retry (per-frame), not the slow 0.4s poll.
if CONFIG.AUTO_ACCEPT.enabled then
    local t0 = os.clock()
    repeat
        install_accept_hook()
        if hook_ready() then break end
        task.wait()
    until os.clock() - t0 > 30
    log(hook_ready() and "accept hook ready (spin)" or "hook not ready after 30s - will keep retrying")
end

local settings_done = false
while true do
    -- re-verify the hook every poll; re-install if DialogApp was swapped
    if CONFIG.AUTO_ACCEPT.enabled and not hook_ready() then
        install_accept_hook()
    end

    -- catch a trade-request dialog that was already open before we started
    if CONFIG.AUTO_ACCEPT.enabled then clear_open_request() end

    -- force settings only after the hook is confirmed in
    if hook_ready() and not settings_done then
        force_trade_settings()
        settings_done = true
    end

    local ok, err = pcall(step_trade)
    if not ok then log("step error:", err) end

    -- write the WinterHub status file (heartbeat + hop signal)
    pcall(write_winterhub)

    task.wait(CONFIG.AUTO_ACCEPT.poll)
end
