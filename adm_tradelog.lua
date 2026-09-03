--[[=====================================================================
    adm_tradelog.lua  -  Trade-FAILURE logger for Adopt Me (Delta)

    USE THIS when the account STAYS in the game but a trade dies with
    "trade unexpectedly failed" (or just closes without completing).
    That is NOT a disconnect, so adm_blackbox.lua won't catch it - this
    script does.

    It watches the trade state machine from the outside (read-only, safe
    to run next to adm_autotrade.lua). Every time a trade window closes
    WITHOUT both sides confirmed, it writes a report: what you offered,
    what the partner offered, the stage it died at, whether each side
    had confirmed, the last trade remotes you fired, and the exact
    in-game failure text if the game printed one.

    Run alongside the autotrade. YOU ONLY EDIT THE CONFIG BLOCK.

    Output files (executor workspace):
      <username>_tradefails.log   - rolling human-readable list of fails
      (optional) Discord webhook   - one embed per fail
=======================================================================]]

local CONFIG = {
    ENABLED = true,

    WEBHOOK = {
        enabled = false, -- local workspace logging works without a webhook
        url = "https://saturnity.site/api/tradelog",
        token = (getgenv and getgenv().SATURNITY_TRADELOG_TOKEN) or "",
    },

    -- Log NORMAL cancels too (you/partner closed the window with nothing
    -- confirmed). false = only log real FAILURES (server reject / error text).
    LOG_CANCELS = false,

    -- Record recent trade remotes (AddItemToOffer, accept, confirm...) so the
    -- report shows the exact last actions before the fail.
    LOG_REMOTES = true,

    BUFFER = 40,     -- recent trade-remote lines to keep
    POLL   = 0.4,    -- state poll interval (match the autotrade)
    FLUSH  = 2,      -- continuously refresh the workspace debug log
    FAILURE_GRACE = 2, -- allow the failure toast to appear after the trade closes
    DEBUG  = false,
}

--[[=====================================================================
    (Nothing below needs editing.)
=======================================================================]]
if not CONFIG.ENABLED then return end

local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local HttpService = game:GetService("HttpService")
local LogService  = game:GetService("LogService")
local CoreGui     = game:GetService("CoreGui")
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

local function log(...) if CONFIG.DEBUG then print("[tradelog]", ...) end end

local _key = "__adm_tradelog_" .. tostring(LocalPlayer.UserId)
if getgenv then
    if getgenv()[_key] then log("already running"); return end
    getgenv()[_key] = true
end

local Fsys = require(game.ReplicatedStorage:WaitForChild("Fsys"))
local load = Fsys.load
local UIManager, KindDB
pcall(function() UIManager = load("UIManager") end)
local function ensure_kinddb() if not KindDB then pcall(function() KindDB = load("KindDB") end) end end

local LOG_FILE   = LocalPlayer.Name .. "_tradefails.log"
local DEBUG_FILE = LocalPlayer.Name .. "_tradelog_debug.log"
local _writefile = writefile
local _readfile  = readfile
local _isfile    = isfile
local _request   = (syn and syn.request) or (http and http.request) or http_request or request
local T0 = os.clock()
local function stamp() return string.format("%7.2f", os.clock() - T0) end

