--!strict
-- Ambient world behaviour: the day/night cycle, published animation ids, and the
-- rebirths-podium statue animations.

local ANIMATIONS = {
	ElectroSwing = "81301976341047",
	FancyFeet = "88664003295065",
	Pumpernickel = "81151223555196",
}

local World = {
	-- Day/night cycle (server DayNightCycle behaviour). Lighting.ClockTime runs from SunriseTime up
	-- to SunsetTime over DayMinutes of real time, then SunsetTime back round to SunriseTime over
	-- NightMinutes — so the two halves can last different real durations. Servers start at sunrise.
	DayNight = {
		Enabled = false, -- Whether day/night cycle is enabled
		DayMinutes = 9, -- real minutes for the day half (sunrise -> sunset)
		NightMinutes = 3, -- real minutes for the night half (sunset -> sunrise)
		SunriseTime = 6, -- ClockTime (hour, 0-24) the day starts at
		SunsetTime = 18, -- ClockTime (hour, 0-24) the night starts at
		StartTime = 9.4, -- ClockTime the cycle begins at when the server starts
	},

	Animations = ANIMATIONS,

	-- Rebirths podium (the top-3 statues by Workspace.Leaderboards.Rebirths.Podium). Each statue
	-- loops an animation — a KeyframeSequence by NAME under ReplicatedStorage.Assets.Animations
	-- (no upload needed; played client-side via AnimationService). Leave "" for no animation.
	Podium = {
		Animations = {
			First = ANIMATIONS.ElectroSwing, -- 1st place
			Second = ANIMATIONS.FancyFeet, -- 2nd place
			Third = ANIMATIONS.Pumpernickel, -- 3rd place
		},
	},
}

table.freeze(World)
table.freeze(World.DayNight)
table.freeze(World.Animations)
table.freeze(World.Podium)
table.freeze(World.Podium.Animations)

return World
