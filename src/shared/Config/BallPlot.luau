--!strict
-- Plot balls (client-side plot ball combining): once a player already has this many
-- physical plot balls of a given skin, any further ball of that skin merges its value into a
-- random existing one instead of spawning a new physical ball.

local BallPlot = {
	MaxPerSkin = 15,

	-- The spawn "shot": a new plot ball fires out of the PlotShoot part along a collision-free
	-- curved (y-arcing) path that lands it near the PlotSpawn part, where normal physics take over.
	-- Seconds the ball waits at the PlotShoot muzzle before the shot fires. Keep this VALUE
	-- equal to Scoring.DestroyDelay (the banked ball's fall-into-the-hole linger) so the plot
	-- copy launches right as the real ball finishes vanishing — deliberately its own knob
	-- rather than reading that config, so the two can be detuned independently.
	ShotDelay = 1,
	ShotTime = 1, -- seconds of flight from PlotShoot to the landing point
	ShotArcHeight = 12, -- studs the arc's midpoint rises above the straight shoot->land line
	ShotSpread = 5, -- studs of random horizontal scatter around the landing point
	BoundsHitSlowFactor = 0.2, -- the shot ball's velocity is multiplied by this the moment it first overlaps PlotBounds after landing
	OutOfBoundsRescueTime = 3, -- seconds after the shot; a ball not overlapping PlotBounds by then teleports to its landing point

	-- Merge direction once a skin is at MaxPerSkin and a new arrival merges into an
	-- existing plot ball (BallPlotService.onSpawn). true (new): the FALLING ball survives —
	-- it inherits the existing target's ids/value and the pre-existing target is what gets
	-- destroyed, so the shot reads as "lands here, picks up value" and nothing visibly
	-- vanishes mid-fall. false (legacy): the falling ball is what vanishes, folding its
	-- value into the stationary target, which pulses to show it grew.
	FallingBallAbsorbsExisting = true,
}

table.freeze(BallPlot)

return BallPlot
