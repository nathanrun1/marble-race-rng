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

local PrestigeService = {}

-- (player, info) — fired after prestige state changes.
PrestigeService.Changed = Signal.new()

type PrestigeData = {
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
	d.count += 1
	ProfileService.ResetProfile(player)
	-- Wipe the run's balance too: prestige resets upgrades AND money back to the
	-- configured starting balance.
	CurrencyService.SetPoints(player, Config.Currency.StartingBalance, "Prestige reset")
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

local function onPlayerAdded(player: Player)
	data[player.UserId] = { count = 0, lifetimeBanked = 0 }
end

local function onPlayerRemoving(player: Player)
	data[player.UserId] = nil
end

function PrestigeService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end

	;(getRemote("GetPrestigeInfo", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return PrestigeService.GetInfo(player)
	end
	;(getRemote("Prestige", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		local ok, reason = PrestigeService.Prestige(player)
		return { ok = ok, reason = reason, info = PrestigeService.GetInfo(player) }
	end
end

return PrestigeService
