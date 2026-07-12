--!strict
-- Playtime reward ladder (see PlaytimeBonusService). Cumulative seconds played -> claimable
-- cash bonus. Retention + early-game afloat. Rungs MUST be ascending by Time and are claimed
-- in order, so only APPEND new rungs (the persisted claimed-count assumes a stable order).

local PlaytimeBonuses = {
	Rungs = {
		{ Time = 3 * 60, Reward = 1000 },
		{ Time = 15 * 60, Reward = 5000 },
		{ Time = 45 * 60, Reward = 20000 },
		{ Time = 90 * 60, Reward = 50000 },
		{ Time = 180 * 60, Reward = 150000 },
		{ Time = 360 * 60, Reward = 500000 },
	},
}

return PlaytimeBonuses