--[[--------------------------------------------------------------------
    Item labeling (same convention as the autotrade webhook).
--------------------------------------------------------------------]]
local function pet_label(item)
    ensure_kinddb()
    local def  = KindDB and KindDB[item.kind]
    local name = (def and def.name) or tostring(item.kind)
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
    for _, it in ipairs(items or {}) do
        local lbl = pet_label(it)
        if not counts[lbl] then order[#order+1] = lbl end
        counts[lbl] = (counts[lbl] or 0) + 1
    end
    local lines = {}
    for _, lbl in ipairs(order) do lines[#lines+1] = ("%dx %s"):format(counts[lbl], lbl) end
    if #lines == 0 then return { "nothing" } end
    return lines
end

--[[--------------------------------------------------------------------
    Recent trade-remote recorder (pcall-guarded __namecall hook).
    Only keeps trade-relevant remotes so the buffer stays focused.
--------------------------------------------------------------------]]
local REMOTES, CONSOLE = {}, {}
local function push_remote(line)
    REMOTES[#REMOTES+1] = line
    if #REMOTES > CONFIG.BUFFER then table.remove(REMOTES, 1) end
end
local function push_console(line)
    CONSOLE[#CONSOLE+1] = line
    if #CONSOLE > CONFIG.BUFFER then table.remove(CONSOLE, 1) end
end

local TRADE_HINTS = { "Offer", "Trade", "trade", "Accept", "Confirm", "confirm" }
local function is_trade_remote(name)
    for _, h in ipairs(TRADE_HINTS) do if name:find(h, 1, true) then return true end end
    return false
end

if CONFIG.LOG_REMOTES and hookmetamethod and getnamecallmethod then
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local m = getnamecallmethod()
        if m == "FireServer" or m == "InvokeServer" then
            local args = table.pack(...)
            pcall(function()
                local nm = self.Name or "?"
                if is_trade_remote(nm) then
                    local parts = {}
                    for i = 1, math.min(args.n, 3) do
                        parts[i] = tostring(args[i]):gsub("[\r\n]", " "):sub(1, 30)
                    end
                    push_remote(string.format("%s  %s:%s(%s)", stamp(), nm, m, table.concat(parts, ", ")))
                end
            end)
        end
        return old(self, ...)
    end))
    log("trade-remote recorder installed")
end

--[[--------------------------------------------------------------------
    Capture the in-game failure text ("trade unexpectedly failed", etc.)
    so the report says WHY, not just THAT it failed.
--------------------------------------------------------------------]]
local last_error_text, last_error_time = nil, 0
local failure_visible = false
local FAIL_HINTS = { "the trade unexpectedly failed", "unexpectedly failed", "trade failed",
                     "could not be completed", "cancelled the trade", "declined" }
local function note_if_fail(text, should_record)
    text = tostring(text or "")
    local lowered = text:lower()
    for _, h in ipairs(FAIL_HINTS) do
        if lowered:find(h, 1, true) then
            if should_record ~= false then
                last_error_text = text:gsub("[\r\n]", " "):sub(1, 160)
                last_error_time = os.clock()
                log("TRADE_FAILURE_DETECTED:", last_error_text)
            end
            return true
        end
    end
    return false
end
pcall(function()
    LogService.MessageOut:Connect(function(msg, message_type)
        pcall(function()
            push_console(string.format("%s  %s  %s", stamp(), tostring(message_type), tostring(msg):gsub("[\r\n]", " "):sub(1, 300)))
            note_if_fail(msg)
        end)
    end)
end)
local function scan_gui_for_fail()
    local found = false
    for _, root in ipairs({ CoreGui, PlayerGui }) do
        pcall(function()
            for _, d in ipairs(root:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
                    if note_if_fail(d.Text, not found and not failure_visible) then found = true end
                end
            end
        end)
    end
    failure_visible = found
end
--[[--------------------------------------------------------------------
    Trade state watcher.
--------------------------------------------------------------------]]
local app_cache
local function get_trade_app()
    -- re-fetch if the cached app is stale/gone (avoids the app_cache bug)
    local ok, app = pcall(function() return UIManager.apps.TradeApp end)
    if ok and app then
        if app ~= app_cache then app_cache = app end
        return app_cache
    end
    return nil
end

-- snapshot of the trade as of the last tick it was open
local snap = nil
local function take_snapshot(app, state)
    local s = { stage = state.current_stage }
    pcall(function()
        local mine    = app:_get_my_offer()
        local partner = app:_get_partner_offer()
        s.my_items        = mine and mine.items or {}
        s.partner_items   = partner and partner.items or {}
        s.my_confirmed    = mine and mine.confirmed or false
        s.partner_confirmed = partner and partner.confirmed or false
        local me = LocalPlayer
        local pp = (state.sender == me) and state.recipient or state.sender
        s.partner_name = (typeof(pp) == "Instance" and pp.Name) or "?"
    end)
    return s
end

local fail_count = 0
local function report_fail(kind_str, snapshot)
    fail_count = fail_count + 1
    local err = (last_error_text and (os.clock() - last_error_time) < 8) and last_error_text or nil

    local my_lines      = summarize(snapshot.my_items)
    local partner_lines = summarize(snapshot.partner_items)
    local remotes_tail  = {}
    for i = math.max(1, #REMOTES - 12), #REMOTES do remotes_tail[#remotes_tail+1] = REMOTES[i] end
    local console_tail = {}
    for i = math.max(1, #CONSOLE - 12), #CONSOLE do console_tail[#console_tail+1] = CONSOLE[i] end

    -- write to rolling log
    local block = {
        "==== TRADE " .. kind_str .. " #" .. fail_count .. "  @" .. os.date("%H:%M:%S") .. " ====",
        "partner: " .. (snapshot.partner_name or "?"),
        "died at stage: " .. tostring(snapshot.stage),
        "confirmed?  me=" .. tostring(snapshot.my_confirmed) .. "  partner=" .. tostring(snapshot.partner_confirmed),
        "game said: " .. (err or "(no error text captured)"),
        "my offer:      " .. table.concat(my_lines, ", "),
        "partner offer: " .. table.concat(partner_lines, ", "),
        "last trade remotes:",
    }
    for _, r in ipairs(remotes_tail) do block[#block+1] = "  " .. r end
    block[#block+1] = "last console messages:"
    for _, line in ipairs(console_tail) do block[#block+1] = "  " .. line end
    block[#block+1] = ""
    local text = table.concat(block, "\n")

    pcall(function()
        if _writefile then
            local prev = (_isfile and _isfile(LOG_FILE) and _readfile and _readfile(LOG_FILE)) or ""
            _writefile(LOG_FILE, prev .. text .. "\n")
        end
    end)
    log("logged " .. kind_str)

    -- webhook
    if CONFIG.WEBHOOK.enabled and CONFIG.WEBHOOK.url ~= "" and _request then
        log("CREATING_LOG_PAYLOAD")
        local function fld(name, lines, inline)
            local v = "```\n" .. table.concat(lines, "\n") .. "\n```"
            if #v > 1000 then v = v:sub(1, 990) .. "\n...```" end
            return { name = name, value = v, inline = inline or false }
        end
        local payload = {
            source = "adm_tradelog",
            deviceId = (getgenv and getgenv().SATURNITY_DEVICE_ID) or LocalPlayer.Name,
            account = LocalPlayer.Name,
            timestamp = os.time(),
            eventType = "TRADE_FAILURE",
            failureReason = err or "Trade closed without both sides confirmed",
            username = "ADM TradeLog",
            embeds = {{
                title = "Trade " .. kind_str,
                description = err and ("Game said: **" .. err .. "**") or "closed without completing",
                color = (kind_str == "FAILED") and 15548997 or 15844367,
                fields = {
                    { name = "Partner", value = snapshot.partner_name or "?", inline = true },
                    { name = "Died at", value = tostring(snapshot.stage), inline = true },
                    { name = "Confirmed", value = "me=" .. tostring(snapshot.my_confirmed) .. " / partner=" .. tostring(snapshot.partner_confirmed), inline = true },
                    fld("My offer", my_lines),
                    fld("Partner offer", partner_lines),
                    fld("Last trade remotes", (#remotes_tail>0 and remotes_tail or {"(none)"})),
                    fld("Last console messages", (#console_tail>0 and console_tail or {"(none)"})),
                },
                footer = { text = LocalPlayer.Name },
            }},
        }
        local ok, body = pcall(function() return HttpService:JSONEncode(payload) end)
        if ok then
            log("SENDING_TO_WEBHOOK")
            local sent, response = pcall(function()
                local headers = { ["Content-Type"] = "application/json" }
                if CONFIG.WEBHOOK.token ~= "" then headers.Authorization = "Bearer " .. CONFIG.WEBHOOK.token end
                return _request({ Url = CONFIG.WEBHOOK.url, Method = "POST",
                                  Headers = headers, Body = body })
            end)
            if sent then
                log("WEBHOOK_RESPONSE:", response and (response.StatusCode or response.Status or response.status_code) or "unknown")
            else
                log("WEBHOOK_RESPONSE: ERROR", response)
            end
        else
            log("PAYLOAD_CREATION_ERROR:", body)
        end
    else
        log("WEBHOOK_SKIPPED:", "enabled=" .. tostring(CONFIG.WEBHOOK.enabled), "request=" .. tostring(_request ~= nil), "url=" .. tostring(CONFIG.WEBHOOK.url ~= ""))
    end
end

--[[--------------------------------------------------------------------
    MAIN LOOP  -  detect the open->closed transition and classify it.
--------------------------------------------------------------------]]
log("running - watching trades for", LocalPlayer.Name)
local was_open = false
local pending_close, pending_close_time = nil, 0
local last_flush = 0
local function flush_debug_log()
    if not _writefile then return end
    local lines = { "=== ADM TradeLog live debug | " .. LocalPlayer.Name .. " | " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===", "", "-- TRADE REMOTES --" }
    for _, line in ipairs(REMOTES) do lines[#lines+1] = line end
    lines[#lines+1] = ""
    lines[#lines+1] = "-- CONSOLE --"
    for _, line in ipairs(CONSOLE) do lines[#lines+1] = line end
    _writefile(DEBUG_FILE, table.concat(lines, "\n"))
end
while true do
    -- Failure UI often appears in PlayerGui only after the trade state closes.
    scan_gui_for_fail()

    local app = get_trade_app()
    local state = nil
    if app then
        local ok, s = pcall(function() return app:_get_local_trade_state() end)
        if ok then state = s end
    end

    if state then
        -- trade is open: keep a fresh snapshot every tick
        snap = take_snapshot(app, state)
        was_open = true
    elseif was_open then
        -- Keep the final snapshot briefly because the failure toast is asynchronous.
        was_open = false
        pending_close, pending_close_time = snap, os.clock()
        snap = nil
    end

    if pending_close and ((last_error_time >= pending_close_time) or (os.clock() - pending_close_time >= CONFIG.FAILURE_GRACE)) then
        local snapshot = pending_close
        pending_close = nil
        if snapshot then
            local completed = (snapshot.stage == "confirmation") and snapshot.my_confirmed and snapshot.partner_confirmed
            if completed then
                log("trade completed cleanly - not logging")
            else
                -- fail vs cancel: fail if the game printed an error recently
                local had_err = last_error_text and (os.clock() - last_error_time) < 8
                if had_err then
                    report_fail("FAILED", snapshot)
                elseif CONFIG.LOG_CANCELS then
                    report_fail("CANCELLED", snapshot)
                else
                    log("closed without confirm, no error text - skipping (LOG_CANCELS off)")
                end
            end
        end
    end

    if os.clock() - last_flush >= CONFIG.FLUSH then
        pcall(flush_debug_log)
        last_flush = os.clock()
    end

    task.wait(CONFIG.POLL)
end
