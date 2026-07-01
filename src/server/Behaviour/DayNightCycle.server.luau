--!strict
-- Server-authoritative day/night cycle. Drives Lighting.ClockTime so every client sees the
-- same time of day (Lighting replicates from the server). Daylight (sunrise -> sunset) takes
-- Config.DayNight.DayMinutes of real time; night (sunset -> sunrise) takes NightMinutes — so the
-- two halves can run at different speeds. All tunable in Config.DayNight. Servers start at sunrise.

local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Config = require(RS.Shared.Config)

local DAY = Config.DayNight
local DAY_SECS   = DAY.DayMinutes * 60
local NIGHT_SECS = DAY.NightMinutes * 60
local CYCLE_SECS = DAY_SECS + NIGHT_SECS
local DAY_SPAN   = DAY.SunsetTime - DAY.SunriseTime  -- game-hours of daylight
local NIGHT_SPAN = 24 - DAY_SPAN                      -- game-hours of night (clock wraps)

-- How often (seconds) we push ClockTime. The sun moves slowly, so ~10 Hz is smooth and keeps
-- replication light (no need to set it every frame).
local UPDATE_INTERVAL = 0.1

-- ClockTime (0..24) for a position `t` seconds into the cycle: daylight first, then night.
local function clockTimeFor(t: number): number
	t %= CYCLE_SECS
	if t < DAY_SECS then
		return DAY.SunriseTime + (t / DAY_SECS) * DAY_SPAN
	end
	local nightFrac = (t - DAY_SECS) / NIGHT_SECS
	return (DAY.SunsetTime + nightFrac * NIGHT_SPAN) % 24
end

-- Inverse of clockTimeFor: the cycle position (seconds) at which Lighting shows ClockTime `ct`.
-- Lets the cycle begin at Config.DayNight.StartTime instead of at sunrise.
local function cyclePosForClock(ct: number): number
	ct %= 24
	if ct >= DAY.SunriseTime and ct < DAY.SunsetTime then
		return ((ct - DAY.SunriseTime) / DAY_SPAN) * DAY_SECS
	end
	local hoursIntoNight = (ct - DAY.SunsetTime) % 24
	return DAY_SECS + (hoursIntoNight / NIGHT_SPAN) * NIGHT_SECS
end

-- Anchor `start` so the first tick lands on StartTime, then the cycle runs from there.
local start = os.clock() - cyclePosForClock(DAY.StartTime)
if Config.DayNight.Enabled then
	while true do
		Lighting.ClockTime = clockTimeFor(os.clock() - start)
		task.wait(UPDATE_INTERVAL)
	end
end
