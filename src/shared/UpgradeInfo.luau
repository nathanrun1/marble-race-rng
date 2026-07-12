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

-- Cost to buy currentTier -> currentTier+1, or nil if already maxed (or unknown track).
-- Geometric: first tier costs Base (or the flat Initial), each further tier multiplies
-- by Growth.
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
	return math.floor(def.Cost.Base * (def.Cost.Growth ^ currentTier))
end

-- One track's shop Info, computed from an explicit tier + cash balance.
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
