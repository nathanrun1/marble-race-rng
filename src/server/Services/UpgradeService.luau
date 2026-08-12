--!strict
-- Authority over purchasing upgrades. Owns pricing (data-driven from Config) and
-- processes purchase requests from the shop UI. Reads/writes player state through
-- ProfileService (tiers) and CurrencyService (cost).
--
-- Scalable by design: every track in UpgradesConfig.Tracks is automatically priced and
-- purchasable. Adding an upgrade is a UpgradesConfig.Tracks entry — nothing changes here.
--
-- UI contract (RemoteFunctions in UpgradeNet):
--   GetUpgradeInfo()        -> { [track]: Info }    snapshot to render the shop
--   PurchaseUpgrade(track)  -> PurchaseResult       buy one tier, get fresh state

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local MonetizationConfig = require(RS.Shared.Config.Monetization)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local UpgradeInfo = require(RS.Shared.UpgradeInfo)
local ProfileService = require(SSS.Scripts.Services.ProfileService)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local StatsService = require(SSS.Scripts.Services.StatsService)
local UpgradeLockService = require(SSS.Scripts.Services.UpgradeLockService)
local SoundService = require(RS.Shared.SoundService)
local ProductService = require(RS.Shared.ProductService)
local UpgradeNet = require(RS.Shared.Remote.UpgradeNet)
local Signal = require(RS.Shared.Utility.Signal)

local UpgradeService = {}

-- Fires when a player buys a ZONE (a MaxBet tier) through Purchase — the deliberate
-- "advance a zone" action, distinct from the generic StatsService.UpgradesAdded (which fires
-- for every track). Signature (player, newTier). Consumed by StarterQuestService's
-- "UpgradeZone" mission. Fired only from Purchase, so free grants (dev product / prestige
-- perk / starter pack via raiseTrack) don't count toward the quest.
UpgradeService.ZoneUpgraded = Signal.new()

-- Instant-tiers dev product: grants this many free tiers on the chosen track.
-- MonetizationConfig.Products ids are authored as strings; the Marketplace APIs use numbers.
local BOOST_TIERS = 3
local BOOST_PRODUCT_ID = tonumber(MonetizationConfig.Products.UpgradeBoost)

-- Defs, pricing, caps, and the Info shape all live in shared/UpgradeInfo — the SAME pure
-- math the client renders from (ShopUI/UpgradeShop compute their displays locally). This
-- module stays the authority on actual purchases: it feeds UpgradeInfo the authoritative
-- tier/balance and does the atomic deduct+increment.
type UpgradeDef = UpgradeInfo.UpgradeDef
local UpgradeDefs = UpgradeInfo.Defs

export type Info = UpgradeInfo.Info
export type PurchaseResult = {
	ok: boolean,
	reason: string?,               -- "invalid_track" | "locked" | "maxed" | "cannot_afford" | "disabled"
	upgrades: { [string]: Info }?, -- fresh snapshot for the UI to re-render
}

