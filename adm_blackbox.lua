--[[=====================================================================
    adm_blackbox.lua  -  Disconnect "flight recorder" for Adopt Me (Delta)

    WHY THIS EXISTS: an Error Code 267 kick ("a bug was detected...")
    kills the Lua VM instantly, so you can't run code AFTER the kick to
    find out what happened. This script is a black box: it records what
    your account is doing the WHOLE time, and the moment the disconnect
    prompt shows up it snapshots the last events into a crash file. On
    the NEXT launch (WinterHub rejoins you), it auto-sends that snapshot
    to Discord so you can read exactly what fired right before the kick.

    Run this ALONGSIDE adm_autotrade.lua (execute both). It doesn't touch
    the autotrade script - it watches the whole game from the outside.

    What it captures:
      - Every outgoing RemoteEvent/Function fire, with args  <-- most useful
      - Console output (errors / warnings / Roblox's own messages)
      - The exact on-screen kick text + error code when you get booted
      - Your last-known trade activity (read from the WinterHub file)

    Files it writes (in your executor's workspace folder):
      <username>_blackbox.log   - rolling human-readable recorder. Open this
                                  ANY time to see the last ~200 events.
      <username>_crash.json     - written on a detected kick; sent to Discord
                                  on the next launch, then marked as sent.

    YOU ONLY EDIT THE CONFIG BLOCK BELOW.
=======================================================================]]

local CONFIG = {
    -- Master switch.
    ENABLED = true,

    -- Send the crash report to Discord on the next launch after a kick.
    WEBHOOK = {
        enabled = true,
        -- Use a SEPARATE webhook from the autotrade one if you like, or the
        -- same. Paste between the quotes.
        url = "",
    },

    -- Record every outgoing remote (FireServer / InvokeServer). This is the
    -- gold for diagnosing 267s that fire on trade actions. Leave on.
    LOG_REMOTES = true,

    -- Record console output (errors, warnings, engine messages).
    LOG_CONSOLE = true,

    -- How many recent lines to keep per buffer (the "black box" depth).
    BUFFER = 200,

    -- How often the rolling .log file is rewritten, in seconds.
    FLUSH = 3,

    -- Print to the Delta console while testing.
    DEBUG = false,
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

local function log(...) if CONFIG.DEBUG then print("[blackbox]", ...) end end

-- singleton per account (Delta clones share getgenv)
local _key = "__adm_blackbox_" .. tostring(LocalPlayer.UserId)
if getgenv then
    if getgenv()[_key] then log("already running for this account"); return end
    getgenv()[_key] = true
end

local T0        = os.clock()
local function stamp() return string.format("%7.2f", os.clock() - T0) end
local LOG_FILE  = LocalPlayer.Name .. "_blackbox.log"
local CRASH_FILE= LocalPlayer.Name .. "_crash.json"
local WH_FILE   = LocalPlayer.Name .. "_winteraddons.json"  -- autotrade's file

-- executor helpers (all guarded)
local _writefile = writefile
local _readfile  = readfile
local _isfile    = isfile
local _delfile   = delfile
local _request   = (syn and syn.request) or (http and http.request) or http_request or request

--[[--------------------------------------------------------------------
    Ring buffers (the black box). Oldest line drops off the front.
--------------------------------------------------------------------]]
local REMOTES, CONSOLE = {}, {}
local function push(buf, line)
    buf[#buf + 1] = line
    if #buf > CONFIG.BUFFER then table.remove(buf, 1) end
end

local function truncate(s, n)
    s = tostring(s):gsub("[\r\n]", " ")
    n = n or 46
    if #s > n then return s:sub(1, n) .. "~" end
    return s
end

--[[--------------------------------------------------------------------
    1. REMOTE RECORDER  -  hook __namecall, log FireServer/InvokeServer.
       CRITICAL: this runs on EVERY remote, so the record path is fully
       pcall'd and ALWAYS returns the original call - a bug here must
       never break the game.
--------------------------------------------------------------------]]
if CONFIG.LOG_REMOTES and hookmetamethod and getnamecallmethod then
    local old
    old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if method == "FireServer" or method == "InvokeServer" then
            local args = table.pack(...)
            pcall(function()
                local parent = (self.Parent and self.Parent.Name) or "?"
                local parts = {}
                for i = 1, math.min(args.n, 4) do
                    parts[i] = truncate(args[i], 30)
                end
                push(REMOTES, string.format("%s  %s.%s:%s(%s)",
                    stamp(), parent, self.Name, method, table.concat(parts, ", ")))
            end)
        end
        return old(self, ...)
    end))
    log("remote recorder installed")
end

--[[--------------------------------------------------------------------
    2. CONSOLE RECORDER  -  capture engine/script output.
--------------------------------------------------------------------]]
local KICK_HINTS = { "Disconnect", "kicked", "moderation", "bug was detected",
                     "Error Code", "err_id", "lost connection", "Lua error" }
local function looks_like_kick(text)
    for _, h in ipairs(KICK_HINTS) do
        if text:find(h, 1, true) then return true end
    end
    return false
end

local crashed = false
local on_crash  -- fwd decl

if CONFIG.LOG_CONSOLE then
    pcall(function()
        LogService.MessageOut:Connect(function(msg, mtype)
            local tag = ({ [Enum.MessageType.MessageOutput] = "OUT",
                           [Enum.MessageType.MessageInfo]   = "INFO",
                           [Enum.MessageType.MessageWarning]= "WARN",
                           [Enum.MessageType.MessageError]  = "ERR " })[mtype] or "??? "
            push(CONSOLE, string.format("%s  %s %s", stamp(), tag, truncate(msg, 140)))
        end)
    end)
end

--[[--------------------------------------------------------------------
    3. KICK DETECTOR  -  the discriminator between a real 267 kick and a
       normal WinterHub server hop. A kick shows the "Disconnected /
       Error Code" prompt on screen; a clean hop shows the teleport
       loader instead. So we key ONLY on that prompt's text - this is
       exactly the box in your screenshot.
--------------------------------------------------------------------]]
local function read_prompt_text()
    -- concat every TextLabel/Button under CoreGui that looks like the
    -- disconnect prompt, so we grab the full message + code.
    local hit, chunks = false, {}
    pcall(function()
        for _, d in ipairs(CoreGui:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text ~= "" then
                local t = d.Text
                if t:find("Error Code", 1, true) or t:find("kicked", 1, true)
                   or t:find("bug was detected", 1, true) or t:find("Disconnected", 1, true) then
                    hit = true
                end
                chunks[#chunks + 1] = t
            end
        end
    end)
    if not hit then return nil end
    local full = table.concat(chunks, " | ")
    local code = full:match("Error Code:%s*(%d+)") or full:match("(%d+)")
    local eid  = full:match("(err_id_%w+)")
    return full, code, eid
end

--[[--------------------------------------------------------------------
    4. CRASH SNAPSHOT + REPORT
--------------------------------------------------------------------]]
local function last_trade_context()
    -- pull count/items the autotrade last wrote, for context.
    if not (_isfile and _readfile and _isfile(WH_FILE)) then return nil end
    local ok, data = pcall(function() return HttpService:JSONDecode(_readfile(WH_FILE)) end)
    if ok then return data end
    return nil
end

on_crash = function(reason, code, eid)
    if crashed then return end
    crashed = true
    log("KICK DETECTED:", code or "?", reason)

    local report = {
        account   = LocalPlayer.Name,
        userid    = LocalPlayer.UserId,
        when      = os.time(),
        runtime_s = math.floor(os.clock() - T0),
        error_code= code,
        err_id    = eid,
        reason    = truncate(reason or "unknown", 400),
        last_remotes = {},
        last_console = {},
        trade_ctx = last_trade_context(),
        sent      = false,
    }
    -- keep the tail of each buffer (most recent = most relevant)
    local function tail(buf, n)
        local out = {}
        for i = math.max(1, #buf - n + 1), #buf do out[#out + 1] = buf[i] end
        return out
    end
    report.last_remotes = tail(REMOTES, 25)
    report.last_console = tail(CONSOLE, 25)

    pcall(function()
        if _writefile then _writefile(CRASH_FILE, HttpService:JSONEncode(report)) end
    end)
    -- best-effort immediate send (may not finish before the VM dies - that's
    -- fine, the next launch will send it from the file).
    pcall(function() if send_crash then send_crash(report) end end)
end

--[[--------------------------------------------------------------------
    5. WEBHOOK  -  send a crash report to Discord (readable embed).
--------------------------------------------------------------------]]
function send_crash(report)
    if not (CONFIG.WEBHOOK.enabled and CONFIG.WEBHOOK.url ~= "" and _request) then return false end

    local function block(lines)
        if #lines == 0 then return "_(none)_" end
        local s = "```\n" .. table.concat(lines, "\n") .. "\n```"
        if #s > 1000 then s = s:sub(1, 990) .. "\n...```" end
        return s
    end

    local desc = report.error_code and ("Error Code **" .. tostring(report.error_code) .. "**") or "Disconnected"
    if report.err_id then desc = desc .. "  (" .. report.err_id .. ")" end

    local fields = {
        { name = "Reason",        value = truncate(report.reason, 300), inline = false },
        { name = "Runtime",       value = tostring(report.runtime_s) .. "s", inline = true },
        { name = "Trades done",   value = tostring(report.trade_ctx and report.trade_ctx.count or "?"), inline = true },
        { name = "Last remotes fired", value = block(report.last_remotes), inline = false },
        { name = "Last console",  value = block(report.last_console), inline = false },
    }
    local payload = {
        username = "ADM BlackBox",
        embeds = {{
            title = "Disconnect captured",
            description = desc,
            color = 15548997, -- red
            fields = fields,
            footer = { text = report.account },
        }},
    }
    local ok, body = pcall(function() return HttpService:JSONEncode(payload) end)
    if not ok then return false end
    local sent = false
    pcall(function()
        _request({ Url = CONFIG.WEBHOOK.url, Method = "POST",
                   Headers = { ["Content-Type"] = "application/json" }, Body = body })
        sent = true
    end)
    return sent
end

--[[--------------------------------------------------------------------
    6. ON STARTUP  -  if the LAST session left a crash file, send it now
       (we're back in-game, so the network is up).
--------------------------------------------------------------------]]
pcall(function()
    if _isfile and _readfile and _isfile(CRASH_FILE) then
        local ok, prev = pcall(function() return HttpService:JSONDecode(_readfile(CRASH_FILE)) end)
        if ok and prev and not prev.sent then
            log("found unsent crash from last session - sending")
            if send_crash(prev) then
                prev.sent = true
                pcall(function() _writefile(CRASH_FILE, HttpService:JSONEncode(prev)) end)
            end
        end
    end
end)

--[[--------------------------------------------------------------------
    7. FLIGHT-RECORDER LOOP  -  flush the rolling log + poll for the kick
       prompt (the prompt can appear without a Log message, so we scan).
--------------------------------------------------------------------]]
local function flush_log()
    local out = {
        "=== ADM BlackBox | " .. LocalPlayer.Name .. " | runtime " .. math.floor(os.clock() - T0) .. "s ===",
        "",
        "-- REMOTES (newest last) --",
    }
    for _, l in ipairs(REMOTES) do out[#out + 1] = l end
    out[#out + 1] = ""
    out[#out + 1] = "-- CONSOLE (newest last) --"
    for _, l in ipairs(CONSOLE) do out[#out + 1] = l end
    pcall(function() if _writefile then _writefile(LOG_FILE, table.concat(out, "\n")) end end)
end

-- also treat a hard connection drop as a kick (NetworkClient loses its child)
pcall(function()
    local nc = game:GetService("NetworkClient")
    nc.ChildRemoved:Connect(function()
        local reason, code, eid = read_prompt_text()
        on_crash(reason or "connection dropped (NetworkClient child removed)", code, eid)
    end)
end)

log("running - watching", LocalPlayer.Name)
local last_flush = 0
while true do
    -- poll for the on-screen disconnect prompt
    if not crashed then
        local reason, code, eid = read_prompt_text()
        if reason and looks_like_kick(reason) then
            on_crash(reason, code, eid)
        end
    end

    if os.clock() - last_flush >= CONFIG.FLUSH then
        flush_log()
        last_flush = os.clock()
    end
    task.wait(0.5)
end
