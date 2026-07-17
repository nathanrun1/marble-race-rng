--!strict
-- Golden peg unlock schedule, shared by GoldenPegService (server — sizes the actual golden
-- set) and PrestigeUI (client — "X Rebirths until next Golden Obstacle"). Escalating: peg k
-- unlocks at prestige k(k+1)/2 — 1, 3, 6, 10, ... — so each peg costs one more rebirth than
-- the last, hard-capped at GoldenPegsConfig.MaxPegs.

local RS = game:GetService("ReplicatedStorage")

local GoldenPegsConfig = require(RS.Shared.Config.GoldenPegs)
local GoldenPegSchedule = {}

-- Pegs earned at a prestige count, including the MaxPegs cap (closed form inverts the
-- triangular numbers).
function GoldenPegSchedule.PegsEarned(prestigeCount: number): number
	local uncapped = math.floor((math.sqrt(8 * prestigeCount + 1) - 1) / 2)
	return math.min(uncapped, GoldenPegsConfig.MaxPegs)
end

-- Prestige count at which the NEXT peg unlocks, or nil if already at the cap.
function GoldenPegSchedule.NextPegAt(prestigeCount: number): number?
	local have = GoldenPegSchedule.PegsEarned(prestigeCount)
	if have >= GoldenPegsConfig.MaxPegs then
		return nil
	end
	local k = have + 1
	return k * (k + 1) / 2
end

return GoldenPegSchedule
