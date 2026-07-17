--!strict
-- Ball physics caps + the ball prefab template.

local RS = game:GetService("ReplicatedStorage")

local Ball = {
	-- MaxSpeed bounds a ball's velocity magnitude (studs/sec) while it falls —
	-- BallService clamps each frame so a ball can't accelerate past it (keeps fast
	-- drops/bounces from blowing through the board or feeling uncontrolled). Tune.
	MaxSpeed = 100,

	-- Per-player live-ball concurrency ceiling (well above any legitimate batch size) —
	-- enforced by BallLaunchService launches and GoldenPegService clone spawns.
	MaxPerPlayer = 160,

	-- The prefab every spawned/sample marble is cloned from.
	Prefab = (RS:WaitForChild("Assets") :: Instance):WaitForChild("BallPrefab"),
}

table.freeze(Ball)

return Ball
