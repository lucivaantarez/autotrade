--[[=====================================================================
    adm_tradeapp_recorder.lua  -  TradeApp diagnostic recorder (for Delta)

    PURPOSE
      Answer one open question: how does Adopt Me actually cancel/decline a
      trade? This recorder WATCHES. The only game calls it makes are three
      read-only state getters; it presses nothing and changes nothing.

    WHAT IT DOES
      - Takes a snapshot of the TradeApp environment while you are idle.
      - Keeps running across as many trades as you want (one execution).
      - Records every phase change: IDLE / INVITATION / NEGOTIATION /
        CONFIRMATION / CLOSED.
      - Records offer COUNTS and confirmed flags (never item identities).
      - Records which trade buttons exist and how many handlers they have.
      - Writes everything to local files on the device running Delta.

    WHAT IT NEVER DOES
      - No Accept. No Decline. No Confirm. No clicking. No firesignal.
      - No remote FireServer/InvokeServer. No __namecall / metamethod hooks.
      - No webhooks, no network, no account names, no tokens, no item UIDs.
      - The ONLY game methods it calls are the read-only getters
        _get_local_trade_state / _get_my_offer / _get_partner_offer. Every
        other method it discovers is listed by name and never invoked.
      - Run this with the AutoTrade script STOPPED, or the button presses
        you see in the log will be AutoTrade's, not yours.

    HOW TO USE
      1. Join Adopt Me, then execute this script ONCE.
      2. Wait for the "READY" message in the Delta console.
      3. Do your three manual tests (decline an invite, decline during
         negotiation, decline during confirmation).
      4. Stop it:   getgenv().ADM_RECORDER_STOP()
      5. Send back the files in the adm_tradeapp_diagnostics folder.

    Only the CONFIG block below is meant to be edited.
=======================================================================]]

local CONFIG = {
    -- Folder created in the Delta workspace for all output.
    OUT_DIR = "adm_tradeapp_diagnostics",

    -- How often the recorder samples trade state, in seconds.
    POLL = 0.25,

    -- Safety caps so the logs can never grow without bound.
    MAX_EVENTS       = 4000,   -- total appended event lines
    MAX_TRANSITIONS  = 1000,   -- total appended phase transitions
    MAX_SNAPSHOTS    = 8,      -- static snapshots kept per static file
    MAX_GUI_NODES    = 1200,   -- GUI nodes visited per hierarchy snapshot
    MAX_GUI_DEPTH    = 8,      -- GUI traversal depth
    MAX_METHOD_KEYS  = 400,    -- method names listed per table
    MAX_META_DEPTH   = 6,      -- metatable chain depth

    -- Stop automatically after this many seconds (safety net).
    MAX_RUNTIME = 5400,

    -- Print progress lines in the Delta console.
    VERBOSE = true,
}

--[[=====================================================================
    (Nothing below needs editing.)
=======================================================================]]

local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function say(...)
    print("[tradeapp-recorder]", ...)
end
local function log(...)
    if CONFIG.VERBOSE then say(...) end
end

-- SINGLETON: a second execution must not double-write the same files.
local GUARD = "__adm_tradeapp_recorder"
if getgenv then
    if getgenv()[GUARD] then
        say("already running - use getgenv().ADM_RECORDER_STOP() first")
        return
    end
    getgenv()[GUARD] = true
end

local function release_guard()
    if getgenv then getgenv()[GUARD] = nil end
end

--[[--------------------------------------------------------------------
    Filesystem helpers. Every call is guarded; a missing executor API is
    reported, never fatal.
--------------------------------------------------------------------]]
local FS = {
    writefile  = writefile,
    appendfile = appendfile,
    readfile   = readfile,
    isfile     = isfile,
    makefolder = makefolder,
    isfolder   = isfolder,
}

local HttpService = game:GetService("HttpService")
local function encode(value)
    local ok, text = pcall(function() return HttpService:JSONEncode(value) end)
    if ok then return text end
    return nil, tostring(text)
end

local fs_available = type(FS.writefile) == "function"
local dir_ready = false

local function ensure_dir()
    if dir_ready or not fs_available then return dir_ready end
    if type(FS.makefolder) ~= "function" then
        -- Some executors write nested paths without an explicit folder.
        dir_ready = true
        return true
    end
    local ok = pcall(function()
        if type(FS.isfolder) == "function" and FS.isfolder(CONFIG.OUT_DIR) then return end
        FS.makefolder(CONFIG.OUT_DIR)
    end)
    dir_ready = ok
    if not ok then say("WARNING: could not create folder " .. CONFIG.OUT_DIR) end
    return ok
end

local function path_for(name)
    return CONFIG.OUT_DIR .. "/" .. name
end

local function write_text(name, text)
    if not fs_available then return false, "no_writefile" end
    ensure_dir()
    local ok, err = pcall(function() FS.writefile(path_for(name), text) end)
    if ok then return true end
    return false, tostring(err)
