-- Deterministic mock adapter for the Gemstone workflow.
-- Used by tests and Studio-style harnesses; never connects to Roblox services.
local Mock = {}
Mock.__index = Mock

function Mock.new(options)
    options = options or {}
    local self = setmetatable({
        ready_after = options.ready_after or 0,
        steps = 0,
        in_game = options.in_game == true,
        onboarding = options.onboarding or "none",
        claimed = options.claimed == true,
        claim_changes_state = options.claim_changes_state ~= false,
        missing_reward = options.missing_reward == true,
        stats = options.stats or {
            username = "mock_account",
            daily_streak = 4,
            stars = 26,
            gemstone_progress = "26/28",
            gemstone_price = 28,
            claim_eligible = options.claimed ~= true,
        },
    }, Mock)
    return self
end

function Mock:is_available() return true end
function Mock:is_game_ready()
    self.steps = self.steps + 1
    return self.steps > self.ready_after
end
function Mock:is_in_game() return self.in_game end
function Mock:initialize_location() return true end
function Mock:get_onboarding_screen() return self.onboarding end
function Mock:handle_play() self.onboarding = "none" self.in_game = true return true end
function Mock:handle_home() self.onboarding = "none" self.in_game = true return true end
function Mock:handle_favorite_color() self.onboarding = "none" self.in_game = true return true end
function Mock:read_reward_state()
    if self.missing_reward then return nil end
    return self.stats
end
function Mock:claim_reward()
    if self.claimed then return false end
    self.claimed = true
    if self.claim_changes_state then
        self.stats.claim_eligible = false
        self.stats.stars = (self.stats.stars or 0) + 1
        local current, target = tostring(self.stats.gemstone_progress):match("(%d+)%s*/%s*(%d+)")
        if current and target then
            self.stats.gemstone_progress = tostring(tonumber(current) + 1) .. "/" .. target
        end
    end
    return true
end

return Mock
