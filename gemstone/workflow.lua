-- Orchestrates the safe, adapter-driven daily-login workflow.
local Model = require(script.Parent.model)
local Startup = require(script.Parent.startup_controller)
local Inspector = require(script.Parent.reward_inspector)
local Claim = require(script.Parent.claim_verifier)
local Reporter = require(script.Parent.reporter)
local Swap = require(script.Parent.winterhub_adapter)
local Recovery = require(script.Parent.error_recovery)

local Workflow = {}

function Workflow.run(adapter, deps, options)
    options = options or {}
    local started = (options.clock and options.clock()) or os.clock()
    local startup = Startup.new(adapter, options.startup)
    local startup_state = startup:run(options.max_startup_steps or 200)
    local result = {
        version = "1.0",
        username = options.username,
        status = startup_state == Model.STATES.IN_GAME and "RUNNING" or "FAILED",
        game_ready = startup_state == Model.STATES.IN_GAME,
        startup_state = startup_state,
        daily_claim = { status = "UNKNOWN", attempted = false, verified = false },
        gemstone = {},
        verification_status = startup_state == Model.STATES.IN_GAME and "PENDING" or "BLOCKED",
        error = startup.error,
    }
    local function set_error(message, code)
        result.error = message
        result.error_info = Recovery.detail(message, code)
    end
    if startup.error then set_error(startup.error) end

    if not result.game_ready then
        result.status = "FAILED"
        result.duration_seconds = ((options.clock and options.clock()) or os.clock()) - started
        Reporter.write(deps and deps.fs, deps and deps.json_encode, result)
        return result
    end

    local before = Inspector.read(adapter)
    if before.status ~= Model.STATUS.VERIFIED then
        result.status = "FAILED"
        result.daily_claim.status = "UNKNOWN"
        set_error(before.error or "reward state unavailable")
    else
        local claim = Claim.claim_once(adapter)
        result.daily_claim = claim
        local after = Inspector.read(adapter)
        result.username = result.username or (after.username and after.username.value) or (before.username and before.username.value)
        result.daily_streak = after.daily_streak and after.daily_streak.value or (before.daily_streak and before.daily_streak.value)
        result.timestamp = after.observed_at and after.observed_at.value or (before.observed_at and before.observed_at.value)
        result.stars = after.stars and after.stars.value or before.stars.value
        result.gemstone = {
            progress = after.gemstone_progress and after.gemstone_progress.value or nil,
            target = after.gemstone_target and after.gemstone_target.value or nil,
            price = after.gemstone_price and after.gemstone_price.value or nil,
            remaining = after.remaining_stars and after.remaining_stars.value or nil,
            affordable = after.stars and after.gemstone_price and after.stars.value >= after.gemstone_price.value or nil,
            purchased = false,
        }
        local stats_complete = result.stars ~= nil
            and result.gemstone.progress ~= nil
            and result.gemstone.target ~= nil
            and result.gemstone.price ~= nil
        result.status = claim.verified and stats_complete and "COMPLETED" or "FAILED"
        result.verification_status = claim.verified and stats_complete and "VERIFIED" or (claim.verified and "BLOCKED" or claim.status)
        result.error = claim.verified and stats_complete and nil or (claim.verified and "required statistics unavailable" or claim.reason)
        if result.error then set_error(result.error) end
    end

    result.duration_seconds = ((options.clock and options.clock()) or os.clock()) - started
    local saved, save_error = Reporter.write(deps and deps.fs, deps and deps.json_encode, result)
    result.statistics_saved = saved == true
    if not saved then
        result.status = "FAILED"
        result.verification_status = "BLOCKED"
        result.error = save_error or result.error or "report write failed"
        set_error(result.error)
    end
    if Swap.eligible(result) then
        local ok, err = Swap.write(deps.fs, deps.json_encode, options.username, result, options.group)
        result.swap = { eligible = true, signal_written = ok == true, error = err }
    else
        result.swap = { eligible = false, signal_written = false }
    end
    return result
end

return Workflow
