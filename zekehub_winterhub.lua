-- ZekeHub Utility + WinterHub contract wrapper.
-- Paste your private key below in a LOCAL copy. Never commit the real key.

getgenv().scriptkey = getgenv().scriptkey or "" -- <-- PASTE YOUR ZEKEHUB KEY BETWEEN THESE QUOTES

getgenv().Utility = getgenv().Utility or {
    AutoPotion = {
        Enabled = false,
        UseAllOnAll = false,
        SelectedPets = {},
    },
    AutoNeon = {
        Enabled = false,
        MakeMega = false,
        SelectedPets = {},
    },
    AutoTrade = {
        Enabled = true,
        Debug = false,
        AutoAcceptTrades = true,
        AutoLeaveAfterTrades = false, -- WinterHub owns server hopping
        LeaveDelay = 5,
        Usernames = {},
        TradeMode = "all",
        Categories = { "pets", "toys", "food", "transport", "gifts", "stickers", "pet_accessories" },
        Items = {},
        ItemCounts = {},
        BlacklistedRarities = {},
        GlobalPetFilter = {
            Versions = {},
            Ages = {},
        },
        PetFilters = {
            -- dog = { regular = { 6 }, neon = {} },
        },
        Filters = {
            Kind = "ALL",
            Type = "ALL",
            Rarity = "ALL",
            Search = "",
        },
    },
    AutoOpen = {
        Enabled = false,
        Items = {},
        OpenDelay = 1,
    },
    Shop = {
        Enabled = false,
        Items = {},
        BuyQuantity = 1,
        BuyDelay = 1,
    },
    AccountManager = {
        Enabled = false, -- WinterHub owns account rotation
        Tool = "none",
        FarmSync = {
            Action = "completed",
            FromFolderId = "",
            ToFolderId = "",
            ChangeWithoutReplacement = false,
            ConfigId = nil,
            ApiKey = "",
        },
        FarmerV5 = {
            ApiKey = "",
            Action = "swap",
            Option = 1,
        },
    },
    Settings = {
        AutoShowUI = true,
        Theme = "Dark",
        ToggleKey = "RightShift",
        UIScale = "auto",
    },
    WinterHub = {
        Enabled = true,
        Heartbeat = 5,
        Poll = 0.4,
        IdleHopSeconds = 12,
        ForceSettings = {
            Enabled = true,
            TradeRequests = true,
            GiveItemRequests = true,
        },
        Webhook = {
            Enabled = true,
            Url = "", -- keep empty in GitHub; pass WINTERHUB_WEBHOOK_URL at runtime
        },
        Debug = false,
    },
}

if getgenv().scriptkey == "" then
    error("Paste your ZekeHub key into getgenv().scriptkey before running this script")
end

local utility = (getgenv and getgenv().Utility) or {}
local CONFIG = utility.WinterHub or {
    Enabled = true,
    Heartbeat = 5,
    Poll = 0.4,
    IdleHopSeconds = 12,
    ForceSettings = {
        Enabled = true,
        TradeRequests = true,
        GiveItemRequests = true,
    },
    Debug = false,
}
local ZEKEHUB_URL = "https://zekehub.com/scripts/AdoptMe/Utility.lua"

if not CONFIG.Enabled then
    return loadstring(game:HttpGet(ZEKEHUB_URL))()
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local status_file = LocalPlayer.Name .. "_winteraddons.json"
local guard_key = "__zekehub_winterhub_" .. tostring(LocalPlayer.UserId)

if getgenv and getgenv()[guard_key] then
    warn("[zekehub/winterhub] wrapper already running")
    return
end
if getgenv then getgenv()[guard_key] = true end

local function log(...)
    if CONFIG.Debug then print("[zekehub/winterhub]", ...) end
end

local trade_count = 0
local last_items = {}
local last_activity = os.clock()
local in_trade = false
local last_write = -CONFIG.Heartbeat
local request = (syn and syn.request) or (http and http.request) or http_request or request
local webhook_url = (getgenv and getgenv().WINTERHUB_WEBHOOK_URL) or (CONFIG.Webhook and CONFIG.Webhook.Url) or ""

