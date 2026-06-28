--!strict
-- Playtime menu chrome: the PlaytimeTriggerHost button on MainGui.LeftBar opens the
-- LeftBar.Playtime panel (and hides itself); the panel's UIListIgnore.CloseButton closes it
-- again, restoring the trigger. This mirrors BallTuningUI's TuneTriggerHost open/close — a
-- UIScale grow/shrink so the left-bar list layout reflows as the panel opens.
--
-- This is UI plumbing ONLY: it just shows/hides the panel. The panel's contents and the
-- PlaytimeBonusService hookup are intentionally not wired here yet. The Playtime panel may
-- not exist at init (it's authored later), so it's resolved lazily on first click rather than
-- via WaitForChild, which would otherwise stall the Bootstrap init chain.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UIButton = require(RS.Shared.UIButton)

local PlaytimeUI = {}

local player = Players.LocalPlayer

local OPEN_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local isOpen = false
local openTween: Tween? = nil
local restScale = 1
local closeBound = false

-- The panel's UIScale — reuse one if present, else make one. We animate this on open (rather
-- than Size) so the left bar's list layout reflows with the growth, matching the tuning menu.
local function panelScale(panel: GuiObject): UIScale
	local s = panel:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = panel
	end
	return s
end

local function openMenu(triggerHost: GuiObject, panel: GuiObject)
	if isOpen then return end
	isOpen = true
	if openTween then openTween:Cancel() end

	triggerHost.Visible = false
	panel.Visible = true

	local scale = panelScale(panel)
	restScale = scale.Scale -- whatever it normally rests at (AutoScale or 1)
	scale.Scale = 0         -- collapse, then grow into place
	openTween = TweenService:Create(scale, OPEN_TWEEN, { Scale = restScale })
	openTween:Play()
end

local function closeMenu(triggerHost: GuiObject, panel: GuiObject)
	if not isOpen then return end
	isOpen = false
	if openTween then
		openTween:Cancel()
		openTween = nil
	end

	panelScale(panel).Scale = restScale -- restore resting size for the next open
	panel.Visible = false
	triggerHost.Visible = true
end

function PlaytimeUI.Init()
	local playerGui = player:WaitForChild("PlayerGui")
	local mainGui = playerGui:WaitForChild("MainGui")
	local leftBar = mainGui:WaitForChild("LeftBar")
	local triggerHost = leftBar:WaitForChild("PlaytimeTriggerHost") :: GuiObject
	triggerHost.Visible = true

	UIButton.bind(triggerHost, {
		onClick = function()
			-- Resolve the panel lazily: it's authored after this module ships.
			local panel = leftBar:FindFirstChild("Playtime") :: GuiObject?
			if not panel then
				warn("PlaytimeUI: LeftBar.Playtime not present yet — nothing to open")
				return
			end
			-- Bind the close button the first time we successfully find the panel.
			if not closeBound then
				local ignore = panel:FindFirstChild("UIListIgnore")
				local closeBtn = ignore and ignore:FindFirstChild("CloseButton")
				if closeBtn and closeBtn:IsA("GuiButton") then
					closeBtn.Activated:Connect(function()
						closeMenu(triggerHost, panel)
					end)
					closeBound = true
				end
			end
			panel.Visible = false -- ensure a clean closed state before the grow tween
			openMenu(triggerHost, panel)
		end,
	})
end

return PlaytimeUI
