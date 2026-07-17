--!strict
-- Shared warning module. Like AnnounceUI but smaller and lower on the screen — for brief,
-- less-important notices (e.g. "Can't afford bet size!"). Server fires Warn to a player; the
-- client pops a small banner a bit below centre, holds it, then fades it out. Messages queue
-- so they don't overlap. Colour is choosable per message (defaults to a warning orange-red).

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local FxNet = require(RS.Shared.Remote.FxNet)

local WarnUI = {}

local DEFAULT_COLOR = Color3.fromRGB(255, 95, 70)

----------------------------------------------------------------------------------
-- Server-only: RemoteEvent creation + Warn
----------------------------------------------------------------------------------
if RunService:IsServer() then
	-- lifetime: seconds the banner stays fully visible before fading (defaults to DISPLAY_TIME).
	function WarnUI.Warn(player: Player, text: string, color: Color3?, lifetime: number?)
		FxNet.WarnMessage:FireClient(player, text, color, lifetime)
	end

	function WarnUI.Init() end -- remotes live in FxNet; nothing to set up
end

----------------------------------------------------------------------------------
-- Client-only: lower, smaller banner + message queue
----------------------------------------------------------------------------------
if RunService:IsClient() then
	local TweenService = game:GetService("TweenService")
	local Players = game:GetService("Players")
	local AutoScale = require(RS.Shared.Utility.AutoScale)

	local POP_IN     = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local FADE_OUT   = TweenInfo.new(0.4,  Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local DISPLAY_TIME = 1.2  -- seconds each banner stays fully visible before fading
	local MSG_GAP      = 0.05 -- pacing between queued banners appearing (ScoreUI-style)
	local HOST_Y       = 0.62 -- where the NEWEST banner sits — a bit below centre
	local MAX_STACK    = 5 -- banners visible at once; older ones are pruned to keep this cap (like ScoreUI)

	local bannerHost: Frame? = nil
	local bannerCounter = 0
	-- Visible banners, oldest first. New ones stack; past MAX_STACK the oldest is pruned
	-- immediately (same policy as ScoreUI's message log).
	local active: { TextLabel } = {}
	local messageQueue: { { text: string, color: Color3?, lifetime: number? } } = {}
	local isProcessing = false

	local function pruneBanner(label: TextLabel)
		local idx = table.find(active, label)
		if idx then
			table.remove(active, idx)
		end
		label:Destroy()
	end

	-- Show one banner (non-blocking): it joins the bottom of the stack, older banners are
	-- pushed up by the list layout, and it fades out on its own timer.
	local function showBanner(text: string, color: Color3?, lifetime: number?)
		local host = bannerHost
		if not host then return end
		bannerCounter += 1

		local label = Instance.new("TextLabel")
		label.Name = "Warning" .. bannerCounter
		label.LayoutOrder = bannerCounter
		label.Size = UDim2.new(1, 0, 0, 52)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = color or DEFAULT_COLOR
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextStrokeTransparency = 0.3
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.Parent = host

		-- Constrain TextScaled — smaller than AnnounceUI's 80.
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = 40
		constraint.Parent = label

		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = label
		TweenService:Create(scale, POP_IN, { Scale = 1 }):Play()

		table.insert(active, label)
		while #active > MAX_STACK do
			pruneBanner(active[1])
		end

		task.delay(lifetime or DISPLAY_TIME, function()
			if not label.Parent then return end
			local tOut = TweenService:Create(label, FADE_OUT, {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			})
			tOut:Play()
			tOut.Completed:Once(function()
				pruneBanner(label)
			end)
		end)
	end

	local function processQueue()
		if isProcessing or #messageQueue == 0 then return end
		isProcessing = true
		task.spawn(function()
			while #messageQueue > 0 do
				local msg = table.remove(messageQueue, 1)
				if msg then
					showBanner(msg.text, msg.color, msg.lifetime)
					task.wait(MSG_GAP)
				end
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

		-- Bottom-anchored so the newest banner sits at HOST_Y and older ones stack upward.
		local host = Instance.new("Frame")
		host.Name = "BannerHost"
		host.Size = UDim2.new(0, 600, 0, (52 + 4) * MAX_STACK)
		host.Position = UDim2.new(0.5, 0, HOST_Y, 26)
		host.AnchorPoint = Vector2.new(0.5, 1)
		host.BackgroundTransparency = 1
		host.Parent = screenGui

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 4)
		layout.Parent = host

		-- Authored at 1080p; shrink on smaller viewports.
		AutoScale.Apply(host)

		bannerHost = host
	end

	-- Client-side counterpart of the server's Warn: show a banner locally without a server
	-- round trip (e.g. DailyRewardUI announcing the just-revealed reward).
	function WarnUI.WarnLocal(text: string, color: Color3?, lifetime: number?)
		table.insert(messageQueue, { text = text, color = color, lifetime = lifetime })
		processQueue()
	end

	function WarnUI.Init()
		local player = Players.LocalPlayer
		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)

		FxNet.WarnMessage.OnClientEvent:Connect(function(text: string, color: Color3?, lifetime: number?)
			table.insert(messageQueue, { text = text, color = color, lifetime = lifetime })
			processQueue()
		end)
	end
end

return WarnUI
