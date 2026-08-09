--!strict
-- Pure upgrade-shop math, shared by server and client so both compute IDENTICAL prices,
-- caps, and affordability from Config alone:
--   - UpgradeService (server) prices real purchases with it (authoritative — the client
--     never tells the server a price).
--   - ShopUI / UpgradeShop (client) render the shop and pad billboards from it locally,
--     using the tiers/balance the server already pushes (ProfileChanged / BalanceChanged),
--     with no per-render round trip.
--
-- Everything here is a pure function of (track, tier, points) — no player objects, no
-- services, no yielding.

local RS = game:GetService("ReplicatedStorage")

local UpgradesConfig = require(RS.Shared.Config.Upgrades)
local UpgradeInfo = {}

-- Loose indexer view of a UpgradesConfig.Tracks / UpgradesConfig.Axes entry: only the fields relevant
-- to pricing, caps, and display (the precise structs stay available to ProfileStats).
export type UpgradeDef = {
	Cost: { Initial: number?, Base: number, Growth: number },
	Name: string?,
	Desc: string?,
	Icon: string?,
	Caps: { number }?,                         -- Frequency: tier cap = #Caps - 1
	Widths: { number }?,                       -- Arc: tier cap = #Widths - 1
	Ranges: { { Min: number, Max: number } }?, -- continuous axes: cap = #Ranges - 1
	MaxTier: number?,
	Currency: string?,                         -- "Diamonds" for wholly CC-priced tracks; nil/absent = cash
	BarrierEvery: number?,                     -- barrier ladder (Luck): every Nth purchase is a Diamond barrier
	BarrierCost: { Base: number, Growth: number }?, -- Diamond curve at barriers, geometric in barriers crossed
	PersistsRebirth: boolean?,                 -- true: ProfileService.ResetProfile leaves the tier alone
}

export type Info = {
	track: string,
	name: string,
	desc: string,
	icon: string,
	tier: number,
	maxTier: number?, -- nil = unbounded
	maxed: boolean,
	price: number?,   -- nil if maxed
	currency: string, -- "Cash" | "Diamonds" — what `price` is denominated in (per-TIER on barrier tracks)
	barrier: boolean, -- barrier-ladder tracks: the next purchase is the Diamond barrier into the next display tier
	canAfford: boolean,
	-- NOTE: per-track "Locked" gating is gone — upgrade gating is now the world
	-- UpgradeLock models (server UpgradeLockService / client UpgradeLocks), which sit
	-- OUTSIDE this pure math: a gated track prices normally here but can't be bought
	-- or opened until its lock is purchased.
}

-- Everything purchasable: the idle/scoring tracks (UpgradesConfig.Tracks) AND the continuous
-- axes (UpgradesConfig.Axes), whose tier unlocks a wider range. Tiers for both already live
-- together in the profile's upgrades table, so they sell the same way.
local Defs: { [string]: UpgradeDef } = {}
for name, def in (UpgradesConfig.Tracks :: any) do
	Defs[name] = def
end
for name, def in (UpgradesConfig.Axes :: any) do
	Defs[name] = def
end

UpgradeInfo.Defs = Defs

-- List-based tracks (Caps/Widths/Ranges) cap at their list length; others are unbounded.
function UpgradeInfo.MaxTierOf(def: UpgradeDef): number?
	if def.Caps then
		return #def.Caps - 1
	elseif def.Widths then
		return #def.Widths - 1
	elseif def.Ranges then
		return #def.Ranges - 1
	elseif def.MaxTier then
		return def.MaxTier
	end
	return nil
end

-- Barrier-ladder tracks (BarrierEvery, currently Luck): is the purchase
-- currentTier -> currentTier+1 the Diamond barrier into the next display tier?
function UpgradeInfo.IsBarrierAt(track: string, currentTier: number): boolean
	local def = Defs[track]
	local every = def and def.BarrierEvery
	return every ~= nil and (currentTier + 1) % every == 0
