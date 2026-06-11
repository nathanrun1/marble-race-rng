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
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

local UpgradeService = {}

-- Loose indexer view of Config.Upgrades for dynamic (track-name) access. The
-- precise struct stays available to ProfileStats; here we only read the fields
-- relevant to pricing, caps, and display.
type UpgradeDef = {
	Cost: { Base: number, Growth: number },
	Name: string?,
	Desc: string?,
	Caps: { number }?,                         -- Frequency: tier cap = #Caps - 1
	Widths: { number }?,                       -- Arc: tier cap = #Widths - 1
	Ranges: { { Min: number, Max: number } }?, -- continuous axes: cap = #Ranges - 1
}

-- Everything purchasable: the idle/scoring tracks (Config.Upgrades) AND the
-- continuous axes (Config.Axes), whose tier unlocks a wider range. Tiers for both
-- already live together in ProfileService's upgrades table, so they sell the same
-- way. A listed entry must have a Cost.
local UpgradeDefs: { [string]: UpgradeDef } = {}
for name, def in (Config.Upgrades :: any) do
	UpgradeDefs[name] = def
end
for name, def in (Config.Axes :: any) do
	UpgradeDefs[name] = def
end

export type Info = {
	track: string,
	name: string,
	desc: string,
	tier: number,
	maxTier: number?, -- nil = unbounded
	maxed: boolean,
	price: number?,   -- nil if maxed
	canAfford: boolean,
}
export type PurchaseResult = {
	ok: boolean,
	reason: string?,               -- "invalid_track" | "maxed" | "cannot_afford"
	upgrades: { [string]: Info }?, -- fresh snapshot for the UI to re-render
}

-- List-based tracks (Caps/Widths/Ranges) cap at their list length; others are
-- unbounded.
local function maxTierOf(def: UpgradeDef): number?
	if def.Caps then
		return #def.Caps - 1
	elseif def.Widths then
		return #def.Widths - 1
	elseif def.Ranges then
		return #def.Ranges - 1
	end
	return nil
end

-- Cost to buy currentTier -> currentTier+1, or nil if already maxed. Geometric:
-- first tier costs Base, each further tier multiplies by Growth.
local function priceAt(track: string, currentTier: number): number?
	local def = UpgradeDefs[track]
	local maxTier = maxTierOf(def)
	if maxTier and currentTier >= maxTier then
		return nil
	end
	return math.floor(def.Cost.Base * (def.Cost.Growth ^ currentTier))
end

function UpgradeService.GetInfo(player: Player, track: string): Info?
	local def = UpgradeDefs[track]
	if not def then
		return nil
	end
	local tier = ProfileService.GetUpgradeTier(player, track)
	local price = priceAt(track, tier)
	return {
		track = track,
		name = def.Name or track,
		desc = def.Desc or "",
		tier = tier,
		maxTier = maxTierOf(def),
		maxed = price == nil,
		price = price,
		canAfford = price ~= nil and CurrencyService.GetPoints(player) >= price,
	}
end

-- Whole-shop snapshot: one Info per track. What the shop UI renders from.
function UpgradeService.GetAllInfo(player: Player): { [string]: Info }
	local out: { [string]: Info } = {}
	for track in UpgradeDefs do
		out[track] = UpgradeService.GetInfo(player, track)
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
	if not UpgradeDefs[track] then
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
	return { ok = true, upgrades = UpgradeService.GetAllInfo(player) }
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
end

return UpgradeService
