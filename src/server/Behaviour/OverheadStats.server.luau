--!strict
-- Overhead stats: a BillboardGui above every player's head showing their rebirth count
-- (hidden at 0), luck rank (text colored by the rank, shared LuckRanks scale), and
-- lifetime average $/marble — the same server-authoritative figures the leaderstats
-- columns use. Built server-side so it replicates to everyone.
--
-- Refresh is throttled: banking marks the player dirty and a slow loop re-renders, so
-- high-frequency builds don't spam property replication to every client per ball.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(RS.Shared.StringUtils)
local LuckRanks = require(RS.Shared.LuckRanks)
local StatsService = require(SSS.Scripts.Modules.StatsService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)

local REFRESH_INTERVAL = 2 -- seconds between dirty re-renders (banking can be many/sec)
local MAX_DISTANCE = 120
local STUDS_ABOVE_HEAD = 2.1 -- clears the default Roblox display name

local PRESTIGE_PURPLE = Color3.fromRGB(179, 136, 255) -- matches the rebirth banner/UI violet
local MONEY_GREEN = Color3.fromRGB(96, 224, 120)      -- matches the HUD $/marble readout

type Entry = {
	gui: BillboardGui,
	prestige: TextLabel,
	luck: TextLabel,
	money: TextLabel,
}

local entries: { [number]: Entry } = {}
local dirty: { [number]: boolean } = {}

local function makeLine(parent: Instance, order: number, color: Color3): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, 0.32, 0)
	lbl.LayoutOrder = order
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.TextColor3 = color
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0.3
	lbl.Text = ""
	lbl.Parent = parent
	return lbl
end

local function refresh(player: Player)
	dirty[player.UserId] = nil
	local entry = entries[player.UserId]
	if not entry or not entry.gui.Parent then
		return
	end

	local count = PrestigeService.GetCount(player)
	entry.prestige.Visible = count > 0
	entry.prestige.Text = "🔄 Rebirth " .. tostring(count)

	local avg = StatsService.GetAvgMoneyPerBall(player)
	local rank = LuckRanks.RankFor(avg)
	entry.luck.Text = "🍀 " .. rank.Name
	LuckRanks.ApplyToLabel(entry.luck, rank) -- flat color, or top-rank text gradient
	entry.money.Text = "💰 $" .. StringUtils.FormatShort(avg) .. "/marble"
end

local function buildFor(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10) :: BasePart?
		or character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not head or not character.Parent then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "OverheadStats"
	gui.Adornee = head
	gui.Size = UDim2.new(7, 0, 2.4, 0) -- studs
	gui.StudsOffset = Vector3.new(0, STUDS_ABOVE_HEAD, 0)
	gui.MaxDistance = MAX_DISTANCE
	gui.LightInfluence = 0

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom -- lines stack down toward the head
	layout.Parent = gui

	entries[player.UserId] = {
		gui = gui,
		prestige = makeLine(gui, 1, PRESTIGE_PURPLE),
		luck = makeLine(gui, 2, Color3.new(1, 1, 1)),
		money = makeLine(gui, 3, MONEY_GREEN),
	}
	-- Parent BEFORE the initial refresh: refresh() skips unparented guis, so the old
	-- order left the labels blank until the first ball bank marked the player dirty.
	gui.Parent = head -- lives (and dies) with the character
	refresh(player)
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(buildFor, player, character)
	end)
	if player.Character then
		task.spawn(buildFor, player, player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, p in Players:GetPlayers() do
	onPlayer(p)
end
Players.PlayerRemoving:Connect(function(player)
	entries[player.UserId] = nil
	dirty[player.UserId] = nil
end)

-- Banking updates the average constantly; coalesce into one re-render per interval.
StatsService.BallBanked:Connect(function(player: Player)
	dirty[player.UserId] = true
end)
-- Prestige count changes surface within the same interval (Changed fires per bank, so it
-- rides the throttle rather than triggering an immediate re-render).
PrestigeService.Changed:Connect(function(player: Player)
	dirty[player.UserId] = true
end)

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		for _, player in Players:GetPlayers() do
			if dirty[player.UserId] then
				refresh(player)
			end
		end
	end
end)
