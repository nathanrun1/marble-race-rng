--!strict
-- Client: renders the group-reward sign(s) and reacts to the join prompt.
--
-- Each part tagged TagsConfig.GroupReward holds Billboard.BillboardGui.TextLabel. The
-- sign reads "Claim Group Reward" (green) when the reward is claimable — i.e. the player
-- isn't in the group, OR is a member and off cooldown — and otherwise counts down the
-- time until the next claim. The server owns the actual claim + cooldown; we only read
-- the persisted last-claim time (via StatsChanged/GetStats) and the local group status.

local CollectionService = game:GetService("CollectionService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local GroupConfig = require(RS.Shared.Config.Group)
local TagsConfig = require(RS.Shared.Config.Tags)
local CurrencyFlyUI = require(script.Parent.CurrencyFlyUI)
local GroupRewardNet = require(RS.Shared.Remote.GroupRewardNet)
local StatsNet = require(RS.Shared.Remote.StatsNet)

local GroupRewardUI = {}

local player = Players.LocalPlayer
local GROUP_ID = GroupConfig.GroupId
local COOLDOWN = GroupConfig.Reward.Cooldown
local CLAIM_TEXT = "Claim Group Reward"
local CLAIM_COLOR = GroupConfig.Reward.LabelColor
local COOLDOWN_COLOR = Color3.fromRGB(200, 200, 200)
local REFRESH_INTERVAL = 30 -- seconds; re-renders the countdown

local GetStatsRF = StatsNet.GetStats :: RemoteFunction
local StatsChangedRE = StatsNet.StatsChanged :: RemoteEvent
local PromptJoinRE = GroupRewardNet.PromptGroupJoin :: RemoteEvent
local ClaimedRE = GroupRewardNet.GroupRewardClaimed :: RemoteEvent

local labels: { [Instance]: TextLabel } = {}
local lastClaim = 0

local function resolveLabel(pad: Instance): TextLabel?
	local billboard = pad:FindFirstChild("Billboard")
	local gui = billboard and billboard:FindFirstChild("BillboardGui")
	local label = gui and gui:FindFirstChild("TextLabel")
	return label :: TextLabel?
end

-- "4h 32m" / "12m" / "45s" remaining.
local function formatRemaining(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return ("%dh %dm"):format(seconds // 3600, (seconds % 3600) // 60)
	elseif seconds >= 60 then
		return ("%dm"):format(seconds // 60)
	end
	return ("%ds"):format(seconds)
end

local function render()
	local remaining = COOLDOWN - (os.time() - lastClaim)
	-- Not a member (so the touch prompts a join) OR off cooldown -> claimable.
	local claimable = (not player:IsInGroup(GROUP_ID)) or remaining <= 0
	for _, label in labels do
		if claimable then
			label.Text = CLAIM_TEXT
			label.TextColor3 = CLAIM_COLOR
		else
			label.Text = "Available in " .. formatRemaining(remaining)
			label.TextColor3 = COOLDOWN_COLOR
		end
	end
end

local function addPad(pad: Instance)
	if labels[pad] then
		return
	end
	local label = resolveLabel(pad)
	if not label then
		warn(("GroupRewardUI: no Billboard.BillboardGui.TextLabel under %s"):format(pad:GetFullName()))
		return
	end
	labels[pad] = label
	render()
end

local function removePad(pad: Instance)
	labels[pad] = nil
end

function GroupRewardUI.Init()
	local stats = GetStatsRF:InvokeServer()
	if stats and type(stats.lastGroupRewardClaim) == "number" then
		lastClaim = stats.lastGroupRewardClaim
	end

	for _, pad in CollectionService:GetTagged(TagsConfig.GroupReward) do
		addPad(pad)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.GroupReward):Connect(addPad)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.GroupReward):Connect(removePad)

	StatsChangedRE.OnClientEvent:Connect(function(s: any)
		if s and type(s.lastGroupRewardClaim) == "number" then
			lastClaim = s.lastGroupRewardClaim
		end
		render()
	end)

	-- Server confirmed a successful claim (the grant is a cash cut of the balance): celebrate.
	ClaimedRE.OnClientEvent:Connect(function()
		CurrencyFlyUI.Play("Cash")
	end)

	-- Server tells us a non-member touched a pad: open the Roblox join-group dialog. Debounced
	-- so the repeated touch fires (every ~1.5s) don't stack prompts. PromptJoinAsync yields and
	-- returns the post-prompt membership status; re-render so the sign reflects a new join.
	local promptOpen = false
	PromptJoinRE.OnClientEvent:Connect(function()
		if promptOpen then
			return
		end
		promptOpen = true
		task.spawn(function()
			local ok, err = pcall(function()
				GroupService:PromptJoinAsync(GROUP_ID)
			end)
			if not ok then
				warn("GroupRewardUI: PromptJoinAsync failed: " .. tostring(err))
			end
			promptOpen = false
			render()
		end)
	end)

	-- Tick the countdown so the sign stays roughly current without a server round-trip.
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			render()
		end
	end)
end

return GroupRewardUI
