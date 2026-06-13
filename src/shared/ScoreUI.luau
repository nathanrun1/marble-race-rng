--!strict
-- Shared score-message module. Server fires PostMessage to send a styled line to
-- a player's score log; client builds the right-side UI and queues messages with
-- brief delays between them. Same server/client split as BallEffects.

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local ScoreUI = {}

----------------------------------------------------------------------------------
-- Server-only: RemoteEvent creation + PostMessage
----------------------------------------------------------------------------------
if RunService:IsServer() then
	local msgRemote: RemoteEvent? = nil

	function ScoreUI.PostMessage(player: Player, text: string, color: Color3?)
		(msgRemote :: RemoteEvent):FireClient(player, text, color)
	end

	function ScoreUI.Init()
		local re = Instance.new("RemoteEvent")
		re.Name = "ScoreMessage"
		re.Parent = RS.Remote
		msgRemote = re
	end
end

----------------------------------------------------------------------------------
-- Client-only: score log UI + message queue
----------------------------------------------------------------------------------
if RunService:IsClient() then
	local TweenService = game:GetService("TweenService")
	local Players = game:GetService("Players")

	local FADE_IN    = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local FADE_OUT   = TweenInfo.new(0.4,  Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local MSG_DELAY  = 0.2   -- seconds between queued messages appearing
	local DISPLAY_TIME = 2.5 -- seconds each message stays visible before fading

	local msgFrame: Frame? = nil
	local msgCounter = 0
	local messageQueue: { { text: string, color: Color3? } } = {}
	local isProcessing = false

	local function showLabel(text: string, color: Color3?)
		local frame = msgFrame
		if not frame then return end
		msgCounter += 1

		local label = Instance.new("TextLabel")
		label.Name = "Msg" .. msgCounter
		label.LayoutOrder = msgCounter
		label.Size = UDim2.new(1, 0, 0, 26)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = color or Color3.new(1, 1, 1)
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextStrokeTransparency = 1
		label.TextTransparency = 1
		label.TextScaled = false
		label.TextSize = 15
		label.Font = Enum.Font.GothamBold
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.Parent = frame

		local tIn = TweenService:Create(label, FADE_IN, {
			TextTransparency = 0,
			TextStrokeTransparency = 0.35,
		})
		tIn:Play()

		task.delay(DISPLAY_TIME, function()
			if not label.Parent then return end
			local tOut = TweenService:Create(label, FADE_OUT, {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
			})
			tOut:Play()
			tOut.Completed:Connect(function() label:Destroy() end)
		end)
	end

	local function processQueue()
		if isProcessing or #messageQueue == 0 then return end
		isProcessing = true
		task.spawn(function()
			while #messageQueue > 0 do
				local msg = table.remove(messageQueue, 1)
				if msg then
					showLabel(msg.text, msg.color)
				end
				task.wait(MSG_DELAY)
			end
			isProcessing = false
		end)
	end

	local function createUI(playerGui: PlayerGui)
		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "ScoreUI"
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = false
		screenGui.Parent = playerGui

		local frame = Instance.new("Frame")
		frame.Name = "MessageLog"
		frame.Size = UDim2.new(0, 260, 0, 400)
		frame.Position = UDim2.new(1, -14, 1, -14)
		frame.AnchorPoint = Vector2.new(1, 1)
		frame.BackgroundTransparency = 1
		frame.ClipsDescendants = true
		frame.Parent = screenGui

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 3)
		layout.Parent = frame

		msgFrame = frame
	end

	function ScoreUI.Init()
		local player = Players.LocalPlayer
		local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
		createUI(playerGui)

		local remote = RS.Remote:WaitForChild("ScoreMessage") :: RemoteEvent
		remote.OnClientEvent:Connect(function(text: string, color: Color3?)
			table.insert(messageQueue, { text = text, color = color })
			processQueue()
		end)
	end
end

return ScoreUI
