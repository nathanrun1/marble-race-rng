--!strict
-- Small always-visible HUD line for the one-time "Getting Started" quest chain
-- (StarterQuestService): "🎯 Getting Started (2/5): Buy 3 upgrades (1/3)". Hides itself once
-- the whole chain is done (or if the player already finished it in a prior session) — this is
-- meant to be a first-session spine, not a permanent HUD fixture.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local AutoScale = require(RS.Shared:WaitForChild("AutoScale"))

local StarterQuestUI = {}

local GOLD = Color3.fromRGB(255, 210, 80)

local label: TextLabel? = nil

local function onInfo(info: any)
	if type(info) ~= "table" or not label then
		return
	end
	if info.done then
		label.Visible = false
		return
	end
	label.Visible = true
	label.Text = string.format(
		"🎯 Getting Started (%d/%d): %s (%d/%d)",
		info.step, info.total, info.text, info.progress, info.target
	)
end

local function createUI(playerGui: PlayerGui)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StarterQuestUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = playerGui

	local container = Instance.new("Frame")
	container.Name = "StarterQuestHUD"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -110)
	container.Size = UDim2.new(0, 620, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Chain"
	lbl.Size = UDim2.new(1, 0, 0, 30)
	lbl.BackgroundTransparency = 1
	lbl.Text = ""
	lbl.Visible = false
	lbl.TextColor3 = GOLD
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0.4
	lbl.TextScaled = false
	lbl.TextSize = 22
	lbl.Font = Enum.Font.FredokaOne
	lbl.Active = false
	lbl.Interactable = false
	lbl.Parent = container
	label = lbl

	AutoScale.Apply(container)
end

function StarterQuestUI.Init()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	createUI(playerGui)

	local remote = RS:WaitForChild("Remote")
	local changedRE = remote:WaitForChild("StarterQuestChanged") :: RemoteEvent
	changedRE.OnClientEvent:Connect(onInfo)

	local getInfoRF = remote:WaitForChild("GetStarterQuestInfo") :: RemoteFunction
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		if ok then
			onInfo(info)
		end
	end)
end

return StarterQuestUI
