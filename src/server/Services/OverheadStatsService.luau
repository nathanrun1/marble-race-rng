--!strict
-- Overhead stats: a BillboardGui above every player's head showing their rebirth count
-- (hidden at 0), luck rank (text colored by the rank, shared LuckRanks scale), lifetime
-- average $/marble, and the marble they're wearing (circular colour swatch in the
-- cosmetics-shop style + the skin's name in its rarity colour) — the same
-- server-authoritative figures the leaderstats columns use. Built server-side so it
-- replicates to everyone.
--
-- Refresh is throttled: banking marks the player dirty and a slow loop re-renders, so
-- high-frequency builds don't spam property replication to every client per ball.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(RS.Shared.Utility.StringUtils)
local LuckRanks = require(RS.Shared.LuckRanks)
local BallSkins = require(RS.Shared.BallSkins)
local StatsService = require(SSS.Scripts.Services.StatsService)
local PrestigeService = require(SSS.Scripts.Services.PrestigeService)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)

local OverheadStatsService = {}

local REFRESH_INTERVAL = 2 -- seconds between dirty re-renders (banking can be many/sec)
local MAX_DISTANCE = 120
-- 2.1 cleared the default Roblox display name but the bottom line still overlapped
-- usernames; +1.5 text lines on top. The gui grew 2.4 -> 3.2 studs for the marble row
-- (each line stays ~0.77 studs: 0.24 × 3.2), and since StudsOffset positions the gui's
-- CENTRE, half the growth (0.4) is added so the bottom line stays put.
local STUDS_ABOVE_HEAD = 3.65

local PRESTIGE_PURPLE = Color3.fromRGB(179, 136, 255) -- matches the rebirth banner/UI violet
local MONEY_GREEN = Color3.fromRGB(96, 224, 120) -- matches the HUD $/marble readout

type Entry = {
	gui: BillboardGui,
	prestige: TextLabel,
	luck: TextLabel,
	money: TextLabel,
	marbleSwatch: Frame,
	marbleStroke: UIStroke,
	marbleName: TextLabel,
}

local entries: { [number]: Entry } = {}
local dirty: { [number]: boolean } = {}

local LINE_HEIGHT = 0.24 -- of the 3.2-stud gui: ~0.77 studs, same as the old 0.32 × 2.4

local function makeLine(parent: Instance, order: number, color: Color3): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, 0, LINE_HEIGHT, 0)
	lbl.LayoutOrder = order
	lbl.Font = Enum.Font.FredokaOne
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

	-- Worn marble: colour swatch + name in the skin's rarity colour.
	local skin = BallSkins.Get(CosmeticService.GetEquipped(player))
	if skin then
		local rarityColor = BallSkins.RarityColor(skin.rarity)
		entry.marbleSwatch.BackgroundColor3 = skin.data.color
		entry.marbleStroke.Color = rarityColor
		entry.marbleName.Text = skin.name
		entry.marbleName.TextColor3 = rarityColor
	end
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
	gui.Size = UDim2.new(7, 0, 3.2, 0) -- studs (see STUDS_ABOVE_HEAD note)
	gui.StudsOffset = Vector3.new(0, STUDS_ABOVE_HEAD, 0)
	gui.MaxDistance = MAX_DISTANCE
	gui.LightInfluence = 0

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom -- lines stack down toward the head
	layout.Parent = gui

	-- Worn-marble row (bottom, closest to the head): circular colour swatch in the
	-- cosmetics-shop style + the skin's name; refresh() colours both by the skin.
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, LINE_HEIGHT, 0)
	row.LayoutOrder = 4
	row.Parent = gui
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.Padding = UDim.new(0, 6)
	rowLayout.Parent = row

	-- Square side derived from the FIXED gui geometry (7 × 3.2 studs, LINE_HEIGHT rows)
	-- rather than an aspect constraint — the constraint's fit modes all read the
	-- authored width (zero) and collapsed/shrank the circle.
	local sideStuds = 0.8 * LINE_HEIGHT * 3.2 -- 0.8 of the row height, in studs
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.LayoutOrder = 1
	swatch.Size = UDim2.new(sideStuds / 7, 0, 0.8, 0)
	swatch.Parent = row
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0.5, 0)
	sc.Parent = swatch
	local swatchStroke = Instance.new("UIStroke")
	swatchStroke.Thickness = 2
	swatchStroke.Parent = swatch

	local marbleName = Instance.new("TextLabel")
	marbleName.LayoutOrder = 2
	marbleName.BackgroundTransparency = 1
	marbleName.AutomaticSize = Enum.AutomaticSize.X
	marbleName.Size = UDim2.new(0, 0, 1, 0)
	marbleName.Font = Enum.Font.FredokaOne
	marbleName.TextScaled = true
	marbleName.TextStrokeColor3 = Color3.new(0, 0, 0)
	marbleName.TextStrokeTransparency = 0.3
	marbleName.Text = ""
	marbleName.Parent = row

	entries[player.UserId] = {
		gui = gui,
		prestige = makeLine(gui, 1, PRESTIGE_PURPLE),
		luck = makeLine(gui, 2, Color3.new(1, 1, 1)),
		money = makeLine(gui, 3, MONEY_GREEN),
		marbleSwatch = swatch,
		marbleStroke = swatchStroke,
		marbleName = marbleName,
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

function OverheadStatsService.Init()
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
	-- Wearing a different marble re-renders the swatch/name row within the same interval.
	CosmeticService.Changed:Connect(function(player: Player)
		dirty[player.UserId] = true
	end)
end

-- The throttled re-render loop never returns; the bootstrap spawns Start.
function OverheadStatsService.Start()
	while true do
		task.wait(REFRESH_INTERVAL)
		for _, player in Players:GetPlayers() do
			if dirty[player.UserId] then
				refresh(player)
			end
		end
	end
end

return OverheadStatsService
