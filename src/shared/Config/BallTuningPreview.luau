--!strict
-- Ball-tuning preview (client, shown while the tuning menu is open): three aim lines
-- from the launch origin (green = center aim, blue = the two arc extremes) and an
-- appearance-only ball that reflects the Size / Elasticity axes.

local BallTuningPreview = {
	LineLength = 45,
	LineThickness = 0.35,
	LineTransparency = 0.55,
	CenterColor = Color3.fromRGB(70, 230, 110), -- center aim
	SideColor = Color3.fromRGB(70, 150, 255), -- arc extremes
	BallPosition = Vector3.new(30, 172.855, 295.361), -- right of the launcher (tune to taste)
}

table.freeze(BallTuningPreview)

return BallTuningPreview
