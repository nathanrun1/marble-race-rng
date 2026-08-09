--!strict
-- Small always-visible HUD chip surfacing a countdown that otherwise sits hidden inside a
-- panel players have to open: time until the next playtime-bonus rung unlocks. A classic
-- "just a couple more minutes" retention hook, but only works as one if the player can
-- actually see it ticking without digging into a menu.
--
-- (The free-box countdown used to live here too. During the fast phase (Free.Interval,
-- ~10s) a chip would flash "READY!" near-constantly so it stays unsurfaced; once the
-- cadence steps up to SlowInterval (~90s after FastClaims lifetime claims) a chip might
-- be worth reintroducing. CosmeticsShop's own claim button/pad still show the timer.)
--
-- Data source (already pushed for other UIs, no new remotes):
--   Playtime — PlaytimeBonusService's Info.total / Info.nextTime (nextTime is the NEXT rung's
--              cumulative-seconds threshold, not a countdown — remaining = nextTime - total),
--              via GetPlaytimeInfo / PlaytimeChanged.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AutoScale = require(RS.Shared.Utility.AutoScale)
local PlaytimeNet = require(RS.Shared.Remote.PlaytimeNet)

local RetentionTimersUI = {}

local BLUE = Color3.fromRGB(120, 190, 255)

local playtimeLabel: TextLabel? = nil

-- nextBonusAt is a local os.clock() deadline re-derived from each server push — lets the
-- chip tick smoothly every frame between the (infrequent) server pushes.
local nextBonusAt: number? = nil
local playtimeExhausted = false -- all rungs claimed: hide the chip instead of showing "—"

local function formatSeconds(s: number): string
	s = math.max(0, math.ceil(s))
	local m = s // 60
	local sec = s % 60
	return string.format("%d:%02d", m, sec)
end

local function onPlaytimeInfo(info: any)
	if type(info) ~= "table" or type(info.total) ~= "number" then
		return
	end
	if type(info.nextTime) ~= "number" then
		playtimeExhausted = true
		nextBonusAt = nil
		return
	end
	playtimeExhausted = false
	nextBonusAt = os.clock() + math.max(0, info.nextTime - info.total)
end

local function step()
	if playtimeLabel then
		if playtimeExhausted then
			playtimeLabel.Visible = false
		elseif nextBonusAt then
			playtimeLabel.Visible = true
			local remaining = nextBonusAt - os.clock()
			playtimeLabel.Text = if remaining > 0
				then "⏱️ Next Bonus: " .. formatSeconds(remaining)
				else "⏱️ Next Bonus: READY!"
		end
	end
end

local function createUI(playerGui: PlayerGui)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RetentionTimersUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = playerGui

	-- One container + one UIListLayout + one shared UIScale, same reasoning as
	-- MoneyPerBallUI's TopHUD: keeps both rows glued together as the viewport shrinks.
	-- Bottom-right, but inset well past 16px off the bottom edge — this game doesn't
	-- customize the default mobile TouchGui, whose jump button docks in that same
	-- corner, so a tight inset would sit the chips right on top of it.
	local container = Instance.new("Frame")
	container.Name = "TimerHUD"
	container.AnchorPoint = Vector2.new(1, 1)
	container.Position = UDim2.new(1, -16, 1, -140)
	container.Size = UDim2.new(0, 260, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	listLayout.Padding = UDim.new(0, 4)
	listLayout.Parent = container

	local function makeRow(name: string, layoutOrder: number, color: Color3, text: string): TextLabel
		local lbl = Instance.new("TextLabel")
		lbl.Name = name
		lbl.LayoutOrder = layoutOrder
		lbl.Size = UDim2.new(1, 0, 0, 26)
		lbl.BackgroundTransparency = 1
		lbl.Text = text
		lbl.TextColor3 = color
		lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
		lbl.TextStrokeTransparency = 0.4
		lbl.TextScaled = false
		lbl.TextSize = 20
		lbl.TextXAlignment = Enum.TextXAlignment.Right
		lbl.Font = Enum.Font.FredokaOne
		lbl.Active = false
		lbl.Interactable = false
		lbl.Parent = container
		return lbl
	end

	playtimeLabel = makeRow("PlaytimeTimer", 1, BLUE, "⏱️ Next Bonus: —")
	playtimeLabel.Visible = false -- until the first PlaytimeChanged/GetPlaytimeInfo push lands

	AutoScale.Apply(container)
end

function RetentionTimersUI.Init()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	createUI(playerGui)


	local playtimeChangedRE = PlaytimeNet.PlaytimeChanged :: RemoteEvent
	playtimeChangedRE.OnClientEvent:Connect(onPlaytimeInfo)
	local getPlaytimeInfoRF = PlaytimeNet.GetPlaytimeInfo :: RemoteFunction
	task.spawn(function()
		local ok, info = pcall(function()
			return getPlaytimeInfoRF:InvokeServer()
		end)
		if ok then
			onPlaytimeInfo(info)
		end
	end)

	RunService.Heartbeat:Connect(step)
end

return RetentionTimersUI
