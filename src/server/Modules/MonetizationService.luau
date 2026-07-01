--!strict
-- Wires the standalone Robux perks to their grant logic by registering ProductService
-- handlers: the cash-multiplier tiers and the starter pack. (The upgrade-boost product
-- is registered by UpgradeService, since it's an extension of the upgrade buy flow.)
--
-- Lives separately from the data it touches so there's no dependency cycle: it depends
-- on the gameplay/data services, but nothing depends on it.
--
-- Config.Products ids are authored as strings; the Marketplace APIs use numbers, so we
-- tonumber() them here.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)
local SoundService = require(RS.Shared.SoundService)
local ScoreUI = require(RS.Shared.ScoreUI)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local ProductService = require(RS.Shared.ProductService)
local StatsService = require(SSS.Scripts.Modules.StatsService)
local UpgradeService = require(SSS.Scripts.Modules.UpgradeService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local DataService = require(SSS.Scripts.Modules.DataService)
local CosmeticService = require(SSS.Scripts.Modules.CosmeticService)
local BallSkins = require(RS.Shared.BallSkins)

local MonetizationService = {}

-- Resolve a Config.Products string id to a number, warning if it's missing/invalid.
local function productId(key: string): number?
	local id = tonumber((Config.Products :: any)[key])
	if not id then
		warn(("MonetizationService: Config.Products.%s is not a valid product id"):format(key))
	end
	return id
end

local function registerCashMultipliers()
	for _, level in Config.CashMultiplier.Levels do
		local id = productId("Multiplier" .. tostring(level) .. "x")
		if id then
			ProductService.RegisterProduct(id, function(player: Player, _receiptInfo: any): boolean
				-- SetCashMultiplier only ever raises, so re-buying a lower/equal tier or
				-- a retried receipt is a safe no-op.
				StatsService.SetCashMultiplier(player, level)
				return true
			end)
		end
	end
end

-- Apply the starter pack's rewards once. Idempotent via the ownsStarterPack flag, so
-- it's safe to call from both the purchase event and the on-load ownership check.
local function grantStarterPack(player: Player)
	-- Admins never receive the starter pack, even if they own the game pass (the on-load
	-- ownership check would otherwise grant it).
	if table.find(Config.Admins, player.UserId) then
		return
	end
	if StatsService.OwnsStarterPack(player) then
		return
	end
	UpgradeService.RaiseAllTracksTo(player, Config.StarterPack.UpgradeTiers)
	CurrencyService.AddPoints(player, Config.StarterPack.Balance, "Starter Pack")
	StatsService.SetOwnsStarterPack(player, true)
	DataService.SaveNow(player) -- persist the grant promptly (real money)

	SoundService.PlayForClient(player, { soundId = Config.Sounds.Upgrade })
	AnnounceUI.Announce(player, "Starter Pack Claimed!", Color3.fromRGB(255, 215, 0))
	ScoreUI.PostMessage(
		player,
		"Starter Pack Bonus! " .. StringUtils.FormatMoney(Config.StarterPack.Balance),
		Color3.fromRGB(55, 132, 170)
	)
end

local function registerStarterPack()
	local id = tonumber(Config.GamePasses.StarterPack)
	if not id then
		warn("MonetizationService: Config.GamePasses.StarterPack is not a valid game pass id")
		return
	end
	-- The starter pack is a permanent game pass, not a consumable product.
	ProductService.RegisterGamePass(id, grantStarterPack)
	-- Catch players who already own the pass (bought in a past session, or a purchase
	-- whose finished event we missed): grant once their data has loaded. Spawned so the
	-- ownership async call never blocks DataService.
	DataService.Loaded:Connect(function(player: Player)
		task.spawn(function()
			if ProductService.PlayerOwnsGamePass(player, id) then
				grantStarterPack(player)
			end
		end)
	end)
end

-- Robux fallback for buying a cosmetic the player can't afford with CC: one dev product per rarity
-- (Config.Cosmetics.RarityProducts). Each grants the player's currently-selected skin, but only if
-- its rarity matches the product — so a cheap (low-rarity) product can't unlock a rarer skin.
local function registerCosmeticFallback()
	for rarity, idStr in Config.Cosmetics.RarityProducts do
		local id = tonumber(idStr)
		if id and id ~= 0 then
			ProductService.RegisterProduct(id, function(player: Player, _receiptInfo: any): boolean
				local skinId = CosmeticService.GetSelected(player)
				local skin = BallSkins.Get(skinId)
				if skin and skin.rarity == rarity then
					CosmeticService.GrantSkin(player, skinId)
				end
				return true
			end)
		end
	end
end

function MonetizationService.Init()
	registerCashMultipliers()
	registerStarterPack()
	registerCosmeticFallback()
end

return MonetizationService
