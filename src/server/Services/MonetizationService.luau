--!strict
-- Wires the standalone Robux perks to their grant logic by registering ProductService
-- handlers: the cash-multiplier tiers and the starter pack. (The upgrade-boost product
-- is registered by UpgradeService, since it's an extension of the upgrade buy flow.)
--
-- Lives separately from the data it touches so there's no dependency cycle: it depends
-- on the gameplay/data services, but nothing depends on it.
--
-- MonetizationConfig.Products ids are authored as strings; the Marketplace APIs use numbers, so we
-- tonumber() them here.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local AdminConfig = require(RS.Shared.Config.Admin)
local CosmeticsConfig = require(RS.Shared.Config.Cosmetics)
local MonetizationConfig = require(RS.Shared.Config.Monetization)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local SoundService = require(RS.Shared.SoundService)
local ScoreUI = require(RS.Shared.ScoreUI)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local ProductService = require(RS.Shared.ProductService)
local StatsService = require(SSS.Scripts.Services.StatsService)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local DataService = require(SSS.Scripts.Services.DataService)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local BallLaunchService = require(SSS.Scripts.Services.BallLaunchService)
local BallSkins = require(RS.Shared.BallSkins)

local MonetizationService = {}

-- Resolve a MonetizationConfig.Products string id to a number, warning if it's missing/invalid.
local function productId(key: string): number?
	local id = tonumber((MonetizationConfig.Products :: any)[key])
	if not id then
		warn(("MonetizationService: MonetizationConfig.Products.%s is not a valid product id"):format(key))
	end
	return id
end

local function registerCashMultipliers()
	for _, level in MonetizationConfig.CashMultiplier.Levels do
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
	if AdminConfig.IsAdmin(player.UserId) then
		return
	end
	if StatsService.OwnsStarterPack(player) then
		return
	end
	CurrencyService.AddPoints(player, MonetizationConfig.StarterPack.Balance, "Starter Pack")
	CosmeticService.AddCC(player, MonetizationConfig.StarterPack.Diamonds)
	for _ = 1, MonetizationConfig.StarterPack.Crates.Count do
		CosmeticService.GrantCrateRollAnnounced(player, MonetizationConfig.StarterPack.Crates.BoxId)
	end
	StatsService.GrantCashBoost(player, MonetizationConfig.StarterPack.Boost.Mult, MonetizationConfig.StarterPack.Boost.Hours * 3600)
	StatsService.SetOwnsStarterPack(player, true)
	DataService.SaveNow(player) -- persist the grant promptly (real money)

	SoundService.PlayForClient(player, { soundId = SoundsConfig.Upgrade })
	AnnounceUI.Announce(player, "Starter Pack Claimed!", Color3.fromRGB(255, 215, 0))
	ScoreUI.PostMessage(
		player,
		("Starter Pack Bonus! %s + 💎%d + %d Marble Boxes + ×%s Cash (%dh)"):format(
			StringUtils.FormatMoney(MonetizationConfig.StarterPack.Balance),
			MonetizationConfig.StarterPack.Diamonds,
			MonetizationConfig.StarterPack.Crates.Count,
			StringUtils.FormatShort(MonetizationConfig.StarterPack.Boost.Mult),
			MonetizationConfig.StarterPack.Boost.Hours
		),
		Color3.fromRGB(55, 132, 170)
	)
end

local function registerStarterPack()
	local id = tonumber(MonetizationConfig.GamePasses.StarterPack)
	if not id then
		warn("MonetizationService: MonetizationConfig.GamePasses.StarterPack is not a valid game pass id")
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
-- (CosmeticsConfig.RarityProducts). Each grants the player's currently-selected skin, but only if
-- its rarity matches the product — so a cheap (low-rarity) product can't unlock a rarer skin.
local function registerCosmeticFallback()
	for rarity, idStr in CosmeticsConfig.RarityProducts do
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

-- Consumable dev product (MonetizationConfig.Products.BallDropMaxBet): instantly fires MonetizationConfig.BallDrop.Count
-- balls valued at the player's current max bet — see BallLaunchService.LaunchMaxBetBatch.
local function registerBallDrop()
	local id = productId("BallDropMaxBet")
	if id and id ~= 0 then
		ProductService.RegisterProduct(id, function(player: Player, _receiptInfo: any): boolean
			BallLaunchService.LaunchMaxBetBatch(player, MonetizationConfig.BallDrop.Count)
			SoundService.PlayForClient(player, { soundId = SoundsConfig.Upgrade })
			AnnounceUI.Announce(player, MonetizationConfig.BallDrop.Count .. " Balls at Max Bet!", Color3.fromRGB(255, 140, 60))
			return true
		end)
	end
end

function MonetizationService.Init()
	registerCashMultipliers()
	registerStarterPack()
	registerCosmeticFallback()
	registerBallDrop()
end

return MonetizationService
