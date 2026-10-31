-- Deterministic harness for adm_autotrade.lua.
-- Runs under Fengari (Lua 5.3) or any Lua 5.3-compatible interpreter.
-- It stubs the Roblox/Delta surface and loads the production script in its
-- __ADM_AUTOTRADE_TEST_MODE seam. No game, network, or filesystem is touched.

local H = {}

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

local function signals()
    return {
        Connect = function() end,
        Fire = function() end,
    }
end

function H.new(opts)
    opts = opts or {}
    local state = {
        now = 1000,
        request_calls = {},
        writes = {},
        prints = {},
        response = { StatusCode = 204 },
        spawn_errors = {},
    }

    local env = {}
    env.__ADM_AUTOTRADE_TEST_MODE = true

    local player = {
        Name = "ReceiverBot",
        UserId = 12345,
        Idled = signals(),
    }

    local http = {}
    function http:JSONEncode(v) return copy(v) end
    function http:JSONDecode(v) return v end

    local settings_db = {
        by_id = {
            trade_requests = { element_options = { choices = { "Friends", "Everyone" } } },
            give_item_requests = { element_options = { choices = { "Friends", "Everyone" } } },
        },
    }

    local settings_helper = {
        set_setting_client = function() end,
    }

    local kind_db = {
        cat = { name = "Cat" },
        dog = { name = "Dog" },
        crystal_egg = { name = "Crystal Egg" },
        dragonfly = { name = "Dragonfly" },
    }

    local promise = {
        resolve = function(value)
            return { expect = function() return value end }
        end,
    }

    local dialog_class = {}
    function dialog_class:dialog(o)
        return "native:" .. tostring(o and o.handle)
    end

    local dialog = setmetatable({
        ticket_count = 0,
        completed_ticket = 0,
        force_response_signal = signals(),
        forced = {},
        __autotrade_hooked = false,
    }, { __index = dialog_class })
    function dialog.force_response_signal.Fire(_, ticket, packed)
        dialog.forced[#dialog.forced + 1] = { ticket = ticket, packed = packed }
    end

    local app = {
        state = nil,
        my_offer = { items = {}, confirmed = false },
        partner_offer = { items = {}, confirmed = false },
        accept_calls = 0,
        confirm_calls = 0,
    }
    function app:_get_local_trade_state() return self.state end
    function app:_get_my_offer() return self.my_offer end
    function app:_get_partner_offer() return self.partner_offer end
    function app:_on_accept_pressed()
        self.accept_calls = self.accept_calls + 1
        if self.on_accept then self.on_accept(self) end
    end
    function app:_on_confirm_pressed()
        self.confirm_calls = self.confirm_calls + 1
        if self.on_confirm then self.on_confirm(self) end
    end

    local uimanager = { apps = { DialogApp = dialog, TradeApp = app } }

    local minigame = {}
    local excluder = {}

    local fsys = { load = function(name)
        if name == "UIManager" then return uimanager end
        if name == "SettingsHelper" then return settings_helper end
        if name == "KindDB" then return kind_db end
        if name == "package:Promise" then return promise end
        if name == "MinigameForcedState" then return minigame end
        if name == "TradeExcluder" then return excluder end
        return nil
    end }

    local replicated = {
        WaitForChild = function(_, name)
            if name == "Fsys" then return fsys end
            return {}
        end,
        ClientDB = { SettingsDB = settings_db },
    }

    local services = {
        Players = { LocalPlayer = player },
        VirtualUser = { CaptureController = function() end, ClickButton2 = function() end },
        HttpService = http,
        ReplicatedStorage = replicated,
        NetworkClient = { ChildRemoved = signals() },
    }

    local game_obj = {
        JobId = opts.job_id or "test-job-1",
        PlaceId = 920587237,
    }
    function game_obj:GetService(name)
        return services[name] or {}
    end
    game_obj.ReplicatedStorage = replicated

    _G.game = game_obj
    _G.getgenv = function() return env end
    _G.writefile = function(name, body)
        state.writes[name] = body
    end
    _G.readfile = function(name) return state.writes[name] end
    _G.isfile = function(name) return state.writes[name] ~= nil end
    _G.request = function(request)
        state.request_calls[#state.request_calls + 1] = copy(request)
        return state.response
    end
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        state.prints[#state.prints + 1] = table.concat(parts, " ")
    end
    _G.warn = _G.print
    _G.typeof = function(v)
        if type(v) == "table" and (v.Name or v.__instance) then return "Instance" end
        return type(v)
    end
    _G.Vector2 = { new = function(x, y) return { X = x, Y = y } end }

    -- Scheduling model. "sync" (default) runs spawned work inline so the
    -- existing suites keep their deterministic ordering. "deferred" models a
    -- real executor: task.spawn queues a coroutine, task.wait suspends it,
    -- and the test decides when work runs via h.pump(). That is what makes
    -- suspended callbacks, slow HTTP and heartbeat independence observable.
    local scheduling = opts.scheduling or "sync"
    local queue = {}
    local function enqueue(fn, ...)
        local args = table.pack(...)
        queue[#queue + 1] = coroutine.create(function()
            fn(table.unpack(args, 1, args.n))
        end)
    end
    local function run_inline(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then state.spawn_errors[#state.spawn_errors + 1] = tostring(err) end
    end

    _G.task = {
        wait = function(seconds)
            -- Only a spawned coroutine may suspend; a top-level call is a
            -- no-op exactly like the real executor's timeout behaviour.
            -- coroutine.running() returns two values and its first value
            -- differs by Lua version on the main thread, so both are
            -- checked: yielding from outside a coroutine would hard-error
            -- instead of no-op.
            local co, is_main = coroutine.running()
            if scheduling == "deferred" and co and not is_main then
                coroutine.yield(seconds)
            end
        end,
        spawn = function(fn, ...)
            if scheduling == "deferred" then enqueue(fn, ...) else run_inline(fn, ...) end
        end,
        defer = function(fn, ...)
            if scheduling == "deferred" then enqueue(fn, ...) else run_inline(fn, ...) end
        end,
    }
    _G.require = function(v)
        if v == fsys then return fsys end
        if v == settings_db then return settings_db end
        return v
    end

    local real_clock = os.clock
    os.clock = function() return state.now end

    local chunk, load_err = loadfile(opts.script or "adm_autotrade.lua")
    if not chunk then
        os.clock = real_clock
        error("failed to load adm_autotrade.lua: " .. tostring(load_err))
    end
    local ok, run_err = pcall(chunk)
    os.clock = real_clock
    if not ok then error("failed to run adm_autotrade.lua: " .. tostring(run_err)) end

    local api = env.__ADM_AUTOTRADE_TEST_API
    if not api then error("test API seam was not reached") end

    return {
        env = env,
        api = api,
        state = state,
        app = app,
        dialog = dialog,
        dialog_class = dialog_class,
        uimanager = uimanager,
        scheduling = scheduling,
        -- Resume every queued coroutine once. Repeats for `rounds` passes and
        -- returns the number still suspended, so a callback that waits N
        -- times is observable instead of silently hanging.
        pump = function(rounds)
            rounds = rounds or 1
            local remaining = #queue
            for _ = 1, rounds do
                if #queue == 0 then break end
                local current, ran = queue, 0
                queue = {}
                for _, co in ipairs(current) do
                    if coroutine.status(co) ~= "dead" then
                        local ok, err = coroutine.resume(co)
                        ran = ran + 1
                        if not ok then
                            state.spawn_errors[#state.spawn_errors + 1] = tostring(err)
                        elseif coroutine.status(co) ~= "dead" then
                            queue[#queue + 1] = co
                        end
                    end
                end
                remaining = #queue
                if ran == 0 then break end
            end
            return remaining
        end,
        pending = function() return #queue end,
        advance = function(seconds) state.now = state.now + (seconds or 0) end,
        set_now = function(v) state.now = v end,
        reset = function()
            api.reset_runtime()
            app.state = nil
            app.my_offer = { items = {}, confirmed = false }
            app.partner_offer = { items = {}, confirmed = false }
            app.accept_calls = 0
            app.confirm_calls = 0
            app.on_accept = nil
            app.on_confirm = nil
            dialog.forced = {}
            dialog.ticket_count = 0
            dialog.completed_ticket = 0
            state.request_calls = {}
            state.writes = {}
            state.response = { StatusCode = 204 }
            state.spawn_errors = {}
        end,
    }
end

-- Convenience helpers for assertions.
function H.item(kind, props)
    return { kind = kind, id = kind, properties = props or {} }
end

function H.offer(items, confirmed)
    return { items = items or {}, confirmed = confirmed == true }
end

function H.session(stage, partner)
    return {
        current_stage = stage or "negotiation",
        sender = partner or { Name = "PartnerBot" },
        recipient = { Name = "ReceiverBot" },
    }
end

function H.assert_eq(actual, expected, label)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(label or "assert", tostring(expected), tostring(actual)), 2)
    end
end

function H.assert_true(value, label)
    if not value then error((label or "assert") .. ": expected truthy", 2) end
end

return H
