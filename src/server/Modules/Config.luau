local RS = game:GetService("ReplicatedStorage")

local Config = {}

Config.Tags = {
	ScoreTarget = "ScoreTarget",       -- Scores on ball collision
	DestroyTarget = "DestroyTarget",   -- Destroys ball on collision
	Ball = "Ball"
}

Config.Attributes = {
	OwnerUserId = "OwnerUserId",       -- Ball owner's user ID
	Cooldown = "Cooldown",             -- Ball same-target repeat score cooldown
	
	PointValue = "PointValue",         -- Score target value
	IsPointMul = "IsPointMultiplier",  -- Whether ball value is multiplied by PointValue (if not, PointValue is added directly)
}

Config.Scoring = {
	DefaultCooldown = 0.25,
}

Config.Currency = {
	StartingBalance = 1000000,
}

Config.Templates = {
	Ball = RS.Assets.BallPrefab
}

table.freeze(Config.Tags)
table.freeze(Config.Attributes)
table.freeze(Config.Scoring)
table.freeze(Config.Currency)
return Config