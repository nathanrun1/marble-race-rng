--!strict
-- Any part tagged TagsConfig.UpgradeShop is an upgrade-shop trigger: touching it opens
-- (or, if already open, switches to) the shop track named by its Track attribute. Tagging
-- replaces the old "must be a child of workspace.UpgradesShop" rule, so a trigger can live
-- anywhere in the workspace.
--
-- Each trigger also gets a persistent floating readout (BillboardGui above its icon tile)
-- showing the track's short name, current level, and next price — coloured green when you
-- can afford it, red when you can't — plus a sparkle particle off the touch pad while it's
-- affordable. This lets players see what's worth buying without walking onto every pad and
-- opening the shop. Affordability/tier/price are computed locally (shared UpgradeInfo math
-- over the tiers/balance the server pushes — see ShopUI.GetAllInfoLocal), refreshed on
-- balance and profile changes.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local TagsConfig = require(RS.Shared.Config.Tags)
local UpgradesConfig = require(RS.Shared.Config.Upgrades)
local StringUtils = require(RS.Shared.Utility.StringUtils)

local UpgradeShop = {}

local player = Players.LocalPlayer
local ShopUI = require(script.Parent.ShopUI)
local UpgradeLocks = require(script.Parent.UpgradeLocks)
local CurrencyNet = require(RS.Shared.Remote.CurrencyNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local BalanceChangedRE = CurrencyNet.BalanceChanged :: RemoteEvent
local ProfileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

local TRACK_ATTR = "Track"

local AFFORD_COLOR = Color3.fromRGB(64, 200, 99)  -- can buy → green
local DENY_COLOR   = Color3.fromRGB(214, 74, 64)  -- can't afford → red
local MAXED_COLOR  = Color3.fromRGB(128, 128, 140) -- nothing left to buy → grey
local LOCKED_COLOR = Color3.fromRGB(90, 90, 96)   -- still locked → grey/black (pad + IconFrame)
local LOCKED_ICON  = "❓"

-- Track defs live in UpgradesConfig.Tracks or UpgradesConfig.Axes (axes are purchasable tracks too).
local function defFor(track: string): any
	return (UpgradesConfig.Tracks :: any)[track] or (UpgradesConfig.Axes :: any)[track]
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
	bb: BillboardGui,      -- whole readout; hidden outright while the track's world lock is unbought
	tierLabel: TextLabel,
	priceLabel: TextLabel,
	priceChip: Frame,
	emitter: ParticleEmitter,
	platform: BasePart,
	iconLabel: TextLabel?, -- the Icon tile's emoji label, so a locked track can show "❓"
	iconFrame: BasePart?,  -- separate housing part greyed out alongside the platform when locked
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
local function makeBillboard(pad: BasePart, iconTile: BasePart?): Display
	local adornee: BasePart = iconTile or pad

	local bb = Instance.new("BillboardGui")
	bb.Name = "ShopInfo"
	bb.Adornee = adornee
	bb.Size = UDim2.fromOffset(170, 140)
	bb.ExtentsOffsetWorldSpace = Vector3.new(0, 3.0, 0) -- float just above the tile
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 90
	bb.Parent = pad -- parent to the pad so dedupe + streaming cleanup track the tagged part

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
		bb = bb,
		tierLabel = tierLabel,
		priceLabel = priceLabel,
		priceChip = priceChip,
		emitter = makeEmitter(pad),
		platform = pad,
	}
end

-- Apply a GetUpgradeInfo entry { tier, price, canAfford, maxed } to one display.
local function applyInfo(d: Display, info: any)
	if UpgradeLocks.IsTrackLocked(d.track) then
		-- Behind an unbought world lock: NO billboard at all (the group's lock pad is
		-- the one selling the unlock), pad dead (see the Touched handler), and the pad
		-- + IconFrame greyed with a "❓" icon.
		d.bb.Enabled = false
		d.emitter.Enabled = false
		d.platform.Color = LOCKED_COLOR
		if d.iconFrame then
			d.iconFrame.Color = LOCKED_COLOR
		end
		if d.iconLabel then
			d.iconLabel.Text = LOCKED_ICON
		end
		return
	end
	d.bb.Enabled = true

	d.tierLabel.Text = "Lv. " .. tostring(info.tier)
	if d.iconLabel then
		local icon = iconFor(d.track)
		if icon then
			d.iconLabel.Text = icon
		end
	end
	if info.maxed then
		d.priceLabel.Text = "MAX"
		d.priceChip.BackgroundColor3 = MAXED_COLOR
		d.emitter.Enabled = false
		d.platform.Color = defaultColors[d.platform]
		if d.iconFrame then
			d.iconFrame.Color = defaultColors[d.iconFrame]
		end
	else
		d.priceLabel.Text = "$" .. StringUtils.FormatShort(info.price)
		local afford = info.canAfford == true
		d.priceChip.BackgroundColor3 = if afford then AFFORD_COLOR else DENY_COLOR
		local defaultColor = defaultColors[d.platform]
		d.platform.Color = if afford then defaultColors[d.platform] else Color3.new(defaultColor.R * 0.8, defaultColor.G * 0.8, defaultColor.B * 0.8)
		if d.iconFrame then
			local iconDefault = defaultColors[d.iconFrame]
			d.iconFrame.Color = if afford then iconDefault else Color3.new(iconDefault.R * 0.8, iconDefault.G * 0.8, iconDefault.B * 0.8)
		end
		d.emitter.Enabled = afford
	end
end

