--!strict
-- Client tutorials. Runs TWO sequences through one shared box/highlight/arrow runner, each
-- persisted separately so it plays once per player ever (StatsService):
--   main     — TutorialConfig.Steps, on first join.
--   cosmetic — TutorialConfig.Cosmetic.Steps, the first time the Diamonds balance reaches
--              TutorialConfig.Cosmetic.DiamondTrigger (never before main is over).
-- Steps advance AUTOMATICALLY as each step's own `complete` trigger fires
-- (LaunchBalls/BuyUpgrade/CollectCoin/BuySkin, ...) — no Next button — but a Skip button
-- always lets the player bail out of the running sequence early. Steps may also,
-- orthogonally, show a physical world-arrow `arrow` target (WorldArrow) pointing the player
-- somewhere. Both arrow and completion are resolved through small per-Kind registries
-- (ARROW_RESOLVERS / COMPLETION_STARTERS) below, so adding a new Kind is one function + one
-- registry entry — nothing else in the stepping/rendering logic changes. See TutorialConfig
-- for the full step-shape contract.
--
-- Presentation is otherwise unchanged from the original text-box tutorial: a medium-large
-- message in a box, optionally dimming the whole screen except a highlighted rect (a
-- four-frame mask tiling around the clear rect, with a ring tracing the hole), and an
-- optional scripted camera shot — all cross-fade/tween smoothly into the next step.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local AttributesConfig = require(RS.Shared.Config.Attributes)
local TagsConfig = require(RS.Shared.Config.Tags)
local TutorialConfig = require(RS.Shared.Config.Tutorial)
local UpgradesConfig = require(RS.Shared.Config.Upgrades)
local AutoScale = require(RS.Shared.Utility.AutoScale)
local Signal = require(RS.Shared.Utility.Signal)

local TutorialController = {}

local player = Players.LocalPlayer
local CameraController = require(script.Parent.CameraController)
local WorldArrow = require(script.Parent.WorldArrow)
local CoinPickups = require(script.Parent.CoinPickups)
local BallTuningUI = require(script.Parent.BallTuningUI)
local LoadoutUI = require(script.Parent.LoadoutUI)
local CrateRollUI = require(script.Parent.CrateRollUI)
local PlaytimeUI = require(script.Parent.PlaytimeUI)
local QuestUI = require(script.Parent.QuestUI)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticsNet = require(RS.Shared.Remote.CosmeticsNet)
local CurrencyNet = require(RS.Shared.Remote.CurrencyNet)
local DataNet = require(RS.Shared.Remote.DataNet)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)
local StatsNet = require(RS.Shared.Remote.StatsNet)

-- Matches UpgradeShop.luau's own (bare, not-in-AttributesConfig) TRACK_ATTR local constant —
-- the attribute a kiosk part stores its upgrade track under. Kept identical here so an
-- "UpgradeShopTrack" arrow finds the exact kiosks UpgradeShop.luau opens on touch.
local TRACK_ATTRIBUTE = "Track"

-- Two ways to define the spot:
--   Element = "MainGui.LeftBar.TriggerQuad.LoadoutTriggerHost" — surround a live
--     GuiObject (dot path under PlayerGui; each segment falls back to a recursive
--     find, so intermediate row/container frames can be skipped) plus Padding px.
--     Resolution/inset-proof: the rect is read from AbsolutePosition/AbsoluteSize.
--   Position/Size UDim2s — hand-authored rect. Anchor picks which point of the rect
--     Position refers to (like GuiObject.AnchorPoint; default centre); RespectInset
--     = true shifts by the topbar GUI inset for coords copied from inset-respecting
--     ScreenGuis (default false = raw screen coords).
-- HighlightDim overrides TutorialConfig.HighlightDim either way.
type Highlight = {
	Element: string?,
	Padding: number?,
	Position: UDim2?,
	Size: UDim2?,
	Anchor: Vector2?,
	RespectInset: boolean?,
	HighlightDim: number?,
}
type Shot = { Position: Vector3, Orientation: Vector3, FieldOfView: number? }

-- Both are open-ended tagged unions: { Kind = "SomeKind", ...Kind-specific fields }. Kept as
-- `any`-payload records (not a closed union type) so TutorialConfig can add new Kinds without
-- touching this module's types — only ARROW_RESOLVERS/COMPLETION_STARTERS need a new entry.
type ArrowSpec = { Kind: string, [string]: any }
type CompletionSpec = { Kind: string, [string]: any }

type Step = {
	text: string,
	boxPosition: UDim2?,
	highlight: Highlight?,
	camera: Shot?,
	arrow: ArrowSpec?,
	complete: CompletionSpec,
}

local TRANSITION = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HALF = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HALF_TIME = 0.2

