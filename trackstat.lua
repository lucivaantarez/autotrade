-- TrackStat: read-only Adopt Me statistics tracker
--
-- Purpose:
--   Observe the currently available Star Rewards GUI and write a compact TXT
--   report for the current account. This script does not click, purchase,
--   invoke remotes, hook connections, or control another automation script.
--
-- Output:
--   trackstat_result.txt
--
-- Timing:
--   Normal scan: every 2 seconds
--   Stable verification: 3 matching samples, 0.5 seconds apart

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    ScanInterval = 2,
    StableInterval = 0.5,
    StableSamples = 3,
    ReportFile = "trackstat_result.txt",
    UnavailableHeartbeat = 30,
}

local PATH = {
    star_app = "StarRewardsApp",
    claim = "StarRewardsApp.Static.Folder.Main.Backing.Content.ClaimScreen.ClaimButton.Button",
    progress = "StarRewardsApp.Static.Folder.Main.Backing.Content.MainScreen.GoalContainer.Content.GoalCount.Count",
    stars = "StarRewardsApp.Static.Folder.Main.Backing.Content.Header.CurrencyDisplay.Count",
}

local function find_path(root, path)
    local current = root
    for segment in string.gmatch(path, "[^%.]+") do
        if not current then return nil end
        current = current:FindFirstChild(segment)
    end
    return current
end

local function get_gui()
    return LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local function read_text(instance)
    if not instance then return nil end
    local ok, value = pcall(function() return instance.Text end)
    return ok and type(value) == "string" and value or nil
end

