-- Gemstone workflow data model and small parsing helpers.
-- This module is game-agnostic: live integrations must provide adapters.

local Model = {}

Model.STATES = {
    BOOTING = "BOOTING",
    WAITING_FOR_GAME = "WAITING_FOR_GAME",
    INITIALIZING_LOCATION = "INITIALIZING_LOCATION",
    ONBOARDING = "ONBOARDING",
    IN_GAME = "IN_GAME",
    REWARD_CHECK = "REWARD_CHECK",
    CLAIMING = "CLAIMING",
    VERIFYING_CLAIM = "VERIFYING_CLAIM",
    READING_STATS = "READING_STATS",
    CHECKING_EGG = "CHECKING_EGG",
    SAVING_RESULT = "SAVING_RESULT",
    READY_TO_SWAP = "READY_TO_SWAP",
    COMPLETED = "COMPLETED",
    FAILED = "FAILED",
}

Model.STATUS = {
    VERIFIED = "VERIFIED",
    UNAVAILABLE = "UNAVAILABLE",
    UNKNOWN = "UNKNOWN",
    BLOCKED = "BLOCKED",
    FAILED = "FAILED",
}

function Model.number(value)
    if type(value) == "number" and value == value then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    local n = tonumber(value:match("%-?%d+%.?%d*"))
    return n
end

function Model.progress(value)
    if type(value) == "table" then
        local current = Model.number(value.current)
        local target = Model.number(value.target)
        if current and target then return current, target end
    end
    if type(value) ~= "string" then return nil, nil end
    local current, target = value:match("(%d+)%s*/%s*(%d+)")
    return tonumber(current), tonumber(target)
end

function Model.value(value, source)
    if value == nil then
        return { value = nil, status = Model.STATUS.UNAVAILABLE, source = source }
    end
    return { value = value, status = Model.STATUS.VERIFIED, source = source }
end

return Model
