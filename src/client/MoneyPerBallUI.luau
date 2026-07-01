--!strict
-- Top-of-screen "average money per ball" readout (green, always visible). Shows the server-
-- authoritative lifetime average (StatsService.GetAvgMoneyPerBall: ballEarnings / ballsBanked) —
-- the same number the leaderstats column and the global leaderboard use — instead of a locally
-- computed figure, so the player never sees a different value here than everywhere else.
--
-- Data source: BalanceChanged tells us a ball banked (reason starts with "Ball "), which
-- schedules a throttled GetStats pull; the display then eases toward whatever that pull returns.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StringUtils = require(RS.Shared.StringUtils)
local AutoScale = require(RS.Shared.AutoScale)

local MoneyPerBallUI = {}

local GREEN = Color3.fromRGB(96, 224, 120)
local SMOOTH_RATE = 3.0     -- per-second rate the shown number eases toward the target (higher =
                            -- snappier). Eases every frame so it glides rather than snapping.
local UPDATE_PERIOD = 1.0   -- how often the shown $/marble text updates
local PULL_INTERVAL = 0.75  -- min seconds between GetStats pulls (coalesces bursts of balls)

local target = 0    -- server-reported average the display glides toward
local displayed = 0 -- the eased value actually shown
local label: TextLabel? = nil

local rankLabel: TextLabel? = nil

local prevUpdate = nil

local getStatsRF: RemoteFunction? = nil
local pullQueued = false

-- Is this balance change a ball banking? CurrencyService uses "Ball destroyed at target: ..." and
-- "Ball stuck (timeout): ..." for banks (both start "Ball "); coins/playtime/etc. don't.
local function isBallBank(reason: any): boolean
	return typeof(reason) == "string" and string.match(reason, "^Ball ") ~= nil
end

-- Pull the current server-authoritative average and set it as the glide target.
local function pullTarget()
	if not getStatsRF then
		return
	end
	local ok, stats = pcall(function()
		return (getStatsRF :: RemoteFunction):InvokeServer()
	end)
	if not ok or type(stats) ~= "table" then
		return
	end
	local earnings = (stats :: any).ballEarnings
	local banked = (stats :: any).ballsBanked
	if type(earnings) == "number" and type(banked) == "number" and banked > 0 then
		target = earnings / banked
	end
end

-- Coalesce bursts of ball-bank events (many a second at high frequency tiers) into one
-- GetStats round-trip every PULL_INTERVAL rather than invoking the remote per ball.
local function schedulePull()
	if pullQueued then
		return
	end
	pullQueued = true
	task.delay(PULL_INTERVAL, function()
		pullQueued = false
		pullTarget()
	end)
end

-- Per frame: ease the shown number toward the target so it always moves smoothly — no hard step
-- when a fresh pull changes it. Frame-rate independent.
local function step(dt: number)
	displayed += (target - displayed) * (1 - math.exp(-SMOOTH_RATE * dt))
	if label and (os.clock() - prevUpdate) > UPDATE_PERIOD then
		prevUpdate = os.clock()
		label.Text = "💰 Average $/Marble: $" .. StringUtils.FormatShort(displayed) .. " 💰"
	end
end

local function createUI(playerGui: PlayerGui)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MoneyPerBallUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = playerGui

	local lbl = Instance.new("TextLabel")
	lbl.Name = "PerBall"
	lbl.AnchorPoint = Vector2.new(0.5, 0)
	lbl.Position = UDim2.new(0.5, 0, 0.045, 0)
	lbl.Size = UDim2.fromOffset(620, 56)
	lbl.BackgroundTransparency = 1
	lbl.Text = "💰 Average $/Marble: $0 💰"
	lbl.TextColor3 = GREEN
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0.4
	lbl.TextScaled = false
	lbl.TextSize = 40
	lbl.Font = Enum.Font.GothamBold
	lbl.Active = false      -- never sink input: clicks (incl. world SurfaceGuis behind it) pass through
	lbl.Interactable = false
	lbl.Parent = screenGui

	-- Shrink on smaller viewports (sizes authored at 1080p), like the other HUD text.
	AutoScale.Apply(lbl)
	label = lbl

	-- Global ranking, directly below the $/marble readout.
	local rankLbl = Instance.new("TextLabel")
	rankLbl.Name = "GlobalRank"
	rankLbl.AnchorPoint = Vector2.new(0.5, 0)
	rankLbl.Position = UDim2.new(0.5, 0, 0.045, 60)
	rankLbl.Size = UDim2.fromOffset(620, 32)
	rankLbl.BackgroundTransparency = 1
	rankLbl.Text = "Global Rank: —"
	rankLbl.TextColor3 = GREEN
	rankLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	rankLbl.TextStrokeTransparency = 0.4
	rankLbl.TextScaled = false
	rankLbl.TextSize = 24
	rankLbl.Font = Enum.Font.GothamBold
	rankLbl.Active = false
	rankLbl.Interactable = false
	rankLbl.Parent = screenGui

	AutoScale.Apply(rankLbl)
	rankLabel = rankLbl
end

-- rank is nil when the player isn't in the top ranks currently rendered on the physical
-- leaderboard (PhysicalMoneyPerBallLeaderboard only reports ranks within its top N).
local function onRankUpdated(rank: number?)
	if not rankLabel then
		return
	end
	rankLabel.Text = if rank then ("Global Rank: #" .. tostring(rank)) else "Global Rank: Unranked"
end

function MoneyPerBallUI.Init()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	createUI(playerGui)

	getStatsRF = RS.Remote:WaitForChild("GetStats") :: RemoteFunction

	local balanceRE = RS.Remote:WaitForChild("BalanceChanged") :: RemoteEvent
	balanceRE.OnClientEvent:Connect(function(_new: number, _amount: number, reason: any)
		if isBallBank(reason) then
			schedulePull()
		end
	end)

	local rankRE = RS.Remote:WaitForChild("MoneyPerBallRank") :: RemoteEvent
	rankRE.OnClientEvent:Connect(onRankUpdated)

	pullTarget() -- seed from current server state (e.g. rejoining with existing lifetime balls)
	displayed = target
	RunService.Heartbeat:Connect(step)

	prevUpdate = os.clock()
end

return MoneyPerBallUI