-- Tracks temporarily not for sale (kept as a switch; currently none — bet sizing is back:
-- a ball's value = bet size × rarity multiplier, see BallLaunchService.ballValueForSkin).
local DISABLED_TRACKS: { [string]: boolean } = {}

local maxTierOf = UpgradeInfo.MaxTierOf
local priceAt = UpgradeInfo.PriceAt

-- The balance of the NEXT purchase's currency (UpgradeInfo.CurrencyAt): cash for most
-- purchases, Diamonds (CC) at Luck's barrier tiers. CosmeticService is lazy-required
-- (same pattern as PrestigeService) so this module adds no load-time edge toward the
-- known ProductService -> DataService -> CosmeticService require chain.
local function balanceFor(player: Player, track: string): number
	if UpgradeInfo.CurrencyAt(track, ProfileService.GetUpgradeTier(player, track)) == "Diamonds" then
		local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
		return CosmeticService.GetCC(player)
	end
	return CurrencyService.GetPoints(player)
end

function UpgradeService.GetInfo(player: Player, track: string): Info?
	return UpgradeInfo.Build(
		track,
		ProfileService.GetUpgradeTier(player, track),
		balanceFor(player, track)
	)
end

-- Whole-shop snapshot: one Info per track. What the shop UI renders from.
function UpgradeService.GetAllInfo(player: Player): { [string]: Info }
	local out: { [string]: Info } = {}
	for track in UpgradeDefs do
		out[track] = UpgradeService.GetInfo(player, track) :: Info
	end
	return out
end

-- Price of the next tier for one track (the "request a price" function). nil if
-- the track is invalid or already maxed.
function UpgradeService.GetPrice(player: Player, track: string): number?
	if not UpgradeDefs[track] then
		return nil
	end
	return priceAt(track, ProfileService.GetUpgradeTier(player, track))
end

-- Buy exactly one tier. Server-authoritative: validates track, cap, and funds,
-- then deducts and increments. There is no yield between the funds check and the
-- deduct, so it is atomic against concurrent requests.
function UpgradeService.Purchase(player: Player, track: string): PurchaseResult
	if UpgradeDefs[track] == nil then
		return { ok = false, reason = "invalid_track" }
	end
	if DISABLED_TRACKS[track] then
		return { ok = false, reason = "disabled", upgrades = UpgradeService.GetAllInfo(player) }
	end
	-- A track behind an unbought world lock can't be purchased at all (the client
	-- greys its kiosk out; this is the authority behind that).
	if UpgradeLockService.IsTrackLocked(player, track) then
		return { ok = false, reason = "locked", upgrades = UpgradeService.GetAllInfo(player) }
	end
	local tier = ProfileService.GetUpgradeTier(player, track)
	local price = priceAt(track, tier)
	if not price then
		return { ok = false, reason = "maxed", upgrades = UpgradeService.GetAllInfo(player) }
	end
	-- Deduct in this PURCHASE's currency (per-tier on barrier-ladder tracks: Luck's
	-- barrier tiers charge Diamonds, its sub-tiers cash). Both paths are atomic against
	-- concurrent requests (no yield between check and deduct; SpendCC re-checks internally).
	if UpgradeInfo.CurrencyAt(track, tier) == "Diamonds" then
		local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
		if not CosmeticService.SpendCC(player, price) then
			return { ok = false, reason = "cannot_afford", upgrades = UpgradeService.GetAllInfo(player) }
		end
	else
		if CurrencyService.GetPoints(player) < price then
			return { ok = false, reason = "cannot_afford", upgrades = UpgradeService.GetAllInfo(player) }
		end
		CurrencyService.AddPoints(player, -price, "Upgrade: " .. track)
	end
	ProfileService.SetUpgradeTier(player, track, tier + 1)
	StatsService.AddUpgradesPurchased(player, 1)
	-- Buying the Zone track IS moving to the next zone (its whole pitch), so the selected
	-- bet tier jumps to the newly owned rung here, in the one place every purchase surface
	-- (kiosk, launch bar, auto button) funnels through. SetBetTier clamps and fires its own
	-- ProfileChanged, which repaints the board/zone client-side. This intentionally dropped
	-- the old "kiosk buys don't bump" guard — post-Zone-reframe, buying and not moving read
	-- as a bug.
	if track == "MaxBet" then
		ProfileService.SetBetTier(player, tier + 1)
		UpgradeService.ZoneUpgraded:Fire(player, tier + 1)
	end
	return { ok = true, upgrades = UpgradeService.GetAllInfo(player) }
end

