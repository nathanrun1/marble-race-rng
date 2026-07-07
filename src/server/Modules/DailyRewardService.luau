--!strict
-- Daily login reward: once per UTC day, ClaimDailyReward rolls a weighted prize from
-- Config.DailyReward.Pool and grants it. Cash scales off the player's HIGHEST OWNED MaxBet
-- tier (ProfileService.GetUpgradeTier, NOT their currently selected loadout.BetTier — see
-- ProfileStats.GetBetSizeAtTier); Diamonds get a streak-scaled "Luck Bonus". Passive data
-- service, QuestService-shaped: DataService owns the lifecycle (ApplyData/SerializeData/
-- Clear), this never touches a DataStore directly.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local CosmeticService = require(SSS.Scripts.Modules.CosmeticService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)

local DailyRewardService = {}

export type DailyRewardData = {
	lastClaimDay: number, -- UTC day (floor(os.time()/86400)) last successfully claimed; -1 = never
	streak: number,       -- consecutive daily claims (>= 1 once any claim has happened)
}

export type RewardResult =
	{ Kind: "Diamonds", Amount: number }
	| { Kind: "Cash", Amount: number }
	| { Kind: "Crate", BoxId: string, BoxName: string }

export type Info = {
	claimableToday: boolean,
	streak: number,    -- the streak THIS claim would lock in (preview, shown before claiming)
	luckBonus: number, -- fraction, e.g. 0.15 = +15% — matches `streak`'s preview
}

export type ClaimResult = {
	ok: boolean,
	reward: RewardResult?,
	streak: number?,
	luckBonus: number?,
}

local states: { [number]: DailyRewardData } = {}
local changedRE: RemoteEvent? = nil

local function currentDay(): number
	return math.floor(os.time() / 86400)
end

local function defaults(): DailyRewardData
	return { lastClaimDay = -1, streak = 0 }
end

local function get(userId: number): DailyRewardData
	return states[userId] or defaults()
end

-- The streak this claim would lock in: continues if the last claim was exactly yesterday,
-- otherwise (a gap, or never claimed) starts fresh at 1. Already claimed today -> unchanged
-- (nothing to project; buildInfo only uses this when claimableToday is true).
local function projectedStreak(d: DailyRewardData): number
	local today = currentDay()
	if d.lastClaimDay == today then
		return d.streak
	elseif d.lastClaimDay == today - 1 then
		return d.streak + 1
	end
	return 1
end

local function luckBonusFor(streak: number): number
	local bonusDays = math.clamp(streak - 1, 0, Config.DailyReward.MaxBonusDays)
	return bonusDays * Config.DailyReward.StreakBonusPerDay
end

local function buildInfo(player: Player): Info
	local d = get(player.UserId)
	local streak = projectedStreak(d)
	return {
		claimableToday = d.lastClaimDay ~= currentDay(),
		streak = streak,
		luckBonus = luckBonusFor(streak),
	}
end

--------------------------------------------------------------------------------
-- Reward rolling: Kind -> (player, entry, luckBonus) -> RewardResult, granting as a side
-- effect. Adding a new reward Kind is one function here + one Config.DailyReward.Pool entry
-- + a matching client cell/result renderer — nothing else changes.
--------------------------------------------------------------------------------

