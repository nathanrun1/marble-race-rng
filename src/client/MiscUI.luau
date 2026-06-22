--!strict
-- Controller for the small "tool" buttons (camera view, SFX mute, music mute) and
-- later the 2× cash card. The visual style + feel are lifted from the GenUI design
-- mockups (hover brightness lift, press squash toward the shadow, blue↔gold gradient
-- for the active state); the placeholder behaviour from those scripts is discarded
-- and replaced with calls into the real services.
--
-- Each tool host has the same shape:  Host > { Shadow, Button > { Hover, Icon } }.
-- The three tool buttons are simple toggles: engaged = gold, idle = blue.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local SoundService = require(RS.Shared.SoundService)
local BallEffects = require(RS.Shared.BallEffects)
local CameraService = require(script.Parent:WaitForChild("CameraService"))

local MiscUI = {}

local player = Players.LocalPlayer
local MainGui = player.PlayerGui:WaitForChild("MainGui")

local defaultColor: { [GuiObject]: Color3 } = {}

----------------------------------------------------------------------------------
-- Shared style + feel (DRY across all the buttons)
----------------------------------------------------------------------------------

local FAST = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_TRANSPARENCY = 0.86
local PRESS_OFFSET = 4

type Gradient = { top: Color3, mid: Color3, bot: Color3 }
local BLUE: Gradient = {
	top = Color3.fromRGB(127, 211, 255),
	mid = Color3.fromRGB(58, 166, 245),
	bot = Color3.fromRGB(36, 134, 224),
}
local GOLD: Gradient = {
	top = Color3.fromRGB(255, 224, 122),
	mid = Color3.fromRGB(255, 211, 77),
	bot = Color3.fromRGB(240, 176, 33),
}
local RED: Gradient = {
	top = Color3.fromRGB(255, 138, 138),
	mid = Color3.fromRGB(240, 70, 70),
	bot = Color3.fromRGB(200, 38, 38),
}

local function setGradient(button: GuiObject, g: Gradient)
	local grad = button:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, g.top),
			ColorSequenceKeypoint.new(0.52, g.mid),
			ColorSequenceKeypoint.new(1.00, g.bot),
		})
	end
end

-- Hover brightness lift + press squash toward the shadow. Shared by every button.
local function attachFeel(button: GuiButton)
	local hover = button:WaitForChild("Hover") :: GuiObject
	local restPos = button.Position
	local pressPos = restPos + UDim2.fromOffset(0, PRESS_OFFSET)

	button.MouseEnter:Connect(function()
		TweenService:Create(hover, FAST, { BackgroundTransparency = HOVER_TRANSPARENCY }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(hover, FAST, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(button, FAST, { Position = restPos }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(button, FAST, { Position = pressPos }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(button, FAST, { Position = restPos }):Play()
	end)
end

-- Wire a Host as a two-state toggle: blue when idle, `activeGradient` when active.
-- `onToggle` receives the new active state and drives the underlying feature;
-- `onRender` (optional) syncs any extra visuals to the state. `initial` sets the
-- starting state without firing onToggle.
local function attachToggle(
	host: Instance,
	initial: boolean,
	activeGradient: Gradient,
	onToggle: (boolean) -> (),
	onRender: ((GuiButton, boolean) -> ())?
)
	local button = host:WaitForChild("Button") :: GuiButton
	attachFeel(button)
	defaultColor[button] = button.BackgroundColor3

	local active = initial
	local function render()
		setGradient(button, if active then activeGradient else BLUE)
		if active then
			button.BackgroundColor3 = Color3.new(1,1,1)
		else
			button.BackgroundColor3 = defaultColor[button]
		end
		
		if onRender then
			onRender(button, active)
		end
	end
	render()

	button.MouseButton1Click:Connect(function()
		active = not active
		render()
		onToggle(active)
	end)
end

-- A mute toggle: turns red while muted and shows the Button.MuteIcon label, which is
-- hidden while unmuted. `onToggle` applies the mute to the relevant SoundService side.
local function attachMuteToggle(host: Instance, initialMuted: boolean, onToggle: (boolean) -> ())
	attachToggle(host, initialMuted, RED, onToggle, function(button, muted)
		local icon = button:FindFirstChild("MuteIcon")
		if icon and icon:IsA("GuiObject") then
			icon.Visible = muted
		end
	end)
end

----------------------------------------------------------------------------------
-- The three tool buttons
----------------------------------------------------------------------------------

function MiscUI.Init()
	local leftBar = MainGui:WaitForChild("LeftBar")
	local tools = leftBar:WaitForChild("Tools")

	-- Camera: gold while the alternate board view is active.
	attachToggle(tools:WaitForChild("CamButtonHost"), CameraService.IsBoardView(), GOLD, function(active)
		CameraService.SetBoardView(active)
	end)

	-- Ball visibility: red + MuteIcon while balls are hidden (destroyed locally).
	attachMuteToggle(tools:WaitForChild("BallVisibleButtonHost"), BallEffects.AreBallsHidden(), function(hidden)
		BallEffects.SetBallsHidden(hidden)
	end)

	-- Sound (ball-effects / SFX) mute: red + MuteIcon while muted.
	attachMuteToggle(tools:WaitForChild("SoundButtonHost"), SoundService.IsSFXMuted(), function(muted)
		SoundService.SetSFXMuted(muted)
	end)

	-- Music mute: red + MuteIcon while muted.
	attachMuteToggle(tools:WaitForChild("MusicButtonHost"), SoundService.IsMusicMuted(), function(muted)
		SoundService.SetMusicMuted(muted)
	end)

	-- TODO: 2× cash card (MainGui.CashMultiHost) — buy flow / gamepass, next pass.
end

return MiscUI
