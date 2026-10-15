-- Read-only reward/statistics inspector.
local Model = require(script.Parent.model)
local Reader = {}

local function field(value, source)
    return Model.value(value, source)
end

function Reader.read(adapter)
    if not adapter or type(adapter.read_reward_state) ~= "function" then
        return { status = Model.STATUS.BLOCKED, error = "reward adapter unavailable" }
    end
    local ok, raw = pcall(adapter.read_reward_state)
    if not ok or type(raw) ~= "table" then
        return { status = Model.STATUS.UNAVAILABLE, error = ok and "reward data unavailable" or tostring(raw) }
    end

    local progress, target = Model.progress(raw.gemstone_progress or raw.progress)
    local price = Model.number(raw.gemstone_price or raw.price)
    local stars = Model.number(raw.stars)
    local remaining = stars and price and price - stars or nil
    if remaining and remaining < 0 then remaining = 0 end

    local result = {
        status = Model.STATUS.VERIFIED,
        username = field(raw.username, "adapter"),
        daily_streak = field(Model.number(raw.daily_streak), "adapter"),
        claim_eligible = field(raw.claim_eligible, "adapter"),
        stars = field(stars, "adapter"),
        gemstone_progress = field(progress, "adapter"),
        gemstone_target = field(target, "adapter"),
        gemstone_price = field(price, "adapter"),
        remaining_stars = field(remaining, "derived"),
        raw = raw,
    }
    if progress == nil and target == nil then
        result.gemstone_progress_status = Model.STATUS.UNAVAILABLE
    else
        result.gemstone_progress_status = Model.STATUS.VERIFIED
    end
    return result
end

return Reader
