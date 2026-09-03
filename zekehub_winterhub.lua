-- WinterHub contract wrapper for ZekeHub Utility.
-- Set getgenv().Utility and getgenv().scriptkey before loading this file.

local CONFIG = {
    heartbeat = 5,
    poll = 0.4,
    idle_hop_seconds = 12,
    zekehub_url = "https://zekehub.com/scripts/AdoptMe/Utility.lua",
    debug = false,
}

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
    if CONFIG.debug then print("[zekehub/winterhub]", ...) end
end

local trade_count = 0
local last_items = {}
local last_activity = os.clock()
local in_trade = false
local last_write = -CONFIG.heartbeat

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

local function write_status()
    if os.clock() - last_write < CONFIG.heartbeat then return end
    last_write = os.clock()
    local status = "active"
    if not in_trade and os.clock() - last_activity > CONFIG.idle_hop_seconds then
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
                    log("trade completed", trade_count)
                end
                completed, received = false, nil
            else
                in_trade = false
            end

            write_status()
        end)
        task.wait(CONFIG.poll)
    end
end)

local loader = loadstring(game:HttpGet(CONFIG.zekehub_url))
if not loader then error("ZekeHub Utility failed to compile") end
return loader()
