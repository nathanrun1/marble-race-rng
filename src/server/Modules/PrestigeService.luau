--!strict
-- Owns the prestige loop: lifetime-banked accumulation, prestige-point formula,
-- cost curve, global payout multiplier, and the reset action.
--
-- Multiplier applies in ScoreHandler after all other bonuses (group, jackpot, etc).
-- Lifetime banked is fed by ScoreHandler via AddLifetimeBanked on every banking.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Config = require(RS.Shared.Config)
local Signal = require(RS.Shared.Signal)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local BallService = require(SSS.Scripts.Modules.BallService)
local StatsService = require(SSS.Scripts.Modules.StatsService)

local PrestigeService = {}

-- (player, info) — fired after prestige state changes.
PrestigeService.Changed = Signal.new()

export type PrestigeData = {
	count: number,
	lifetimeBanked: number,
}

local data: { [number]: PrestigeData } = {}

local function get(player: Player): PrestigeData
	local d = data[player.UserId]
	assert(d, "No prestige data for " .. player.Name)
	return d
end

-- PP = floor((lifetimeBanked / Scale) ^ Exponent)
local function computePP(lifetimeBanked: number): number
	return math.floor((lifetimeBanked / Config.Prestige.Scale) ^ Config.Prestige.Exponent)
end

-- Cost for the Nth prestige (1-indexed): ceil(CostBase × CostGrowth^(N-1))
local function computeCost(n: number): number
	return math.ceil(Config.Prestige.CostBase * Config.Prestige.CostGrowth ^ (n - 1))
end

export type PrestigeInfo = {
	count: number,
	lifetimeBanked: number,
	prestigePoints: number,
	nextCost: number,         -- PP cost to reach count+1
	canPrestige: boolean,
	multiplier: number,
}

local function buildInfo(d: PrestigeData): PrestigeInfo
	local pp = computePP(d.lifetimeBanked)
	local nextCost = computeCost(d.count + 1)
	return {
		count = d.count,
		lifetimeBanked = d.lifetimeBanked,
		prestigePoints = pp,
		nextCost = nextCost,
		canPrestige = pp >= nextCost,
		multiplier = Config.Prestige.MultPer ^ d.count,
	}
end

function PrestigeService.GetInfo(player: Player): PrestigeInfo
	return buildInfo(get(player))
end

-- Non-asserting prestige count (0 if the player's data isn't present yet). Safe for
-- systems that may run before DataService seeds the player (e.g. the leaderboard),
-- which then correct themselves on PrestigeService.Changed.
function PrestigeService.GetCount(player: Player): number
	local d = data[player.UserId]
	return if d then d.count else 0
end

-- MultPer ^ count; applied to banked by ScoreHandler.
function PrestigeService.GetMultiplier(player: Player): number
	return Config.Prestige.MultPer ^ get(player).count
end

-- Dev only: directly set prestige count (bypasses cost check).
function PrestigeService.SetCount(player: Player, count: number)
	local d = get(player)
	d.count = count
	PrestigeService.Changed:Fire(player, buildInfo(d))
end

-- Dev only: directly set lifetime banked (adjusts PP without a real run).
function PrestigeService.SetLifetimeBanked(player: Player, amount: number)
	local d = get(player)
	d.lifetimeBanked = amount
	PrestigeService.Changed:Fire(player, buildInfo(d))
end

-- Called by ScoreHandler every time a ball banks, to accumulate lifetime banked.
function PrestigeService.AddLifetimeBanked(player: Player, amount: number)
	local d = data[player.UserId]
	if not d then
		return
	end
	d.lifetimeBanked += amount
	PrestigeService.Changed:Fire(player, buildInfo(d))
end

-- Attempt a prestige. Returns (ok, reason?). On success: wipes upgrades/loadout,
-- increments count, fires Changed.
function PrestigeService.Prestige(player: Player): (boolean, string?)
	local d = get(player)
	local info = buildInfo(d)
	if not info.canPrestige then
		return false, "not_enough_pp"
	end
	-- Exploit guard: balls fired before prestige still carry their (large) pre-reset
	-- value and would bank into the fresh account. Before applying the reset, open a
	-- no-score window, strip ownership off in-flight balls, and detach them from
	-- their tracked ball state so none of them can credit this player.
	-- ScoringService is lazy-required here to avoid a load-time require cycle
	-- (ScoringService -> ScoreHandler -> PrestigeService).
	local ScoringService = require(SSS.Scripts.Modules.ScoringService)
	ScoringService.BeginNoScore(player.UserId, Config.Prestige.NoScoreSeconds)
	BallService.RemoveOwnership(player.UserId)
	ScoringService.ClearOwner(player.UserId)

	d.count += 1
	ProfileService.ResetProfile(player)
	-- Wipe the run's balance too: prestige resets upgrades AND money back to the
	-- configured starting balance.
	CurrencyService.SetPoints(player, Config.Currency.StartingBalance, "Prestige reset")

	-- Starter pack perk: owners get a free tier on every track after each prestige, so
	-- the reset doesn't start them from bare zero. Lazy-require UpgradeService to avoid
	-- a load-time cycle (UpgradeService -> ProductService -> DataService -> Prestige).
	if StatsService.OwnsStarterPack(player) then
		local UpgradeService = require(SSS.Scripts.Modules.UpgradeService)
		UpgradeService.RaiseAllTracksTo(player, Config.StarterPack.PostPrestigeFreeTier)
	end

	PrestigeService.Changed:Fire(player, buildInfo(d))
	return true, nil
end

local function getRemote(name: string, class: string): Instance
	local remotes = RS.Remote
	local existing = remotes:FindFirstChild(name)
	if existing then
		return existing
	end
	local r = Instance.new(class)
	r.Name = name
	r.Parent = remotes
	return r
end

-- Set prestige state from saved data (or fresh zero). Called by DataService on join.
function PrestigeService.ApplyData(player: Player, saved: PrestigeData?)
	local d: PrestigeData = {
		count = (saved and saved.count) or 0,
		lifetimeBanked = (saved and saved.lifetimeBanked) or 0,
	}
	data[player.UserId] = d
	PrestigeService.Changed:Fire(player, buildInfo(d))
end

-- The prestige state to persist for this player.
function PrestigeService.SerializeData(player: Player): PrestigeData
	return get(player)
end

function PrestigeService.Clear(player: Player)
	data[player.UserId] = nil
end

function PrestigeService.Init()
	(getRemote("GetPrestigeInfo", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return PrestigeService.GetInfo(player)
	end
	;(getRemote("Prestige", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		local ok, reason = PrestigeService.Prestige(player)
		return { ok = ok, reason = reason, info = PrestigeService.GetInfo(player) }
	end

	-- Push prestige info to the client on every change (join load, banking, prestige),
	-- so the UI/badge (e.g. the availability glow) updates live without waiting for a
	-- BalanceChanged or the menu being opened. Changed already carries the PrestigeInfo.
	local prestigeChangedRE = getRemote("PrestigeChanged", "RemoteEvent") :: RemoteEvent
	PrestigeService.Changed:Connect(function(player: Player, info: PrestigeInfo)
		prestigeChangedRE:FireClient(player, info)
	end)
end

return PrestigeService
