--!strict
-- Robux monetization: dev products, game passes, the cash-multiplier ladder, the
-- Ball Drop consumable, the starter pack, and Diamonds purchase packs.

local Monetization = {
	-- Robux developer products. Logical key -> product id. The server (MonetizationService)
	-- registers a grant handler per id; client UI prompts a purchase by looking the id up
	-- here. Fill in real product ids from the Creator Dashboard.
	Products = {
		UpgradeBoost = "3605952101",
		Multiplier2x = "3605951905",
		Multiplier4x = "3605951969",
		Multiplier8x = "3605951998",
		Multiplier16x = "3605952025",
		BallDropMaxBet = "3607663509",
	},

	-- Robux game passes (permanent, one-time ownership — distinct from consumable dev
	-- products above). Granted via ownership, not ProcessReceipt (see ProductService).
	GamePasses = {
		StarterPack = "1882812049",
	},

	-- Cash multiplier (Robux): a permanent global multiplier on banked cash. Each level
	-- is its own dev product (Products["Multiplier"..level.."x"]); the shop button
	-- offers the next level in order, and disappears once the top one is owned.
	CashMultiplier = {
		Levels = { 2, 4, 8, 16 }, -- purchasable multipliers, ascending; last = max
	},

	-- Ball Drop (Robux): a consumable dev product (Products.BallDropMaxBet) that instantly
	-- fires Count balls, each valued at the player's CURRENT max bet (not their chosen loadout.Bet) —
	-- free, bypassing the launch cooldown/affordability check (see BallLaunchService.LaunchMaxBetBatch).
	BallDrop = {
		Count = 30,
	},

	-- Starter pack (Robux): a one-time new-player boost. Grants Balance cash, Diamonds,
	-- and Crates.Count free openings of the Crates.BoxId box. Only offered while the
	-- player has fewer than MaxUpgrades total upgrade tiers and hasn't already bought it.
	-- Once owned, every prestige thereafter grants PostPrestigeFreeTier on all tracks.
	StarterPack = {
		Balance = 75000, -- cash granted on purchase
		Diamonds = 100, -- Diamonds granted on purchase
		Crates = { BoxId = "Silver", Count = 2 }, -- free crate rolls granted on purchase
		Boost = { Mult = 1.5, Hours = 24 }, -- timed cash multiplier granted on purchase
		MaxUpgrades = 20, -- hide the pack once the player has this many total upgrades
		PostPrestigeFreeTier = 1, -- free tier on all tracks after each prestige (owners only)
	},

	-- Diamonds purchase packs (client DiamondsShopUI + product registration in CosmeticService).
	-- Ordered smallest -> biggest; Diamonds-per-Robux IMPROVES up the ladder so bigger packs are
	-- better value (RobuxHint is display-only fallback text — the real price comes from the dev
	-- product once its id is set). PLACEHOLDER product ids ("0" = button prompts nothing).
	DiamondPacks = {
		{ Id = "Handful", Name = "Handful of Diamonds", Icon = "🤲", Diamonds = 100, Product = "3608551478", RobuxHint = 50 },
		{ Id = "Crate", Name = "Crate of Diamonds", Icon = "📦", Diamonds = 350, Product = "3608551532", RobuxHint = 149 },
		{ Id = "Pile", Name = "Pile of Diamonds", Icon = "💰", Diamonds = 900, Product = "3608551575", RobuxHint = 349 },
		{ Id = "Mountain", Name = "Mountain of Diamonds", Icon = "⛰️", Diamonds = 3000, Product = "3608551623", RobuxHint = 999 },
	},

	-- Minimum seconds between auto-prompts of the UpgradeBoost (3×) purchase dialog when a player
	-- clicks Buy and can't afford the upgrade (ShopUI's promptBoost, BallLaunchUI's attemptUnlock) —
	-- otherwise repeatedly clicking Buy while broke would pop the Robux dialog every single click.
	UpgradeBoostPromptCooldown = 600,
}

table.freeze(Monetization)
table.freeze(Monetization.Products)
table.freeze(Monetization.GamePasses)
table.freeze(Monetization.CashMultiplier)
table.freeze(Monetization.StarterPack)
table.freeze(Monetization.DiamondPacks)

return Monetization
