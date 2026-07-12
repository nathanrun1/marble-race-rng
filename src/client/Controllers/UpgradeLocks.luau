--!strict
-- Client side of the world upgrade locks (server: UpgradeLockService). Each Model
-- tagged TagsConfig.UpgradeLock gates the upgrade tracks in its "UpgradeLock"
-- attribute behind a flat "Price" unlock, bought by walking on the model's "Pad"
-- child. This module:
--   * builds an upgrade-shop-style billboard over each Pad ("Unlock" + price chip,
--     green/red by affordability) and opens ShopUI's lock view on touch;
--   * fades the WHOLE lock model out locally once bought (parts go non-collide +
--     transparent via LocalTransparencyModifier, so nothing replicates), instantly
--     on join for an already-bought lock, tweened when bought live;
--   * restores the model when the lock comes back (prestige resets the profile's
--     unlockedLocks, which pushes ProfileChanged);
--   * answers UpgradeLocks.IsTrackLocked for UpgradeShop, whose gated kiosks grey
--     out (❓, no billboard, dead pad) until the group's lock is bought.
--
-- State is read straight from the profile pushes (profile.unlockedLocks) — the
-- server's ProfileService flags are the single source of truth.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local TagsConfig = require(RS.Shared.Config.Tags)
local UpgradesConfig = require(RS.Shared.Config.Upgrades)
local StringUtils = require(RS.Shared.Utility.StringUtils)

local UpgradeLocks = {}

local player = Players.LocalPlayer
local ShopUI = require(script.Parent.ShopUI)
local CurrencyNet = require(RS.Shared.Remote.CurrencyNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)

local BalanceChangedRE = CurrencyNet.BalanceChanged :: RemoteEvent
local ProfileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

local LOCK_ATTR = TagsConfig.UpgradeLock -- the attribute shares the tag's name
local PRICE_ATTR = "Price"

-- Display name for a gated track: upgrade tracks and axis tracks live in different
-- Config tables, and lock attributes may list either kind.
local function trackDisplayName(track: string): string
	local def = (UpgradesConfig.Tracks :: any)[track] or (UpgradesConfig.Axes :: any)[track]
	return if type(def) == "table" and type(def.Name) == "string" then def.Name else track
end

-- Matches UpgradeShop's billboard palette.
local AFFORD_COLOR = Color3.fromRGB(64, 200, 99)
local DENY_COLOR   = Color3.fromRGB(214, 74, 64)

local FADE_TIME = 0.6
local TOUCH_DEBOUNCE = 1.0

-- lock id -> bought (from the latest profile push).
local unlocked: { [string]: boolean } = {}
-- track -> every lock id listing it: a track under SEVERAL locks stays locked until
-- all of them are bought (mirrors UpgradeLockService).
local trackLocks: { [string]: { string } } = {}

type PartState = { part: BasePart, canCollide: boolean, canTouch: boolean }
type GuiState = { gui: BillboardGui, enabled: boolean } -- authored billboards inside the model
type LockState = {
	id: string,
	price: number,
	tracks: { string },
	faded: boolean?, -- nil = never applied (first apply is instant)
	parts: { PartState },
	guis: { GuiState },
	bb: BillboardGui?,
	chip: Frame?,
}
local lockStates: { [Model]: LockState } = {}

local balance = 0
local lastTouch: { [Instance]: number } = {}

function UpgradeLocks.IsTrackLocked(track: string): boolean
	local ids = trackLocks[track]
	if not ids then
		return false
	end
	for _, id in ids do
		if unlocked[id] ~= true then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------------------
