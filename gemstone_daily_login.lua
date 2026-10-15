-- Gemstone Daily Login Assistant
-- Standalone, evidence-driven adapter.
--
-- This release intentionally performs read-only GUI inspection only.
-- It does not invoke undocumented remotes, simulated input, executor hooks,
-- or account rotation. Unsupported actions are reported as BLOCKED.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    ReportText = "gemstone_result.txt",
    ReportJson = "gemstone_result.json",
    SwapSuffix = "_winterswap.json",
    SwapGroup = "finished",
    PollLimit = 120,
    PollStep = 0.25,
    ManualAssistPolls = 360, -- bounded 90-second manual onboarding window
    EnableLiveActions = false, -- remains false until separately verified
}

local STATE = {
    BOOTING = "BOOTING",
    WAITING_FOR_GAME = "WAITING_FOR_GAME",
    ONBOARDING = "ONBOARDING",
    IN_GAME = "IN_GAME",
    REWARD_CHECK = "REWARD_CHECK",
    CLAIMING = "CLAIMING",
    VERIFYING_CLAIM = "VERIFYING_CLAIM",
    READING_STATS = "READING_STATS",
    SAVING_RESULT = "SAVING_RESULT",
    READY_TO_SWAP = "READY_TO_SWAP",
    COMPLETED = "COMPLETED",
    FAILED = "FAILED",
}

local function find_path(root, path)
    local current = root
    for segment in string.gmatch(path, "[^%.]+") do
        if not current then return nil end
        current = current:FindFirstChild(segment)
    end
    return current
end

local function visible(instance)
    if not instance then return false end
    local ok, value = pcall(function() return instance.Visible end)
    return ok and value == true
end

local function text(instance)
    if not instance then return nil end
    local ok, value = pcall(function() return instance.Text end)
    return ok and type(value) == "string" and value or nil
end

local function property(instance, name)
    if not instance then return nil end
    local ok, value = pcall(function() return instance[name] end)
    return ok and value or nil
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then return nil end
    return tonumber(value:match("%-?%d+%.?%d*"))
end

local function progress(value)
    if type(value) ~= "string" then return nil, nil end
    local current, target = value:match("(%d+)%s*/%s*(%d+)")
    return tonumber(current), tonumber(target)
end

local function gui()
    return LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
end

local PATH = {
    play = "NewsApp.EnclosingFrame.MainFrame.Buttons.PlayButton",
    alternate_play = "ExperimentalNewsApp.EnclosingFrame.MainFrame.Contents.PlayButton",
    home = "DialogApp.Dialog.SpawnChooserDialog.UpperCardContainer.ChoicesContent.Choices.Home.Button",
    color = "DialogApp.Dialog.ThemeColorDialog",
    navigator = "NavigatorApp.Frame.Buttons.Extras.StarRewards",
    star_app = "StarRewardsApp",
    claim = "StarRewardsApp.Static.Folder.Main.Backing.Content.ClaimScreen.ClaimButton.Button",
    progress = "StarRewardsApp.Static.Folder.Main.Backing.Content.MainScreen.GoalContainer.Content.GoalCount.Count",
    stars = "StarRewardsApp.Static.Folder.Main.Backing.Content.Header.CurrencyDisplay.Count",
    price = "StarRewardsApp.Static.Folder.Main.Backing.Content.ShopScreen.Grid.Scroller.star_egg.PriceTag.Price",
}

local function read_gui_state()
    local root = gui()
    if not root then return { status = "UNAVAILABLE", reason = "PlayerGui unavailable" } end
    local play = find_path(root, PATH.play) or find_path(root, PATH.alternate_play)
    local home = find_path(root, PATH.home)
    local color = find_path(root, PATH.color)
    local star_app = find_path(root, PATH.star_app)
    local claim = find_path(root, PATH.claim)
    local navigator = find_path(root, PATH.navigator)

    local ptext = text(find_path(root, PATH.progress))
    local current, target = progress(ptext)
    local stars = number(text(find_path(root, PATH.stars)))
    local price = number(text(find_path(root, PATH.price)))

    local phase = "none"
    if visible(play) then phase = "play"
    elseif visible(home) then phase = "home"
    elseif visible(color) then phase = "favorite_color"
    elseif visible(navigator) and not visible(play) then phase = "none"
    end

    return {
        status = "VERIFIED",
        phase = phase,
        in_game = visible(navigator) and not visible(play),
        play_button = {
            present = play ~= nil,
            visible = visible(play),
            active = property(play, "Active"),
            interactable = property(play, "Interactable"),
            class_name = property(play, "ClassName"),
        },
        star_app_visible = visible(star_app),
        claim_visible = visible(claim),
        claim_eligible = visible(claim) and true or nil,
        stars = stars,
        gemstone_progress = current,
        gemstone_target = target,
        gemstone_price = price,
        progress_text = ptext,
        observed_at = os.time(),
    }
end

local function error_info(code, message)
    return { code = code, message = message }
end

