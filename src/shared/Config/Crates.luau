--!strict
-- Marble Boxes: rolls are the way to get skins. The shop no longer SELLS boxes (its LUCK
-- tab replaced the crate cards — skins are a core bet-multiplier mechanic now); Boxes
-- below remain the definitions behind the free roll, the daily reward's instant-open
-- crate, and the Robux crate dev products. Weights are per-rarity (1..12) relative chances.
-- Pity: rolling Every times without hitting rarity >= MinRarity forces one; the counter
-- resets whenever a roll (natural or forced) lands MinRarity+. Counters persist per box.
-- The Free box is never purchasable: it's granted on a session timer (FirstDelay after
-- join, then every Interval after each claim) and claimed from the shop's crates tab.

export type BoxDef = {
	Id: string,
	Name: string,
	Cost: number,
	Product: string,
	Weights: { number },
	Pity: { Every: number, MinRarity: number },
}

local Crates = {
	-- Weights are per-rarity (1..12); rarities 6+ only drop from the Gold Box.
	-- Product: a Robux dev product that opens ONE box of this type (pity ticks as usual).
	-- PLACEHOLDER ids — fill in real product ids from the Creator Dashboard ("0" = hidden).
	-- Every tier carries a TINY tail into higher rarities than its bread-and-butter range
	-- (Free→Legendary, Basic→Mythic, Silver→Divine): barely moves the distribution, but
	-- even the cheapest box can dream.
	Boxes = {
		{ Id = "Basic", Name = "Basic Box", Cost = 150, Product = "3608526615", Weights = { 60, 30, 9, 1, 0.25, 0.05, 0, 0, 0, 0, 0, 0 }, Pity = { Every = 10, MinRarity = 3 } },
		{ Id = "Silver", Name = "Silver Box", Cost = 400, Product = "3608536989", Weights = { 30, 40, 22, 7, 1, 0.2, 0.06, 0.02, 0, 0, 0, 0 }, Pity = { Every = 15, MinRarity = 4 } },
		{ Id = "Gold", Name = "Gold Box", Cost = 1000, Product = "3608537009", Weights = { 0, 25, 45, 24, 5, 0.7, 0.2, 0.08, 0.02, 0.006, 0.0015, 0.0003 }, Pity = { Every = 20, MinRarity = 5 } },
	} :: { BoxDef },
	Free = {
		Id = "FreeBox",
		Name = "Free Box",
		-- Every rarity is reachable from the constant free roll (it IS the core loop now) — the
		-- 6-12 tail is astronomically thin at base odds, but Luck compresses it into range.
		Weights = { 75, 20, 4.5, 0.5, 0.08, 0.015, 0.004, 0.001, 0.0002, 0.00005, 0.00001, 0.000002 },
		FirstDelay = 0, -- seconds after join until the FIRST free box (0 = instant hook)
		-- Front-loaded cadence (2026-07 rebalance): the first FastClaims LIFETIME claims
		-- come every Interval seconds (quick early collection building), then the timer
		-- steps up to SlowInterval forever. Skins are a permanent income multiplier, so a
		-- flat fast interval (~450 rolls/hour) compounds across rebirths and collapses
		-- time-per-rebirth to minutes regardless of pricing (BALANCE_RESULTS.md). The
		-- lifetime claim count persists (CosmeticService's freeClaims).
		Interval = 10,
		FastClaims = 40,
		SlowInterval = 90,
	},
	-- Crate-opening reel (CrateRollUI): slot-style strip of possible skins that decelerates
	-- onto the rolled one. Fillers are drawn from the crate's OWN Weights, so what spins
	-- past honestly previews that crate's odds. Same shape as Config/DailyReward Reel.
	Reel = {
		FillerCells = 36, -- 1.5× the daily reward's; paired with 1.5× SpinTime the strip
		CellsAfterResult = 3, -- travels at a similar speed, just half again as long
		CellSize = Vector2.new(140, 140),
		CellPadding = 12,
		SpinTime = 4.8,
	},
}

table.freeze(Crates)

return Crates
