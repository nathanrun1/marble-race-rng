--!strict
-- Marble Boxes: crate rolls are the main way to get skins (the shop's direct-purchase flow
-- is retired in favour of the index tab). Weights are per-rarity (1..9) relative chances.
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
	-- Weights are per-rarity (1..9); rarities 6-9 only drop from the Gold Box.
	-- Product: a Robux dev product that opens ONE box of this type (pity ticks as usual).
	-- PLACEHOLDER ids — fill in real product ids from the Creator Dashboard ("0" = hidden).
	-- Every tier carries a TINY tail into higher rarities than its bread-and-butter range
	-- (Free→Legendary, Basic→Mythic, Silver→Divine): barely moves the distribution, but
	-- even the cheapest box can dream.
	Boxes = {
		{ Id = "Basic", Name = "Basic Box", Cost = 150, Product = "3608526615", Weights = { 60, 30, 9, 1, 0.25, 0.05, 0, 0, 0 }, Pity = { Every = 10, MinRarity = 3 } },
		{ Id = "Silver", Name = "Silver Box", Cost = 400, Product = "3608536989", Weights = { 30, 40, 22, 7, 1, 0.2, 0.06, 0.02, 0 }, Pity = { Every = 15, MinRarity = 4 } },
		{ Id = "Gold", Name = "Gold Box", Cost = 1000, Product = "3608537009", Weights = { 0, 25, 45, 24, 5, 0.7, 0.2, 0.08, 0.02 }, Pity = { Every = 20, MinRarity = 5 } },
	} :: { BoxDef },
	Free = {
		Id = "FreeBox",
		Name = "Free Box",
		-- Every rarity is reachable from the constant free roll (it IS the core loop now) — the
		-- 6-9 tail is astronomically thin at base odds, but Luck compresses it into range.
		Weights = { 75, 20, 4.5, 0.5, 0.08, 0.015, 0.004, 0.001, 0.0002 },
		FirstDelay = 0, -- seconds after join until the FIRST free box (0 = instant hook)
		-- Not really a "come back later" hook anymore — the delay is just an anti-spam floor,
		-- short enough that claiming reads as "roll constantly" rather than waiting out a timer.
		Interval = 2,
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
