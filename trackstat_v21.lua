-- TRACKSTAT V21 | Targeted continuous read-only scanner
-- Evidence baseline: ClientData + new:StarRewardsDB, LocalPlayer only.
-- Does not open StarRewards GUI, claim rewards, purchase items, call game remotes,
-- or transmit Roblox authentication credentials.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

local INTERVAL = 2
local HEARTBEAT = 60
local TXT = "trackstat_result.txt"
local JSON = "trackstat_result.json"
local VERSION = "21.0"

local env = (type(getgenv) == "function" and getgenv()) or _G
if env.__TRACKSTAT_V21 and env.__TRACKSTAT_V21.running then
    env.__TRACKSTAT_V21.running = false
end
local state = { running = true, upload_busy = false, last_upload_signature = nil, last_upload_at = 0 }
env.__TRACKSTAT_V21 = state
local remoteConfig = env.__TRACKSTAT_CONFIG or {}
local REMOTE_URL = type(remoteConfig.endpoint) == "string" and remoteConfig.endpoint or nil
local REMOTE_TOKEN = type(remoteConfig.device_token) == "string" and remoteConfig.device_token or nil
local UPLOAD_HEARTBEAT = 60

local function stamp()
    local ok, result = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    return ok and result or tostring(os.time())
end

local function log(kind, msg)
    print(string.format("[%s] [TRACKSTAT] %s | %s", stamp(), kind, msg))
end

local function safeLoad()
    local fsysObj = ReplicatedStorage:FindFirstChild("Fsys")
    if not fsysObj then return nil, nil, "Fsys missing" end
    local ok, fsys = pcall(require, fsysObj)
    if not ok or type(fsys) ~= "table" or type(fsys.load) ~= "function" then
        return nil, nil, "Fsys unavailable"
    end
    local loaded, client = pcall(fsys.load, "ClientData")
    if not loaded or type(client) ~= "table" or type(client.get_data) ~= "function" then
        return nil, nil, "ClientData unavailable"
    end
    local dbOk, db = pcall(fsys.load, "new:StarRewardsDB")
    if not dbOk or type(db) ~= "table" then db = nil end
    return client, db
end

local function number(v)
    return type(v) == "number" and v or nil
end

local function read(client, db)
    local ok, all = pcall(client.get_data)
    if not ok or type(all) ~= "table" then return nil, "ClientData not ready" end
    local own = all[player.Name]
    if type(own) ~= "table" then return nil, "Local player data not ready" end
    local reward = own.star_rewards_manager
    local daily = own.daily_login_manager
    if type(reward) ~= "table" or type(daily) ~= "table" then
        return nil, "Reward managers not ready"
    end
    local stars = number(own.stars)
    local goal = reward.current_goal
    local goalDef = db and type(goal) == "string" and db[goal] or nil
    local price = type(goalDef) == "table" and number(goalDef.price) or nil
    local claimed = type(reward.claimed) == "boolean" and reward.claimed or nil
    local nextClaim = number(reward.next_claim_timestamp)
    return {
        version = VERSION,
        username = player.Name,
        account_id = tostring(player.UserId),
        observed_at = stamp(),
        observed_unix = os.time(),
        status = stars ~= nil and claimed ~= nil and "READY" or "PARTIAL",
        source = "ClientData",
        stars = stars,
        daily_streak = number(daily.streak),
        longest_streak = number(daily.longest_streak),
        claimed = claimed,
        daily = claimed == nil and "UNKNOWN" or (claimed and "CLAIMED" or "UNCLAIMED"),
        current_goal = goal,
        egg_price = price,
        stars_remaining = stars and price and math.max(0, price - stars) or nil,
        next_claim_timestamp = nextClaim,
        next_claim_in_seconds = number(daily.time_until_next_streak),
        progress_kind = "balance_vs_price",
    }
end

local function value(v)
    if v == nil then return "--" end
    return tostring(v)
end

local function formatLine(r)
    return string.format("Stars: %s/%s | Streak: %s | Daily: %s | Left: %s",
        value(r.stars), value(r.egg_price), value(r.daily_streak), r.daily, value(r.stars_remaining))
end