end

-- The currency the NEXT purchase on `track` charges: "Diamonds" for wholly
-- Diamond-priced tracks and for barrier purchases on barrier-ladder tracks,
-- otherwise "Cash". The single authority both UpgradeService (real deduct) and
-- the shop UIs (display/affordability) price from.
function UpgradeInfo.CurrencyAt(track: string, currentTier: number): string
	local def = Defs[track]
	if def and def.Currency == "Diamonds" then
		return "Diamonds"
	end
	if UpgradeInfo.IsBarrierAt(track, currentTier) then
		return "Diamonds"
	end
	return "Cash"
end

-- Roman numeral suffix for a barrier-ladder sub-tier (1..BarrierEvery-1).
local SUB_TIER_NUMERAL = { "I", "II", "III", "IV", "V", "VI", "VII" }

-- Display label for a tier. Barrier-ladder tracks read "1", "1-I", "1-II", "1-III",
-- "2", ... (display tier = internal // BarrierEvery + 1, roman-numeral suffix per
-- sub-tier); everything else is the plain tier number.
function UpgradeInfo.TierLabel(track: string, tier: number): string
	local def = Defs[track]
	local every = def and def.BarrierEvery
	if every then
		local base = tostring(tier // every + 1)
		local sub = tier % every
		if sub == 0 then
			return base
		end
		return base .. "-" .. (SUB_TIER_NUMERAL[sub] or tostring(sub))
	end
	return tostring(tier)
end

-- Cost to buy currentTier -> currentTier+1, or nil if already maxed (or unknown track).
-- Geometric: first tier costs Base (or the flat Initial), each further tier multiplies
-- by Growth. Barrier purchases (IsBarrierAt) price off BarrierCost instead — geometric
-- in the number of barriers already crossed, i.e. one Growth step per display tier.
function UpgradeInfo.PriceAt(track: string, currentTier: number): number?
	local def = Defs[track]
	if not def then
		return nil
	end
	if currentTier == 0 and def.Cost.Initial then
		return def.Cost.Initial
	end
	local maxTier = UpgradeInfo.MaxTierOf(def)
	if maxTier and currentTier >= maxTier then
		return nil
	end
	local barrierCost = def.BarrierCost
	if barrierCost and UpgradeInfo.IsBarrierAt(track, currentTier) then
		local barriersCrossed = (currentTier + 1) // (def.BarrierEvery :: number) - 1
		return math.floor(barrierCost.Base * (barrierCost.Growth ^ barriersCrossed))
	end
	return math.floor(def.Cost.Base * (def.Cost.Growth ^ currentTier))
end

-- One track's shop Info, computed from an explicit tier + balance. `points` must be the
-- balance of the NEXT purchase's currency (CurrencyAt — cash for most tracks, Diamonds
-- at Luck's barriers) — the caller picks; canAfford is computed against whatever it passes.
function UpgradeInfo.Build(track: string, tier: number, points: number): Info?
	local def = Defs[track]
	if not def then
		return nil
	end
	local price = UpgradeInfo.PriceAt(track, tier)
	return {
		track = track,
		name = def.Name or track,
		desc = def.Desc or "",
		icon = def.Icon or "",
		tier = tier,
		maxTier = UpgradeInfo.MaxTierOf(def),
		maxed = price == nil,
		price = price,
		currency = UpgradeInfo.CurrencyAt(track, tier),
		barrier = UpgradeInfo.IsBarrierAt(track, tier),
		canAfford = price ~= nil and points >= price,
	}
end

-- Whole-shop snapshot from an upgrades table (profile.upgrades shape) + cash balance.
function UpgradeInfo.BuildAll(upgrades: { [string]: number }, points: number): { [string]: Info }
	local out: { [string]: Info } = {}
	for track in Defs do
		out[track] = UpgradeInfo.Build(track, upgrades[track] or 0, points) :: Info
	end
	return out
end

return UpgradeInfo
