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
        enabled = true,
        url = "",   -- paste a Discord webhook (can reuse the autotrade one)
    },

    -- Log NORMAL cancels too (you/partner closed the window with nothing
    -- confirmed). false = only log real FAILURES (server reject / error text).
    LOG_CANCELS = false,

    -- Record recent trade remotes (AddItemToOffer, accept, confirm...) so the
    -- report shows the exact last actions before the fail.
    LOG_REMOTES = true,

    BUFFER = 40,     -- recent trade-remote lines to keep
    POLL   = 0.4,    -- state poll interval (match the autotrade)
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
local REMOTES = {}
local function push_remote(line)
    REMOTES[#REMOTES+1] = line
    if #REMOTES > CONFIG.BUFFER then table.remove(REMOTES, 1) end
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
local FAIL_HINTS = { "unexpectedly failed", "Trade failed", "trade failed",
                     "could not be completed", "cancelled the trade", "declined" }
local function note_if_fail(text)
    for _, h in ipairs(FAIL_HINTS) do
        if text:find(h, 1, true) then
            last_error_text = text:gsub("[\r\n]", " "):sub(1, 160)
            last_error_time = os.clock()
            return
        end
    end
end
pcall(function()
    LogService.MessageOut:Connect(function(msg) pcall(note_if_fail, msg) end)
end)
local function scan_coregui_for_fail()
    pcall(function()
        for _, d in ipairs(CoreGui:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
                note_if_fail(d.Text)
            end
        end
    end)
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
local function report_fail(kind_str)
    fail_count = fail_count + 1
    local err = (last_error_text and (os.clock() - last_error_time) < 8) and last_error_text or nil

    local my_lines      = summarize(snap.my_items)
    local partner_lines = summarize(snap.partner_items)
    local remotes_tail  = {}
    for i = math.max(1, #REMOTES - 12), #REMOTES do remotes_tail[#remotes_tail+1] = REMOTES[i] end

    -- write to rolling log
    local block = {
        "==== TRADE " .. kind_str .. " #" .. fail_count .. "  @" .. os.date("%H:%M:%S") .. " ====",
        "partner: " .. (snap.partner_name or "?"),
        "died at stage: " .. tostring(snap.stage),
        "confirmed?  me=" .. tostring(snap.my_confirmed) .. "  partner=" .. tostring(snap.partner_confirmed),
        "game said: " .. (err or "(no error text captured)"),
        "my offer:      " .. table.concat(my_lines, ", "),
        "partner offer: " .. table.concat(partner_lines, ", "),
        "last trade remotes:",
    }
    for _, r in ipairs(remotes_tail) do block[#block+1] = "  " .. r end
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
        local function fld(name, lines, inline)
            local v = "```\n" .. table.concat(lines, "\n") .. "\n```"
            if #v > 1000 then v = v:sub(1, 990) .. "\n...```" end
            return { name = name, value = v, inline = inline or false }
        end
        local payload = {
            username = "ADM TradeLog",
            embeds = {{
                title = "Trade " .. kind_str,
                description = err and ("Game said: **" .. err .. "**") or "closed without completing",
                color = (kind_str == "FAILED") and 15548997 or 15844367,
                fields = {
                    { name = "Partner", value = snap.partner_name or "?", inline = true },
                    { name = "Died at", value = tostring(snap.stage), inline = true },
                    { name = "Confirmed", value = "me=" .. tostring(snap.my_confirmed) .. " / partner=" .. tostring(snap.partner_confirmed), inline = true },
                    fld("My offer", my_lines),
                    fld("Partner offer", partner_lines),
                    fld("Last trade remotes", (#remotes_tail>0 and remotes_tail or {"(none)"})),
                },
                footer = { text = LocalPlayer.Name },
            }},
        }
        local ok, body = pcall(function() return HttpService:JSONEncode(payload) end)
        if ok then
            pcall(function()
                _request({ Url = CONFIG.WEBHOOK.url, Method = "POST",
                           Headers = { ["Content-Type"] = "application/json" }, Body = body })
            end)
        end
    end
end

--[[--------------------------------------------------------------------
    MAIN LOOP  -  detect the open->closed transition and classify it.
--------------------------------------------------------------------]]
log("running - watching trades for", LocalPlayer.Name)
local was_open = false
while true do
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
        scan_coregui_for_fail()  -- catch the error toast while still open
    elseif was_open then
        -- just closed. classify using the LAST snapshot we took.
        was_open = false
        if snap then
            local completed = (snap.stage == "confirmation") and snap.my_confirmed and snap.partner_confirmed
            if completed then
                log("trade completed cleanly - not logging")
            else
                -- fail vs cancel: fail if the game printed an error recently
                local had_err = last_error_text and (os.clock() - last_error_time) < 8
                if had_err then
                    report_fail("FAILED")
                elseif CONFIG.LOG_CANCELS then
                    report_fail("CANCELLED")
                else
                    log("closed without confirm, no error text - skipping (LOG_CANCELS off)")
                end
            end
        end
        snap = nil
    end

    task.wait(CONFIG.POLL)
end
