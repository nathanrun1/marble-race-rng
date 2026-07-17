--!strict
-- Golden pegs (prestige perk): rebirths mark pegs on the board as "golden" on an escalating
-- schedule — peg k at prestige k(k+1)/2, i.e. 1, 3, 6, 10, ... (see GoldenPegService) —
-- FOR THAT PLAYER — the board is shared, so the set is per-player and only that player's
-- balls trigger it (their golden pegs are highlighted client-side by GoldenPegView). When
-- one of your balls hits one of your golden pegs (at most once per ball per peg), it rolls:
-- CloneChance → the ball is cloned into a second free ball of the same value; otherwise the
-- ball's live value is multiplied by BoostMult. See GoldenPegService (set + clone) /
-- ScoreHandler (trigger).

local GoldenPegs = {
	DoubleChance = 0.90, -- probability a golden hit boosts the ball's value (by BoostMult)
	CloneChance = 0.10, -- probability a golden hit clones the ball instead
	BoostMult = 1.1, -- value multiplier on a boost hit (was ×2 — nerfed, it dominated)
	MaxPegs = 10, -- hard per-player cap; the unlock schedule stops here
}

table.freeze(GoldenPegs)

return GoldenPegs
