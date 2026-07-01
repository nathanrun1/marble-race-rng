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
local AnnounceUI = require(RS.Shared.AnnounceUI)
local WarnUI = require(RS.Shared.WarnUI)
local StringUtils = require(RS.Shared.StringUtils)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local BallService = require(SSS.Scripts.Modules.BallService)
local StatsService = require(SSS.Scripts.Modules.StatsService)

local PrestigeService = {}

-- Banner colour for the "Rebirth available!" announce — matches PrestigeUI's violet.
local REBIRTH_PURPLE = Color3.fromRGB(179, 136, 255)

-- (player, info) — fired after prestige state changes.
PrestigeService.Changed = Signal.new()

export type PrestigeData = {
	count: number,
	-- True cumulative banked, never frozen — the cosmetic "Lifetime Banked" stat.
	lifetimeBanked: number,
	-- The portion of banking that has been credited toward earning PP. Stops growing
	-- while available PP is at the hold cap (the anti-hoard freeze), so excess banking
	-- past the cap yields no PP. Equals lifetimeBanked until the first time you cap out.
	creditedBanked: number,
	-- Total PP consumed by prestiges so far. availablePP = earnedPP(creditedBanked) - ppSpent.
	ppSpent: number,
}

local data: { [number]: PrestigeData } = {}

-- Runtime-only alert state (not persisted): whether prestige was affordable as of the last
-- banking (so "Prestige available!" announces once on the false→true edge), and the os.clock()
-- of the last "PP limit" nag (so it throttles to Config.Prestige.LimitWarnInterval).
local alertCanPrestige: { [number]: boolean } = {}
local lastLimitWarn: { [number]: number } = {}

local function get(player: Player): PrestigeData
	local d = data[player.UserId]
	assert(d, "No prestige data for " .. player.Name)
	return d
end

-- Total PP ever earned from a given amount of credited banking:
-- earnedPP = floor((creditedBanked / Scale) ^ Exponent). Concave (Exponent < 1).
local function computePP(creditedBanked: number): number
	return math.floor((creditedBanked / Config.Prestige.Scale) ^ Config.Prestige.Exponent)
end

-- Cost for the Nth prestige (1-indexed): ceil(CostBase × CostGrowth^(N-1))
local function computeCost(n: number): number
	return math.ceil(Config.Prestige.CostBase * Config.Prestige.CostGrowth ^ (n - 1))
end

-- Sum of costs for prestiges 1..n — the PP a player at `count = n` has already spent.
-- Looped (not closed-form) so it matches the per-level ceil() exactly.
local function totalCostThrough(n: number): number
	local total = 0
	for k = 1, n do
		total += computeCost(k)
	end
	return total
end

-- Available (spendable) PP and the current hold cap, from a player's data.
local function availablePP(d: PrestigeData): number
	return math.max(0, computePP(d.creditedBanked) - d.ppSpent)
end

local function holdCapFor(count: number): number
	return math.ceil(Config.Prestige.HoldCapMult * computeCost(count + 1))
end