local function request_function()
    if type(request) == "function" then return request end
    if type(http_request) == "function" then return http_request end
    if type(syn) == "table" and type(syn.request) == "function" then return syn.request end
    return nil
end

local function upload_once(result)
    if not REMOTE_URL or not REMOTE_TOKEN then return false, "remote sync not configured" end
    local send = request_function()
    if not send then return false, "executor HTTP request unavailable" end
    local ok, response = pcall(send, {
        Url = REMOTE_URL,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. REMOTE_TOKEN,
        },
        Body = HttpService:JSONEncode(result),
    })
    if not ok or type(response) ~= "table" then return false, "request failed" end
    local code = tonumber(response.StatusCode or response.Status or 0)
    if code == 200 or code == 202 then return true end
    return false, "server rejected report (HTTP " .. tostring(code) .. ")"
end

local function upload_async(result, signature)
    if not REMOTE_URL or not REMOTE_TOKEN then return end
    local heartbeat_due = os.clock() - state.last_upload_at >= UPLOAD_HEARTBEAT
    if state.upload_busy or (state.last_upload_signature == signature and not heartbeat_due) then return end
    state.upload_busy = true
    task.spawn(function()
        local delays = { 0, 2, 5, 10 }
        local success, reason = false, nil
        for attempt = 1, #delays do
            if delays[attempt] > 0 then task.wait(delays[attempt]) end
            success, reason = upload_once(result)
            if success then break end
        end
        if success then
            state.last_upload_signature = signature
            state.last_upload_at = os.clock()
            log("SYNCED", "Server accepted statistics")
        elseif reason ~= "remote sync not configured" then
            log("SYNC_FAILED", reason or "unknown upload error")
        end
        state.upload_busy = false
    end)
end
local function save(r)
    if type(writefile) ~= "function" then return end
    local text = table.concat({
        "TRACKSTAT V" .. VERSION,
        "Updated: " .. r.observed_at,
        "Status: " .. r.status,
        "Account: " .. value(r.username),
        formatLine(r),
        "Goal: " .. value(r.current_goal),
        "Next claim timestamp: " .. value(r.next_claim_timestamp),
        "Progress meaning: Stars balance / item price (not lifetime progress)",
    }, "\n")
    pcall(writefile, TXT, text)
    pcall(function() writefile(JSON, HttpService:JSONEncode(r)) end)
end

log("STARTED", "Scan: 2s | Target: LocalPlayer | Read-only")
task.spawn(function()
    local client, db
    local previous, lastHeartbeat, lastIssue = nil, os.clock(), nil
    while state.running do
        local success, err = pcall(function()
            if not client then
                local reason
                client, db, reason = safeLoad()
                if not client then error(reason or "ClientData unavailable") end
            end
            if not db then
                local fsysObj = ReplicatedStorage:FindFirstChild("Fsys")
                if fsysObj then
                    local fsys = require(fsysObj)
                    local ok, loaded = pcall(fsys.load, "new:StarRewardsDB")
                    if ok and type(loaded) == "table" then db = loaded end
                end
            end
            local result, reason = read(client, db)
            if not result then error(reason) end
            local signature = table.concat({value(result.stars), value(result.egg_price),
                value(result.daily_streak), result.daily, value(result.current_goal),
                value(result.next_claim_timestamp)}, "|")
            if signature ~= previous then
                log(previous and "UPDATED" or "READY", formatLine(result))
                previous = signature
            end
            lastIssue = nil
            save(result)
            upload_async(result, signature)
            if os.clock() - lastHeartbeat >= HEARTBEAT then
                log("ALIVE", formatLine(result))
                lastHeartbeat = os.clock()
            end
        end)
        if not success then
            local issue = tostring(err):gsub("^.-:%d+: ", "")
            if issue ~= lastIssue then log("WAITING", issue) end
            lastIssue = issue
            if issue:find("ClientData") or issue:find("Fsys") then client = nil end
            if os.clock() - lastHeartbeat >= HEARTBEAT then
                log("ALIVE", "Waiting for game data")
                lastHeartbeat = os.clock()
            end
        end
        task.wait(INTERVAL)
    end
    log("STOPPED", "Scanner replaced or stopped")
end)