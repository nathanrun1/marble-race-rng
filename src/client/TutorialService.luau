--!strict
-- Client join tutorial. Plays Config.Tutorial.Steps once per player (persisted via
-- StatsService), advancing AUTOMATICALLY as each step's own `complete` trigger fires
-- (LaunchBalls/BuyUpgrade/CollectCoin, ...) — no Next button — but a Skip button always lets
-- the player bail out of the whole sequence early. Steps may also, orthogonally, show a
-- physical world-arrow `arrow` target (WorldArrow) pointing the player somewhere. Both arrow
-- and completion are resolved through small per-Kind registries (ARROW_RESOLVERS /
-- COMPLETION_STARTERS) below, so adding a new Kind is one function + one registry entry —
-- nothing else in the stepping/rendering logic changes. See Config.Tutorial for the full
-- step-shape contract.
--
-- Presentation is otherwise unchanged from the original text-box tutorial: a medium-large
-- message in a box, optionally dimming the whole screen except a highlighted rect (a
-- four-frame mask tiling around the clear rect, with a ring tracing the hole), and an
-- optional scripted camera shot — all cross-fade/tween smoothly into the next step.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)
local AutoScale = require(RS.Shared.AutoScale)

local TutorialService = {}

local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")
local CameraService = require(PlayerScripts:WaitForChild("CameraService"));
local WorldArrow = require(PlayerScripts:WaitForChild("WorldArrow"));
local CoinPickups = require(PlayerScripts:WaitForChild("CoinPickups"));

-- Matches UpgradeShop.luau's own (bare, not-in-Config.Attributes) TRACK_ATTR local constant —
-- the attribute a kiosk part stores its upgrade track under. Kept identical here so an
-- "UpgradeShopTrack" arrow finds the exact kiosks UpgradeShop.luau opens on touch.
local TRACK_ATTRIBUTE = "Track"

type Highlight = { Position: UDim2, Size: UDim2 }
type Shot = { Position: Vector3, Orientation: Vector3, FieldOfView: number? }

-- Both are open-ended tagged unions: { Kind = "SomeKind", ...Kind-specific fields }. Kept as
-- `any`-payload records (not a closed union type) so Config.Tutorial can add new Kinds without
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

local DIM = 0.45                              -- dark-panel BackgroundTransparency when dimming
local DEFAULT_BOX_POS = UDim2.fromScale(0.5, 0.72)
local TEXT_STROKE = 0.4

local steps: { Step } = (Config.Tutorial.Steps :: any) :: { Step }

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
local overEvent = Instance.new("BindableEvent")
local isOver = false

local function markOver()
	if isOver then
		return
	end
	isOver = true
	overEvent:Fire()
end

-- Yields until the tutorial is over (returns immediately if it already is).
function TutorialService.WaitUntilOver()
	if not isOver then
		overEvent.Event:Wait()
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
	box.Size = UDim2.fromOffset(720, 240)
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
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0.1)
	label.Size = UDim2.new(1, -60, 0, 110)
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
	sizeConstraint.MaxTextSize = 40 -- medium-large
	sizeConstraint.Parent = label

	-- Skip: bails out of the whole sequence early (no per-step Next — steps auto-advance —
	-- but the player can always leave). Tucked in the box's corner so it doesn't compete with
	-- the message itself.
	skipBtn = Instance.new("TextButton")
	skipBtn.Name = "Skip"
	skipBtn.AnchorPoint = Vector2.new(1, 0)
	skipBtn.Position = UDim2.new(1, -14, 0, 10)
	skipBtn.Size = UDim2.fromOffset(80, 32)
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

-- Resolve a highlight (centre Position + Size as UDim2s) to a Scale rect (cx, cy, w, h, all
-- 0..1 of the screen). The UDim2 resolves like any screen UDim2 (Scale × viewport) except the
-- Offset is multiplied by the AutoScale factor, so a 1080p-authored offset pos/size lines up
-- with AutoScaled UI on any resolution. (Pure-Scale highlights are unaffected: offset 0.)
local function resolveRect(h: Highlight): (number, number, number, number)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local f = AutoScale.GetScale()
	local cx = (vp.X * h.Position.X.Scale + h.Position.X.Offset * f) / vp.X
	local cy = (vp.Y * h.Position.Y.Scale + h.Position.Y.Offset * f) / vp.Y
	local w = (vp.X * h.Size.X.Scale + h.Size.X.Offset * f) / vp.X
	local ht = (vp.Y * h.Size.Y.Scale + h.Size.Y.Offset * f) / vp.Y
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
		layoutMask(h, not dimVisible) -- snap geometry if we're fading in from nothing
		for _, frame in maskFrames do
			TweenService:Create(frame, TRANSITION, { BackgroundTransparency = DIM }):Play()
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
		for _, pad in CollectionService:GetTagged(Config.Tags.UpgradeShop) do
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

