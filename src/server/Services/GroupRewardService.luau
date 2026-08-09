--!strict
-- Group reward: auto-wires every workspace part tagged TagsConfig.GroupReward (a
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

local GroupConfig = require(RS.Shared.Config.Group)
local TagsConfig = require(RS.Shared.Config.Tags)
local GroupRewardNet = require(RS.Shared.Remote.GroupRewardNet)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local ScoreUI = require(RS.Shared.ScoreUI)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local StatsService = require(SSS.Scripts.Services.StatsService)

local GroupRewardService = {}

local GROUP_ID = GroupConfig.GroupId
local FRACTION = GroupConfig.Reward.Fraction
local COOLDOWN = GroupConfig.Reward.Cooldown

-- Short per-player touch debounce so standing/walking on the pad doesn't spam claim
-- attempts. The authoritative gate is the 5-hour cooldown in StatsService; this just
-- keeps a single step-on from firing many times.
local TOUCH_DEBOUNCE = 1.5
local busy: { [number]: boolean } = {}

-- Live connections keyed by the tagged part, so removal tears them down.
local connections: { [Instance]: RBXScriptConnection } = {}

local promptJoinRE: RemoteEvent? = nil
local claimedRE: RemoteEvent? = nil -- fired at the claimer on a successful grant (client FX)

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
		-- Not a member: have the client open the Roblox join-group dialog (GroupRewardUI uses
		-- GroupService:PromptJoinAsync), plus an announce hint for context.
		if promptJoinRE then
			promptJoinRE:FireClient(player)
		end
		AnnounceUI.Announce(player, "Join X Studios to claim the reward!", GroupConfig.Reward.LabelColor)
		return
	end

	local last = StatsService.GetLastGroupRewardClaim(player)
	if os.time() - last < COOLDOWN then
		return -- still on cooldown; the sign shows the remaining time
	end

	local reward = math.floor(CurrencyService.GetPoints(player) * FRACTION)
	StatsService.SetGroupRewardClaimedNow(player) -- stamp first so a re-touch is gated
	-- Celebration FX BEFORE the grant (remote delivery is ordered): the client fly holds
	-- the balance readout's live sum from the pre-grant value and streams the reward in
	-- with the icons — pushed from here (not inferred from the persisted claim timestamp
	-- replicating) so a rejoin shortly after a claim can't look like a fresh one.
	if claimedRE then
		claimedRE:FireClient(player, reward)
	end
	CurrencyService.AddPoints(player, reward, "Group Reward")
	local percent = math.floor(FRACTION * 100 + 0.5)
	AnnounceUI.Announce(
		player,
		("Claimed %s (%d%%)!"):format(StringUtils.FormatMoney(reward), percent),
		GroupConfig.Reward.LabelColor
	)
	ScoreUI.PostMessage(player, "Group Reward: " .. StringUtils.FormatMoney(reward), GroupConfig.Reward.MsgColor)
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
	promptJoinRE = GroupRewardNet.PromptGroupJoin
	claimedRE = GroupRewardNet.GroupRewardClaimed

	for _, inst in CollectionService:GetTagged(TagsConfig.GroupReward) do
		addPad(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.GroupReward):Connect(addPad)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.GroupReward):Connect(removePad)
end

return GroupRewardService
