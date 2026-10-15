-- Adapter-driven startup controller.
-- No GUI paths, remotes, or executor functions are hardcoded here.

local Model = require(script.Parent.model)
local Controller = {}
Controller.__index = Controller

local function now_or(clock)
    return clock and clock() or os.clock()
end

function Controller.new(adapter, options)
    options = options or {}
    return setmetatable({
        adapter = adapter,
        state = Model.STATES.BOOTING,
        entered_at = nil,
        attempts = 0,
        max_attempts = options.max_attempts or 3,
        timeout = options.timeout or 45,
        clock = options.clock,
        error = nil,
        history = {},
    }, Controller)
end

function Controller:_transition(next_state, reason, now)
    self.state = next_state
    self.entered_at = now
    self.attempts = 0
    table.insert(self.history, { state = next_state, reason = reason, at = now })
end

function Controller:_failed(message, now)
    self.error = message
    self:_transition(Model.STATES.FAILED, message, now)
end

function Controller:_timed_out(now)
    return self.entered_at and now - self.entered_at >= self.timeout
end

function Controller:_try(action, now)
    if self.attempts >= self.max_attempts then
        self:_failed("retry limit exceeded", now)
        return false
    end
    self.attempts = self.attempts + 1
    local ok, result = pcall(action)
    if not ok or result == false then return false end
    return true
end

function Controller:step()
    local now = now_or(self.clock)
    if not self.entered_at then self.entered_at = now end
    if self.state == Model.STATES.COMPLETED or self.state == Model.STATES.FAILED then
        return self.state
    end
    if self:_timed_out(now) then
        self:_failed("state timeout: " .. self.state, now)
        return self.state
    end

    local adapter = self.adapter
    if self.state == Model.STATES.BOOTING then
        if not adapter or type(adapter.is_available) ~= "function" then
            self:_failed("startup adapter unavailable", now)
        else
            self:_transition(Model.STATES.WAITING_FOR_GAME, "adapter available", now)
        end
    elseif self.state == Model.STATES.WAITING_FOR_GAME then
        if adapter.is_game_ready() then
            self:_transition(Model.STATES.INITIALIZING_LOCATION, "game ready", now)
        end
    elseif self.state == Model.STATES.INITIALIZING_LOCATION then
        if adapter.is_in_game() then
            self:_transition(Model.STATES.IN_GAME, "already in game", now)
        elseif self:_try(function() return adapter.initialize_location() end, now) then
            if adapter.is_in_game() then
                self:_transition(Model.STATES.IN_GAME, "location verified", now)
            else
                self:_transition(Model.STATES.ONBOARDING, "location requires onboarding", now)
            end
        end
    elseif self.state == Model.STATES.ONBOARDING then
        local screen = adapter.get_onboarding_screen()
        if screen == "play" then
            self:_try(function() return adapter.handle_play() end, now)
        elseif screen == "home" then
            self:_try(function() return adapter.handle_home() end, now)
        elseif screen == "favorite_color" then
            self:_try(function() return adapter.handle_favorite_color() end, now)
        elseif screen == "none" or screen == nil then
            if adapter.is_in_game() then
                self:_transition(Model.STATES.IN_GAME, "onboarding verified", now)
            end
        else
            self:_failed("unsupported onboarding screen: " .. tostring(screen), now)
        end
    elseif self.state == Model.STATES.IN_GAME then
        self:_transition(Model.STATES.REWARD_CHECK, "in-game verified", now)
    end
    return self.state
end

function Controller:run(max_steps)
    max_steps = max_steps or 200
    for _ = 1, max_steps do
        local state = self:step()
        if state == Model.STATES.IN_GAME or state == Model.STATES.FAILED then
            return state
        end
    end
    self:_failed("step limit exceeded", now_or(self.clock))
    return self.state
end

return Controller
