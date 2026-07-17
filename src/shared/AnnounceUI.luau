--!strict
-- Shared announcement module. Like ScoreUI, but for a single important message shown
-- large and centered. Server fires Announce to a player; client pops the banner in the
-- middle of the screen, holds it, then fades it out. Messages queue so two announcements
-- don't overlap. Color is choosable per message.

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local FxNet = require(RS.Shared.Remote.FxNet)

local AnnounceUI = {}

----------------------------------------------------------------------------------
-- Server-only: RemoteEvent creation + Announce
----------------------------------------------------------------------------------
if RunService:IsServer() then
	-- lifetime: seconds the banner stays fully visible before fading (defaults to DISPLAY_TIME).
	function AnnounceUI.Announce(player: Player, text: string, color: Color3?, lifetime: number?)
		FxNet.AnnounceMessage:FireClient(player, text, color, lifetime)
	end

	function AnnounceUI.Init() end -- remotes live in FxNet; nothing to set up
end

----------------------------------------------------------------------------------
-- Client-only: centered banner + message queue
----------------------------------------------------------------------------------
if RunService:IsClient() then
	local TweenService = game:GetService("TweenService")
	local Players = game:GetService("Players")
	local AutoScale = require(RS.Shared.Utility.AutoScale)

	-- Pop in with a slight overshoot, hold, then fade + drift up on the way out.
	local POP_IN     = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local FADE_OUT   = TweenInfo.new(0.5,  Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local DISPLAY_TIME = 2.0 -- seconds the banner stays fully visible before fading
	local MSG_GAP      = 0.15 -- seconds between consecutive announcements

	local bannerHost: Frame? = nil
	local messageQueue: { { text: string, color: Color3?, lifetime: number? } } = {}
	local isProcessing = false

	-- Show one banner and yield until it has fully left the screen, so queued
	-- announcements play one at a time.
	local function showBanner(text: string, color: Color3?, lifetime: number?)
		local host = bannerHost
		if not host then return end

		local label = Instance.new("TextLabel")
		label.Name = "Announcement"
		label.Size = UDim2.new(1, 0, 0, 110)
		label.Position = UDim2.new(0.5, 0, 0.5, 0)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = color or Color3.new(1, 1, 1)
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextStrokeTransparency = 0.2
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.Parent = host

		-- Constrain TextScaled so it fills big without going absurd on wide screens.
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 80
		constraint.Parent = label

		-- Pop the scale 0 -> 1 (with overshoot) on entry.
		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = label

		label.TextTransparency = 0
		label.TextStrokeTransparency = 0.2
		TweenService:Create(scale, POP_IN, { Scale = 1 }):Play()

		task.wait(lifetime or DISPLAY_TIME)
		if not label.Parent then return end

		local tOut = TweenService:Create(label, FADE_OUT, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		-- Drift the banner up a touch as it fades.
		TweenService:Create(label, FADE_OUT, { Position = UDim2.new(0.5, 0, 0.42, 0) }):Play()
		tOut:Play()
		tOut.Completed:Wait()
		label:Destroy()
	end

	local function processQueue()
		if isProcessing or #messageQueue == 0 then return end
		isProcessing = true
		task.spawn(function()
			while #messageQueue > 0 do
				local msg = table.remove(messageQueue, 1)
				if msg then
					showBanner(msg.text, msg.color, msg.lifetime)
				end
				task.wait(MSG_GAP)
			end
			isProcessing = false
		end)
	end

	local function createUI(playerGui: PlayerGui)
		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "AnnounceUI"
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = false
		screenGui.DisplayOrder = 10 -- above the regular HUD
		screenGui.Parent = playerGui

		local host = Instance.new("Frame")
		host.Name = "BannerHost"
		host.Size = UDim2.new(0, 900, 0, 110)
		host.Position = UDim2.new(0.5, 0, 0.5, 0)
		host.AnchorPoint = Vector2.new(0.5, 0.5)
		host.BackgroundTransparency = 1
		host.Parent = screenGui

		-- Authored at 1080p; shrink on smaller viewports.
		AutoScale.Apply(host)

		bannerHost = host
	end

	function AnnounceUI.Init()
		local player = Players.LocalPlayer
		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)

		FxNet.AnnounceMessage.OnClientEvent:Connect(function(text: string, color: Color3?, lifetime: number?)
			table.insert(messageQueue, { text = text, color = color, lifetime = lifetime })
			processQueue()
		end)
	end
end

return AnnounceUI
