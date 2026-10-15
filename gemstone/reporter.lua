-- Deterministic TrackStat report writer.
local Reporter = {}

local function encode(json, value)
    if type(json) ~= "function" then error("json encoder required") end
    return json(value)
end

local function text(result)
    local lines = {
        "Gemstone Result",
        "version=" .. tostring(result.version or "1.0"),
        "username=" .. tostring(result.username or "unknown"),
        "status=" .. tostring(result.status or "UNKNOWN"),
        "startup_state=" .. tostring(result.startup_state or "UNKNOWN"),
        "claim_status=" .. tostring(result.daily_claim and result.daily_claim.status or "UNKNOWN"),
        "claim_verified=" .. tostring(result.daily_claim and result.daily_claim.verified or false),
        "stars=" .. tostring(result.stars or "unavailable"),
        "gemstone_progress=" .. tostring(result.gemstone and result.gemstone.progress or "unavailable"),
        "gemstone_target=" .. tostring(result.gemstone and result.gemstone.target or "unavailable"),
        "gemstone_price=" .. tostring(result.gemstone and result.gemstone.price or "unavailable"),
        "duration_seconds=" .. tostring(result.duration_seconds or "unavailable"),
        "verification_status=" .. tostring(result.verification_status or "UNKNOWN"),
        "error=" .. tostring(result.error or "none"),
    }
    return table.concat(lines, "\n") .. "\n"
end

function Reporter.write(fs, json, result)
    if not fs or type(fs.write) ~= "function" then
        return false, "file adapter unavailable"
    end
    local ok, err = pcall(function()
        fs.write("gemstone_result.txt", text(result))
        fs.write("gemstone_result.json", encode(json, result))
    end)
    return ok, ok and nil or tostring(err)
end

Reporter.text = text
return Reporter
