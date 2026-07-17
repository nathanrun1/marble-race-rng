--!strict
-- Scripted camera shots (client CameraService). Orientation is in degrees, matching
-- a Part's Orientation property (Y, X, Z order).

local Camera = {
	-- "Better view" board-facing angle the player can toggle to.
	BoardView = {
		Position = Vector3.new(22.273, 237.588, -39.821),
		Orientation = Vector3.new(-47, 180, 0),
		FieldOfView = 70,
	},
	-- Shot used while the ball-tuning menu is open.
	BallTuning = {
		Position = Vector3.new(21.45, 190, 300),
		Orientation = Vector3.new(-65, 0, 0),
		FieldOfView = 70,
	},
}

table.freeze(Camera)
table.freeze(Camera.BoardView)
table.freeze(Camera.BallTuning)

return Camera
