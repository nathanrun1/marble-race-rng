--!strict
-- Scoring pipeline tuning (ScoringService/ScoreHandler) + the destroy-target (slot)
-- payout table DestroyTargetService stamps onto the board.

local Scoring = {
	DefaultCooldown = 1.5,
	MinCombo = 17, -- lowered 8→5: the ball-speed cap cut bounce counts (~18→11), so combo needs an easier gate
	-- Minimum scoretarget multiplier (×) on a hit that triggers high-point FX.
	SpecialFXMinMultiplier = 1.25,
	-- Seconds a ball may stay alive before it is force-banked at 1× and despawned
	-- (a ball wedged on geometry must not live forever). Tune above a normal fall.
	MaxBallLifetime = 35,
	-- Jackpot payout: hitting a JackpotTarget adds JackpotMultiplier × the ball's
	-- otherwise-final banked value (so total = banked × (1 + this)). Tune.
	-- Lowered 20→12: the jackpot edge was >half the no-build slot EV (the bet-spam exploit).
	JackpotMultiplier = 12,

	-- Destroy-target (slot) payouts, keyed by the part's DestroyTargetID attribute.
	-- DestroyTargetService applies these on load: a number -> set the PointMul attribute;
	-- the Jackpot sentinel -> tag the slot JackpotTarget (pays via JackpotMultiplier above)
	-- instead of a PointMul. It also writes the multiplier onto the slot's
	-- Parent.Display.SurfaceGui.TextLabel. Palindrome: id i and 17-i match.
	DestroyTargets = {
		Jackpot = "JACKPOT", -- sentinel: this slot is a JackpotTarget, not a PointMul slot
		Multipliers = {
			-- "S5" table. Non-jackpot slots (1..16) are tuned to a GENTLE EV ≈ 0.9 with a low
			-- variance (median ≈ 0.62, std ≈ 0.65) — so a non-targeting player bleeds slowly and
			-- steadily instead of riding a 0.25-median slot machine. Skewed outward: 4 winning
			-- slots/side (1.1 → 2.6) at the edges, losing center (0.4 → 0.62). The big 12× jackpot
			-- (slots 0/17) sits behind the value+heat gate (CollisionService), so its variance is
			-- quarantined to targeting builds that clear it (gate-open EV ≈ 1.34). See balance memory.
			[0] = "JACKPOT", [1] = 2.6, [2] = 1.8, [3] = 1.3, [4] = 1.1, [5] = 0.62,
			[6] = 0.52, [7] = 0.45, [8] = 0.4, [9] = 0.4, [10] = 0.45, [11] = 0.52,
			[12] = 0.62, [13] = 1.1, [14] = 1.3, [15] = 1.8, [16] = 2.6, [17] = "JACKPOT",
		} :: { [number]: number | string },
	},
}

table.freeze(Scoring)
table.freeze(Scoring.DestroyTargets)
table.freeze(Scoring.DestroyTargets.Multipliers)

return Scoring
