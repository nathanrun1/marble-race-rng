--!strict
-- The 3D launcher model, rotated client-side (LauncherView) to match the player's
-- live aim, and the launch geometry/batch timing shared by the server (actual
-- launches, BallLaunchService) and the client (aim-line preview) so they can't drift.
-- Orientation is yaw-only (X/Z = 0): default faces straight down the ramp, and the
-- swivel deflects it between the right and left extremes.

local functionalFolder = workspace:FindFirstChild("Functional")

local Launcher = {
	Model = if functionalFolder then functionalFolder:FindFirstChild("Launcher") else nil, -- workspace.Functional.Launcher
	RotationPeriod = 3, -- seconds for one full swivel cycle (shared with BallLaunchService)
	SyncInterval = 30, -- seconds between client→server phase resyncs
	DefaultOrientation = Vector3.new(0, 90, 0), -- straight (swivel 0)
	RightOrientation = Vector3.new(0, 0, 0), -- full right (left facing the board)
	LeftOrientation = Vector3.new(0, 180, 0), -- full left (right facing the launcher)
	-- BaseDirection is the neutral aim (down the ramp); the swivel rotates it about +Y.
	-- LaunchOrigin is where balls spawn / lines start.
	BaseDirection = Vector3.new(0, 0, -1),
	LaunchOrigin = Vector3.new(21.3205, 172.855, 295.361),
	-- UNUSED since the per-slot launch rework (each slot cools down independently off the
	-- Frequency upgrade — ProfileStats.GetLaunchDelay); kept while the rework settles.
	BatchDelay = 3,
}

table.freeze(Launcher)

return Launcher
