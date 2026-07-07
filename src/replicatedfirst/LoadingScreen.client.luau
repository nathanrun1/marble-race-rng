--!strict
-- Custom loading screen. Lives in ReplicatedFirst so it runs before the join snapshot
-- finishes replicating: light pink full-screen, white staged progress bar, "Loading...",
-- and a lower-centre Skip button. Fades out on its own once the world is ready:
--   gui up (15%) -> game.Loaded (50%) -> workspace.PersistentLoaded (100%) -> fade.
-- PersistentLoaded = every ModelStreamingMode.Persistent model has replicated (the
-- board/shop/spawn models are marked Persistent in Studio), which is the streaming-
-- enabled meaning of "the workspace is loaded". A hard timeout dismisses the screen
-- regardless, so a streaming hiccup can never trap the player here.
--
-- Deliberately self-contained: no requires (ReplicatedStorage may not be in yet), no
-- image assets, and a CanvasGroup root so the fade is one GroupTransparency tween.

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local MAX_WAIT = 15 -- seconds before the screen dismisses itself no matter what
local FADE_TIME = 0.6

local PINK = Color3.fromRGB(255, 214, 235)
local WHITE = Color3.new(1, 1, 1)
local TEXT_PINK = Color3.fromRGB(214, 110, 168)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000 -- above everything, including CurrencyFly (60)
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local root = Instance.new("CanvasGroup")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = PINK
root.BorderSizePixel = 0
root.Parent = gui

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.44)
title.Size = UDim2.new(0.5, 0, 0, 64)
title.BackgroundTransparency = 1
title.Font = Enum.Font.FredokaOne
title.TextScaled = true
title.TextColor3 = WHITE
title.TextStrokeColor3 = TEXT_PINK
title.TextStrokeTransparency = 0.6
title.Text = "Loading..."
title.Parent = root

-- Track (translucent white) + fill (solid white), both pill-rounded.
local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0.5)
track.Position = UDim2.fromScale(0.5, 0.53)
track.Size = UDim2.new(0.32, 0, 0, 16)
track.BackgroundColor3 = WHITE
track.BackgroundTransparency = 0.65
track.BorderSizePixel = 0
track.Parent = root
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = track

local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = WHITE
fill.BorderSizePixel = 0
fill.Parent = track
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

local skip = Instance.new("TextButton")
skip.AnchorPoint = Vector2.new(0.5, 1)
skip.Position = UDim2.new(0.5, 0, 1, -36)
skip.Size = UDim2.fromOffset(140, 40)
skip.BackgroundColor3 = WHITE
skip.BackgroundTransparency = 0.25
skip.AutoButtonColor = true
skip.Font = Enum.Font.FredokaOne
skip.TextSize = 20
skip.TextColor3 = TEXT_PINK
skip.Text = "Skip"
skip.Parent = root
local skipCorner = Instance.new("UICorner")
skipCorner.CornerRadius = UDim.new(1, 0)
skipCorner.Parent = skip

gui.Parent = playerGui

local done = false
local function finish()
	if done then
		return
	end
	done = true
	TweenService:Create(fill, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) }):Play()
	local fade = TweenService:Create(root, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { GroupTransparency = 1 })
	fade.Completed:Once(function()
		gui:Destroy()
	end)
	fade:Play()
end

local function setProgress(frac: number)
	if done then
		return
	end
	TweenService:Create(fill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(frac, 1) }):Play()
end

skip.Activated:Connect(finish)
task.delay(MAX_WAIT, finish) -- hard ceiling: never trap the player here

setProgress(0.15)
if not game:IsLoaded() then
	game.Loaded:Wait()
end
setProgress(0.5)
-- Streaming: wait for every Persistent-marked model (the board/shop/spawn set) to be
-- fully replicated. Without streaming this event never fires, so skip it then.
if workspace.StreamingEnabled and not done then
	workspace.PersistentLoaded:Wait()
end
setProgress(1)
task.wait(0.25) -- let the full bar register before it fades
finish()
