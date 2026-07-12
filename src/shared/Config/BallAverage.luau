--!strict
-- The $/marble average (StatsService.GetAvgMoneyPerBall — HUD, leaderstat, global leaderboard):
-- an exponentially-weighted average over only the most recent Window balls banked. A ball older
-- than Window balls ago is dropped entirely (zero influence, not just decayed-small); within the
-- window, Decay^age weights recent balls higher. Decay is derived so the OLDEST ball still in the
-- window (age Window-1) carries ~1% of the newest ball's weight — Window alone can be retuned
-- and Decay follows automatically.

local WINDOW = 50

local BallAverage = {
	Window = WINDOW,
	Decay = 0.01 ^ (1 / (WINDOW - 1)),
}

return BallAverage
