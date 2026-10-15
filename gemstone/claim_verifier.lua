-- Claim verification compares read-only state before and after an authorized adapter action.
local Model = require(script.Parent.model)
local Verifier = {}

function Verifier.capture(adapter)
    local ok, value = pcall(adapter.read_reward_state)
    if not ok or type(value) ~= "table" then return nil, tostring(value) end
    return value
end

function Verifier.verify(before, after)
    if type(before) ~= "table" or type(after) ~= "table" then
        return { status = Model.STATUS.UNKNOWN, verified = false, reason = "missing before/after state" }
    end
    local b_progress = Model.progress(before.gemstone_progress or before.progress)
    local a_progress = Model.progress(after.gemstone_progress or after.progress)
    local eligibility_changed = before.claim_eligible == true and after.claim_eligible == false
    local progress_increased = b_progress and a_progress and a_progress > b_progress
    local stars_increased = Model.number(after.stars) and Model.number(before.stars)
        and Model.number(after.stars) > Model.number(before.stars)
    if progress_increased or eligibility_changed or stars_increased then
        return { status = Model.STATUS.VERIFIED, verified = true, reason = "post-claim state changed" }
    end
    return { status = Model.STATUS.FAILED, verified = false, reason = "no authoritative state change" }
end

function Verifier.claim_once(adapter)
    if type(adapter.claim_reward) ~= "function" then
        return { attempted = false, verified = false, status = Model.STATUS.BLOCKED, reason = "claim adapter unavailable" }
    end
    local before, before_error = Verifier.capture(adapter)
    if not before then
        return { attempted = false, verified = false, status = Model.STATUS.UNKNOWN, reason = before_error }
    end
    if before.claim_eligible == false then
        return { attempted = false, verified = true, status = Model.STATUS.VERIFIED, reason = "already claimed" }
    end
    local ok, action_result = pcall(adapter.claim_reward)
    if not ok or action_result == false then
        return { attempted = true, verified = false, status = Model.STATUS.FAILED, reason = tostring(action_result) }
    end
    local after, after_error = Verifier.capture(adapter)
    local result = Verifier.verify(before, after)
    result.attempted = true
    if not after then result.reason = after_error end
    return result
end

return Verifier
