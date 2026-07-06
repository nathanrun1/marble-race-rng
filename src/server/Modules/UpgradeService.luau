--!strict
-- Authority over purchasing upgrades. Owns pricing (data-driven from Config) and
-- processes purchase requests from the shop UI. Reads/writes player state through
-- ProfileService (tiers) and CurrencyService (cost).
--
-- Scalable by design: every track in Config.Upgrades is automatically priced and
-- purchasable. Adding an upgrade is a Config.Upgrades entry — nothing changes here.
--
-- UI contract (RemoteFunctions under RS.Remote, created on Init):
--   GetUpgradeInfo()        -> { [track]: Info }    snapshot to render the shop
--   PurchaseUpgrade(track)  -> PurchaseResult       buy one tier, get fresh state

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Config = require(RS.Shared.Config)
local UpgradeInfo = require(RS.Shared.UpgradeInfo)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local StatsService = require(SSS.Scripts.Modules.StatsService)
local SoundService = require(RS.Shared.SoundService)
local ProductService = require(RS.Shared.ProductService)

local UpgradeService = {}

-- Instant-tiers dev product: grants this many free tiers on the chosen track.
-- Config.Products ids are authored as strings; the Marketplace APIs use numbers.
local BOOST_TIERS = 3
local BOOST_PRODUCT_ID = tonumber(Config.Products.UpgradeBoost)

-- Defs, pricing, caps, and the Info shape all live in shared/UpgradeInfo — the SAME pure
-- math the client renders from (ShopUI/UpgradeShop compute their displays locally). This
-- module stays the authority on actual purchases: it feeds UpgradeInfo the authoritative
-- tier/balance and does the atomic deduct+increment.
type UpgradeDef = UpgradeInfo.UpgradeDef
local UpgradeDefs = UpgradeInfo.Defs

export type Info = UpgradeInfo.Info
export type PurchaseResult = {
	ok: boolean,
	reason: string?,               -- "invalid_track" | "maxed" | "cannot_afford"
	upgrades: { [string]: Info }?, -- fresh snapshot for the UI to re-render
}

local maxTierOf = UpgradeInfo.MaxTierOf
local priceAt = UpgradeInfo.PriceAt

function UpgradeService.GetInfo(player: Player, track: string): Info?
	return UpgradeInfo.Build(
		track,
		ProfileService.GetUpgradeTier(player, track),
		CurrencyService.GetPoints(player)
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
	local tier = ProfileService.GetUpgradeTier(player, track)
	local price = priceAt(track, tier)
	if not price then
		return { ok = false, reason = "maxed", upgrades = UpgradeService.GetAllInfo(player) }
	end
	if CurrencyService.GetPoints(player) < price then
		return { ok = false, reason = "cannot_afford", upgrades = UpgradeService.GetAllInfo(player) }
	end

	CurrencyService.AddPoints(player, -price, "Upgrade: " .. track)
	ProfileService.SetUpgradeTier(player, track, tier + 1)
	StatsService.AddUpgradesPurchased(player, 1)
	-- MaxBet raises the ceiling of the bet ladder; jump the player's SELECTED bet tier to the
	-- rung they just bought too (matching the "just click max after upgrading" habit from
	-- before the raise/lower system existed), regardless of which UI bought it — the shop's
	-- buy button or BallLaunchUI's own unlock flow (which also does this locally, redundantly
	-- but harmlessly, since SetBetTier is idempotent at the same tier).
	if track == "MaxBet" then
		ProfileService.SetBetTier(player, tier + 1)
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
	if not BOOST_PRODUCT_ID then
		warn("UpgradeService: Config.Products.UpgradeBoost is not a valid product id")
		return nil
	end
	local tier = ProfileService.GetUpgradeTier(player, track)
	-- Don't prompt on a still-locked track — the 3× pack isn't offered until it's unlocked.
	if def.Locked == true and tier == 0 then
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

local function getRemoteFunction(name: string): RemoteFunction
	local remotes = RS.Remote
	local existing = remotes:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = remotes
	return rf
end

function UpgradeService.Init()
	getRemoteFunction("GetUpgradeInfo").OnServerInvoke = function(player: Player)
		return UpgradeService.GetAllInfo(player)
	end
	getRemoteFunction("PurchaseUpgrade").OnServerInvoke = function(player: Player, track: any)
		if type(track) ~= "string" then
			return { ok = false, reason = "invalid_track" }
		end
		return UpgradeService.Purchase(player, track)
	end
	-- Client asks to buy the instant-tiers product for a track; we record intent and
	-- return the product id to prompt (nil if invalid/unconfigured).
	getRemoteFunction("RequestUpgradeBoost").OnServerInvoke = function(player: Player, track: any)
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
			SoundService.PlayForClient(player, { soundId = Config.Sounds.Upgrade })
			return true
		end)
	end
end

return UpgradeService
