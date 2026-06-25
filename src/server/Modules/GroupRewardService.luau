--!strict
-- Group reward: auto-wires every workspace part tagged Config.Tags.GroupReward (a
-- circle on the ground). Walking onto one is a claim attempt, which the SERVER owns:
--   * Not in the group     -> tell the client to prompt a join (best-effort, see note).
--   * In group, off cooldown -> grant Fraction of the player's current balance,
--                               announce + post a message, then stamp the cooldown.
--   * In group, on cooldown  -> ignore (the sign already shows the remaining time).
--
-- The cooldown + claim timestamp live in StatsService (persisted), so the client can
-- read the last-claim time via the existing GetStats/StatsChanged remotes and render
-- the sign itself; this module only fires PromptGroupJoin for the not-a-member case.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local ScoreUI = require(RS.Shared.ScoreUI)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local StatsService = require(SSS.Scripts.Modules.StatsService)

local GroupRewardService = {}

local GROUP_ID = Config.Groups.GroupId
local FRACTION = Config.GroupReward.Fraction
local COOLDOWN = Config.GroupReward.Cooldown

-- Short per-player touch debounce so standing/walking on the pad doesn't spam claim
-- attempts. The authoritative gate is the 5-hour cooldown in StatsService; this just
-- keeps a single step-on from firing many times.
local TOUCH_DEBOUNCE = 1.5
local busy: { [number]: boolean } = {}

-- Live connections keyed by the tagged part, so removal tears them down.
local connections: { [Instance]: RBXScriptConnection } = {}

local promptJoinRE: RemoteEvent? = nil

local function attemptClaim(player: Player)
	local id = player.UserId
	if busy[id] then
		return
	end
	busy[id] = true
	task.delay(TOUCH_DEBOUNCE, function()
		busy[id] = nil
	end)

	if not player:IsInGroup(GROUP_ID) then
		-- Roblox has no native "join group" prompt; the client hook is best-effort (see
		-- GroupRewardUI). Post a hint so the player still gets feedback on touch.
		if promptJoinRE then
			promptJoinRE:FireClient(player)
		end
		AnnounceUI.Announce(player, "Join X Studios to claim the reward!", Config.GroupReward.LabelColor)
		return
	end

	local last = StatsService.GetLastGroupRewardClaim(player)
	if os.time() - last < COOLDOWN then
		return -- still on cooldown; the sign shows the remaining time
	end

	local reward = math.floor(CurrencyService.GetPoints(player) * FRACTION)
	StatsService.SetGroupRewardClaimedNow(player) -- stamp first so a re-touch is gated
	CurrencyService.AddPoints(player, reward, "Group Reward")
	AnnounceUI.Announce(player, "Claimed +15%!", Config.GroupReward.LabelColor)
	ScoreUI.PostMessage(player, "Group Reward: " .. StringUtils.FormatMoney(reward), Config.GroupReward.MsgColor)
end

local function addPad(inst: Instance)
	if connections[inst] then
		return
	end
	if not inst:IsA("BasePart") then
		warn(("GroupRewardService: tagged instance %s is not a BasePart; skipping"):format(inst:GetFullName()))
		return
	end
	connections[inst] = inst.Touched:Connect(function(part: BasePart)
		local player = Players:GetPlayerFromCharacter(part.Parent)
		if player then
			attemptClaim(player)
		end
	end)
end

local function removePad(inst: Instance)
	local conn = connections[inst]
	if conn then
		conn:Disconnect()
		connections[inst] = nil
	end
end

function GroupRewardService.Init()
	local re = Instance.new("RemoteEvent")
	re.Name = "PromptGroupJoin"
	re.Parent = RS.Remote
	promptJoinRE = re

	for _, inst in CollectionService:GetTagged(Config.Tags.GroupReward) do
		addPad(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.GroupReward):Connect(addPad)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.GroupReward):Connect(removePad)
end

return GroupRewardService