local DIM = TutorialConfig.HighlightDim      -- dark-panel BackgroundTransparency when dimming
local DEFAULT_BOX_POS = UDim2.fromScale(0.5, 0.72)
local TEXT_STROKE = 0.4

local steps: { Step } = (TutorialConfig.Steps :: any) :: { Step }
local cosmeticSteps: { Step } = (TutorialConfig.Cosmetic.Steps :: any) :: { Step }
local tuningSteps: { Step } = (TutorialConfig.Tuning.Steps :: any) :: { Step }
local loadoutSteps: { Step } = (((TutorialConfig :: any).Loadout and (TutorialConfig :: any).Loadout.Steps) or {}) :: { Step }

-- The sequence the runner is currently playing. finish() reports activeId to the server
-- ("main" / "cosmetic" / "tuning") so the right completed-flag is persisted.
local activeSteps: { Step } = steps
local activeId = "main"
-- True from startSequence until finish()'s teardown completes — the later tutorials'
-- watchers queue behind it so two sequences never fight over the shared UI.
local sequenceRunning = false

-- UI handles (built in createUI).
local screenGui: ScreenGui
local maskFrames: { Frame } = {} -- [1]=top [2]=bottom [3]=left [4]=right
local ring: Frame
local box: Frame
local label: TextLabel
local skipBtn: TextButton

local currentIndex = 0
local stepToken = 0   -- guards the delayed text-swap against rapid advances
local dimVisible = false
local finished = false
local completionCleanup: (() -> ())? = nil -- disconnects the current step's completion listener(s)

-- Forward-declared: applyStep's completion callback calls advance(), but advance() itself
-- calls applyStep() for the next index — same mutual-forward-decl shape as ProfileService's
-- reclampLoadout / QuestUI's openPanel elsewhere in this codebase.
local advance: () -> ()

-- "Over" = this player will see no (more) tutorial this session: it was already completed on
-- a previous visit, no steps are configured, or they just finished/skipped it. Other
-- join-time popups (DailyRewardUI) wait on this so two centered prompts never stack.
local overEvent = Signal.new()
local isOver = false

local function markOver()
	if isOver then
		return
	end
	isOver = true
	overEvent:Fire()
end

-- Yields until the tutorial is over (returns immediately if it already is).
function TutorialController.WaitUntilOver()
	if not isOver then
		overEvent:Wait()
	end
end

--------------------------------------------------------------------------------
-- UI construction
--------------------------------------------------------------------------------

local function makePanel(name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = 1
	f.Parent = screenGui
	return f
end

local function createUI(playerGui: PlayerGui)
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TutorialUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 50 -- above the HUD
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	table.clear(maskFrames) -- rebuilt per run (the cosmetic sequence re-creates the whole UI)
	for _, n in { "MaskTop", "MaskBottom", "MaskLeft", "MaskRight" } do
		table.insert(maskFrames, makePanel(n))
	end

	-- Ring tracing the highlighted spot.
	ring = Instance.new("Frame")
	ring.Name = "HighlightRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 2
	ring.Parent = screenGui
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0, 10)
	ringCorner.Parent = ring
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 3
	stroke.Transparency = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = ring

	-- Message box (authored at 1080p, AutoScaled down on smaller screens).
	box = Instance.new("Frame")
	box.Name = "MessageBox"
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = DEFAULT_BOX_POS
	box.Size = UDim2.fromOffset(480, 110)
	box.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	box.BackgroundTransparency = 1
	box.ZIndex = 5
	box.Parent = screenGui
	local boxCorner = Instance.new("UICorner")
	boxCorner.CornerRadius = UDim.new(0, 16)
	boxCorner.Parent = box
	local boxStroke = Instance.new("UIStroke")
	boxStroke.Color = Color3.fromRGB(90, 100, 130)
	boxStroke.Thickness = 2
	boxStroke.Parent = box

	label = Instance.new("TextLabel")
	label.Name = "Message"
	-- Fills the whole box (minus edge padding) so there's no dead band under the text; the
	-- UITextSizeConstraint below still caps how big TextScaled lets it get.
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.new(1, -60, 1, -36)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 1
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 1
	label.TextScaled = true
	label.TextWrapped = true
	label.Font = Enum.Font.GothamMedium
	label.ZIndex = 6
	label.Parent = box
	local sizeConstraint = Instance.new("UITextSizeConstraint")
	sizeConstraint.MaxTextSize = 26 -- proportioned to the compact box
	sizeConstraint.Parent = label

	-- Skip: bails out of the whole sequence early (no per-step Next — steps auto-advance —
	-- but the player can always leave). Tucked in the box's corner so it doesn't compete with
	-- the message itself.
	skipBtn = Instance.new("TextButton")
	skipBtn.Name = "Skip"
	skipBtn.AnchorPoint = Vector2.new(1, 0)
	skipBtn.Position = UDim2.new(1, -10, 0, 8)
	skipBtn.Size = UDim2.fromOffset(60, 24)
	skipBtn.BackgroundColor3 = Color3.fromRGB(70, 74, 86)
	skipBtn.AutoButtonColor = true
	skipBtn.Text = "Skip"
	skipBtn.TextColor3 = Color3.new(1, 1, 1)
	skipBtn.TextScaled = true
	skipBtn.Font = Enum.Font.GothamBold
	skipBtn.ZIndex = 6
	skipBtn.Parent = box
	local skipCorner = Instance.new("UICorner")
	skipCorner.CornerRadius = UDim.new(0, 8)
	skipCorner.Parent = skipBtn
	local skipPad = Instance.new("UIPadding")
	skipPad.PaddingTop = UDim.new(0, 6)
	skipPad.PaddingBottom = UDim.new(0, 6)
	skipPad.Parent = skipBtn

	AutoScale.Apply(box)
