--!strict
-- Crate-opening reveal (Marble Boxes): a slot-style horizontal reel of skin cells — same
-- mechanism as DailyRewardUI's spin — that decelerates onto the skin the server already
-- rolled. Filler cells are drawn from the CRATE'S OWN rarity weights (Config.Crates
-- Boxes[].Weights / Free.Weights), so the strip honestly previews what that crate can
-- drop; locked-vs-owned isn't hidden (this is a reveal, not the index). Each cell that
-- crosses the pointer plays the Bounce tick (roulette-wheel style).
--
--   CrateRollUI.Play(weights, result)  -- YIELDS until the reel lands + lingers; the
--                                         caller then does its own banner/celebration.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local AutoScale = require(RS.Shared.AutoScale)
local Config = require(RS.Shared.Config)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local StringUtils = require(RS.Shared.StringUtils)
local SoundService = require(RS.Shared.SoundService)

local CrateRollUI = {}

local player = Players.LocalPlayer

local BG = Color3.fromRGB(22, 18, 30)
local GOLD = Color3.fromRGB(255, 205, 70)
local CELL_BG = Color3.fromRGB(40, 34, 54)
local TEXT_LIGHT = Color3.fromRGB(240, 238, 248)

local RESULT_LINGER = 1.0
local TICK_VOLUME = 0.5

type RollResult = {
	ok: boolean,
	skinId: string?,
	rarity: number?,
	copies: number?,
	star: number?,
	isNew: boolean?,
}

-- Skins grouped by rarity (filler picks: rarity by crate weights, then uniform skin).
local skinsByRarity: { [number]: { string } } = {}
for id, skin in BallSkins.GetAll() do
	local list = skinsByRarity[skin.rarity]
	if not list then
		list = {}
		skinsByRarity[skin.rarity] = list
	end
	table.insert(list, id)
end

