--!strict
-- Client join tutorial. Plays Config.Tutorial.Steps once per player (until finished or
-- skipped, persisted via StatsService). Each step shows a medium-large message in a box with
-- Skip / Next buttons, and may dim the whole screen except a highlighted rect. Steps — text,
-- box position, and highlight — all cross-fade/tween smoothly into the next.
--
-- The dim "hole" is a four-frame mask (top/bottom/left/right dark panels tiling around the
-- clear rect), so there's a genuine cut-out without an image mask; a ring traces the hole.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)
local AutoScale = require(RS.Shared.AutoScale)

local TutorialService = {}

local player = Players.LocalPlayer
local CameraService = require(player:WaitForChild("PlayerScripts"):WaitForChild("CameraService"))

type Highlight = { Position: UDim2, Size: UDim2 }
type Shot = { Position: Vector3, Orientation: Vector3, FieldOfView: number? }
type Step = { text: string, boxPosition: UDim2?, highlight: Highlight?, camera: Shot? }

local TRANSITION = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HALF = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HALF_TIME = 0.2

local DIM = 0.45                              -- dark-panel BackgroundTransparency when dimming
local DEFAULT_BOX_POS = UDim2.fromScale(0.5, 0.82)
local TEXT_STROKE = 0.4

local steps: { Step } = (Config.Tutorial.Steps :: any) :: { Step }

-- UI handles (built in createUI).
local screenGui: ScreenGui
local maskFrames: { Frame } = {} -- [1]=top [2]=bottom [3]=left [4]=right
local ring: Frame
local box: Frame
local label: TextLabel
local nextBtn: TextButton
local skipBtn: TextButton

local currentIndex = 0
local stepToken = 0   -- guards the delayed text-swap against rapid advances
local dimVisible = false
local finished = false

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

local function makeButton(name: string, text: string, color: Color3, pos: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.AnchorPoint = Vector2.new(0.5, 1)
	b.Position = pos
	b.Size = UDim2.fromOffset(150, 48)
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextScaled = true
	b.Font = Enum.Font.GothamBold
	b.ZIndex = 6
	b.Parent = box

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = b

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.Parent = b
	return b
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

	skipBtn = makeButton("Skip", "Skip", Color3.fromRGB(70, 74, 86), UDim2.new(0.5, -90, 1, -24))
	nextBtn = makeButton("Next", "Next", Color3.fromRGB(70, 150, 90), UDim2.new(0.5, 90, 1, -24))

	AutoScale.Apply(box)
end

--------------------------------------------------------------------------------
-- Step application (smooth transitions)
--------------------------------------------------------------------------------

-- Resolve a highlight (centre Position + Size as UDim2s) to a Scale rect (cx, cy, w, h, all
-- 0..1 of the screen). The UDim2 resolves like any screen UDim2 — Scale × viewport — except
-- the Offset is multiplied by the AutoScale factor, so a 1080p-authored offset pos/size lines
-- up with AutoScaled UI on any resolution. (Pure-Scale highlights are unaffected: offset 0.)
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

local function applyStep(index: number)
	currentIndex = index
	stepToken += 1
	local myToken = stepToken
	local step = steps[index]

	nextBtn.Text = if index >= #steps then "Finish" else "Next"

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
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function finish()
	if finished then
		return
	end
	finished = true
	stepToken += 1 -- cancel any pending text swap
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
	for _, b in { skipBtn, nextBtn } do
		b.Active = false
		TweenService:Create(b, TRANSITION, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	end
	task.delay(TRANSITION.Time, function()
		screenGui:Destroy()
	end)
end

local function onNext()
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
			return
		end

		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)
		nextBtn.Activated:Connect(onNext)
		skipBtn.Activated:Connect(finish)
		begin()
	end)
end

return TutorialService