-- The creditedBanked value at which available PP reaches the hold cap. Banking is clamped to
-- this (inverting earnedPP = (creditedBanked/Scale)^Exp), so available PP can't overshoot
-- HoldCapMult × nextCost no matter how large a single bank is — and creditedBanked never holds
-- a hidden reservoir above the cap that could chain a second rebirth after spending.
local function creditedCapFor(d: PrestigeData): number
	-- +0.5 so the floor in computePP lands cleanly on the cap (not cap-1 from float error),
	-- while still keeping floored available PP at exactly the cap and never above it.
	local earnedCap = d.ppSpent + holdCapFor(d.count) + 0.5
	return Config.Prestige.Scale * earnedCap ^ (1 / Config.Prestige.Exponent)
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
	local pp = availablePP(d)
	local nextCost = computeCost(d.count + 1)
	return {
		count = d.count,
		lifetimeBanked = d.lifetimeBanked,
		prestigePoints = pp, -- spendable PP, not lifetime total (earn/spend currency)
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

-- Dev only: directly set prestige count (bypasses cost check). Re-anchors ppSpent to the
-- cost of those prestiges so available PP stays consistent (e.g. /reset to count 0 zeroes it).
function PrestigeService.SetCount(player: Player, count: number)
	local d = get(player)
	d.count = count
	d.ppSpent = totalCostThrough(count)
	PrestigeService.Changed:Fire(player, buildInfo(d))
end

-- Dev only: directly set lifetime banked (adjusts PP without a real run). Sets both the
-- cosmetic total and the PP-crediting accumulator so available PP reflects it immediately.
function PrestigeService.SetLifetimeBanked(player: Player, amount: number)
	local d = get(player)
	d.lifetimeBanked = amount
	d.creditedBanked = amount
	PrestigeService.Changed:Fire(player, buildInfo(d))
end

-- Called by ScoreHandler every time a ball banks. Always grows the cosmetic lifetime total;
-- only credits PP while available PP is below the hold cap. Once you're holding ~HoldCapMult ×
-- the next cost, further banking earns no PP — so you can't farm lifetime banked into a
-- stockpile of prestiges; you have to actually prestige to make banking matter again.
function PrestigeService.AddLifetimeBanked(player: Player, amount: number)
	local d = data[player.UserId]
	if not d then
		return
	end
	d.lifetimeBanked += amount
	-- Credit PP, but hard-clamp at the cap so a single big bank can't overshoot it.
	local cap = creditedCapFor(d)
	d.creditedBanked = math.min(d.creditedBanked + amount, cap)
	local capped = d.creditedBanked >= cap

	-- Announce the moment prestige becomes affordable (once, on the rising edge).
	local info = buildInfo(d)
	if info.canPrestige and not alertCanPrestige[player.UserId] then
		AnnounceUI.Announce(player, "Rebirth available!", REBIRTH_PURPLE, 3)
	end
	alertCanPrestige[player.UserId] = info.canPrestige

	-- While banking is capped (PP wasted until they rebirth), nag at most once per interval.
	if capped then
		local now = os.clock()
		if now - (lastLimitWarn[player.UserId] or 0) >= Config.Prestige.LimitWarnInterval then
			WarnUI.Warn(player, "RP limit exceeded, rebirth recommended", nil, 5)
			lastLimitWarn[player.UserId] = now
		end
	end

	PrestigeService.Changed:Fire(player, info)
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

	-- Spend the PP: deduct this prestige's cost so it can't be re-spent. creditedBanked is
	-- left intact (it's a high-water mark), so available PP simply drops by nextCost — leaving
	-- at most the ~1× buffer the hold cap allows, never enough to chain a second prestige.
	d.ppSpent += info.nextCost
	-- Rebirthing converts the RP spent on this rebirth into CC (the cosmetics currency). Lazy-require
	-- to avoid a load-time cycle, same as the ScoringService/UpgradeService requires above.
	local CosmeticService = require(SSS.Scripts.Modules.CosmeticService)
	local ccGained = math.floor(info.nextCost * Config.Cosmetics.RebirthCCRatio)
	CosmeticService.AddCC(player, ccGained)
	if ccGained > 0 then
		WarnUI.Warn(player, "Earned " .. StringUtils.FormatShort(ccGained) .. " CC!", Color3.fromRGB(255, 210, 60), 4)
	end
	d.count += 1
	-- Re-arm the "Prestige available!" edge so it announces again next time they climb back.
	alertCanPrestige[player.UserId] = false
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
	local count = (saved and saved.count) or 0
	local lifetimeBanked = (saved and saved.lifetimeBanked) or 0
	local d: PrestigeData = {
		count = count,
		lifetimeBanked = lifetimeBanked,
		-- Back-compat: data saved before the earn/spend split has no creditedBanked/ppSpent.
		-- Credit equals the lifetime total, and treat the player's existing prestiges as already
		-- paid for (sum of their costs), so available PP starts consistent rather than refunding
		-- every past prestige at once.
		creditedBanked = (saved and saved.creditedBanked) or lifetimeBanked,
		ppSpent = (saved and saved.ppSpent) or totalCostThrough(count),
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
	alertCanPrestige[player.UserId] = nil
	lastLimitWarn[player.UserId] = nil
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