local function rollFillerSkin(weights: { number }): string
	local total = 0
	for rarity, w in weights do
		if skinsByRarity[rarity] then
			total += w
		end
	end
	local pick = math.random() * total
	for rarity, w in weights do
		if skinsByRarity[rarity] then
			pick -= w
			if pick <= 0 then
				local pool = skinsByRarity[rarity]
				return pool[math.random(#pool)]
			end
		end
	end
	local pool = skinsByRarity[1] or (skinsByRarity :: any)[next(skinsByRarity)]
	return pool[math.random(#pool)]
end

----------------------------------------------------------------
-- UI (built once, reused per roll)
----------------------------------------------------------------
local screenGui: ScreenGui? = nil
local reelViewport: Frame
local reelContent: Frame
local reelViewportWidth = 0

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

-- One reel cell: rarity-colored card with the skin's swatch circle, name, rarity, and
-- the loadout bonus it grants (`copies` sizes the bonus — fillers preview ★1, the result
-- cell shows the actual post-roll value).
local function makeCell(parent: Instance, layoutOrder: number, skinId: string, badge: string?, copies: number?)
	local R = Config.Crates.Reel
	local skin = BallSkins.Get(skinId)
	if not skin then
		return
	end
	local rarityColor = BallSkins.RarityColor(skin.rarity)

	local cell = Instance.new("Frame")
	cell.Name = "Cell"
	cell.Size = UDim2.fromOffset(R.CellSize.X, R.CellSize.Y)
	cell.BackgroundColor3 = CELL_BG:Lerp(rarityColor, 0.12)
	cell.BorderSizePixel = 0
	cell.LayoutOrder = layoutOrder
	cell.Parent = parent
	corner(cell, 12)
	local stroke = Instance.new("UIStroke")
	stroke.Color = rarityColor
	stroke.Thickness = 2
	stroke.Parent = cell

	local swatch = Instance.new("Frame")
	swatch.Size = UDim2.fromScale(0.38, 0.38)
	swatch.Position = UDim2.fromScale(0.5, 0.06)
	swatch.AnchorPoint = Vector2.new(0.5, 0)
	swatch.BackgroundColor3 = skin.data.color
	swatch.Parent = cell
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = swatch
	local scorner = Instance.new("UICorner")
	scorner.CornerRadius = UDim.new(0.5, 0)
	scorner.Parent = swatch
	local sstroke = Instance.new("UIStroke")
	sstroke.Color = rarityColor
	sstroke.Thickness = 2
	sstroke.Parent = swatch

	local function line(y: number, h: number, text: string, color: Color3)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, -10, h, 0)
		l.Position = UDim2.fromScale(0.5, y)
		l.AnchorPoint = Vector2.new(0.5, 0)
		l.Font = Enum.Font.FredokaOne
		l.TextScaled = true
		l.TextColor3 = color
		l.Text = text
		l.Parent = cell
	end

	line(0.47, 0.14, skin.name, TEXT_LIGHT)
	line(0.61, 0.11, BallSkins.RarityName(skin.rarity), rarityColor)
	-- The loadout bonus this skin would pay from a slot (star-scaled by `copies`).
	local bonus = CosmeticBonus.SkinBonus(skinId, copies or 1)
	line(0.72, 0.11, ("+%s%% bonus"):format(StringUtils.FormatShort(bonus * 100)), Color3.fromRGB(120, 230, 150))
	if badge then
		line(0.84, 0.12, badge, GOLD)
	end
end

local function createUI()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local R = Config.Crates.Reel
	reelViewportWidth = R.CellSize.X * 3 + R.CellPadding * 2

	local gui = Instance.new("ScreenGui")
	gui.Name = "CrateRollUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 46 -- above the daily-reward modal, below CurrencyFly (60)
	gui.Enabled = false
	gui.Parent = playerGui
	screenGui = gui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.ZIndex = 1
	dim.Parent = gui

	reelViewport = Instance.new("Frame")
	reelViewport.Name = "ReelViewport"
	reelViewport.AnchorPoint = Vector2.new(0.5, 0.5)
	reelViewport.Position = UDim2.fromScale(0.5, 0.5)
	reelViewport.Size = UDim2.fromOffset(reelViewportWidth, R.CellSize.Y + 24)
	reelViewport.BackgroundColor3 = BG
	reelViewport.BorderSizePixel = 0
	reelViewport.ClipsDescendants = true
	reelViewport.ZIndex = 2
	reelViewport.Parent = gui
	corner(reelViewport, 18)
	-- Offset-sized (the spin math runs in raw cell coords), so viewport scaling comes
	-- from AutoScale's UIScale — same treatment as the daily-reward reel.
	AutoScale.Apply(reelViewport)
	local rvs = Instance.new("UIStroke")
	rvs.Color = GOLD
	rvs.Thickness = 3
	rvs.Parent = reelViewport

	local pointer = Instance.new("Frame")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 0)
	pointer.Position = UDim2.fromScale(0.5, 0)
	pointer.Size = UDim2.new(0, 4, 1, 0)
	pointer.BackgroundColor3 = GOLD
	pointer.BorderSizePixel = 0
	pointer.ZIndex = 3
	pointer.Parent = reelViewport

	reelContent = Instance.new("Frame")
	reelContent.Name = "ReelContent"
	reelContent.AnchorPoint = Vector2.new(0, 0.5)
	reelContent.Position = UDim2.new(0, 0, 0.5, 0)
	reelContent.AutomaticSize = Enum.AutomaticSize.X
	reelContent.Size = UDim2.fromOffset(0, R.CellSize.Y)
	reelContent.BackgroundTransparency = 1
	reelContent.ZIndex = 2
	reelContent.Parent = reelViewport
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, R.CellPadding)
	layout.Parent = reelContent
end

----------------------------------------------------------------
-- Spin
----------------------------------------------------------------
local spinning = false

-- Whether a reveal is currently running (TutorialService holds the loadout tutorial
-- until the reel has finished).
function CrateRollUI.IsSpinning(): boolean
	return spinning
end

-- Play the reel for a server-rolled result. Yields until the reel has landed and
-- lingered; no-ops (returns immediately) if a spin is already running or the result
-- has no skin.
function CrateRollUI.Play(weights: { number }, result: RollResult)
	if spinning or not result.ok or not result.skinId then
		return
	end
	spinning = true
	if not screenGui then
		createUI()
	end
	local gui = screenGui :: ScreenGui
	local R = Config.Crates.Reel

	for _, c in reelContent:GetChildren() do
		if c.Name == "Cell" then
			c:Destroy()
		end
	end

	local total = R.FillerCells + 1
	local landIndex = R.FillerCells - R.CellsAfterResult + 1
	for i = 1, total do
		if i == landIndex then
			local badge = if result.isNew then "NEW!" else "★" .. tostring(result.star or CosmeticBonus.StarOf(result.copies or 1))
			makeCell(reelContent, i, result.skinId :: string, badge, result.copies)
		else
			makeCell(reelContent, i, rollFillerSkin(weights), nil, nil)
		end
	end

	reelContent.Position = UDim2.new(0, 0, 0.5, 0)
	gui.Enabled = true

	-- Land offset: center the result cell under the pointer.
	local stride = R.CellSize.X + R.CellPadding
	local cellCenterX = (landIndex - 1) * stride + R.CellSize.X / 2
	local targetX = -(cellCenterX - reelViewportWidth / 2)

	-- Roulette tick: one Bounce per cell-boundary the strip crosses. SoundService pools
	-- per sound id, so rapid early ticks overlap instead of restarting each other.
	local startX = reelContent.Position.X.Offset
	local lastTicks = 0
	local tickConn = RunService.Heartbeat:Connect(function()
		local ticks = math.floor((startX - reelContent.Position.X.Offset) / stride)
		if ticks > lastTicks then
			lastTicks = ticks
			SoundService.Play({ soundId = Config.Sounds.Bounce, volume = TICK_VOLUME, jitter = 0.04 })
		end
	end)

	local tween = TweenService:Create(
		reelContent,
		TweenInfo.new(R.SpinTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, targetX, 0.5, 0) }
	)
	local done = Instance.new("BindableEvent")
	tween.Completed:Once(function()
		done:Fire()
	end)
	tween:Play()
	done.Event:Wait()
	done:Destroy()
	tickConn:Disconnect()

	task.wait(RESULT_LINGER)
	gui.Enabled = false
	spinning = false
end

return CrateRollUI