local function write_report(result)
    local ok, encoded = pcall(function() return HttpService:JSONEncode(result) end)
    if not ok then return false, "JSON encoding failed: " .. tostring(encoded) end
    if type(writefile) ~= "function" then return false, "writefile unavailable" end
    local wrote, err = pcall(function()
        writefile(CONFIG.ReportText, table.concat({
            "Gemstone Result",
            "username=" .. tostring(result.username),
            "status=" .. tostring(result.status),
            "startup_state=" .. tostring(result.startup_state),
            "play_present=" .. tostring(result.play_button and result.play_button.present or "unavailable"),
            "play_visible=" .. tostring(result.play_button and result.play_button.visible or "unavailable"),
            "play_active=" .. tostring(result.play_button and result.play_button.active or "unavailable"),
            "play_interactable=" .. tostring(result.play_button and result.play_button.interactable or "unavailable"),
            "claim_status=" .. tostring(result.daily_claim.status),
            "claim_verified=" .. tostring(result.daily_claim.verified),
            "stars=" .. tostring(result.stars or "unavailable"),
            "gemstone_progress=" .. tostring(result.gemstone.progress or "unavailable"),
            "gemstone_target=" .. tostring(result.gemstone.target or "unavailable"),
            "gemstone_price=" .. tostring(result.gemstone.price or "unavailable"),
            "timestamp=" .. tostring(result.timestamp or "unavailable"),
            "verification_status=" .. tostring(result.verification_status),
            "error_code=" .. tostring(result.error_info and result.error_info.code or "NONE"),
            "error=" .. tostring(result.error or "none"),
        }, "\n") .. "\n")
        writefile(CONFIG.ReportJson, encoded)
    end)
    return wrote, wrote and nil or tostring(err)
end

local function swap_signal(result)
    if result.status ~= "COMPLETED" or result.verification_status ~= "VERIFIED"
        or result.daily_claim.verified ~= true or result.statistics_saved ~= true then
        return false, "result not eligible"
    end
    if type(writefile) ~= "function" then return false, "writefile unavailable" end
    local filename = tostring(LocalPlayer.Name) .. CONFIG.SwapSuffix
    local payload = HttpService:JSONEncode({ group = CONFIG.SwapGroup, ts = os.time() })
    local ok, err = pcall(function() writefile(filename, payload) end)
    return ok, ok and nil or tostring(err)
end

local function blocked_action(name)
    return false, error_info("BLOCKED", name .. " is not implemented from verified evidence")
end

local function main()
    local started = os.clock()
    local result = {
        version = "1.0",
        username = LocalPlayer and LocalPlayer.Name or "unknown",
        status = "FAILED",
        game_ready = false,
        startup_state = STATE.BOOTING,
        daily_claim = { status = "UNKNOWN", attempted = false, verified = false },
        gemstone = { purchased = false },
        verification_status = "BLOCKED",
        swap = { eligible = false, signal_written = false },
    }

    local state = STATE.WAITING_FOR_GAME
    local snapshot
    local manual_remaining = CONFIG.ManualAssistPolls
    local last_manual_action
    for _ = 1, CONFIG.PollLimit + CONFIG.ManualAssistPolls do
        snapshot = read_gui_state()
        if snapshot.status == "VERIFIED" then
            if snapshot.in_game then
                state = STATE.IN_GAME
                break
            end
            state = STATE.ONBOARDING
            local action = snapshot.phase == "play" and "Play activation"
                or snapshot.phase == "home" and "Home selection"
                or snapshot.phase == "favorite_color" and "Favorite Color handling"
                or "Onboarding completion"
            result.startup_state = state
            result.play_button = snapshot.play_button
            result.error = action .. " requires manual confirmation; automatic activation is disabled"
            result.error_info = error_info("BLOCKED", result.error)
            if action ~= last_manual_action then
                warn("[gemstone] " .. result.error)
                last_manual_action = action
            end
            manual_remaining = manual_remaining - 1
            if manual_remaining <= 0 then break end
        end
        task.wait(CONFIG.PollStep)
    end

    if state ~= STATE.IN_GAME then
        result.startup_state = state
        result.duration_seconds = os.clock() - started
        local saved, save_error = write_report(result)
        result.statistics_saved = saved == true
        if not saved then result.error = save_error end
        return result
    end

    result.game_ready = true
    result.startup_state = STATE.IN_GAME
    result.status = "FAILED"
    result.verification_status = "BLOCKED"
    result.daily_claim.status = "UNKNOWN"
    result.error = "Live claim action is not verified; no claim attempted"
    result.error_info = error_info("BLOCKED", result.error)
    result.stars = snapshot.stars
    result.timestamp = snapshot.observed_at
    result.gemstone.progress = snapshot.gemstone_progress
    result.gemstone.target = snapshot.gemstone_target
    result.gemstone.price = snapshot.gemstone_price
    result.gemstone.affordable = snapshot.stars and snapshot.gemstone_price
        and snapshot.stars >= snapshot.gemstone_price or nil
    result.duration_seconds = os.clock() - started

    local saved, save_error = write_report(result)
    result.statistics_saved = saved == true
    if not saved then
        result.error = save_error
        result.error_info = error_info("REPORT_WRITE_FAILED", save_error)
    end
    return result
end

return main()