-- Pad billboard (same look as UpgradeShop's kiosk readouts: name + price chip)
----------------------------------------------------------------------------------
local function makeBillboard(pad: BasePart, price: number, tracks: { string }): (BillboardGui, Frame)
	local bb = Instance.new("BillboardGui")
	bb.Name = "UnlockInfo"
	bb.Adornee = pad
	bb.Size = UDim2.fromOffset(210, 136)
	-- (7, 0, 0) in WORLD space: StudsOffsetWorldSpace follows the ADORNEE's axes
	-- (despite the name), and the pad cylinder lies on its side — local X is world-up.
	-- Plain StudsOffset (billboard/camera axes) drifts the sign sideways instead.
	bb.StudsOffsetWorldSpace = Vector3.new(7, 0, 0)
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 90
	bb.Parent = pad

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
	nameLabel.Size = UDim2.new(1, 0, 0, 38)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.TextStrokeTransparency = 0.35
	nameLabel.Text = "🔒 Unlock"
	nameLabel.Parent = root
	local nameConstraint = Instance.new("UITextSizeConstraint")
	nameConstraint.MaxTextSize = 32
	nameConstraint.Parent = nameLabel

	-- What's inside: the gated tracks by display name, so the lock reads as a goal
	-- ("Unlocks: Combo, Heat Sense…") instead of a grey mystery.
	local names = {}
	for _, track in tracks do
		table.insert(names, trackDisplayName(track))
	end
	local contents = Instance.new("TextLabel")
	contents.LayoutOrder = 2
	contents.BackgroundTransparency = 1
	contents.Size = UDim2.new(1, 0, 0, 40)
	contents.Font = Enum.Font.GothamMedium
	contents.TextSize = 16
	contents.TextWrapped = true
	contents.TextColor3 = Color3.fromRGB(235, 235, 235)
	contents.TextStrokeColor3 = Color3.new(0, 0, 0)
	contents.TextStrokeTransparency = 0.35
	contents.Text = "Unlocks: " .. table.concat(names, ", ")
	contents.Parent = root

	local priceChip = Instance.new("Frame")
	priceChip.LayoutOrder = 3
	priceChip.Size = UDim2.fromOffset(0, 34)
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
	priceLabel.Size = UDim2.fromOffset(0, 34)
	priceLabel.AutomaticSize = Enum.AutomaticSize.X
	priceLabel.Font = Enum.Font.GothamBold
	priceLabel.TextSize = 22
	priceLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	priceLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	priceLabel.TextStrokeTransparency = 0.5
	priceLabel.Text = "$" .. StringUtils.FormatShort(price)
	priceLabel.Parent = priceChip

	return bb, priceChip
end

----------------------------------------------------------------------------------
-- Fade / restore
----------------------------------------------------------------------------------
local function setFaded(model: Model, faded: boolean)
	local st = lockStates[model]
	if not st or st.faded == faded then
		return
	end
	local instant = st.faded == nil -- first application (join) snaps, no tween
	st.faded = faded
	for _, e in st.parts do
		if not e.part:IsDescendantOf(game) then
			continue
		end
		if faded then
			e.part.CanCollide = false
			e.part.CanTouch = false
			if instant then
				e.part.LocalTransparencyModifier = 1
			else
				TweenService:Create(e.part, TweenInfo.new(FADE_TIME), { LocalTransparencyModifier = 1 }):Play()
			end
		else
			-- The lock is back (prestige): restore exactly what was authored.
			e.part.CanCollide = e.canCollide
			e.part.CanTouch = e.canTouch
			e.part.LocalTransparencyModifier = 0
		end
	end
	if st.bb then
		st.bb.Enabled = not faded
	end
	-- Authored billboards inside the model (e.g. Lock/Billboard/BillboardGui) go dark
	-- with it too, restoring their authored Enabled when the lock returns.
	for _, g in st.guis do
		if g.gui:IsDescendantOf(game) then
			g.gui.Enabled = if faded then false else g.enabled
		end
	end
end

local function applyAll()
	for model, st in lockStates do
		setFaded(model, unlocked[st.id] == true)
	end
end

local function refreshChips()
	for _, st in lockStates do
		if st.chip then
			st.chip.BackgroundColor3 = if balance >= st.price then AFFORD_COLOR else DENY_COLOR
		end
	end
end

----------------------------------------------------------------------------------
-- Setup (streaming-safe: dedupe per model, Pad may replicate late)
----------------------------------------------------------------------------------
local function setupLock(inst: Instance)
	if not inst:IsA("Model") or lockStates[inst] then
		return
	end
	local id = inst:GetAttribute(LOCK_ATTR)
	local price = tonumber(inst:GetAttribute(PRICE_ATTR)) -- authored as string or number
	if type(id) ~= "string" or not price then
		warn(("UpgradeLocks: %s is missing the UpgradeLock (string) or Price attribute"):format(inst:GetFullName()))
		return
	end

	local tracks: { string } = {}
	for token in string.gmatch(id, "[%w_]+") do
		table.insert(tracks, token)
		local ids = trackLocks[token] or {}
		if not table.find(ids, id) then
			table.insert(ids, id)
		end
		trackLocks[token] = ids
	end

	local st: LockState = { id = id, price = price, tracks = tracks, parts = {}, guis = {} }

	-- Register one descendant, applying the CURRENT faded state immediately — with
	-- StreamingEnabled the model's parts arrive piecemeal, often AFTER the profile said
	-- this lock is already bought, so each late part must hide itself on arrival.
	local function adopt(d: Instance)
		if d:IsA("BasePart") then
			table.insert(st.parts, { part = d, canCollide = d.CanCollide, canTouch = d.CanTouch })
			if st.faded then
				d.CanCollide = false
				d.CanTouch = false
				d.LocalTransparencyModifier = 1
			end
		elseif d:IsA("BillboardGui") and d.Name ~= "UnlockInfo" then -- ours is handled via st.bb
			table.insert(st.guis, { gui = d, enabled = d.Enabled })
			if st.faded then
				d.Enabled = false
			end
		end
	end
	for _, d in inst:GetDescendants() do
		adopt(d)
	end
	inst.DescendantAdded:Connect(adopt)
	lockStates[inst] = st

	task.spawn(function()
		local pad = inst:WaitForChild("Pad", 10)
		if not (pad and pad:IsA("BasePart")) then
			warn(("UpgradeLocks: %s has no Pad part — lock renders but can't be bought"):format(inst:GetFullName()))
			return
		end
		local bb, chip = makeBillboard(pad, price, tracks)
		st.bb = bb
		st.chip = chip
		refreshChips()
		-- The lock may have resolved as already-bought while we waited on the Pad
		-- streaming in; setFaded would early-return (state unchanged), so apply the
		-- billboard's visibility directly.
		bb.Enabled = st.faded ~= true

		pad.Touched:Connect(function(obj: Instance)
			local char = player.Character
			if not char or not obj:IsDescendantOf(char) then
				return
			end
			if unlocked[id] == true then
				return
			end
			local now = os.clock()
			if now - (lastTouch[pad] or 0) < TOUCH_DEBOUNCE then
				return
			end
			lastTouch[pad] = now
			ShopUI.OpenLock({ id = id, price = price, tracks = tracks })
		end)
	end)

	setFaded(inst, unlocked[id] == true)
end

function UpgradeLocks.Init()
	for _, inst in CollectionService:GetTagged(TagsConfig.UpgradeLock) do
		setupLock(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.UpgradeLock):Connect(setupLock)

	ProfileChangedRE.OnClientEvent:Connect(function(profile: any)
		if type(profile) ~= "table" then
			return
		end
		unlocked = if type(profile.unlockedLocks) == "table" then profile.unlockedLocks else {}
		applyAll()
	end)

	BalanceChangedRE.OnClientEvent:Connect(function(newBalance: number)
		balance = newBalance
		refreshChips()
	end)

	-- Seed both caches once (pushes only arrive on changes; data may already be loaded).
	task.spawn(function()
		local GetProfileRF = ProfileNet.GetProfile :: RemoteFunction
		local GetBalanceRF = CurrencyNet.GetBalance :: RemoteFunction
		local okP, profile = pcall(function()
			return GetProfileRF:InvokeServer()
		end)
		if okP and type(profile) == "table" and type(profile.unlockedLocks) == "table" then
			unlocked = profile.unlockedLocks
			applyAll()
		end
		local okB, bal = pcall(function()
			return GetBalanceRF:InvokeServer()
		end)
		if okB and type(bal) == "number" then
			balance = bal
			refreshChips()
		end
	end)
end

return UpgradeLocks
