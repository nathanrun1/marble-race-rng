--!strict
-- Shared warning module. Like AnnounceUI but smaller and lower on the screen — for brief,
-- less-important notices (e.g. "Can't afford bet size!"). Server fires Warn to a player; the
-- client pops a small banner a bit below centre, holds it, then fades it out. Messages queue
-- so they don't overlap. Colour is choosable per message (defaults to a warning orange-red).

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local WarnUI = {}

local DEFAULT_COLOR = Color3.fromRGB(255, 95, 70)

----------------------------------------------------------------------------------
-- Server-only: RemoteEvent creation + Warn
----------------------------------------------------------------------------------
if RunService:IsServer() then
	local warnRemote: RemoteEvent? = nil

	function WarnUI.Warn(player: Player, text: string, color: Color3?)
		(warnRemote :: RemoteEvent):FireClient(player, text, color)
	end

	function WarnUI.Init()
		local re = Instance.new("RemoteEvent")
		re.Name = "WarnMessage"
		re.Parent = RS.Remote
		warnRemote = re
	end
end

----------------------------------------------------------------------------------
-- Client-only: lower, smaller banner + message queue
----------------------------------------------------------------------------------
if RunService:IsClient() then
	local TweenService = game:GetService("TweenService")
	local Players = game:GetService("Players")
	local AutoScale = require(RS.Shared.AutoScale)

	local POP_IN     = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local FADE_OUT   = TweenInfo.new(0.4,  Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local DISPLAY_TIME = 1.2  -- seconds the banner stays fully visible before fading
	local MSG_GAP      = 0.1  -- seconds between consecutive warnings
	local HOST_Y       = 0.62 -- vertical anchor — a bit below centre

	local bannerHost: Frame? = nil
	local messageQueue: { { text: string, color: Color3? } } = {}
	local isProcessing = false

	-- Show one banner and yield until it has fully left the screen.
	local function showBanner(text: string, color: Color3?)
		local host = bannerHost
		if not host then return end

		local label = Instance.new("TextLabel")
		label.Name = "Warning"
		label.Size = UDim2.new(1, 0, 0, 60)
		label.Position = UDim2.new(0.5, 0, 0.5, 0)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = color or DEFAULT_COLOR
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextStrokeTransparency = 0.3
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Parent = host

		-- Constrain TextScaled — smaller than AnnounceUI's 80.
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 40
		constraint.Parent = label

		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = label

		TweenService:Create(scale, POP_IN, { Scale = 1 }):Play()

		task.wait(DISPLAY_TIME)
		if not label.Parent then return end

		local tOut = TweenService:Create(label, FADE_OUT, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		TweenService:Create(label, FADE_OUT, { Position = UDim2.new(0.5, 0, 0.45, 0) }):Play()
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
					showBanner(msg.text, msg.color)
				end
				task.wait(MSG_GAP)
			end
			isProcessing = false
		end)
	end

	local function createUI(playerGui: PlayerGui)
		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "WarnUI"
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = false
		screenGui.DisplayOrder = 11 -- above the HUD / alongside AnnounceUI
		screenGui.Parent = playerGui

		local host = Instance.new("Frame")
		host.Name = "BannerHost"
		host.Size = UDim2.new(0, 600, 0, 60)
		host.Position = UDim2.new(0.5, 0, HOST_Y, 0)
		host.AnchorPoint = Vector2.new(0.5, 0.5)
		host.BackgroundTransparency = 1
		host.Parent = screenGui

		-- Authored at 1080p; shrink on smaller viewports.
		AutoScale.Apply(host)

		bannerHost = host
	end

	function WarnUI.Init()
		local player = Players.LocalPlayer
		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)

		local remote = RS.Remote:WaitForChild("WarnMessage") :: RemoteEvent
		remote.OnClientEvent:Connect(function(text: string, color: Color3?)
			table.insert(messageQueue, { text = text, color = color })
			processQueue()
		end)
	end
end

return WarnUI
