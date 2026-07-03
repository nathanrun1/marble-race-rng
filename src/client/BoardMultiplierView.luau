--!strict
-- Shows the board's bottom slot multipliers boosted by the LOCAL player's Base Bonus.
-- The boost is per-player (ScoreHandler folds BaseAdditive into the effective slot /
-- jackpot multipliers at banking), so each client rewrites the slot display labels with
-- ITS OWN effective values — the same labels DestroyTargetService writes the base values
-- to at server start. Formatting matches: "x" + StringUtils.FormatShort.
--
-- Refresh triggers: once on init, on any upgrade purchase (StatsChanged's lifetime
-- upgradesPurchased counter moving), and on a rebirth (PrestigeChanged count moving —
-- prestige resets the tier). Pulls are coalesced, and labels only rewrite when the
-- derived rate actually changes.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local StringUtils = require(RS.Shared.StringUtils)

local BoardMultiplierView = {}

local MULTS = Config.DestroyTargets.Multipliers :: { [number]: any }
local JACKPOT = Config.DestroyTargets.Jackpot
local PULL_DELAY = 1 -- seconds to coalesce refresh triggers before one GetUpgradeInfo pull

local currentRate = 0
local lastUpgradesPurchased: number? = nil
local lastPrestigeCount: number? = nil
local pullQueued = false

local getUpgradeInfoRF: RemoteFunction

-- Same label walk as DestroyTargetService: slot part -> Parent.Display.SurfaceGui.TextLabel.
local function labelFor(part: Instance): TextLabel?
	local parent = part.Parent
	local display = parent and parent:FindFirstChild("Display")
	local gui = display and display:FindFirstChild("SurfaceGui")
	local label = gui and gui:FindFirstChild("TextLabel")
	return if label and label:IsA("TextLabel") then label else nil
end

local function displayText(mult: any, rate: number): string
	-- Numeric slots pay value × mult × (1+rate); a jackpot slot pays
	-- base × (1 + JackpotMultiplier × (1+rate)) — show those effective multipliers.
	local n = if mult == JACKPOT
		then 1 + Config.Scoring.JackpotMultiplier * (1 + rate)
		else (mult :: number) * (1 + rate)
	return "x" .. StringUtils.FormatShort(n)
end

local function applyTo(part: Instance)
	local id = tonumber(part:GetAttribute(Config.Attributes.DestroyTargetID))
	local mult = if id then MULTS[id] else nil
	if mult == nil then
		return
	end
	local label = labelFor(part)
	if label then
		label.Text = displayText(mult, currentRate)
	end
end

local function applyAll()
	for _, part in CollectionService:GetTagged(Config.Tags.DestroyTarget) do
		applyTo(part)
	end
end

-- Pull the current BaseAdditive tier and re-render if the derived rate moved.
local function refreshRate()
	local ok, info = pcall(function()
		return getUpgradeInfoRF:InvokeServer()
	end)
	if not ok or type(info) ~= "table" then
		return
	end
	local track = (info :: any).BaseAdditive
	local tierNum = if type(track) == "table" and type(track.tier) == "number" then track.tier else 0
	local rate = ProfileStats.GetBaseAdditive({ BaseAdditive = tierNum })
	if rate ~= currentRate then
		currentRate = rate
		applyAll()
	end
end

local function schedulePull()
	if pullQueued then
		return
	end
	pullQueued = true
	task.delay(PULL_DELAY, function()
		pullQueued = false
		refreshRate()
	end)
end

function BoardMultiplierView.Init()
	getUpgradeInfoRF = RS.Remote:WaitForChild("GetUpgradeInfo") :: RemoteFunction
	local statsChanged = RS.Remote:WaitForChild("StatsChanged") :: RemoteEvent
	local prestigeChanged = RS.Remote:WaitForChild("PrestigeChanged") :: RemoteEvent

	-- Any tier purchase moves the lifetime upgradesPurchased counter (also fires on data
	-- load, catching a saved tier); only then is a pull worth scheduling.
	statsChanged.OnClientEvent:Connect(function(stats: any)
		local n = if type(stats) == "table" then tonumber(stats.upgradesPurchased) else nil
		if n and n ~= lastUpgradesPurchased then
			lastUpgradesPurchased = n
			schedulePull()
		end
	end)
	-- PrestigeChanged fires on every bank; only a count change (rebirth reset) matters.
	prestigeChanged.OnClientEvent:Connect(function(info: any)
		local n = if type(info) == "table" then tonumber(info.count) else nil
		if n and n ~= lastPrestigeCount then
			lastPrestigeCount = n
			schedulePull()
		end
	end)
	-- Slots streaming/added later still get the local view.
	CollectionService:GetInstanceAddedSignal(Config.Tags.DestroyTarget):Connect(function(part)
		task.defer(applyTo, part) -- deferred: DestroyTargetService stamps the id attribute on this signal too
	end)

	task.spawn(refreshRate)
end

return BoardMultiplierView
