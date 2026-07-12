--!strict
-- Plot balls (client-side plot ball combining): once a player already has this many
-- physical plot balls of a given skin, any further ball of that skin merges its value into a
-- random existing one instead of spawning a new physical ball.

local BallPlot = {
	MaxPerSkin = 5,
}

table.freeze(BallPlot)

return BallPlot
