--!strict
-- Database of available ball skins. A skin is purely cosmetic: a base colour plus
-- an optional single ParticleEmitter the ball emits. Each entry carries a display
-- name and a rarity 1 (common) .. 5 (rarest).
--
-- CosmeticService reads this to paint balls; a shop/inventory UI can read it to list
-- skins. Skeleton for now — more skins get added here later.

local BallSkins = {}

-- A subset of ParticleEmitter properties a skin may set. Nil fields fall back to
-- CosmeticService's defaults when the emitter is built.
export type ParticleData = {
	color: ColorSequence?,
	texture: string?,
	rate: number?,
	lifetime: NumberRange?,
	speed: NumberRange?,
	size: NumberSequence?,
	transparency: NumberSequence?,
	spreadAngle: Vector2?,
	lightEmission: number?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
}

export type SkinData = {
	color: Color3,           -- ball base colour (BallEffects brightens this with heat)
	particle: ParticleData?, -- nil = no particles
}

export type BallSkin = {
	name: string,
	rarity: number,          -- 1 (common) .. 5 (rarest)
	data: SkinData,
}

local DEFAULT_SKIN_ID = "default"

-- id -> skin. Ids are stable keys (used by CosmeticService and saved loadouts);
-- names are display-only and may change.
local Skins: { [string]: BallSkin } = {
	[DEFAULT_SKIN_ID] = {
		name = "Classic",
		rarity = 1,
		data = {
			color = Color3.fromRGB(163, 163, 163),
		},
	},
	-- Example of a particle skin; the schema all later skins follow.
	ember = {
		name = "Ember",
		rarity = 3,
		data = {
			color = Color3.fromRGB(230, 90, 30),
			particle = {
				color = ColorSequence.new(Color3.fromRGB(255, 160, 60), Color3.fromRGB(255, 70, 20)),
				rate = 16,
				lifetime = NumberRange.new(0.4, 0.8),
				speed = NumberRange.new(0.5, 1.5),
				size = NumberSequence.new(0.3, 0),
				transparency = NumberSequence.new(0.2, 1),
				lightEmission = 0.6,
			},
		},
	},
}

function BallSkins.Get(id: string): BallSkin?
	return Skins[id]
end

-- The whole table (read-only by convention) for UI listing.
function BallSkins.GetAll(): { [string]: BallSkin }
	return Skins
end

function BallSkins.GetDefaultId(): string
	return DEFAULT_SKIN_ID
end

return BallSkins
