--!strict
-- Any part tagged Config.Tags.UpgradeShop is an upgrade-shop trigger: touching it opens
-- (or, if already open, switches to) the shop track named by its Track attribute. Tagging
-- replaces the old "must be a child of workspace.UpgradesShop" rule, so a trigger can live
-- anywhere in the workspace.
--
-- Each trigger also gets a persistent floating readout (BillboardGui above its icon tile)
-- showing the track's short name, current level, and next price — coloured green when you
-- can afford it, red when you can't — plus a sparkle particle off the touch pad while it's
-- affordable. This lets players see what's worth buying without walking onto every pad and
-- opening the shop. Affordability/tier/price all come from GetUpgradeInfo (server-computed),
-- refreshed on balance and profile changes.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)

local UpgradeShop = {}

local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")
local ShopUI = require(PlayerScripts:WaitForChild("ShopUI"))

local Remote = RS:WaitForChild("Remote")
local GetUpgradeInfoRF = Remote:WaitForChild("GetUpgradeInfo") :: RemoteFunction
local BalanceChangedRE = Remote:WaitForChild("BalanceChanged") :: RemoteEvent
local ProfileChangedRE = Remote:WaitForChild("ProfileChanged") :: RemoteEvent

local TRACK_ATTR = "Track"

local AFFORD_COLOR = Color3.fromRGB(64, 200, 99)  -- can buy → green
local DENY_COLOR   = Color3.fromRGB(214, 74, 64)  -- can't afford → red
local MAXED_COLOR  = Color3.fromRGB(128, 128, 140) -- nothing left to buy → grey

-- Track defs live in Config.Upgrades or Config.Axes (axes are purchasable tracks too).
local function defFor(track: string): any
	return (Config.Upgrades :: any)[track] or (Config.Axes :: any)[track]
end

local function iconFor(track: string): string?
	local def = defFor(track)
	return def and def.Icon
end

-- Short label for the billboard; falls back to the full Name, then the raw track key.
local function shortFor(track: string): string
	local def = defFor(track)
	return (def and (def.Short or def.Name)) or track
end

----------------------------------------------------------------------------------
-- Per-trigger floating readout + sparkle
----------------------------------------------------------------------------------
type Display = {
	track: string,
	tierLabel: TextLabel,
	priceLabel: TextLabel,
	priceChip: Frame,
	emitter: ParticleEmitter,
	platform: BasePart,
}

local displays: { Display } = {}
local defaultColors: { [BasePart]: Color3 } = {}

-- Sparkle that plays off the touch pad while the upgrade is affordable.
local function makeEmitter(pad: BasePart): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = "AffordSparkle"
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(150, 255, 175), Color3.fromRGB(255, 232, 120))
	e.LightEmission = 0.6
	e.Lifetime = NumberRange.new(0.7, 1.2)
	e.Rate = 12
	e.Speed = NumberRange.new(2, 4)
	e.SpreadAngle = Vector2.new(18, 18)
	e.Acceleration = Vector3.new(0, 4, 0)
	e.EmissionDirection = Enum.NormalId.Top
	e.Rotation = NumberRange.new(0, 360)
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Enabled = false
	e.Parent = pad
	return e
end

-- Floating readout: short name (top), price chip (mid), level (bottom). Adorned above the
-- icon tile if there is one, else above the pad itself.
local function makeBillboard(pad: BasePart): Display
	local adornee: BasePart = pad
	local icon = pad:FindFirstChild("Icon")
	if icon and icon:IsA("BasePart") then
		adornee = icon
	end

	local bb = Instance.new("BillboardGui")
	bb.Name = "ShopInfo"
	bb.Adornee = adornee
	bb.Size = UDim2.fromOffset(170, 140)
	bb.ExtentsOffsetWorldSpace = Vector3.new(0, 3.0, 0) -- float just above the tile
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 90
	bb.Parent = adornee

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = bb

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = root

	local nameLabel = Instance.new("TextLabel")
	nameLabel.LayoutOrder = 1
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0, 30)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0.35
	nameLabel.Text = shortFor(pad:GetAttribute(TRACK_ATTR) :: string)
	nameLabel.Parent = root
	local nameConstraint = Instance.new("UITextSizeConstraint")
	nameConstraint.MaxTextSize = 26
	nameConstraint.Parent = nameLabel

	local priceChip = Instance.new("Frame")
	priceChip.LayoutOrder = 2
	priceChip.Size = UDim2.fromOffset(0, 28)
	priceChip.AutomaticSize = Enum.AutomaticSize.X
	priceChip.BackgroundColor3 = DENY_COLOR
	priceChip.Parent = root
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(1, 0)
	chipCorner.Parent = priceChip
	local chipStroke = Instance.new("UIStroke")
	chipStroke.Color = Color3.new(0, 0, 0)
	chipStroke.Transparency = 0.5
	chipStroke.Thickness = 1.5
	chipStroke.Parent = priceChip
	local chipPad = Instance.new("UIPadding")
	chipPad.PaddingLeft = UDim.new(0, 10)
	chipPad.PaddingRight = UDim.new(0, 10)
	chipPad.Parent = priceChip

	local priceLabel = Instance.new("TextLabel")
	priceLabel.BackgroundTransparency = 1
	priceLabel.Size = UDim2.fromOffset(0, 28)
	priceLabel.AutomaticSize = Enum.AutomaticSize.X
	priceLabel.Font = Enum.Font.GothamBold
	priceLabel.TextSize = 18
	priceLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	priceLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	priceLabel.TextStrokeTransparency = 0.5
	priceLabel.Text = "$0"
	priceLabel.Parent = priceChip

	local tierLabel = Instance.new("TextLabel")
	tierLabel.LayoutOrder = 3
	tierLabel.BackgroundTransparency = 1
	tierLabel.Size = UDim2.new(1, 0, 0, 18)
	tierLabel.Font = Enum.Font.GothamMedium
	tierLabel.TextScaled = true
	tierLabel.TextColor3 = Color3.fromRGB(225, 225, 235)
	tierLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	tierLabel.TextStrokeTransparency = 0.4
	tierLabel.Text = "Lv. 0"
	tierLabel.FontFace.Bold = true
	tierLabel.Parent = root
	local tierConstraint = Instance.new("UITextSizeConstraint")
	tierConstraint.MaxTextSize = 24
	tierConstraint.Parent = tierLabel

	defaultColors[pad] = pad.Color

	return {
		track = pad:GetAttribute(TRACK_ATTR) :: string,
		tierLabel = tierLabel,
		priceLabel = priceLabel,
		priceChip = priceChip,
		emitter = makeEmitter(pad),
		platform = pad,
	}
