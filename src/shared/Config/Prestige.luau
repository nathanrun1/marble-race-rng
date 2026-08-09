--!strict
-- Prestige (rebirth) economy — see PrestigeService.

local Prestige = {
	-- 2026-07 rebalance (BALANCE_RESULTS.md): Scale/CostGrowth/MultPer retuned by the
	-- rebirth sim against the 2026-07-18 geotest. First-rebirth lifetime-banked
	-- threshold LB_1 = Scale × CostBase^(1/Exponent) ≈ 2.0e13; sim predicts ~29 min
	-- (chaos) / ~18 min (targeting) for rebirth 1, settling to a ~15–19 min plateau.
	Scale = 282300000, -- denominator in PP formula (earnedPP = (creditedBanked/Scale)^Exponent)
	Exponent = 0.35, -- sublinear compression
	CostBase = 50, -- PP cost of first prestige (computeCost is 1-indexed, so this IS prestige #1's cost)
	-- Per-level cost growth. 2.4 looks huge next to MultPer, but income between rebirths
	-- grows from more than the prestige multiplier: the skin collection (permanent) and
	-- faster re-maxing compound with it. Empirically (sim, rebirths 1–8) this is what
	-- holds time-per-rebirth roughly constant; the naive MultPer^Exponent break-even
	-- formula ignores skins and badly undershoots.
	CostGrowth = 2.4,
	MultPer = 1.15, -- global banked multiplier per prestige (multiplicative)
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