-- Weighted pick from the pool. (No skip logic needed anymore: the Crate kind is never a
-- dead roll — a duplicate marble stars up instead of being wasted.)
local function rollPoolEntry(_player: Player): any
	local pool = Config.DailyReward.Pool
	local total = 0
	for _, entry in pool do
		total += entry.Weight
	end
	local r = math.random() * total
	local acc = 0
	for _, entry in pool do
		acc += entry.Weight
		if r <= acc then
			return entry
		end
	end
	return pool[#pool]
end

local function rollDiamonds(player: Player, entry: any, luckBonus: number): RewardResult
	local base = math.random(entry.Min, entry.Max)
	local amount = math.floor(base * (1 + luckBonus) + 0.5)
	CosmeticService.AddCC(player, amount)
	return { Kind = "Diamonds", Amount = amount }
end

-- NOT scaled by the currently-selected bet (loadout.BetTier) — the highest tier the player
-- has ever unlocked (ProfileService.GetUpgradeTier), per the design: this reward reflects
-- overall progression, not whatever bet size happens to be selected right now.
local function rollCash(player: Player, entry: any, _luckBonus: number): RewardResult
	local ownedTier = ProfileService.GetUpgradeTier(player, "MaxBet")
	local betSize = ProfileStats.GetBetSizeAtTier(ownedTier)
	local amount = math.floor(betSize * entry.Multiplier)
	CurrencyService.AddPoints(player, amount, "Daily reward")
	return { Kind = "Cash", Amount = amount }
end

-- A free UNOPENED Marble Box (entry.BoxId picks which; defaults to Basic), banked into
-- the player's stash — they open it at the cosmetics shop whenever they like.
local function rollCrate(player: Player, entry: any, _luckBonus: number): RewardResult?
	local boxId = entry.BoxId or "Basic"
	if not CosmeticService.AddBox(player, boxId) then
		return nil
	end
	local boxName = boxId .. " Box"
	for _, box in Config.Crates.Boxes do
		if box.Id == boxId then
			boxName = box.Name
			break
		end
	end
	return { Kind = "Crate", BoxId = boxId, BoxName = boxName }
end

local REWARD_ROLLERS: { [string]: (Player, any, number) -> RewardResult? } = {
	Diamonds = rollDiamonds,
	Cash = rollCash,
	Crate = rollCrate,
}

function DailyRewardService.GetInfo(player: Player): Info
	return buildInfo(player)
end

-- Claim today's reward. No-op (ok=false) if already claimed today.
function DailyRewardService.Claim(player: Player): ClaimResult
	local d = get(player.UserId)
	local today = currentDay()
	if d.lastClaimDay == today then
		return { ok = false }
	end

	local streak = projectedStreak(d)
	local luckBonus = luckBonusFor(streak)

	local entry = rollPoolEntry(player)
	local roller = REWARD_ROLLERS[entry.Kind]
	local result = if roller then roller(player, entry, luckBonus) else nil
	if not result then
		-- Shouldn't happen (every pool Kind grants unconditionally), but never let a claim
		-- silently fail — fall back to a flat Diamonds grant.
		local amount = math.floor(10 * (1 + luckBonus) + 0.5)
		CosmeticService.AddCC(player, amount)
		result = { Kind = "Diamonds", Amount = amount }
	end

	d.lastClaimDay = today
	d.streak = streak
	states[player.UserId] = d

	if changedRE then
		changedRE:FireClient(player, buildInfo(player))
	end
	return { ok = true, reward = result, streak = streak, luckBonus = luckBonus }
end

--------------------------------------------------------------------------------
-- Data lifecycle (DataService-driven; never a direct DataStore call).
--------------------------------------------------------------------------------

function DailyRewardService.ApplyData(player: Player, saved: DailyRewardData?)
	local d = defaults()
	if saved then
		if type(saved.lastClaimDay) == "number" then
			d.lastClaimDay = saved.lastClaimDay
		end
		if type(saved.streak) == "number" then
			d.streak = saved.streak
		end
	end
	states[player.UserId] = d
end

function DailyRewardService.SerializeData(player: Player): DailyRewardData
	return get(player.UserId)
end

function DailyRewardService.Clear(player: Player)
	states[player.UserId] = nil
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local function getRemote(name: string, class: string): Instance
	local existing = RS.Remote:FindFirstChild(name)
	if existing then
		return existing
	end
	local r = Instance.new(class)
	r.Name = name
	r.Parent = RS.Remote
	return r
end

function DailyRewardService.Init()
	changedRE = getRemote("DailyRewardChanged", "RemoteEvent") :: RemoteEvent
	;(getRemote("GetDailyRewardInfo", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return DailyRewardService.GetInfo(player)
	end
	;(getRemote("ClaimDailyReward", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return DailyRewardService.Claim(player)
	end
end

return DailyRewardService