local function parse_number(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then return nil end
    return tonumber(value:match("%-?%d+%.?%d*"))
end

local function parse_progress(value)
    if type(value) ~= "string" then return nil, nil end
    local current, target = value:match("(%d+)%s*/%s*(%d+)")
    return tonumber(current), tonumber(target)
end

local function is_visible(instance)
    if not instance then return false end
    local ok, value = pcall(function() return instance.Visible end)
    return ok and value == true
end

local function scan()
    local gui = get_gui()
    if not gui then
        return {
            complete = false,
            reason = "PlayerGui unavailable",
        }
    end

    local app = find_path(gui, PATH.star_app)
    local claim = find_path(gui, PATH.claim)
    local progress_node = find_path(gui, PATH.progress)
    local stars_node = find_path(gui, PATH.stars)

    local progress_text = read_text(progress_node)
    local progress, target = parse_progress(progress_text)
    local stars = parse_number(read_text(stars_node))

    local claim_visible = is_visible(claim)
    local app_visible = is_visible(app)

    local reward_status
    if claim_visible then
        reward_status = "AVAILABLE"
    elseif app_visible and progress ~= nil and stars ~= nil then
        -- Absence of ClaimButton is not proof of an already-claimed reward.
        reward_status = "NOT_VISIBLE"
    else
        reward_status = "UNKNOWN"
    end

    local complete = type(stars) == "number"
        and type(progress) == "number"
        and type(target) == "number"

    return {
        complete = complete,
        reason = complete and nil or "Required Star Rewards values unavailable",
        username = LocalPlayer and LocalPlayer.Name or "unknown",
        stars = stars,
        daily_reward = {
            status = reward_status,
            claim_visible = claim_visible,
        },
        gemstone = {
            progress = progress,
            target = target,
        },
        progress_text = progress_text,
        app_visible = app_visible,
    }
end

local function same_values(a, b)
    if not a or not b then return false end
    return a.complete == b.complete
        and a.username == b.username
        and a.stars == b.stars
        and a.daily_reward.status == b.daily_reward.status
        and a.gemstone.progress == b.gemstone.progress
        and a.gemstone.target == b.gemstone.target
end

local function build_result(snapshot, verified)
    local result = {
        version = "1.0",
        username = snapshot.username or (LocalPlayer and LocalPlayer.Name or "unknown"),
        stars = snapshot.stars,
        daily_reward = snapshot.daily_reward,
        gemstone = snapshot.gemstone,
        last_sync = verified and os.time() or nil,
        verification_status = verified and "VERIFIED" or "UNAVAILABLE",
        scan_interval_seconds = CONFIG.ScanInterval,
        stable_samples = CONFIG.StableSamples,
        reason = snapshot.reason,
    }
    return result
end

local function value_or_unavailable(value)
    return value == nil and "unavailable" or tostring(value)
end

local function report_text(result)
    return table.concat({
        "TrackStat Result",
        "username=" .. value_or_unavailable(result.username),
        "verification_status=" .. value_or_unavailable(result.verification_status),
        "stars=" .. value_or_unavailable(result.stars),
        "daily_reward_status=" .. value_or_unavailable(result.daily_reward and result.daily_reward.status),
        "claim_visible=" .. value_or_unavailable(result.daily_reward and result.daily_reward.claim_visible),
        "gemstone_progress=" .. value_or_unavailable(result.gemstone and result.gemstone.progress),
        "gemstone_target=" .. value_or_unavailable(result.gemstone and result.gemstone.target),
        "last_sync=" .. value_or_unavailable(result.last_sync),
        "scan_interval_seconds=" .. tostring(result.scan_interval_seconds),
        "stable_samples=" .. tostring(result.stable_samples),
        "reason=" .. value_or_unavailable(result.reason),
    }, "\n") .. "\n"
end

local function print_result(result)
    print("[trackstat] ------------------------------")
    print("[trackstat] username: " .. value_or_unavailable(result.username))
    print("[trackstat] stars: " .. value_or_unavailable(result.stars))
    print("[trackstat] daily reward: " .. value_or_unavailable(result.daily_reward and result.daily_reward.status))
    print("[trackstat] gemstone: "
        .. value_or_unavailable(result.gemstone and result.gemstone.progress)
        .. "/"
        .. value_or_unavailable(result.gemstone and result.gemstone.target))
    print("[trackstat] last_sync: " .. value_or_unavailable(result.last_sync))
    print("[trackstat] status: " .. value_or_unavailable(result.verification_status))
    if result.reason then
        print("[trackstat] reason: " .. tostring(result.reason))
    end
    print("[trackstat] ------------------------------")
end

local function write_report(result)
    if type(writefile) ~= "function" then
        warn("[trackstat] writefile is unavailable; console output only")
        return false
    end

    local ok, err = pcall(function()
        writefile(CONFIG.ReportFile, report_text(result))
    end)
    if not ok then
        warn("[trackstat] report write failed: " .. tostring(err))
        return false
    end
    return true
end

local function stable_sample()
    local first = scan()
    if not first.complete then
        return first, false
    end

    for _ = 2, CONFIG.StableSamples do
        task.wait(CONFIG.StableInterval)
        local next_sample = scan()
        if not same_values(first, next_sample) then
            return next_sample, false
        end
    end

    return first, true
end

local last_report_key
local last_unavailable_at = 0

local function report_key(result)
    return table.concat({
        tostring(result.username),
        tostring(result.stars),
        tostring(result.daily_reward and result.daily_reward.status),
        tostring(result.gemstone and result.gemstone.progress),
        tostring(result.gemstone and result.gemstone.target),
        tostring(result.verification_status),
    }, "|")
end

print("[trackstat] started; scanning every " .. tostring(CONFIG.ScanInterval) .. " seconds")
print("[trackstat] read-only mode; no clicks, purchases, remotes, or hooks")

while true do
    local snapshot, verified = stable_sample()
    local result = build_result(snapshot, verified)
    local key = report_key(result)
    local now = os.clock()

    if verified and key ~= last_report_key then
        last_report_key = key
        write_report(result)
        print_result(result)
    elseif not verified and (now - last_unavailable_at) >= CONFIG.UnavailableHeartbeat then
        last_unavailable_at = now
        write_report(result)
        print_result(result)
    end

    task.wait(CONFIG.ScanInterval)
end