end

--------------------------------------------------------------------------------
-- Step application (smooth transitions) — dim/highlight/camera logic unchanged
--------------------------------------------------------------------------------

-- Walk a dot path under PlayerGui to a GuiObject. Each segment tries a direct child
-- first, then a recursive find — so container frames (TriggerQuad's rows, etc.) don't
-- have to appear in the path.
local function resolveElement(path: string): GuiObject?
	local inst: Instance? = player:FindFirstChildOfClass("PlayerGui")
	for token in string.gmatch(path, "[^%.]+") do
		if not inst then
			return nil
		end
		inst = inst:FindFirstChild(token) or inst:FindFirstChild(token, true)
	end
	return if inst and inst:IsA("GuiObject") then inst else nil
end

-- Resolve a highlight to a CENTRE Scale rect (cx, cy, w, h, all 0..1 of the screen).
--
-- Element form: the rect is the live GuiObject's AbsolutePosition/AbsoluteSize plus
-- Padding px (scaled by AutoScale) — inset/resolution/scale all come along for free.
-- AbsolutePosition's origin is the inset-safe corner, and this gui ignores the inset
-- (full-screen mask), so the inset is added back to land in full-screen coords.
--
-- Position/Size form: the UDim2s resolve like any screen UDim2 (Scale × viewport)
-- except the Offset is multiplied by the AutoScale factor, so a 1080p-authored offset
-- pos/size lines up with AutoScaled UI on any resolution. (Pure-Scale highlights are
-- unaffected: offset 0.)
local function resolveRect(h: Highlight): (number, number, number, number)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local f = AutoScale.GetScale()

	if h.Element then
		local el = resolveElement(h.Element)
		if el then
			local inset = GuiService:GetGuiInset()
			local pad = (h.Padding or 10) * f
			local pos, size = el.AbsolutePosition, el.AbsoluteSize
			local cx = (pos.X + size.X / 2 + inset.X) / vp.X
			local cy = (pos.Y + size.Y / 2 + inset.Y) / vp.Y
			return cx, cy, (size.X + pad * 2) / vp.X, (size.Y + pad * 2) / vp.Y
		end
		warn("TutorialController: highlight element not found: " .. h.Element)
		return 0.5, 0.5, 0, 0
	end

	local hPos = h.Position :: UDim2
	local hSize = h.Size :: UDim2
	local w = (vp.X * hSize.X.Scale + hSize.X.Offset * f) / vp.X
	local ht = (vp.Y * hSize.Y.Scale + hSize.Y.Offset * f) / vp.Y
	-- This gui ignores the topbar inset (the dim mask must cover the WHOLE screen), so by
	-- default authored coords are raw screen coords. RespectInset = true shifts the rect
	-- by the inset instead — for spots whose coords were copied from an inset-respecting
	-- ScreenGui, so they land where that UI actually renders.
	local inset = if h.RespectInset then GuiService:GetGuiInset() else Vector2.zero
	-- Position marks the rect's Anchor point (default centre); shift to the centre.
	local a = h.Anchor or Vector2.new(0.5, 0.5)
	local cx = (vp.X * hPos.X.Scale + hPos.X.Offset * f + inset.X) / vp.X + (0.5 - a.X) * w
	local cy = (vp.Y * hPos.Y.Scale + hPos.Y.Offset * f + inset.Y) / vp.Y + (0.5 - a.Y) * ht
	return cx, cy, w, ht
end

-- Lay the four mask panels around `h`, tweening their geometry unless `instant` (used when
-- the dim wasn't visible, so it doesn't visibly sweep in from a stale layout).
local function layoutMask(h: Highlight, instant: boolean)
	local cx, cy, w, ht = resolveRect(h)
	local left = math.clamp(cx - w / 2, 0, 1)
	local right = math.clamp(cx + w / 2, 0, 1)
	local top = math.clamp(cy - ht / 2, 0, 1)
	local bottom = math.clamp(cy + ht / 2, 0, 1)

	local geom = {
		[1] = { UDim2.fromScale(0, 0), UDim2.fromScale(1, top) },                        -- top
		[2] = { UDim2.fromScale(0, bottom), UDim2.fromScale(1, 1 - bottom) },             -- bottom
		[3] = { UDim2.fromScale(0, top), UDim2.fromScale(left, bottom - top) },           -- left
		[4] = { UDim2.fromScale(right, top), UDim2.fromScale(1 - right, bottom - top) },  -- right
	}
	for i, frame in maskFrames do
		local pos, size = geom[i][1], geom[i][2]
		if instant then
			frame.Position, frame.Size = pos, size
		else
			TweenService:Create(frame, TRANSITION, { Position = pos, Size = size }):Play()
		end
	end

	local ringPos = UDim2.fromScale(cx, cy)
	local ringSize = UDim2.fromScale(right - left, bottom - top)
	if instant then
		ring.Position, ring.Size = ringPos, ringSize
	else
		TweenService:Create(ring, TRANSITION, { Position = ringPos, Size = ringSize }):Play()
	end
end

local function applyHighlight(h: Highlight?)
	local stroke = ring:FindFirstChild("Stroke") :: UIStroke
	if h then
		local dim = h.HighlightDim or DIM -- per-step override (0 = fully black surround)
		layoutMask(h, not dimVisible) -- snap geometry if we're fading in from nothing
		for _, frame in maskFrames do
			TweenService:Create(frame, TRANSITION, { BackgroundTransparency = dim }):Play()
		end
		TweenService:Create(stroke, TRANSITION, { Transparency = 0 }):Play()
		dimVisible = true
	else
		for _, frame in maskFrames do
			TweenService:Create(frame, TRANSITION, { BackgroundTransparency = 1 }):Play()
		end
		TweenService:Create(stroke, TRANSITION, { Transparency = 1 }):Play()
		dimVisible = false
	end
end

--------------------------------------------------------------------------------
-- Arrow target resolvers: Kind -> (spec) -> a live (() -> Vector3?) getter for WorldArrow.
--------------------------------------------------------------------------------

-- Points at the world kiosk (UpgradeShop-tagged part/model) whose Track attribute matches.
local function resolveUpgradeShopTrack(spec: ArrowSpec): () -> Vector3?
	local track = spec.Track
	return function(): Vector3?
		for _, pad in CollectionService:GetTagged(TagsConfig.UpgradeShop) do
			if pad:GetAttribute(TRACK_ATTRIBUTE) == track then
				if pad:IsA("BasePart") then
					return pad.Position
				elseif pad:IsA("PVInstance") then
					return pad:GetPivot().Position
				end
			end
		end
		return nil
	end
end

-- Points at the player's nearest active coin, force-spawning one (once) if none are active.
local function resolveNearestCoin(_spec: ArrowSpec): () -> Vector3?
	local requestedSpawn = false
	return function(): Vector3?
		local char = player.Character
		local root = char and (char:FindFirstChild("HumanoidRootPart") :: BasePart?)
		if not root then
			return nil
		end
		local pos = CoinPickups.GetNearestActivePosition(root.Position)
		if not pos and not requestedSpawn then
			requestedSpawn = true
			CoinPickups.RequestForceSpawn()
		end
		return pos
	end
end

-- Points at the cosmetics shop: the part carrying a CosmeticsGui-tagged SurfaceGui (via its
-- Adornee or parent part — the same tag CosmeticsShop.luau builds its storefront into).
local function resolveCosmeticsShop(_spec: ArrowSpec): () -> Vector3?
	return function(): Vector3?
		for _, tagged in CollectionService:GetTagged(TagsConfig.CosmeticsGui) do
			local part: Instance? = if tagged:IsA("SurfaceGui") then (tagged.Adornee or tagged.Parent) else tagged
			if part and part:IsA("BasePart") then
				return part.Position
			end
		end
		return nil
	end
end

-- Points at the free-marble-box claim pad (the first part tagged FreeCratePad).
local function resolveFreeCratePad(_spec: ArrowSpec): () -> Vector3?
	return function(): Vector3?
		for _, pad in CollectionService:GetTagged(TagsConfig.FreeCratePad) do
			if pad:IsA("BasePart") then
				return pad.Position
			end
		end
		return nil
	end
end

local ARROW_RESOLVERS: { [string]: (ArrowSpec) -> () -> Vector3? } = {
	UpgradeShopTrack = resolveUpgradeShopTrack,
	NearestCoin = resolveNearestCoin,
	CosmeticsShop = resolveCosmeticsShop,
	FreeCratePad = resolveFreeCratePad,
}

--------------------------------------------------------------------------------
-- Completion starters: Kind -> (spec, onComplete) -> cleanup(). Each returns a function that
-- disconnects whatever it hooked; TutorialController calls it when leaving the step (advance,
-- skip-to-finish, or teardown) so listeners never outlive their step.
--------------------------------------------------------------------------------

-- N of the LOCAL player's own marbles actually spawning (TagsConfig.Ball + OwnerUserId
-- attribute — both replicate normally, so this can't be spoofed and needs no new remote).
local function startLaunchBalls(spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local need = spec.Count :: number
	local count = 0
	local conn = CollectionService:GetInstanceAddedSignal(TagsConfig.Ball):Connect(function(ball: Instance)
		if ball:GetAttribute(AttributesConfig.OwnerUserId) == player.UserId then
			count += 1
			if count >= need then
				onComplete()
			end
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- The named track's upgrade tier rising above whatever it was when the step started (diff
-- against ProfileChanged, the same pattern BallLaunchUI uses for MaxBet tier changes).
local function startBuyUpgrade(spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local track = spec.Track :: string
	local getProfileRF = ProfileNet.GetProfile :: RemoteFunction
	local profileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

	local function tierOf(profile: any): number
		if type(profile) == "table" and type(profile.upgrades) == "table" then
			return profile.upgrades[track] or 0
		end
		return 0
	end

	local ok, profile = pcall(function()
		return getProfileRF:InvokeServer()
	end)
	local baseline = if ok then tierOf(profile) else 0

	local conn = profileChangedRE.OnClientEvent:Connect(function(p: any)
		if tierOf(p) > baseline then
			onComplete()
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- Any coin claim (CoinPickups.Claimed) — deliberately not tied to which coin.
local function startCollectCoin(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local conn = CoinPickups.Claimed:Connect(onComplete)
	return function()
		conn:Disconnect()
	end
end

-- The ball-tuning menu being opened (BallTuningUI.MenuOpened); completes immediately —
-- deferred, applyStep is still mid-setup — if it's already open when the step starts.
local function startOpenTuningMenu(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	if BallTuningUI.IsMenuOpen() then
		task.defer(onComplete)
		return function() end
	end
	local conn = BallTuningUI.MenuOpened:Connect(onComplete)
	return function()
		conn:Disconnect()
	end
end

-- The loadout panel being opened (LoadoutUI.Opened); completes immediately (deferred)
-- if it's already open when the step starts — same shape as OpenTuningMenu.
local function startOpenLoadout(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	if LoadoutUI.IsOpen() then
		task.defer(onComplete)
		return function() end
	end
	local conn = LoadoutUI.Opened:Connect(onComplete)
	return function()
		conn:Disconnect()
	end
end

-- Any Marble Box opening (CosmeticChanged): the TOTAL copy count rising covers dupe
-- rolls too, which owned-count misses (a dupe adds no new owned id). Baselined like
-- BuySkin below so pre-existing copies don't complete the step instantly.
local function startRollCrate(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
	local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction

	local function copiesSum(info: any): number
		local n = 0
		if type(info) == "table" and type(info.copies) == "table" then
			for _, c in info.copies do
				if type(c) == "number" then
					n += c
				end
			end
		end
		return n
	end

	local baseline = math.huge
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		baseline = if ok then copiesSum(info) else 1
	end)

	local conn = changedRE.OnClientEvent:Connect(function(info: any)
		if copiesSum(info) > baseline then
			onComplete()
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- The Luck upgrade tier rising past the step-start baseline (ProfileChanged) — the
-- cosmetic tutorial's target since Luck replaced the purchasable crates in the shop.
local function startBuyLuck(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local getProfileRF = ProfileNet.GetProfile :: RemoteFunction
	local profileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

	local function luckTier(profile: any): number
		if type(profile) == "table" and type(profile.upgrades) == "table" and type(profile.upgrades.Luck) == "number" then
			return profile.upgrades.Luck
		end
		return 0
	end

	local baseline = math.huge
	task.spawn(function()
		local ok, profile = pcall(function()
			return getProfileRF:InvokeServer()
		end)
		baseline = if ok then luckTier(profile) else 0
	end)

	local conn = profileChangedRE.OnClientEvent:Connect(function(profile: any)
		if luckTier(profile) > baseline then
			onComplete()
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- A skin landing in any bonus-loadout slot (CosmeticChanged loadout fill count rising
-- past the step-start baseline), OR any EQUIP BEST press — the press completes even
-- when the loadout is already optimal and nothing changes.
local function startEquipLoadoutSlot(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
	local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction

	local function filledSlots(info: any): number
		local n = 0
		if type(info) == "table" and type(info.loadout) == "table" then
			for _ in info.loadout do
				n += 1
			end
		end
		return n
	end

	local baseline = math.huge
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		baseline = if ok then filledSlots(info) else 0
	end)

	local conn = changedRE.OnClientEvent:Connect(function(info: any)
		if filledSlots(info) > baseline then
			onComplete()
		end
	end)
	local pressConn = LoadoutUI.EquipBestPressed:Connect(onComplete)
	return function()
		conn:Disconnect()
		pressConn:Disconnect()
	end
end

-- Any skin being ADDED to the owned set (CosmeticChanged) — bought from the shop, or earned
-- any other way (a daily-reward Skin roll counts too). Baselines the current owned count
-- first so a pre-existing collection doesn't complete the step instantly.
local function startBuySkin(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
	local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction

	local function ownedCount(info: any): number
		local n = 0
		if type(info) == "table" and type(info.owned) == "table" then
			for _ in info.owned do
				n += 1
			end
		end
		return n
	end

	-- math.huge until the snapshot resolves, so a racing CosmeticChanged can't complete
	-- against a not-yet-seeded baseline.
	local baseline = math.huge
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		baseline = if ok then ownedCount(info) else 1 -- 1 = the always-owned default skin
	end)

	local conn = changedRE.OnClientEvent:Connect(function(info: any)
		if ownedCount(info) > baseline then
			onComplete()
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- N of the LOCAL player's own marbles banking ("scoring"). BalanceChanged carries the
-- CurrencyService reason string, and every bank's reason starts with "Ball " ("Ball
-- destroyed at target: ...", "Ball stuck (timeout): ...") — the same prefix match
-- MoneyPerBallUI keys its $/marble pulls on; coins/quests/rewards never use it.
local function startScoreBalls(spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local need = (spec.Count :: number?) or 1
	local count = 0
	local balanceRE = CurrencyNet.BalanceChanged :: RemoteEvent
	local conn = balanceRE.OnClientEvent:Connect(function(_new: number, _amount: number, reason: any)
		if typeof(reason) == "string" and string.match(reason, "^Ball ") then
			count += 1
			if count >= need then
				onComplete()
			end
		end
	end)
	return function()
		conn:Disconnect()
	end
end

-- The player's character stepping on the free-marble-box pad (any part tagged
-- FreeCratePad). The touch alone completes — the claim/cooldown stays the pad's own
-- business (CosmeticsShop), so this works even if the box was already claimed.
local function startTouchFreeCratePad(_spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local conns: { RBXScriptConnection } = {}
	local function wire(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		table.insert(conns, inst.Touched:Connect(function(obj: Instance)
			local char = player.Character
			if char and obj:IsDescendantOf(char) then
				onComplete()
			end
		end))
	end
	for _, inst in CollectionService:GetTagged(TagsConfig.FreeCratePad) do
		wire(inst)
	end
	table.insert(conns, CollectionService:GetInstanceAddedSignal(TagsConfig.FreeCratePad):Connect(wire))
	return function()
		for _, c in conns do
			c:Disconnect()
		end
	end
end

local COMPLETION_STARTERS: { [string]: (CompletionSpec, () -> ()) -> () -> () } = {
	LaunchBalls = startLaunchBalls,
	BuyUpgrade = startBuyUpgrade,
	CollectCoin = startCollectCoin,
	ScoreBalls = startScoreBalls,
	BuySkin = startBuySkin,
	RollCrate = startRollCrate,
	BuyLuck = startBuyLuck,
	OpenTuningMenu = startOpenTuningMenu,
	OpenLoadout = startOpenLoadout,
	EquipLoadoutSlot = startEquipLoadoutSlot,
	TouchFreeCratePad = startTouchFreeCratePad,
}

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- LeftBar.TriggerQuad is shared by several panels (Playtime/Tuning/Quest/Loadout), each of
-- which hides the WHOLE quad while open (see PlaytimeUI/BallTuningUI/QuestUI openMenu). A step
-- that highlights a TriggerQuad element can get stuck if a different panel is already covering
-- it, so force them all shut before laying out this step's highlight.
local function closeTriggerQuadPanels()
	PlaytimeUI.Close()
	BallTuningUI.Close()
	QuestUI.Close()
	-- LoadoutUI is deliberately excluded: the Loadout tutorial's own OpenLoadout completion
	-- would otherwise be self-defeating if a later step ever needed to re-highlight it while open.
end

local function applyStep(index: number)
	currentIndex = index
	stepToken += 1
	local myToken = stepToken
	local step = activeSteps[index]
	closeTriggerQuadPanels()

	-- Move the box (if the step repositions it) and cross-fade the text.
	TweenService:Create(box, TRANSITION, { Position = step.boxPosition or DEFAULT_BOX_POS }):Play()
	TweenService:Create(label, HALF, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(HALF_TIME, function()
		if myToken ~= stepToken then
			return -- advanced again before the swap; let the newer call own the text
		end
		label.Text = step.text
		TweenService:Create(label, HALF, { TextTransparency = 0, TextStrokeTransparency = TEXT_STROKE }):Play()
	end)

	applyHighlight(step.highlight)
	-- Move the camera for this step (nil returns to the default/board camera). CameraController
	-- tweens the move smoothly, in step with the rest of the transition.
	CameraController.SetTutorialView(step.camera)

	-- Arrow: orthogonal to highlight/camera — always clear the previous step's, then show
	-- this step's if it has one.
	WorldArrow.Hide()
	if step.arrow then
		local resolveArrow = ARROW_RESOLVERS[step.arrow.Kind]
		if resolveArrow then
			WorldArrow.Show(resolveArrow(step.arrow))
		else
			warn("TutorialController: no arrow resolver for Kind '" .. tostring(step.arrow.Kind) .. "'")
		end
	end

	-- Completion: replaces the old Next button entirely. Tear down the previous step's
	-- listener (if any) and start this one's.
	if completionCleanup then
		completionCleanup()
		completionCleanup = nil
	end
	local startCompletion = COMPLETION_STARTERS[step.complete.Kind]
	if startCompletion then
		completionCleanup = startCompletion(step.complete, advance)
	else
		warn("TutorialController: no completion starter for Kind '" .. tostring(step.complete.Kind) .. "' — step will never auto-advance")
	end
end

local function finish()
	if finished then
		return
	end
	finished = true
	if activeId == "main" then
		markOver() -- join-time popups (DailyRewardUI) gate on the MAIN tutorial only
	end
	stepToken += 1 -- cancel any pending text swap
	WorldArrow.Hide()
	if completionCleanup then
		completionCleanup()
		completionCleanup = nil
	end
	CameraController.SetTutorialView(nil) -- hand the camera back

	-- Tell the server which tutorial finished/was skipped, so it never replays.
	local re = RS:FindFirstChild("Remote") and StatsNet.CompleteTutorial
	if re and re:IsA("RemoteEvent") then
		re:FireServer(activeId)
	end

	-- Fade everything out, then tear down.
	TweenService:Create(box, TRANSITION, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(label, TRANSITION, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	local stroke = ring:FindFirstChild("Stroke") :: UIStroke
	TweenService:Create(stroke, TRANSITION, { Transparency = 1 }):Play()
	for _, frame in maskFrames do
		TweenService:Create(frame, TRANSITION, { BackgroundTransparency = 1 }):Play()
	end
	skipBtn.Active = false
	TweenService:Create(skipBtn, TRANSITION, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	-- Captured, not read at fire time: a later sequence may have rebuilt screenGui by the
	-- time this delay lands, and it must destroy THIS run's gui, not the new one.
	local gui = screenGui
	task.delay(TRANSITION.Time, function()
		gui:Destroy()
		sequenceRunning = false -- teardown done; a queued sequence may now take the UI
	end)
end

advance = function()
	if finished then
		return
	end
	if currentIndex >= #activeSteps then
		finish()
	else
		applyStep(currentIndex + 1)
	end
end

local function begin()
	screenGui.Enabled = true
	-- Fade the box in, then show step 1.
	box.BackgroundTransparency = 1
	TweenService:Create(box, TRANSITION, { BackgroundTransparency = 0.1 }):Play()
	applyStep(1)
end

-- Start the runner on a sequence. The whole UI is rebuilt per run — finish() tears it down.
-- Yields while another sequence is still running/tearing down (only one may drive the
-- shared UI); the wait-loop check and the flag set have no yield between them, so two
-- queued watchers resume one at a time and can't both grab the slot.
local function startSequence(playerGui: PlayerGui, id: string, seq: { Step })
	while sequenceRunning do
		task.wait(0.5)
	end
	sequenceRunning = true
	activeId = id
	activeSteps = seq
	finished = false
	createUI(playerGui)
	skipBtn.Activated:Connect(finish)
	begin()
end

function TutorialController.Init()
	-- Gate yields (data load + stats), so run it off-thread to not stall the bootstrap.
	task.spawn(function()
		-- Wait for saved data to load before checking, so a returning player who already did
		-- a tutorial doesn't see it again on a pre-load default.
		local waitLoaded = DataNet.WaitForDataLoaded :: RemoteFunction
		waitLoaded:InvokeServer()
		local getStats = StatsNet.GetStats :: RemoteFunction
		local stats = getStats:InvokeServer()
		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

		if #steps == 0 or (stats and stats.completedTutorial) then
			markOver()
		else
			startSequence(playerGui, "main", steps)
		end

		-- Cosmetic tutorial: after the main one is over, the first time the Diamonds balance
		-- reaches the trigger. Skipped forever once finished/skipped (persisted server-side).
		task.spawn(function()
			if #cosmeticSteps == 0 or (stats and stats.completedCosmeticTutorial) then
				return
			end
			TutorialController.WaitUntilOver()

			local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
			local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction
			local triggered = false
			local conn: RBXScriptConnection? = nil
			local function maybeTrigger(info: any)
				if triggered or type(info) ~= "table" or type(info.cc) ~= "number" then
					return
				end
				if info.cc < TutorialConfig.Cosmetic.DiamondTrigger then
					return
				end
				triggered = true
				if conn then
					conn:Disconnect()
				end
				-- Own thread: startSequence yields while another sequence tears down.
				task.spawn(startSequence, playerGui, "cosmetic", cosmeticSteps)
			end
			conn = changedRE.OnClientEvent:Connect(maybeTrigger)
			-- Snapshot too: the balance may already be past the trigger when this binds.
			local ok, info = pcall(function()
				return getInfoRF:InvokeServer()
			end)
			if ok then
				maybeTrigger(info)
			end
		end)

		-- Loadout tutorial: after the main one is over, the first time any skin OTHER than
		-- the default Classic is owned (first crate pull / daily-reward skin) — walks the
		-- player through opening the loadout and slotting a skin. Run-once (persisted).
		task.spawn(function()
			if #loadoutSteps == 0 or (stats and stats.completedLoadoutTutorial) then
				return
			end
			TutorialController.WaitUntilOver()

			local changedRE = CosmeticsNet.CosmeticChanged :: RemoteEvent
			local getInfoRF = CosmeticsNet.GetCosmeticInfo :: RemoteFunction
			local DEFAULT_ID = BallSkins.GetDefaultId()
			local triggered = false
			local conn: RBXScriptConnection? = nil
			local function maybeTrigger(info: any)
				if triggered or type(info) ~= "table" or type(info.owned) ~= "table" then
					return
				end
				local hasNonDefault = false
				for id in info.owned do
					if id ~= DEFAULT_ID then
						hasNonDefault = true
						break
					end
				end
				if not hasNonDefault then
					return
				end
				triggered = true
				if conn then
					conn:Disconnect()
				end
				-- Own thread: startSequence yields while another sequence tears down.
				task.spawn(function()
					-- The inventory push lands the moment the SERVER rolls — before the crate
					-- reel even starts client-side. Give the reveal a beat to begin, then hold
					-- until it fully finishes so the tutorial doesn't talk over the spin.
					task.wait(0.6)
					while CrateRollUI.IsSpinning() do
						task.wait(0.25)
					end
					startSequence(playerGui, "loadout", loadoutSteps)
				end)
			end
			conn = changedRE.OnClientEvent:Connect(maybeTrigger)
			-- Snapshot too: the skin may already be owned when this binds.
			local ok, info = pcall(function()
				return getInfoRF:InvokeServer()
			end)
			if ok then
				maybeTrigger(info)
			end
		end)

		-- Tuning tutorial: after the main one is over, the first time ANY ball-tuning axis
		-- (a UpgradesConfig.Axes track) gains a tier — points the player at the tuning menu and
		-- waits for them to open it. Same run-once persistence as the others.
		task.spawn(function()
			if #tuningSteps == 0 or (stats and stats.completedTuningTutorial) then
				return
			end
			TutorialController.WaitUntilOver()

			local getProfileRF = ProfileNet.GetProfile :: RemoteFunction
			local profileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

			local function axisTiers(profile: any): { [string]: number }
				local out: { [string]: number } = {}
				for axis in (UpgradesConfig.Axes :: any) :: { [string]: any } do
					local t = 0
					if type(profile) == "table" and type(profile.upgrades) == "table" then
						t = profile.upgrades[axis] or 0
					end
					out[axis] = t
				end
				return out
			end

			local ok, profile = pcall(function()
				return getProfileRF:InvokeServer()
			end)
			local baseline = axisTiers(if ok then profile else nil)

			local conn: RBXScriptConnection? = nil
			conn = profileChangedRE.OnClientEvent:Connect(function(p: any)
				local tiers = axisTiers(p)
				for axis, t in tiers do
					if t > baseline[axis] then
						if conn then
							conn:Disconnect()
						end
						task.spawn(startSequence, playerGui, "tuning", tuningSteps)
						return
					end
				end
				-- Adopt decreases (a prestige wipes upgrade tiers) so the NEXT axis buy
				-- still reads as an increase instead of hiding below the stale baseline.
				baseline = tiers
			end)
		end)
	end)
end

return TutorialController
