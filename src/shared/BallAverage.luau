--!strict
-- Shared $/marble weighting math (see BallAverageConfig for the tuning rationale): an
-- exponentially-weighted average over only the most recent Window balls banked, with a ball
-- older than that dropped entirely rather than merely decayed small. Both StatsService
-- (authoritative, server-side) and MoneyPerBallUI (mirroring the same recentBalls list the
-- server sends over GetStats) call this, so the two never disagree on the number shown.

local RS = game:GetService("ReplicatedStorage")

local BallAverageConfig = require(RS.Shared.Config.BallAverage)
local BallAverage = {}

-- recentBalls is oldest-first, newest LAST (see Push below).
function BallAverage.Compute(recentBalls: { number }): number
	local n = #recentBalls
	if n == 0 then
		return 0
	end
	local weightedSum = 0
	local totalWeight = 0
	local weight = 1
	for i = n, 1, -1 do
		weightedSum += recentBalls[i] * weight
		totalWeight += weight
		weight *= BallAverageConfig.Decay
	end
	return weightedSum / totalWeight
end

-- Append a newly-banked value, evicting the oldest entry once the window is full — so a ball
-- past BallAverageConfig.Window bankings ago carries exactly zero weight, not just a small one.
function BallAverage.Push(recentBalls: { number }, value: number)
	table.insert(recentBalls, value)
	if #recentBalls > BallAverageConfig.Window then
		table.remove(recentBalls, 1)
	end
end

return BallAverage