local Fsys = require(game.ReplicatedStorage:WaitForChild("Fsys"))
local UIManager, KindDB
local function game_module(name)
    local ok, value = pcall(function() return Fsys.load(name) end)
    return ok and value or nil
end

local function trade_app()
    if not UIManager then UIManager = game_module("UIManager") end
    return UIManager and UIManager.apps and UIManager.apps.TradeApp or nil
end

local function force_everyone(setting_id)
    local helper = game_module("SettingsHelper")
    local ok, database = pcall(function() return require(game.ReplicatedStorage.ClientDB.SettingsDB) end)
    local definition = ok and database and database.by_id[setting_id]
    local choices = definition and definition.element_options and definition.element_options.choices
    local everyone = choices and table.find(choices, "Everyone")
    if not helper or not everyone then return false end
    return pcall(function() helper.set_setting_client({ setting_id = setting_id, value = everyone }) end)
end

task.spawn(function()
    local settings = CONFIG.ForceSettings or {}
    if not settings.Enabled then return end
    for _ = 1, 30 do
        local trade_ok = not settings.TradeRequests or force_everyone("trade_requests")
        local give_ok = not settings.GiveItemRequests or force_everyone("give_item_requests")
        if trade_ok and give_ok then log("trade settings forced to Everyone") return end
        task.wait(1)
    end
    warn("[zekehub/winterhub] could not force trade settings after 30 seconds")
end)

local function summarize(items)
    if not KindDB then KindDB = game_module("KindDB") end
    local counts, order = {}, {}
    for _, item in ipairs(items or {}) do
        local definition = KindDB and KindDB[item.kind]
        local name = (definition and definition.name) or tostring(item.kind)
        if not counts[name] then order[#order + 1] = name end
        counts[name] = (counts[name] or 0) + 1
    end
    local result = {}
    for _, name in ipairs(order) do result[#result + 1] = { name = name, qty = counts[name] } end
    return result
end

local function send_trade_webhook(items)
    if not request or webhook_url == "" or (CONFIG.Webhook and CONFIG.Webhook.Enabled == false) then return end
    local lines = {}
    for _, item in ipairs(items) do lines[#lines + 1] = string.format("%dx %s", item.qty, item.name) end
    local body = HttpService:JSONEncode({
        username = "ZekeHub WinterHub",
        embeds = {{
            title = "Trade complete",
            description = #lines > 0 and table.concat(lines, "\n") or "No received items",
            color = 5763719,
            footer = { text = LocalPlayer.Name },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }},
    })
    local ok, response = pcall(function()
        return request({ Url = webhook_url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
    end)
    log("webhook", ok and response and (response.StatusCode or response.Status) or response)
end

local function write_status()
    if os.clock() - last_write < CONFIG.Heartbeat then return end
    last_write = os.clock()
    local status = "active"
    if not in_trade and os.clock() - last_activity > CONFIG.IdleHopSeconds then
        status = "completed"
    end
    writefile(status_file, HttpService:JSONEncode({
        status = status,
        ts = os.time(),
        count = trade_count,
        items = last_items,
    }))
    log("status", status, "count", trade_count)
end

task.spawn(function()
    local was_open = false
    local completed, received = false, nil

    while true do
        pcall(function()
            local app = trade_app()
            local state = app and app:_get_local_trade_state() or nil

            if state then
                in_trade = true
                was_open = true
                last_activity = os.clock()

                if state.current_stage == "confirmation" then
                    local mine = app:_get_my_offer()
                    local partner = app:_get_partner_offer()
                    if mine and partner and mine.confirmed and partner.confirmed then
                        completed = true
                        received = partner.items
                    end
                end
            elseif was_open then
                in_trade = false
                was_open = false
                last_activity = os.clock()
                if completed then
                    trade_count = trade_count + 1
                    last_items = summarize(received)
                    send_trade_webhook(last_items)
                    log("trade completed", trade_count)
                end
                completed, received = false, nil
            else
                in_trade = false
            end

            write_status()
        end)
        task.wait(CONFIG.Poll)
    end
end)

local loader = loadstring(game:HttpGet(ZEKEHUB_URL))
if not loader then error("ZekeHub Utility failed to compile") end
return loader()
