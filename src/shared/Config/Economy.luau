--!strict
-- Economy anchors: starting balance, the bet-ladder anchors ProfileStats derives from,
-- and the Beginner's Luck onboarding boost.

local Economy = {
	-- Cold-start onboarding: 100 couldn't afford a single core upgrade (cheapest was 230), so
	-- new players could only buy near-useless cheap axes and bled out. 1000 buys ~3 core tiers
	-- up front so the first decisions are impactful ones. Axes were repriced to ~1.5–2k so they
	-- sit ABOVE the core tracks (mid-game purchases), not below them.
	StartingBalance = 1000,

	StartMaxBet = 40, -- guideline §4; anchor for the MaxBet ladder from tier 1 up (see Upgrades.Tracks.MaxBet)
	StartBetSize = 10, -- tier 0's bet size: the free starting rung, below StartMaxBet's old tier-0 value
	TrickleFraction = 0.05, -- × currentMaxBet, free per batch (§1.2)
	VJackFraction = 0.55, -- V_JACK = this × currentMaxBet (§1.3 jackpot gate)
	BasePriceGrowth = 4.5, -- default upgrade Cost.Growth (price multiplier per tier)

	-- Beginner's Luck: a one-time, free timed cash boost for brand-new accounts only (granted by
	-- DataService.onPlayerAdded the moment it finds no saved data at all — never re-granted on a
	-- later session). Reuses the same timed-boost slot as Config/Monetization StarterPack.Boost
	-- (StatsService.GrantCashBoost/GetCashBoost) rather than a separate mechanism; a real
	-- starter-pack purchase during the window simply overwrites it (last grant wins), which is
	-- fine since a first-minute player won't have bought it yet. Exists to nudge a fresh default
	-- build's board EV (~0.95-1.0x) just over 1.0x so the first autonomous minutes aren't a
	-- coinflip that ends most sessions before the player is invested.
	BeginnersLuck = {
		Mult = 1.15, -- multiplier on banked cash while active
		Seconds = 15 * 60, -- window length from first join
	},
}

table.freeze(Economy)
table.freeze(Economy.BeginnersLuck)

return Economy
