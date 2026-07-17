--!strict
-- Top-of-screen "average money per ball" readout (green, always visible). Shows the server-
-- authoritative average (StatsService.GetAvgMoneyPerBall, mirrored here via BallAverage.Compute
-- on the same recentBalls list the server sends) — the same number the leaderstats column and
-- the global leaderboard use — instead of a locally computed figure, so the player never sees a
-- different value here than everywhere else.
--
-- Data source: BalanceChanged tells us a ball banked (reason starts with "Ball "), which
-- schedules a throttled GetStats pull; the display then eases toward whatever that pull returns.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StringUtils = require(RS.Shared.Utility.StringUtils)
local AutoScale = require(RS.Shared.Utility.AutoScale)
local LuckRanks = require(RS.Shared.LuckRanks)
local BallAverage = require(RS.Shared.BallAverage)
local CurrencyNet = require(RS.Shared.Remote.CurrencyNet)
local LeaderboardNet = require(RS.Shared.Remote.LeaderboardNet)
local StatsNet = require(RS.Shared.Remote.StatsNet)

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
local luckLabel: TextLabel? = nil

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
	local recentBalls = (stats :: any).recentBalls
	if type(recentBalls) == "table" then
		target = BallAverage.Compute(recentBalls)
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
		-- Luck rank rides the same value: named tier + how far to the next one (shared
		-- LuckRanks scale — matches the "Luck" leaderstat column exactly). ApplyToLabel
		-- handles the flat color / top-rank gradient styling.
		if luckLabel then
			local rank, nextRank = LuckRanks.RankFor(displayed)
			luckLabel.Text = if nextRank
				then string.format("🍀 Luck: %s  (next: %s at $%s)", rank.Name, nextRank.Name, StringUtils.FormatShort(nextRank.Threshold))
				else "🍀 Luck: " .. rank.Name
			LuckRanks.ApplyToLabel(luckLabel, rank)
		end
	end
end

local function createUI(playerGui: PlayerGui)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MoneyPerBallUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.Parent = playerGui

	-- All three rows live in one container so they scale AND stack together: a UIScale
	-- parented to a label only scales that label's own Size, not its Position offset
	-- relative to the ScreenGui — so three independently-positioned/autoscaled labels
	-- drift apart as the viewport shrinks (their fixed-pixel gaps don't shrink with them).
	-- Putting them in a single Frame with ONE UIScale + a UIListLayout fixes both: the
	-- list layout removes manual offsets entirely, and the shared UIScale scales the
	-- whole stack (including the layout's padding) as one unit.
	local container = Instance.new("Frame")
	container.Name = "TopHUD"
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.Position = UDim2.new(0.5, 0, 0.045, 0)
	container.Size = UDim2.new(0, 620, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.Parent = screenGui

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = container

	local lbl = Instance.new("TextLabel")
	lbl.Name = "PerBall"
	lbl.LayoutOrder = 1
	lbl.Size = UDim2.new(1, 0, 0, 56)
	lbl.BackgroundTransparency = 1
	lbl.Text = "💰 Average $/Marble: $0 💰"
	lbl.TextColor3 = GREEN
	lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0.4
	lbl.TextScaled = false
	lbl.TextSize = 40
	lbl.Font = Enum.Font.FredokaOne
	lbl.Active = false      -- never sink input: clicks (incl. world SurfaceGuis behind it) pass through
	lbl.Interactable = false
	lbl.Parent = container
	label = lbl

	-- Luck rank (named tier for the average), directly below the $/marble readout.
	local luckLbl = Instance.new("TextLabel")
	luckLbl.Name = "LuckRank"
	luckLbl.LayoutOrder = 2
	luckLbl.Size = UDim2.new(1, 0, 0, 30)
	luckLbl.BackgroundTransparency = 1
	luckLbl.Text = "🍀 Luck: " .. LuckRanks.Ranks[1].Name
	luckLbl.TextColor3 = LuckRanks.Ranks[1].Color
	luckLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	luckLbl.TextStrokeTransparency = 0.4
	luckLbl.TextScaled = false
	luckLbl.TextSize = 26
	luckLbl.Font = Enum.Font.FredokaOne
	luckLbl.Active = false
	luckLbl.Interactable = false
	luckLbl.Parent = container
	luckLabel = luckLbl

	-- Global ranking, below the luck rank.
	local rankLbl = Instance.new("TextLabel")
	rankLbl.Name = "GlobalRank"
	rankLbl.LayoutOrder = 3
	rankLbl.Size = UDim2.new(1, 0, 0, 32)
	rankLbl.BackgroundTransparency = 1
	rankLbl.Text = "Global Rank: —"
	rankLbl.TextColor3 = GREEN
	rankLbl.TextStrokeColor3 = Color3.new(0, 0, 0)
	rankLbl.TextStrokeTransparency = 0.4
	rankLbl.TextScaled = false
	rankLbl.TextSize = 24
	rankLbl.Font = Enum.Font.FredokaOne
	rankLbl.Active = false
	rankLbl.Interactable = false
	rankLbl.Parent = container
	rankLabel = rankLbl

	-- Shrink the whole stack on smaller viewports (sizes authored at 1080p), as one unit.
	AutoScale.Apply(container)
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

	getStatsRF = StatsNet.GetStats :: RemoteFunction

	local balanceRE = CurrencyNet.BalanceChanged :: RemoteEvent
	balanceRE.OnClientEvent:Connect(function(_new: number, _amount: number, reason: any)
		if isBallBank(reason) then
			schedulePull()
		end
	end)

	local rankRE = LeaderboardNet.MoneyPerBallRank :: RemoteEvent
	rankRE.OnClientEvent:Connect(onRankUpdated)

	pullTarget() -- seed from current server state (e.g. rejoining with existing lifetime balls)
	displayed = target
	RunService.Heartbeat:Connect(step)

	prevUpdate = os.clock()
end

return MoneyPerBallUI