-- Raise a track to `targetTier` (clamped to its cap, never lowered), crediting the
-- tiers actually gained to the player's upgrade stat. Returns tiers gained.
local function raiseTrack(player: Player, track: string, targetTier: number): number
	local def = UpgradeDefs[track]
	if not def then
		return 0
	end
	local current = ProfileService.GetUpgradeTier(player, track)
	local maxTier = maxTierOf(def)
	if maxTier then
		targetTier = math.min(targetTier, maxTier)
	end
	targetTier = math.max(targetTier, current) -- monotonic
	local gained = targetTier - current
	if gained > 0 then
		ProfileService.SetUpgradeTier(player, track, targetTier)
		StatsService.AddUpgradesPurchased(player, gained)
	end
	return gained
end

-- Grant `count` free tiers on a track (no cost), clamped to the track's max tier.
-- Used by the instant-tiers dev product. Returns tiers actually granted.
function UpgradeService.GrantTiers(player: Player, track: string, count: number): number
	return raiseTrack(player, track, ProfileService.GetUpgradeTier(player, track) + count)
end

-- Raise every upgrade track to at least `tier` (free). Used by the starter pack and
-- the post-prestige perk. Returns total tiers granted across all tracks.
function UpgradeService.RaiseAllTracksTo(player: Player, tier: number): number
	local total = 0
	for track in UpgradeDefs do
		total += raiseTrack(player, track, tier)
	end
	return total
end

-- The player intends to buy the instant-tiers product for `track`. Validate it,
-- record it (persisted, so a crash/rejoin before the receipt processes still knows
-- what to grant), and return the product id for the client to prompt. nil if the
-- track is invalid or the product isn't configured.
function UpgradeService.RequestBoost(player: Player, track: string): number?
	local def = UpgradeDefs[track]
	if not def then
		return nil
	end
	if DISABLED_TRACKS[track] then
		return nil
	end
	if not BOOST_PRODUCT_ID then
		warn("UpgradeService: MonetizationConfig.Products.UpgradeBoost is not a valid product id")
		return nil
	end
	local tier = ProfileService.GetUpgradeTier(player, track)
	-- Don't prompt on a track behind an unbought world lock — the 3× pack isn't
	-- offered until the lock is purchased.
	if UpgradeLockService.IsTrackLocked(player, track) then
		return nil
	end
	-- Don't prompt on a maxed track — there'd be nothing to grant.
	local maxTier = maxTierOf(def)
	if maxTier and tier >= maxTier then
		return nil
	end
	ProfileService.SetPendingBoostTrack(player, track)
	return BOOST_PRODUCT_ID
end


function UpgradeService.Init()
	UpgradeNet.GetUpgradeInfo.OnServerInvoke = function(player: Player)
		return UpgradeService.GetAllInfo(player)
	end
	UpgradeNet.PurchaseUpgrade.OnServerInvoke = function(player: Player, track: any)
		if type(track) ~= "string" then
			return { ok = false, reason = "invalid_track" }
		end
		return UpgradeService.Purchase(player, track)
	end
	-- Client asks to buy the instant-tiers product for a track; we record intent and
	-- return the product id to prompt (nil if invalid/unconfigured).
	UpgradeNet.RequestUpgradeBoost.OnServerInvoke = function(player: Player, track: any)
		if type(track) ~= "string" then
			return nil
		end
		return UpgradeService.RequestBoost(player, track)
	end

	-- Fulfilment: when the instant-tiers product is purchased, grant the tiers on the
	-- track the player recorded, then clear it. Returns false (retry) if we don't know
	-- the track yet — ProcessReceipt will retry until the pending track is available.
	if BOOST_PRODUCT_ID then
		ProductService.RegisterProduct(BOOST_PRODUCT_ID, function(player: Player, _receiptInfo: any): boolean
			local track = ProfileService.GetPendingBoostTrack(player)
			if not track or not UpgradeDefs[track] then
				return false
			end
			UpgradeService.GrantTiers(player, track, BOOST_TIERS)
			ProfileService.SetPendingBoostTrack(player, nil)
			SoundService.PlayForClient(player, { soundId = SoundsConfig.Upgrade })
			return true
		end)
	end
end

return UpgradeService