end

-- Apply a GetUpgradeInfo entry { tier, price, canAfford, maxed } to one display.
local function applyInfo(d: Display, info: any)
	d.tierLabel.Text = "Lv. " .. tostring(info.tier)
	if info.maxed then
		d.priceLabel.Text = "MAX"
		d.priceChip.BackgroundColor3 = MAXED_COLOR
		d.emitter.Enabled = false
		d.platform.Color = defaultColors[d.platform]
	else
		d.priceLabel.Text = "$" .. StringUtils.FormatShort(info.price)
		local afford = info.canAfford == true
		d.priceChip.BackgroundColor3 = if afford then AFFORD_COLOR else DENY_COLOR
		local defaultColor = defaultColors[d.platform]
		d.platform.Color = if afford then defaultColors[d.platform] else Color3.new(defaultColor.R * 0.8, defaultColor.G * 0.8, defaultColor.B * 0.8)
		d.emitter.Enabled = afford
	end
end

----------------------------------------------------------------------------------
-- Refresh (coalesced): one GetUpgradeInfo snapshot updates every display.
----------------------------------------------------------------------------------
local refreshScheduled = false

local function refreshAll()
	if #displays == 0 then return end
	local ok, snapshot = pcall(function()
		return GetUpgradeInfoRF:InvokeServer()
	end)
	if not ok or type(snapshot) ~= "table" then return end
	for _, d in displays do
		local info = (snapshot :: any)[d.track]
		if info then
			applyInfo(d, info)
		end
	end
end

-- BalanceChanged can fire many times a second (every bank), so batch bursts into one
-- round-trip every ~0.4s rather than invoking the remote per event.
local function requestRefresh()
	if refreshScheduled then return end
	refreshScheduled = true
	task.delay(0.4, function()
		refreshScheduled = false
		refreshAll()
	end)
end

----------------------------------------------------------------------------------
-- Icon painting + touch wiring (unchanged behaviour) + display setup
----------------------------------------------------------------------------------
local function applyIcon(inst: Instance, track: string)
	local icon = iconFor(track)
	if not icon then return end
	local container = inst:FindFirstChild("Icon")
	local gui = container and container:FindFirstChild("SurfaceGui")
	local label = gui and gui:FindFirstChild("TextLabel")
	if label and label:IsA("TextLabel") then
		label.Text = icon
	end
end

local function setupShopAt(inst: Instance)
	if not inst:IsA("BasePart") then return end
	local track: string? = inst:GetAttribute(TRACK_ATTR) :: string?
	if not track then return end
	applyIcon(inst, track)

	-- Floating readout + affordability sparkle (skip if already built for this part).
	if not inst:FindFirstChild("ShopInfo") then
		table.insert(displays, makeBillboard(inst))
	end

	inst.Touched:Connect(function(obj: Instance)
		if not obj:IsDescendantOf(player.Character) then return end
		if ShopUI.IsOpen() then
			ShopUI.LoadTrack(track)
			return
		end
		ShopUI.OpenShop(track)
	end)
end

function UpgradeShop.Init()
	for _, inst in CollectionService:GetTagged(Config.Tags.UpgradeShop) do
		setupShopAt(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.UpgradeShop):Connect(function(inst)
		setupShopAt(inst)
		requestRefresh()
	end)

	BalanceChangedRE.OnClientEvent:Connect(requestRefresh)
	ProfileChangedRE.OnClientEvent:Connect(requestRefresh)

	refreshAll()
end

return UpgradeShop
