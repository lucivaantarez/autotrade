-- WinterHub swap adapter. It only signals verified terminal results.
local Adapter = {}

function Adapter.eligible(result)
    return type(result) == "table"
        and result.status == "COMPLETED"
        and result.game_ready == true
        and result.daily_claim ~= nil
        and result.daily_claim.status ~= "UNKNOWN"
        and result.daily_claim.verified == true
        and result.statistics_saved == true
        and result.verification_status == "VERIFIED"
end

function Adapter.write(fs, json, username, result, group)
    if not Adapter.eligible(result) then
        return false, "result is not eligible for swap"
    end
    if not fs or type(fs.write) ~= "function" then
        return false, "file adapter unavailable"
    end
    if type(json) ~= "function" then
        return false, "json encoder unavailable"
    end
    local payload = { group = group, ts = os.time() }
    local ok, err = pcall(function()
        fs.write(tostring(username) .. "_winterswap.json", json(payload))
    end)
    return ok, ok and nil or tostring(err)
end

return Adapter