local ARROW_RESOLVERS: { [string]: (ArrowSpec) -> () -> Vector3? } = {
	UpgradeShopTrack = resolveUpgradeShopTrack,
	NearestCoin = resolveNearestCoin,
}

--------------------------------------------------------------------------------
-- Completion starters: Kind -> (spec, onComplete) -> cleanup(). Each returns a function that
-- disconnects whatever it hooked; TutorialService calls it when leaving the step (advance,
-- skip-to-finish, or teardown) so listeners never outlive their step.
--------------------------------------------------------------------------------

-- N of the LOCAL player's own marbles actually spawning (Config.Tags.Ball + OwnerUserId
-- attribute — both replicate normally, so this can't be spoofed and needs no new remote).
local function startLaunchBalls(spec: CompletionSpec, onComplete: () -> ()): () -> ()
	local need = spec.Count :: number
	local count = 0
	local conn = CollectionService:GetInstanceAddedSignal(Config.Tags.Ball):Connect(function(ball: Instance)
		if ball:GetAttribute(Config.Attributes.OwnerUserId) == player.UserId then
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
	local remote = RS:WaitForChild("Remote")
	local getProfileRF = remote:WaitForChild("GetProfile") :: RemoteFunction
	local profileChangedRE = remote:WaitForChild("ProfileChanged") :: RemoteEvent

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

local COMPLETION_STARTERS: { [string]: (CompletionSpec, () -> ()) -> () -> () } = {
	LaunchBalls = startLaunchBalls,
	BuyUpgrade = startBuyUpgrade,
	CollectCoin = startCollectCoin,
}

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function applyStep(index: number)
	currentIndex = index
	stepToken += 1
	local myToken = stepToken
	local step = steps[index]

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
	-- Move the camera for this step (nil returns to the default/board camera). CameraService
	-- tweens the move smoothly, in step with the rest of the transition.
	CameraService.SetTutorialView(step.camera)

	-- Arrow: orthogonal to highlight/camera — always clear the previous step's, then show
	-- this step's if it has one.
	WorldArrow.Hide()
	if step.arrow then
		local resolveArrow = ARROW_RESOLVERS[step.arrow.Kind]
		if resolveArrow then
			WorldArrow.Show(resolveArrow(step.arrow))
		else
			warn("TutorialService: no arrow resolver for Kind '" .. tostring(step.arrow.Kind) .. "'")
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
		warn("TutorialService: no completion starter for Kind '" .. tostring(step.complete.Kind) .. "' — step will never auto-advance")
	end
end

local function finish()
	if finished then
		return
	end
	finished = true
	markOver()
	stepToken += 1 -- cancel any pending text swap
	WorldArrow.Hide()
	if completionCleanup then
		completionCleanup()
		completionCleanup = nil
	end
	CameraService.SetTutorialView(nil) -- hand the camera back

	-- Tell the server so it never replays.
	local re = RS:FindFirstChild("Remote") and RS.Remote:FindFirstChild("CompleteTutorial")
	if re and re:IsA("RemoteEvent") then
		re:FireServer()
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
	task.delay(TRANSITION.Time, function()
		screenGui:Destroy()
	end)
end

advance = function()
	if finished then
		return
	end
	if currentIndex >= #steps then
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

function TutorialService.Init()
	if #steps == 0 then
		markOver()
		return
	end

	-- Gate yields (data load + stats), so run it off-thread to not stall the bootstrap.
	task.spawn(function()
		-- Wait for saved data to load before checking, so a returning player who already did
		-- the tutorial doesn't see it again on a pre-load default. Skip if already completed.
		local remote = RS:WaitForChild("Remote")
		local waitLoaded = remote:WaitForChild("WaitForDataLoaded") :: RemoteFunction
		waitLoaded:InvokeServer()
		local getStats = remote:WaitForChild("GetStats") :: RemoteFunction
		local stats = getStats:InvokeServer()
		if stats and stats.completedTutorial then
			markOver()
			return
		end

		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)
		skipBtn.Activated:Connect(finish)
		begin()
	end)
end

return TutorialService
