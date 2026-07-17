--!strict
-- Daily login reward (server DailyRewardService + client DailyRewardUI): once per UTC day, a
-- centered prompt offers a claim; claiming rolls a weighted prize from Pool and reveals it via
-- a horizontal slot-style reel spin. Granting/rendering a reward Kind is a small registry in
-- each of DailyRewardService (server, rolls+grants) and DailyRewardUI (client, cell/result
-- display) — add a new Kind by extending Pool + both registries, nothing else changes.
--   Diamonds : flat Min..Max Diamonds, boosted by the login-streak Luck Bonus (below).
--   Cash     : Multiplier × the player's HIGHEST-OWNED MaxBet tier's bet size (NOT their
--              currently selected bet) — scales with progression without its own tier/config.
--   Crate    : a free UNOPENED Marble Box (BoxId picks which) banked into the player's
--              stash — they open it at the cosmetics shop whenever they like.

export type PoolEntry = {
	Kind: "Diamonds" | "Cash" | "Crate",
	Weight: number,
	Min: number?, -- Diamonds
	Max: number?, -- Diamonds
	Multiplier: number?, -- Cash
	BoxId: string?, -- Crate
}

local DailyReward = {
	-- Ordered worst -> best; Weight falls as the prize's value rises, so probability actually
	-- tracks how good a roll is (10 > 8 > 5 > 4 > 2 > 1.5 > 1). The rare/top Diamonds tier is
	-- the "lucky end": ~10 Diamonds max, deliberately modest next to a free Basic Box (150
	-- Diamonds' worth) or the big Cash multiplier — Diamonds/day is meant to trickle, not
	-- race a player to a Marble Box (rebirthing is the intended main Diamonds source).
	Pool = {
		{ Kind = "Diamonds", Weight = 10, Min = 2, Max = 4 },
		{ Kind = "Cash", Weight = 8, Multiplier = 1 },
		{ Kind = "Diamonds", Weight = 5, Min = 4, Max = 7 },
		{ Kind = "Cash", Weight = 4, Multiplier = 3 },
		{ Kind = "Diamonds", Weight = 2, Min = 7, Max = 10 },
		{ Kind = "Cash", Weight = 1.5, Multiplier = 8 },
		{ Kind = "Crate", Weight = 1, BoxId = "Basic" },
		{ Kind = "Crate", Weight = 0.4, BoxId = "Silver" },
	} :: { PoolEntry },
	-- Diamonds-only streak bonus ("Luck Bonus" in the UI): +StreakBonusPerDay per consecutive
	-- login day beyond the first, capped at MaxBonusDays (so it doesn't grow forever) — e.g.
	-- day 4 -> +15% at the default 5%/day. Missing a day resets the streak to 1 (no bonus).
	StreakBonusPerDay = 0.05,
	MaxBonusDays = 20, -- caps the bonus at +100% (20 × 5%)
	-- Slot-reel visuals (client DailyRewardUI): a horizontal strip of decorative filler cells
	-- spins past and decelerates onto the true (server-rolled) result, which sits
	-- CellsAfterResult cells before the strip's end (so it doesn't look like it just happened
	-- to land on the very last one).
	Reel = {
		FillerCells = 24,
		CellsAfterResult = 3,
		CellSize = Vector2.new(140, 140),
		CellPadding = 12,
		SpinTime = 3.2,
	},
}

return DailyReward