end

-- Buffered fallback for executors without appendfile. A naive read-modify-
-- write per line is quadratic; batching keeps total I/O linear-ish and
-- bounded by the event caps.
local append_buffer = {}
local APPEND_BATCH = 25

local function flush_append(name, force)
    local buffer = append_buffer[name]
    if not buffer or #buffer == 0 then return true end
    if not force and #buffer < APPEND_BATCH then return true end
    local chunk = table.concat(buffer)
    append_buffer[name] = {}
    local previous = ""
    if type(FS.isfile) == "function" and type(FS.readfile) == "function" then
        pcall(function()
            if FS.isfile(path_for(name)) then previous = FS.readfile(path_for(name)) or "" end
        end)
    end
    local ok, err = pcall(function() FS.writefile(path_for(name), previous .. chunk) end)
    if ok then return true end
    return false, tostring(err)
end

local function flush_all_appends()
    local results = true
    for name in pairs(append_buffer) do
        local ok = flush_append(name, true)
        if not ok then results = false end
    end
    return results
end

local function append_text(name, text)
    if not fs_available then return false, "no_writefile" end
    ensure_dir()
    if type(FS.appendfile) == "function" then
        local ok, err = pcall(function() FS.appendfile(path_for(name), text) end)
        if ok then return true end
        return false, tostring(err)
    end
    append_buffer[name] = append_buffer[name] or {}
    local buffer = append_buffer[name]
    buffer[#buffer + 1] = text
    return flush_append(name, false)
end

local write_failures = 0
local function write_json(name, value)
    local text, err = encode(value)
    if not text then
        write_failures = write_failures + 1
        log("encode failed for", name, err)
        return false
    end
    local ok, werr = write_text(name, text)
    if not ok then
        write_failures = write_failures + 1
        log("write failed for", name, werr)
    end
    return ok
end

local function append_jsonl(name, value)
    local text, err = encode(value)
    if not text then
        write_failures = write_failures + 1
        log("encode failed for", name, err)
        return false
    end
    local ok, werr = append_text(name, text .. "\n")
    if not ok then
        write_failures = write_failures + 1
        log("append failed for", name, werr)
    end
    return ok
end

--[[--------------------------------------------------------------------
    Clock + counters.
--------------------------------------------------------------------]]
local T0 = os.clock()
local function now() return os.clock() - T0 end
local function stamp() return tonumber(string.format("%.3f", now())) end

local counters = { events = 0, transitions = 0 }
local caps_hit = { events = false, transitions = false }

local FILES = {
    env         = "01_environment.json",
    gui         = "02_gui_hierarchy.json",
    methods     = "03_methods.json",
    buttons     = "04_button_connections.json",
    events      = "05_trade_events.jsonl",
    transitions = "06_state_transitions.jsonl",
    summary     = "summary.txt",
}

local function record_event(kind, data)
    if counters.events >= CONFIG.MAX_EVENTS then
        if not caps_hit.events then
            caps_hit.events = true
            say("event cap reached (" .. CONFIG.MAX_EVENTS .. ") - no more events recorded")
        end
        return
    end
    counters.events = counters.events + 1
    local entry = { seq = counters.events, t = stamp(), kind = kind }
    if type(data) == "table" then
        for k, v in pairs(data) do
            if k ~= "seq" and k ~= "t" and k ~= "kind" then entry[k] = v end
        end
    end
    append_jsonl(FILES.events, entry)
end

local function record_transition(entry)
    if counters.transitions >= CONFIG.MAX_TRANSITIONS then
        if not caps_hit.transitions then
            caps_hit.transitions = true
            say("transition cap reached - no more transitions recorded")
        end
        return
    end
    counters.transitions = counters.transitions + 1
    entry.seq = counters.transitions
    entry.t = stamp()
    append_jsonl(FILES.transitions, entry)
end

--[[--------------------------------------------------------------------
    Safe reads. Nothing here may ever call a game function that mutates.
--------------------------------------------------------------------]]
local function prop(instance, name)
    if not instance then return nil end
    local ok, value = pcall(function() return instance[name] end)
    if ok then return value end
    return nil
end

local function class_of(instance)
    local ok, value = pcall(function() return instance.ClassName end)
    return ok and value or nil
end

local function is_button(instance)
    local ok, value = pcall(function()
        return instance:IsA("GuiButton")
    end)
    return ok and value == true
end

--[[--------------------------------------------------------------------
    Game module access (read-only).
--------------------------------------------------------------------]]
local Fsys, Fload, UIManager
-- A missing Fsys makes WaitForChild block for its full timeout. Cache the
-- failure and retry on a slow backoff so a wrong place or a renamed module
-- cannot turn a 0.25s poll into a 20s stall.
local fsys_retry_after = 0
local function ensure_fsys()
    if Fload then return true end
    if os.clock() < fsys_retry_after then return false end
    local ok = pcall(function()
        Fsys = require(game.ReplicatedStorage:WaitForChild("Fsys", 5))
        Fload = Fsys and Fsys.load
    end)
    if ok and type(Fload) == "function" then return true end
    Fload = nil
    fsys_retry_after = os.clock() + 15
    return false
end

local function ensure_uimanager()
    if UIManager then return UIManager end
    if not ensure_fsys() then return nil end
    pcall(function() UIManager = Fload("UIManager") end)
    return UIManager
end

local function apps()
    local um = ensure_uimanager()
    if not um then return nil end
    local ok, value = pcall(function() return um.apps end)
    return ok and value or nil
end

local function trade_app()
    local a = apps()
    if not a then return nil end
    local ok, app = pcall(function() return a.TradeApp end)
    return ok and app or nil
end

local function dialog_app()
    local a = apps()
    if not a then return nil end
    local ok, app = pcall(function() return a.DialogApp end)
    return ok and app or nil
end

-- Returns state, readable. readable=false means the read FAILED or the app
-- was missing: that is UNKNOWN, never "the trade closed".
local function trade_state(app)
    if not app then return nil, false end
    local ok, state = pcall(function() return app:_get_local_trade_state() end)
    if ok then return state, true end
    return nil, false
end

-- Count offer entries without reading any item identity.
-- Returns count, or nil when the offer is not readable (UNKNOWN != EMPTY).
local function offer_count(offer)
    if type(offer) ~= "table" then return nil end
    local items = offer.items
    if type(items) ~= "table" then return nil end
    local n = 0
    for _, item in pairs(items) do
        if type(item) == "table" then n = n + 1 end
    end
    return n
end

local function offer_snapshot(app)
    local snap = {
        my_items = nil, partner_items = nil,
        my_confirmed = nil, partner_confirmed = nil,
    }
    if not app then return snap end
    pcall(function()
        local mine = app:_get_my_offer()
        snap.my_items = offer_count(mine)
        if type(mine) == "table" then snap.my_confirmed = mine.confirmed == true end
    end)
    pcall(function()
        local partner = app:_get_partner_offer()
        snap.partner_items = offer_count(partner)
        if type(partner) == "table" then snap.partner_confirmed = partner.confirmed == true end
    end)
    return snap
end

--[[--------------------------------------------------------------------
    STATIC INSPECTION 1 - environment
--------------------------------------------------------------------]]
local function capability(name, value)
    return { name = name, available = type(value) == "function" }
end

local function environment_snapshot()
    local caps = {
        capability("writefile", FS.writefile),
        capability("appendfile", FS.appendfile),
        capability("readfile", FS.readfile),
        capability("isfile", FS.isfile),
        capability("makefolder", FS.makefolder),
        capability("isfolder", FS.isfolder),
        capability("getconnections", getconnections),
        capability("getgenv", getgenv),
        capability("hookmetamethod", hookmetamethod),
    }
    -- No account name, no UserId, no tokens: PlaceId/JobId identify the run.
    return {
        recorder_version = "1.0.0",
        place_id = prop(game, "PlaceId"),
        job_id = prop(game, "JobId"),
        fsys_loaded = ensure_fsys(),
        uimanager_loaded = ensure_uimanager() ~= nil,
        trade_app_present = trade_app() ~= nil,
        dialog_app_present = dialog_app() ~= nil,
        filesystem_available = fs_available,
        append_supported = type(FS.appendfile) == "function",
        capabilities = caps,
        poll_seconds = CONFIG.POLL,
        started_at_unix = os.time(),
    }
end

--[[--------------------------------------------------------------------
    STATIC INSPECTION 2 - TradeApp GUI hierarchy (bounded)
--------------------------------------------------------------------]]
local function player_gui()
    local ok, gui = pcall(function() return LocalPlayer:FindFirstChild("PlayerGui") end)
    return ok and gui or nil
end

local function trade_gui_root()
    local gui = player_gui()
    if not gui then return nil end
    local ok, root = pcall(function() return gui:FindFirstChild("TradeApp") end)
    return ok and root or nil
end

-- Adopt Me names some GUI children after the thing they hold (the evidence
-- dumps show e.g. "cracked_egg" under other apps). Offer slots are therefore
-- treated as untrusted: anything below a Slots container is reduced to an
-- index so an item identity can never reach the report.
local SAFE_NODE_NAME = "^[A-Za-z][A-Za-z0-9_]*$"
local node_index = {}

local function safe_node_name(instance, parent_path)
    local raw = prop(instance, "Name")
    raw = (type(raw) == "string") and raw or "?"
    local untrusted = parent_path:find("Slots", 1, true) ~= nil
        or parent_path:find("Offer", 1, true) ~= nil
    if untrusted and raw ~= "SlotTemplate" and raw ~= "Slots" then
        node_index[parent_path] = (node_index[parent_path] or 0) + 1
        return "#" .. node_index[parent_path]
    end
    if not raw:match(SAFE_NODE_NAME) then return "<redacted>" end
    if #raw > 48 then return raw:sub(1, 48) .. "~" end
    return raw
end

-- Member keys are listed by name. A non-string key would otherwise publish a
-- raw pointer address, so only its type is recorded.
local function safe_key_name(key)
    if type(key) ~= "string" then return "<" .. type(key) .. " key>" end
    if #key > 64 then return key:sub(1, 64) .. "~" end
    return key
end

local function gui_hierarchy_snapshot()
    local root = trade_gui_root()
    if not root then
        return { present = false, nodes = {}, node_count = 0, truncated = false }
    end
    local nodes, visited, truncated = {}, 0, false

    local function walk(instance, path, depth)
        if truncated then return end
        if depth > CONFIG.MAX_GUI_DEPTH then return end
        local children = {}
        local ok = pcall(function() children = instance:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            if visited >= CONFIG.MAX_GUI_NODES then
                truncated = true
                return
            end
            visited = visited + 1
            local child_path = path .. "." .. safe_node_name(child, path)
            local entry = {
                path = child_path,
                class = class_of(child),
                depth = depth,
            }
            local visible = prop(child, "Visible")
            if visible ~= nil then entry.visible = visible == true end
            if is_button(child) then
                entry.button = true
                entry.active = prop(child, "Active") == true
                local interactable = prop(child, "Interactable")
                if interactable ~= nil then entry.interactable = interactable == true end
            end
            nodes[#nodes + 1] = entry
            walk(child, child_path, depth + 1)
        end
    end

    walk(root, "TradeApp", 1)
    return { present = true, nodes = nodes, node_count = #nodes, truncated = truncated }
end

--[[--------------------------------------------------------------------
    STATIC INSPECTION 3 - method names (NAMES ONLY, never called)
--------------------------------------------------------------------]]
local function key_listing(tbl)
    local out, count, truncated = {}, 0, false
    if type(tbl) ~= "table" then return out, truncated end
    local ok = pcall(function()
        for key, value in pairs(tbl) do
            if count >= CONFIG.MAX_METHOD_KEYS then
                truncated = true
                break
            end
            count = count + 1
            -- Record the NAME and the TYPE only. The value is never invoked
            -- and function bodies are never read or dumped.
            out[#out + 1] = { name = safe_key_name(key), type = type(value) }
        end
    end)
    if not ok then return out, truncated end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out, truncated
end

local function describe_table(tbl, label)
    local direct, direct_truncated = key_listing(tbl)
    local chain = {}
    local seen = {}
    local current = tbl
    for depth = 1, CONFIG.MAX_META_DEPTH do
        local meta
        local ok = pcall(function() meta = getmetatable(current) end)
        if not ok or type(meta) ~= "table" then break end
        local index = rawget(meta, "__index")
        if type(index) ~= "table" or seen[index] then break end
        seen[index] = true
        local keys, keys_truncated = key_listing(index)
        chain[#chain + 1] = {
            depth = depth,
            keys = keys,
            key_count = #keys,
            truncated = keys_truncated,
        }
        current = index
    end
    return {
        label = label,
        present = type(tbl) == "table",
        direct_keys = direct,
        direct_key_count = #direct,
        direct_truncated = direct_truncated,
        metatable_chain = chain,
    }
end

local function methods_snapshot()
    return {
        note = "names and types only; no function was called and no body was read",
        trade_app = describe_table(trade_app(), "UIManager.apps.TradeApp"),
        dialog_app = describe_table(dialog_app(), "UIManager.apps.DialogApp"),
    }
end

--[[--------------------------------------------------------------------
    STATIC INSPECTION 4 - button handler counts
       getconnections is used to COUNT handlers only. Connections are never
       fired, never disabled, and callback bodies are never extracted.
--------------------------------------------------------------------]]
local KNOWN_BUTTONS = {
    "Frame.NegotiationFrame.Body.Accept",
    "Frame.NegotiationFrame.Body.Decline",
    "Frame.ConfirmationFrame.Accept",
    "Frame.ConfirmationFrame.Decline",
    "Frame.SpectateFrame.Close",
    "Frame.NegotiationFrame.ChatFrame.Header.ExitButton",
    "Tooltip.ExitButton",
}

local getconn = getconnections

local function connection_count(instance, signal_name)
    if type(getconn) ~= "function" or not instance then return nil end
    local count
    pcall(function()
        local signal = instance[signal_name]
        if signal == nil then return end
        local list = getconn(signal)
        if type(list) == "table" then count = #list end
    end)
    return count
end

local function resolve(root, dotted)
    local current = root
    for segment in string.gmatch(dotted, "[^%.]+") do
        if not current then return nil end
        local ok, nxt = pcall(function() return current:FindFirstChild(segment) end)
        if not ok then return nil end
        current = nxt
    end
    return current
end

-- with_connections defaults to true: the static snapshots always want the
-- handler counts. The high-frequency poll passes false to skip them.
local function button_report(instance, path, with_connections)
    local entry = { path = "TradeApp." .. path, present = instance ~= nil }
    if not instance then return entry end
    entry.class = class_of(instance)
    entry.visible = prop(instance, "Visible") == true
    entry.active = prop(instance, "Active") == true
    local interactable = prop(instance, "Interactable")
    if interactable ~= nil then entry.interactable = interactable == true end
    if with_connections ~= false then
        entry.activated_connections = connection_count(instance, "Activated")
        entry.mouse_button1_connections = connection_count(instance, "MouseButton1Click")
    end
    return entry
end

local function buttons_snapshot()
    local root = trade_gui_root()
    local report = {
        note = "handler counts only; no signal was fired and no callback was read",
        getconnections_available = type(getconn) == "function",
        trade_gui_present = root ~= nil,
        known = {},
        discovered = {},
    }
    if not root then return report end

    local seen = {}
    for _, path in ipairs(KNOWN_BUTTONS) do
        local instance = resolve(root, path)
        if instance then seen[instance] = true end
        report.known[#report.known + 1] = button_report(instance, path)
    end

    -- Any other buttons inside TradeApp that the known list does not cover.
    local visited = 0
    local function walk(instance, path, depth)
        if depth > CONFIG.MAX_GUI_DEPTH or visited >= CONFIG.MAX_GUI_NODES then return end
        local children = {}
        local ok = pcall(function() children = instance:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            visited = visited + 1
            if visited >= CONFIG.MAX_GUI_NODES then return end
            local safe_name = safe_node_name(child, path)
            local child_path = (path == "" and safe_name) or (path .. "." .. safe_name)
            if is_button(child) and not seen[child] then
                seen[child] = true
                report.discovered[#report.discovered + 1] = button_report(child, child_path)
            end
            walk(child, child_path, depth + 1)
        end
    end
    walk(root, "", 1)
    return report
end

--[[--------------------------------------------------------------------
    Static snapshot store. A snapshot is appended only when its content
    actually changed, so repeated identical dumps never pile up.
--------------------------------------------------------------------]]
local static_store = {}

local function push_snapshot(file_key, label, builder, reason)
    local ok, value = pcall(builder)
    if not ok then
        log("snapshot failed:", label, tostring(value))
        return false
    end
    local text = encode(value)
    if not text then return false end

    local store = static_store[file_key]
    if not store then
        store = { signature = nil, payload = { label = label, snapshots = {} } }
        static_store[file_key] = store
    end
    if store.signature == text then return false end
    if #store.payload.snapshots >= CONFIG.MAX_SNAPSHOTS then
        -- Make the cap visible on disk; a silently frozen file would let an
        -- analyst believe later states were simply unchanged.
        if not store.payload.truncated then
            store.payload.truncated = true
            write_json(FILES[file_key], store.payload)
        end
        return false
    end
    store.signature = text
    store.payload.snapshots[#store.payload.snapshots + 1] = {
        index = #store.payload.snapshots + 1,
        t = stamp(),
        reason = reason,
        data = value,
    }
    write_json(FILES[file_key], store.payload)
    return true
end

local function capture_static(reason)
    local changed = {}
    if push_snapshot("gui", "TradeApp GUI hierarchy", gui_hierarchy_snapshot, reason) then
        changed[#changed + 1] = "gui"
    end
    if push_snapshot("methods", "TradeApp / DialogApp member names", methods_snapshot, reason) then
        changed[#changed + 1] = "methods"
    end
    if push_snapshot("buttons", "TradeApp button handler counts", buttons_snapshot, reason) then
        changed[#changed + 1] = "buttons"
    end
    if #changed > 0 then
        record_event("static_snapshot", { reason = reason, files = changed })
    end
    return changed
end

--[[--------------------------------------------------------------------
    PHASE DETECTION
      Primary source is the real trade state, not GUI visibility:
        state.current_stage == "confirmation" -> CONFIRMATION
        any other non-nil state               -> NEGOTIATION
      INVITATION comes from DialogApp's ticket counters, which is the only
      reliable signal (is_dialog_open reads false while a request shows).
      A trade that disappears emits CLOSED, then settles back to IDLE.
--------------------------------------------------------------------]]
local PHASE = {
    IDLE = "IDLE",
    INVITATION = "INVITATION",
    NEGOTIATION = "NEGOTIATION",
    CONFIRMATION = "CONFIRMATION",
    CLOSED = "CLOSED",
}

local function invitation_pending()
    local d = dialog_app()
    if not d then return false, nil, nil end
    local count = prop(d, "ticket_count")
    local done = prop(d, "completed_ticket")
    if type(count) ~= "number" or type(done) ~= "number" then return false, count, done end
    return count > done, count, done
end

-- Returns phase, app, state, stage, readable.
-- readable=false means the trade state could not be read this poll. The
-- caller MUST NOT treat that as a close: an unreadable app looks exactly
-- like a cancellation otherwise, which is the one thing this recorder
-- exists to measure accurately.
local function detect_phase()
    local app = trade_app()
    local state, readable = trade_state(app)
    if state then
        local stage = nil
        pcall(function() stage = state.current_stage end)
        if stage == "confirmation" then
            return PHASE.CONFIRMATION, app, state, stage, true
        end
        return PHASE.NEGOTIATION, app, state, stage, true
    end
    local pending = invitation_pending()
    if pending then return PHASE.INVITATION, app, nil, nil, readable end
    return PHASE.IDLE, app, nil, nil, readable
end

--[[--------------------------------------------------------------------
    Button availability tracking (change-driven, bounded).
--------------------------------------------------------------------]]
local button_basic_sig, button_conn_sig = {}, {}
local button_poll_tick = 0
local CONNECTION_SWEEP_EVERY = 8   -- polls between getconnections sweeps

local function poll_buttons(force_connections)
    local root = trade_gui_root()
    if not root then return end
    button_poll_tick = button_poll_tick + 1
    -- getconnections allocates a table per call, so sweep it on a slow
    -- cadence. Presence/visibility is cheap and polled every time.
    local with_connections = force_connections == true
        or (button_poll_tick % CONNECTION_SWEEP_EVERY == 1)
    for _, path in ipairs(KNOWN_BUTTONS) do
        local instance = resolve(root, path)
        local report = button_report(instance, path, with_connections)
        local basic = table.concat({
            tostring(report.present),
            tostring(report.visible),
            tostring(report.active),
            tostring(report.interactable),
        }, "|")
        local changed = button_basic_sig[path] ~= nil and button_basic_sig[path] ~= basic
        if with_connections then
            local conns = tostring(report.activated_connections)
                .. "|" .. tostring(report.mouse_button1_connections)
            if button_conn_sig[path] ~= nil and button_conn_sig[path] ~= conns then
                changed = true
            end
            button_conn_sig[path] = conns
        end
        if changed then record_event("button_change", report) end
        button_basic_sig[path] = basic
    end
end

--[[--------------------------------------------------------------------
    MAIN OBSERVER LOOP
--------------------------------------------------------------------]]
local running = true
local stopped_reason = nil
local session_index = 0
local stats = {
    sessions_opened = 0,
    closes_from_negotiation = 0,
    closes_from_confirmation = 0,
    invitations_seen = 0,
    invitations_resolved_without_trade = 0,
    both_confirmed_closes = 0,
}

local current_phase = nil
local phase_since = now()
local last_offers = nil
local last_offer_signature = nil
local last_ticket_signature = nil
local deepest_stage = nil
-- Set while the trade state cannot be read, so a failed read is never
-- mistaken for a trade that closed.
local unreadable_since = nil

local function offers_signature(snapshot)
    return table.concat({
        tostring(snapshot.my_items),
        tostring(snapshot.partner_items),
        tostring(snapshot.my_confirmed),
        tostring(snapshot.partner_confirmed),
    }, "|")
end

local function enter_phase(next_phase, context)
    local previous = current_phase
    local held = now() - phase_since
    current_phase = next_phase
    phase_since = now()

    local entry = {
        from = previous,
        to = next_phase,
        held_seconds = tonumber(string.format("%.3f", held)),
        session = session_index,
    }
    if context then
        for k, v in pairs(context) do entry[k] = v end
    end
    record_transition(entry)
    log("phase:", tostring(previous), "->", next_phase)

    capture_static("phase:" .. next_phase)
end

local function finalize(reason)
    if not running then return end
    running = false
    stopped_reason = reason or "stopped"

    record_event("recorder_stopped", { reason = stopped_reason })
    flush_all_appends()

    local lines = {
        "ADM TradeApp Recorder - summary",
        "recorder_version : 1.0.0",
        "stopped_reason   : " .. tostring(stopped_reason),
        "runtime_seconds  : " .. string.format("%.1f", now()),
        "place_id         : " .. tostring(prop(game, "PlaceId")),
        "job_id           : " .. tostring(prop(game, "JobId")),
        "",
        "events_recorded      : " .. counters.events .. (caps_hit.events and " (CAPPED)" or ""),
        "transitions_recorded : " .. counters.transitions .. (caps_hit.transitions and " (CAPPED)" or ""),
        "write_failures       : " .. write_failures,
        "filesystem_available : " .. tostring(fs_available),
        "append_supported     : " .. tostring(type(FS.appendfile) == "function"),
        "",
        "trade_sessions_opened          : " .. stats.sessions_opened,
        "closed_from_negotiation        : " .. stats.closes_from_negotiation,
        "closed_from_confirmation       : " .. stats.closes_from_confirmation,
        "closes_with_both_confirmed     : " .. stats.both_confirmed_closes,
        "invitations_seen               : " .. stats.invitations_seen,
        "invitations_without_trade_open : " .. stats.invitations_resolved_without_trade,
        "",
        "A close from NEGOTIATION or CONFIRMATION with both_confirmed=false is a",
        "cancellation. Compare 06_state_transitions.jsonl timings with the moment",
        "you pressed Decline.",
        "",
        "Files to return:",
        "  " .. path_for(FILES.env),
        "  " .. path_for(FILES.gui),
        "  " .. path_for(FILES.methods),
        "  " .. path_for(FILES.buttons),
        "  " .. path_for(FILES.events),
        "  " .. path_for(FILES.transitions),
        "  " .. path_for(FILES.summary),
        "",
        "The only game methods this recorder called are the read-only getters",
        "_get_local_trade_state / _get_my_offer / _get_partner_offer. It pressed no",
        "button, fired no signal or remote, installed no hook, and uploaded nothing.",
        "",
    }
    local summary_ok = write_text(FILES.summary, table.concat(lines, "\n"))
    flush_all_appends()

    -- No signal listeners were installed by this recorder (polling only),
    -- so there is nothing to disconnect. Stated explicitly for auditability.
    if getgenv then getgenv().ADM_RECORDER_STOP = nil end
    release_guard()

    if not fs_available then
        say("STOPPED (" .. tostring(stopped_reason) .. ") - NOTHING WAS SAVED: "
            .. "this executor exposes no writefile")
    elseif not summary_ok then
        say("STOPPED (" .. tostring(stopped_reason) .. ") - WARNING: the summary could not "
            .. "be written; check " .. CONFIG.OUT_DIR .. "/ for partial files")
    elseif write_failures > 0 then
        say("STOPPED (" .. tostring(stopped_reason) .. ") - files in " .. CONFIG.OUT_DIR
            .. "/ (WARNING: " .. write_failures .. " write failures)")
    else
        say("STOPPED (" .. tostring(stopped_reason) .. ") - files in " .. CONFIG.OUT_DIR .. "/")
    end
end

if getgenv then
    getgenv().ADM_RECORDER_STOP = function()
        finalize("user_requested")
        return true
    end
end

--[[--------------------------------------------------------------------
    STARTUP
--------------------------------------------------------------------]]
say("STARTED - read-only TradeApp recorder, no trade actions will be taken")

local STOP_HINT = (getgenv ~= nil)
    and "Stop with: getgenv().ADM_RECORDER_STOP()"
    or ("No getgenv on this executor: there is no manual stop. The recorder "
        .. "ends automatically after " .. CONFIG.MAX_RUNTIME .. "s.")

if not fs_available then
    say("LIMITATION: this executor exposes no writefile; nothing can be saved to disk.")
    say("Console output only. " .. STOP_HINT)
else
    ensure_dir()
    -- Fresh run: start the event/transition logs from empty so an old run's
    -- lines cannot be mistaken for this one. Copy anything you still need
    -- out of the folder BEFORE re-executing.
    write_text(FILES.events, "")
    write_text(FILES.transitions, "")
end

-- Wait, bounded, for the game UI to exist before the first snapshot.
local boot_deadline = os.clock() + 60
while running and os.clock() < boot_deadline do
    if trade_app() ~= nil then break end
    task.wait(0.5)
end

if not running then
    -- Stopped during the boot wait; finalize already ran.
    return
end

write_json(FILES.env, environment_snapshot())
capture_static("startup")
poll_buttons(true)

local initial_phase, _, _, initial_stage = detect_phase()
current_phase = initial_phase
phase_since = now()

-- A trade that is already open when the recorder starts is still a session;
-- otherwise its eventual close would be counted without an opening.
if initial_phase == PHASE.NEGOTIATION or initial_phase == PHASE.CONFIRMATION then
    session_index = 1
    stats.sessions_opened = 1
    deepest_stage = initial_stage
end

record_transition({
    from = nil, to = initial_phase, held_seconds = 0,
    session = session_index, reason = "startup",
})

if trade_app() == nil then
    say("NOTE: TradeApp was not reachable at startup; it will be re-checked every poll.")
end

say("READY - phase " .. tostring(initial_phase))
say("Now do your manual tests. " .. STOP_HINT)

task.spawn(function()
    while running do
        local ok, err = pcall(function()
            if now() >= CONFIG.MAX_RUNTIME then
                finalize("max_runtime")
                return
            end

            local phase, app, state, stage, readable = detect_phase()

            -- An unreadable TradeApp is UNKNOWN, not a closed trade. Hold the
            -- current phase so a transient read failure cannot fabricate the
            -- very cancellation fingerprint this recorder is measuring.
            local was_open_now = (current_phase == PHASE.NEGOTIATION
                or current_phase == PHASE.CONFIRMATION)
            if not readable and was_open_now then
                if not unreadable_since then
                    unreadable_since = now()
                    record_event("state_read_failed", {
                        phase = current_phase,
                        session = session_index,
                        note = "trade state unreadable; holding phase (not a close)",
                    })
                end
                return
            end
            unreadable_since = nil

            -- Invitation ticket movement is worth recording on its own: it is
            -- how a declined invite shows up when no trade window ever opens.
            local pending, count, done = invitation_pending()
            local ticket_signature = tostring(pending) .. "|" .. tostring(count) .. "|" .. tostring(done)
            if last_ticket_signature ~= ticket_signature then
                if last_ticket_signature ~= nil then
                    record_event("dialog_ticket_change", {
                        pending = pending,
                        ticket_count = count,
                        completed_ticket = done,
                        phase = phase,
                    })
                    if pending then stats.invitations_seen = stats.invitations_seen + 1 end
                end
                last_ticket_signature = ticket_signature
            end

            -- Resolve the phase change FIRST so every event written this poll
            -- carries the session it actually belongs to.
            local opening = (phase == PHASE.NEGOTIATION or phase == PHASE.CONFIRMATION)
            local was_open = (current_phase == PHASE.NEGOTIATION
                or current_phase == PHASE.CONFIRMATION)
            local phase_changed = (phase ~= current_phase)
            local closed_from = current_phase

            if phase_changed and opening and not was_open then
                session_index = session_index + 1
                stats.sessions_opened = stats.sessions_opened + 1
                deepest_stage = stage
                last_offer_signature = nil
                enter_phase(phase, { stage = stage, event = "trade_opened" })

            elseif phase_changed and was_open and not opening then
                -- The trade window went away on a READABLE poll. Report what
                -- it looked like immediately before it vanished: that is the
                -- cancellation fingerprint we are hunting for.
                local final_offers = last_offers or {}
                local both_confirmed = (final_offers.my_confirmed == true)
                    and (final_offers.partner_confirmed == true)
                if both_confirmed then
                    stats.both_confirmed_closes = stats.both_confirmed_closes + 1
                end
                if closed_from == PHASE.CONFIRMATION then
                    stats.closes_from_confirmation = stats.closes_from_confirmation + 1
                else
                    stats.closes_from_negotiation = stats.closes_from_negotiation + 1
                end

                enter_phase(PHASE.CLOSED, {
                    closed_from = closed_from,
                    last_stage = deepest_stage,
                    my_items = final_offers.my_items,
                    partner_items = final_offers.partner_items,
                    my_confirmed = final_offers.my_confirmed,
                    partner_confirmed = final_offers.partner_confirmed,
                    both_confirmed = both_confirmed,
                    classification = both_confirmed and "completed_or_confirmed_close"
                        or "closed_without_both_confirmed",
                })

                last_offers = nil
                last_offer_signature = nil
                deepest_stage = nil

                -- Settle into whatever the real phase is now.
                enter_phase(phase, { stage = stage, event = "after_close" })

            elseif phase_changed then
                if closed_from == PHASE.INVITATION and phase == PHASE.IDLE then
                    stats.invitations_resolved_without_trade =
                        stats.invitations_resolved_without_trade + 1
                end
                enter_phase(phase, { stage = stage })
            end

            -- Offer counts / confirmed flags while a trade is open. Runs after
            -- the phase resolution so session_index is already correct.
            if state then
                local snapshot = offer_snapshot(app)
                local signature = offers_signature(snapshot)
                if last_offer_signature ~= signature then
                    last_offer_signature = signature
                    record_event("offer_change", {
                        phase = phase,
                        stage = stage,
                        session = session_index,
                        my_items = snapshot.my_items,
                        partner_items = snapshot.partner_items,
                        my_confirmed = snapshot.my_confirmed,
                        partner_confirmed = snapshot.partner_confirmed,
                    })
                end
                last_offers = snapshot
                if stage == "confirmation" then deepest_stage = "confirmation"
                elseif deepest_stage == nil then deepest_stage = stage end
            end

            poll_buttons()
        end)
        if not ok then
            -- Roblox error text can embed "Players.<AccountName>..." paths.
            -- Strip the account segment and cap the length before logging.
            local message = tostring(err):gsub("Players%.[%w_]+", "Players.<redacted>")
            record_event("recorder_error", { message = message:sub(1, 300) })
            log("poll error:", err)
        end
        if running then task.wait(CONFIG.POLL) end
    end
end)
