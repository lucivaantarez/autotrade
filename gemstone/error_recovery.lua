-- Shared failure classification and bounded retry helper.
local Recovery = {}

Recovery.CODES = {
    TIMEOUT = "TIMEOUT",
    MISSING_DATA = "MISSING_DATA",
    MISSING_GUI = "MISSING_GUI",
    INTERACTION_FAILED = "INTERACTION_FAILED",
    STALE_STATE = "STALE_STATE",
    UNEXPECTED_STATE = "UNEXPECTED_STATE",
    ADAPTER_UNAVAILABLE = "ADAPTER_UNAVAILABLE",
    UNKNOWN = "UNKNOWN",
}

function Recovery.classify(message)
    local text = string.lower(tostring(message or ""))
    if text:find("timeout", 1, true) or text:find("timed out", 1, true) then
        return Recovery.CODES.TIMEOUT
    end
    if text:find("missing reward", 1, true) or text:find("reward data", 1, true)
        or text:find("required statistics", 1, true) then
        return Recovery.CODES.MISSING_DATA
    end
    if text:find("gui", 1, true) or text:find("screen", 1, true) then
        return Recovery.CODES.MISSING_GUI
    end
    if text:find("claim", 1, true) or text:find("interaction", 1, true)
        or text:find("retry limit", 1, true) then
        return Recovery.CODES.INTERACTION_FAILED
    end
    if text:find("stale", 1, true) then
        return Recovery.CODES.STALE_STATE
    end
    if text:find("unsupported", 1, true) or text:find("unexpected", 1, true) then
        return Recovery.CODES.UNEXPECTED_STATE
    end
    if text:find("adapter", 1, true) then
        return Recovery.CODES.ADAPTER_UNAVAILABLE
    end
    return Recovery.CODES.UNKNOWN
end

function Recovery.detail(message, code)
    return { code = code or Recovery.classify(message), message = tostring(message or "unknown error") }
end

function Recovery.retry(operation, max_attempts)
    max_attempts = max_attempts or 3
    local last_error
    for attempt = 1, max_attempts do
        local ok, result = pcall(operation, attempt)
        if ok and result ~= false and result ~= nil then
            return true, result, attempt
        end
        last_error = ok and "operation returned false" or result
    end
    return false, Recovery.detail(last_error), max_attempts
end

return Recovery
