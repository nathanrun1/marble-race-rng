--!strict
-- Attribute names: the registry of every attribute scripts read/write on instances.
-- Attributes carry instance-specific config/marking only — runtime game state lives
-- in the owning service's tables, never here.

local Attributes = {
	OwnerUserId = "OwnerUserId", -- Ball owner's user ID
	Cooldown = "Cooldown", -- Ball same-target repeat score cooldown

	PointMul = "PointMul", -- If defined, a destroy target's point multiplier
	DestroyTargetID = "DestroyTargetID", -- Integer id identifying which destroy target (slot) a ball banked at
	PegHeat = "PegHeat", -- Peg heat (signed): hot >0, cold <0. Accumulated per ball, applied value-proportionally at banking, scaled by the player's PegHeat tier.

	-- Per-ball config, set at spawn from the owner's loadout (see ProfileService)
	Value = "Value", -- Ball's value (B/N for this batch)
	Weight = "Weight", -- Weight slider 0 (light) .. 1 (heavy)
	Size = "Size", -- Size slider
	BatchId = "BatchId", -- Batch this ball belongs to (per-player combo settlement)
	SkinId = "SkinId", -- Cosmetic skin id this specific ball was spawned wearing (see CosmeticService.onBallSpawn); lets BallPlotService reconstruct its appearance after the ball itself is despawned

	-- Obstacle Behaviour
	ObstacleRotate = "ORotate", -- Obstacle rotates by given angles (Vector3)
	ObstacleAlternation = "OAlternate", -- Obstacle "alternates", i.e. rotates this angle in one direction, then the other (from the original orientation), repeat
	OObstacleAlternationSpeed = "OAlternateSpeed", -- Speed of alternation
}

table.freeze(Attributes)

return Attributes
