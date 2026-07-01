--!strict
-- Top-of-screen "average money per ball" readout (green, always visible). Averages the banked
-- cash of the last WINDOW balls. So an upgrade registers quickly instead of being diluted by old
-- balls, a profile change (upgrade / loadout / prestige) temporarily biases the average toward
-- the newest balls, then relaxes back to a flat 20-ball mean as fresh balls come in.
--
-- Data source: CurrencyService's BalanceChanged carries each ball's banked cash as its delta
-- (reason starts with "Ball "), and ProfileChanged is the build-changed signal. This is purely
-- a snappy recency-weighted display; the persisted/ranked $/marble metric (leaderstats column,
-- global leaderboard, MoneyPerBallRank below) is computed server-side in StatsService instead.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StringUtils = require(RS.Shared.StringUtils)
local AutoScale = require(RS.Shared.AutoScale)

local MoneyPerBallUI = {}

local WINDOW     = 15    -- balls averaged (wider = steadier against jackpot/payout variance)
local FLAT_DECAY = 1.0   -- steady state: every ball in the window weighted equally
local BIAS_DECAY = 0.9   -- recency-weight base right after a build change (lower = newest dominates,
                         -- but jumpier; ~0.9 still medians over ~10 recent balls so it stays steady
                         -- eFven mid-upgrade, just nudged toward the newest)
local RELAX      = 0.25  -- per-ball relaxation of decay back toward FLAT_DECAY (higher = bias fades
                         -- faster, so it settles back to the steady average sooner)
local GREEN      = Color3.fromRGB(96, 224, 120)
local SMOOTH_RATE = 3.0  -- per-second rate the shown number eases toward the target median (higher =
                         -- snappier). The display decays toward the target EVERY frame, so the number
                         -- always glides instead of stepping when a ball enters/leaves the window.
local UPDATE_PERIOD = 1.0  -- How often the shown $/marble updates

local values: { number } = {}  -- banked cash, oldest first / newest last, capped at WINDOW
local decay = FLAT_DECAY
local target = 0    -- recency-weighted median the display glides toward (recomputed per ball / change)
local displayed = 0 -- the eased value actually shown; decays toward `target` every frame
local label: TextLabel? = nil

local rankLabel: TextLabel? = nil

local prevUpdate = nil

-- Is this balance change a ball banking? CurrencyService uses "Ball destroyed at target: ..." and
-- "Ball stuck (timeout): ..." for banks (both start "Ball "); coins/playtime/etc. don't.
local function isBallBank(reason: any): boolean
	return typeof(reason) == "string" and string.match(reason, "^Ball ") ~= nil
end

-- Weighted MEDIAN of the window (still shown as "Average" in the UI, but a median so a rare
-- jackpot doesn't yank the number around). Each ball is weighted by recency — newest weight 1,
-- each older one ×decay: decay == 1 is a plain median; decay < 1 (just after a build change)
-- leans it toward the newest balls, so an upgrade still surfaces within a few balls.
local function weightedMedian(): number
	local n = #values
	if n == 0 then
		return 0
	end
	local sorted = table.create(n)
	local total = 0.0
	for j = 1, n do
		local w = decay ^ (n - j) -- n - j == age in balls (0 = newest)
		sorted[j] = { v = values[j], w = w }
		total += w
	end
	table.sort(sorted, function(a, b)
		return a.v < b.v
	end)
	local half = total / 2
	local acc = 0.0
	for _, p in sorted do
		acc += p.w
		if acc >= half then
			return p.v
		end
	end
	return sorted[n].v
end

-- The median the display should glide toward (cheap; only recomputed on a ball or build change).
local function recomputeTarget()
	target = weightedMedian()
end

-- Per frame: ease the shown number toward the target so it always moves smoothly — no hard step
-- when a value enters or leaves the window. Frame-rate independent.
local function step(dt: number)
	displayed += (target - displayed) * (1 - math.exp(-SMOOTH_RATE * dt))
	if label and (os.clock() - prevUpdate) > UPDATE_PERIOD then
		prevUpdate = os.clock()
		label.Text = "💰 Average $/Marble: $" .. StringUtils.FormatShort(displayed) .. " 💰"
	end
end

local function onBallBanked(amount: number)
	table.insert(values, amount)
	if #values > WINDOW then
		table.remove(values, 1)
	end
	-- Relax the recency bias one step toward a flat median for the next ball, then re-target.
	decay += (FLAT_DECAY - decay) * RELAX
	recomputeTarget()
end

-- Build changed (upgrade / loadout / prestige): arm the recency bias so the target shifts toward
-- the new output within a few balls (the display then glides to it smoothly).
local function onProfileChanged()
	decay = BIAS_DECAY
	recomputeTarget()
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

	local balanceRE = RS.Remote:WaitForChild("BalanceChanged") :: RemoteEvent
	balanceRE.OnClientEvent:Connect(function(_new: number, amount: number, reason: any)
		if isBallBank(reason) then
			onBallBanked(amount)
		end
	end)

	local profileRE = RS.Remote:WaitForChild("ProfileChanged") :: RemoteEvent
	profileRE.OnClientEvent:Connect(onProfileChanged)

	local rankRE = RS.Remote:WaitForChild("MoneyPerBallRank") :: RemoteEvent
	rankRE.OnClientEvent:Connect(onRankUpdated)

	recomputeTarget()
	RunService.Heartbeat:Connect(step)

	prevUpdate = os.clock()
end

return MoneyPerBallUI
