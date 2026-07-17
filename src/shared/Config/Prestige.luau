--!strict
-- Prestige (rebirth) economy — see PrestigeService.

local Prestige = {
	Scale = 18820, -- denominator in PP formula (earnedPP = (creditedBanked/Scale)^Exponent).
	-- Divided ×10^3 from 18820000 to make rebirths easier: since required cash
	-- LB_n = Scale × cost(n)^(1/Exponent), this divides the lifetime-banked
	-- threshold for EVERY prestige level by 1000 while CostBase (still 50 PP for
	-- prestige #1) and the whole PP cost curve are untouched — only how much cash
	-- it takes to earn a given amount of PP changed, not the PP economy itself.
	Exponent = 0.35, -- sublinear compression
	CostBase = 50, -- PP cost of first prestige (computeCost is 1-indexed, so this IS prestige #1's
	-- cost). With Scale above, ~30 min for an optimal build on the S5 slot table
	-- (assumes the gate is cleared early, i.e. VJackFraction ≈ 0.55).
	-- Per-level cost growth. Constant time-to-prestige requires CostGrowth = MultPer^Exponent
	-- (because the LB needed for prestige N grows as CostGrowth^(N/Exponent) while the global
	-- multiplier only offsets it as MultPer^N). Break-even here is 1.25^0.35 ≈ 1.081. The old 2.0
	-- was WAY above it: requirement grew 7.25^N vs a 1.25^N multiplier, so late prestiges took
	-- exponentially longer AND the targeting build (which banks super-linearly in time) pulled
	-- ahead of combo. Current value targets the CASH requirement growing exactly 1.2× faster
	-- per level than the multiplier offsets it: CostGrowth = (1.2 × MultPer)^Exponent =
	-- 1.5^0.35 ≈ 1.1525, i.e. each prestige takes ~20% longer in real time than the previous
	-- one — every run stays a near-copy of run 0, with later prestiges a clear step up.
	CostGrowth = 1.1525,
	MultPer = 1.25, -- global banked multiplier per prestige (multiplicative)
	-- Anti-hoard: available PP is an earn/spend currency. Banking stops crediting PP once you hold
	-- this many × the next prestige's cost, so you can buffer at most ~one extra prestige and can't
	-- farm lifetime banked into a stockpile of prestiges. Prestige SPENDS the cost (see PrestigeService).
	HoldCapMult = 1.5,
	-- Once banking is capped (no more PP credited), nag the player to rebirth at most this
	-- often (seconds) via WarnUI, since further play is wasted PP until they prestige.
	LimitWarnInterval = 20,
	NoScoreSeconds = 5, -- post-prestige no-score window (exploit guard)
}

table.freeze(Prestige)

return Prestige
