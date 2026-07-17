--!strict
-- Obby zones (ObbyService/ObbyZone): walkspeed forced while inside the course.

local Obby = {
	DefaultWalkSpeed = 32, -- restored when a player leaves the obby area
	ObbyWalkSpeed = 16, -- forced while inside the Checkpoints.In volume
}

table.freeze(Obby)

return Obby