----------------------------------------------------------------------------------
-- Refresh (coalesced): one locally-computed snapshot updates every display.
----------------------------------------------------------------------------------
local refreshScheduled = false

local function refreshAll()
	if #displays == 0 then return end
	-- Computed client-side from the tiers/balance the server pushes (ShopUI's caches) —
	-- no round trip, same numbers the server would price.
	local snapshot = ShopUI.GetAllInfoLocal()
	for _, d in displays do
		local info = (snapshot :: any)[d.track]
		if info then
			applyInfo(d, info)
		end
	end
end

-- BalanceChanged can fire many times a second (every bank), so batch bursts into one
-- repaint every ~0.4s rather than re-styling every billboard per event.
local function requestRefresh()
	if refreshScheduled then return end
	refreshScheduled = true
	task.delay(0.4, function()
		refreshScheduled = false
		refreshAll()
	end)
end

----------------------------------------------------------------------------------
-- Icon painting + touch wiring + display setup (streaming/replication-safe)
----------------------------------------------------------------------------------
-- A tagged part can replicate/stream in BEFORE its Icon child does (worse on mobile), and can
-- stream in and out repeatedly. Without guarding, that adorns the billboard to the ground (no
-- Icon tile yet), skips the icon text, and builds DUPLICATE billboards/emitters/Touched
-- connections that pile up — a real source of mobile churn/lag. So: dedupe per part, wait for
-- the Icon tile, and tear down on stream-out.
local seen: { [BasePart]: boolean } = {}
local displaysByPart: { [BasePart]: Display } = {}

-- Resolve the icon tile's surface label, waiting for the SurfaceGui/TextLabel to replicate.
-- Doesn't set its text here — applyInfo owns that (it needs to show "❓" instead of the real
-- icon while the track is still locked), this just hands back the label to write into.
local function resolveIconLabel(iconTile: Instance): TextLabel?
	local gui = iconTile:WaitForChild("SurfaceGui", 5)
	local label = gui and gui:WaitForChild("TextLabel", 5)
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

-- Resolve the (possibly late-replicating) Icon tile + IconFrame housing, build the billboard
-- adorned to the Icon tile, and wire both into the Display so applyInfo can paint/grey them.
-- Runs in its own task so the WaitForChilds don't block other parts' setup.
local function buildDisplay(inst: BasePart, track: string)
	local iconChild = inst:WaitForChild("Icon", 10)
	if not inst:IsDescendantOf(workspace) then
		return -- streamed out / destroyed while we waited
	end
	local iconTile = if iconChild and iconChild:IsA("BasePart") then iconChild else nil
	local iconLabel: TextLabel? = if iconTile then resolveIconLabel(iconTile) else nil
	if displaysByPart[inst] or inst:FindFirstChild("ShopInfo") then
		return -- already built
	end
	local display = makeBillboard(inst, iconTile)
	display.iconLabel = iconLabel

	local iconFrame = inst:FindFirstChild("IconFrame")
	if iconFrame and iconFrame:IsA("BasePart") then
		display.iconFrame = iconFrame
		defaultColors[iconFrame] = iconFrame.Color
	end

	displaysByPart[inst] = display
	table.insert(displays, display)
	requestRefresh()
end

-- Per-pad touch debounce: a single step-on fires Touched once per limb, which re-entered
-- OpenShop/LoadTrack back-to-back and double-played the open tween. Keyed by pad (not one
-- shared timer) so stepping straight from one kiosk onto another still switches tracks
-- immediately.
local TOUCH_DEBOUNCE = 0.5
local lastTouch: { [Instance]: number } = {}

local function setupShopAt(inst: Instance)
	if not inst:IsA("BasePart") or seen[inst] then
		return
	end
	local track: string? = inst:GetAttribute(TRACK_ATTR) :: string?
	if not track then
		return
	end
	seen[inst] = true

	inst.Touched:Connect(function(obj: Instance)
		if not obj:IsDescendantOf(player.Character) then return end
		if UpgradeLocks.IsTrackLocked(track) then
			return -- gated: the group's lock pad is the only way in
		end
		local now = os.clock()
		if now - (lastTouch[inst] or 0) < TOUCH_DEBOUNCE then return end
		lastTouch[inst] = now
		if ShopUI.IsOpen() then
			ShopUI.LoadTrack(track)
			return
		end
		ShopUI.OpenShop(track)
	end)

	task.spawn(buildDisplay, inst, track)
end

-- Streaming cleanup: when a tagged part leaves, drop its Display so refreshAll doesn't touch a
-- destroyed part and the list doesn't grow with stale entries.
local function teardownShopAt(inst: Instance)
	if not inst:IsA("BasePart") then return end
	seen[inst] = nil
	defaultColors[inst] = nil
	lastTouch[inst] = nil
	local d = displaysByPart[inst]
	if not d then return end
	displaysByPart[inst] = nil
	if d.iconFrame then
		defaultColors[d.iconFrame] = nil
	end
	for i, other in displays do
		if other == d then
			table.remove(displays, i)
			break
		end
	end
end

function UpgradeShop.Init()
	for _, inst in CollectionService:GetTagged(TagsConfig.UpgradeShop) do
		setupShopAt(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.UpgradeShop):Connect(setupShopAt)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.UpgradeShop):Connect(teardownShopAt)

	BalanceChangedRE.OnClientEvent:Connect(requestRefresh)
	ProfileChangedRE.OnClientEvent:Connect(requestRefresh)

	refreshAll()
end

return UpgradeShop
