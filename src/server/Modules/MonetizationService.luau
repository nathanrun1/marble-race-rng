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
local ProductService = require(RS.Shared.ProductService)
local StatsService = require(SSS.Scripts.Modules.StatsService)
local UpgradeService = require(SSS.Scripts.Modules.UpgradeService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local DataService = require(SSS.Scripts.Modules.DataService)

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
	if StatsService.OwnsStarterPack(player) then
		return
	end
	UpgradeService.RaiseAllTracksTo(player, Config.StarterPack.UpgradeTiers)
	CurrencyService.AddPoints(player, Config.StarterPack.Balance, "Starter Pack")
	StatsService.SetOwnsStarterPack(player, true)
	DataService.SaveNow(player) -- persist the grant promptly (real money)

	SoundService.PlayForClient(player, { soundId = Config.Sounds.Upgrade })
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

function MonetizationService.Init()
	registerCashMultipliers()
	registerStarterPack()
end

return MonetizationService
