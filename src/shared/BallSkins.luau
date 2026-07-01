--!strict
-- Database of available ball skins (cosmetics). A skin is purely cosmetic: a base colour, zero or
-- more AMBIENT ParticleEmitters the ball constantly emits, and an optional BOUNCE burst — a short
-- one-off particle Emit fired each time the ball bounces (and showcased periodically on the shop
-- sample ball). Each entry carries a display name, a rarity 1 (common) .. 5 (rarest), and a CC price.
--
-- Particles are configured per skin across the full ParticleEmitter property set; a skin may LAYER
-- several ambient emitters. Intensity scales hard with rarity. BallEffects.ApplyAppearance builds the
-- emitters; BallEffects.EmitBounce fires the bounce burst.

local BallSkins = {}

local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE     = "rbxasset://textures/particles/fire_main.dds"
local SMOKE    = "rbxasset://textures/particles/smoke_main.dds"

-- A subset of ParticleEmitter properties a skin may set. Nil fields keep the emitter default.
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
	lightInfluence: number?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
	acceleration: Vector3?,
	drag: number?,
	velocityInheritance: number?,
	emissionDirection: Enum.NormalId?,
	zOffset: number?,
	squash: NumberSequence?,
	orientation: Enum.ParticleOrientation?,
	brightness: number?,
	shape: Enum.ParticleEmitterShape?,
	burstCount: number?, -- only for a skin's `bounce` emitter: particles Emit()'d per bounce
}

-- A cosmetic part that revolves around the ball (no collision, semi-transparent). Defined by its
-- shape + size + appearance, an offset from the ball centre (the orbit radius), and how it revolves
-- (axis + speed + starting phase), plus an optional self-spin. See BallEffects.applyOrbits/UpdateOrbits.
export type OrbitData = {
	shape: Enum.PartType?,    -- Ball / Block / Cylinder (default Ball)
	size: Vector3?,           -- part size (default ~0.6)
	offset: Vector3?,         -- position relative to the ball centre = the orbit radius (default (2,0,0))
	color: Color3?,
	material: Enum.Material?, -- default Neon
	transparency: number?,    -- default 0.4 (visible but distinct from the ball)
	axis: Vector3?,           -- unit orbit axis through the ball centre (default Y)
	speed: number?,           -- orbit angular speed, radians/sec (default 2)
	spin: Vector3?,           -- the part's own local spin, radians/sec per axis (optional)
	phase: number?,           -- starting angle offset, radians (space multiple parts apart)
}

-- An outline/glow (Roblox Highlight) on the ball. Colours default to the skin's base colour when nil.
export type HighlightData = {
	fillColor: Color3?,
	fillTransparency: number?,           -- default 0.75 (subtle inner fill)
	outlineColor: Color3?,
	outlineTransparency: number?,        -- default 0 (solid outline)
	depthMode: Enum.HighlightDepthMode?, -- default Occluded (hidden behind walls, not X-rayed)
}

export type SkinData = {
	color: Color3,                -- ball base colour (BallEffects brightens this with heat)
	particles: { ParticleData }?, -- ambient emitters (layered); nil = none
	bounce: ParticleData?,        -- short burst Emit()'d on each bounce / showcased on the sample
	orbits: { OrbitData }?,       -- cosmetic parts that revolve around the ball (nil = none)
	highlight: HighlightData?,    -- glow; rarity >= 3 auto-gets one (base colour) unless set here
}

export type BallSkin = {
	name: string,
	rarity: number,            -- 1 (common) .. 5 (rarest)
	price: number,             -- CC cost (0 = free / owned by default)
	data: SkinData,
}

local DEFAULT_SKIN_ID = "default"

local RARITY_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromRGB(170, 178, 192), -- Common
	[2] = Color3.fromRGB(96, 200, 120),  -- Uncommon
	[3] = Color3.fromRGB(80, 160, 255),  -- Rare
	[4] = Color3.fromRGB(180, 110, 245), -- Epic
	[5] = Color3.fromRGB(255, 180, 60),  -- Legendary
}
local RARITY_NAMES: { [number]: string } = {
	[1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary",
}

-- A size sequence that swells then shrinks (a soft pulse).
local function pulse(maxSize: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, maxSize),
		NumberSequenceKeypoint.new(1, 0),
	})
end

local function cseq(...: { number }): ColorSequence
	local kps = {}
	for _, kp in { ... } do
		table.insert(kps, ColorSequenceKeypoint.new(kp[1], Color3.fromRGB(kp[2], kp[3], kp[4])))
	end
	return ColorSequence.new(kps)
end

-- A bounce burst: a big, bright, fast outward POP. Deliberately larger / brighter than the ambient
-- particles — and a soft round sprite by default (NOT the sparkly ambient texture) — so it reads as a
-- distinct impact and stays visible from far away.
local function burst(color: ColorSequence, count: number, size: number, texture: string?): ParticleData
	return {
		texture = texture, -- nil => default soft round sprite, distinct from the sparkly ambient
		color = color,
		burstCount = count,
		lifetime = NumberRange.new(0.35, 0.7),
		speed = NumberRange.new(16, 30),
		size = NumberSequence.new(size * 2.4, 0),
		transparency = NumberSequence.new(0, 1),
		spreadAngle = Vector2.new(180, 180),
		drag = 7,
		rotSpeed = NumberRange.new(-360, 360),
		lightEmission = 1,
		brightness = 9,
	}
end

-- A single orbiting cosmetic part: revolves `radius` studs from the ball centre at `speed` rad/s,
-- offset by `phase` radians so several can be spaced apart. Neon + semi-transparent by default.
local function orbit(radius: number, speed: number, phase: number, color: Color3, size: number?, shape: Enum.PartType?): OrbitData
	return {
		offset = Vector3.new(radius, 0, 0),
		speed = speed,
		phase = phase,
		color = color,
		size = Vector3.one * (size or 0.5),
		shape = shape or Enum.PartType.Ball,
		material = Enum.Material.Neon,
		transparency = 0.35,
		axis = Vector3.yAxis,
		spin = Vector3.new(0, 6, 0),
	}
end

-- A skin highlight using one colour for both fill and outline (the common case).
local function glow(color: Color3): HighlightData
	return { fillColor = color, outlineColor = color, fillTransparency = 0.75 }
end

local Skins: { [string]: BallSkin } = {
	------------------------------------------------------------------ Common (no particles)
	[DEFAULT_SKIN_ID] = {
		name = "Classic", rarity = 1, price = 0,
		data = { color = Color3.fromRGB(163, 163, 163) },
	},
	slate = {
		name = "Slate", rarity = 1, price = 50,
		data = { color = Color3.fromRGB(92, 99, 112) },
	},
	coral = {
		name = "Coral", rarity = 1, price = 50,
		data = { color = Color3.fromRGB(255, 127, 110) },
	},
	charcoal = {
		name = "Charcoal", rarity = 1, price = 50,
		data = { color = Color3.fromRGB(48, 50, 58) },
	},
	rose = {
		name = "Rose", rarity = 1, price = 65,
		data = { color = Color3.fromRGB(240, 110, 170) },
	},

	------------------------------------------------------------------ Uncommon (one bold emitter)
	mint = {
		name = "Mint", rarity = 2, price = 150,
		data = {
			color = Color3.fromRGB(120, 230, 180),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 200, 255, 220 }, { 1, 90, 230, 160 }),
				rate = 34, lifetime = NumberRange.new(0.7, 1.4), speed = NumberRange.new(1, 2.5),
				size = pulse(0.6), transparency = NumberSequence.new(0.1, 1),
				acceleration = Vector3.new(0, 6, 0), drag = 1, spreadAngle = Vector2.new(35, 35),
				rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-120, 120),
				lightEmission = 0.8, brightness = 2,
			} },
		},
	},
	ocean = {
		name = "Ocean", rarity = 2, price = 150,
		data = {
			color = Color3.fromRGB(40, 130, 230),
			particles = { {
				color = cseq({ 0, 180, 235, 255 }, { 1, 40, 120, 230 }),
				rate = 40, lifetime = NumberRange.new(0.8, 1.6), speed = NumberRange.new(1, 3),
				size = pulse(0.55), transparency = NumberSequence.new(0.2, 1),
				acceleration = Vector3.new(0, 10, 0), drag = 1.5, spreadAngle = Vector2.new(30, 30),
				lightEmission = 0.6, brightness = 1.5,
			} },
		},
	},
	sunburst = {
		name = "Sunburst", rarity = 2, price = 175,
		data = {
			color = Color3.fromRGB(255, 205, 60),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 255, 250, 180 }, { 1, 255, 150, 30 }),
				rate = 50, lifetime = NumberRange.new(0.5, 1), speed = NumberRange.new(5, 10),
				size = pulse(0.5), transparency = NumberSequence.new(0, 1),
				spreadAngle = Vector2.new(180, 180), drag = 5,
				lightEmission = 1, brightness = 3, rotSpeed = NumberRange.new(-180, 180),
			} },
			bounce = burst(cseq({ 0, 255, 240, 160 }, { 1, 255, 150, 30 }), 12, 0.3),
		},
	},
	lime = {
		name = "Lime", rarity = 2, price = 150,
		data = {
			color = Color3.fromRGB(170, 240, 60),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 220, 255, 140 }, { 1, 150, 230, 40 }),
				rate = 36, lifetime = NumberRange.new(0.6, 1.2), speed = NumberRange.new(2, 4),
				size = pulse(0.5), transparency = NumberSequence.new(0.1, 1),
				spreadAngle = Vector2.new(40, 40), lightEmission = 0.8, brightness = 2,
			} },
		},
	},
	bubblegum = {
		name = "Bubblegum", rarity = 2, price = 200,
		data = {
			color = Color3.fromRGB(255, 150, 215),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 255, 220, 245 }, { 1, 255, 120, 200 }),
				rate = 40, lifetime = NumberRange.new(0.7, 1.4), speed = NumberRange.new(1, 3),
				size = pulse(0.55), transparency = NumberSequence.new(0.1, 1),
				acceleration = Vector3.new(0, 5, 0), spreadAngle = Vector2.new(45, 45),
				rotSpeed = NumberRange.new(-90, 90), lightEmission = 0.9, brightness = 2.5,
			} },
			bounce = burst(cseq({ 0, 255, 230, 250 }, { 1, 255, 120, 200 }), 10, 0.35),
		},
	},

	------------------------------------------------------------------ Rare
	ember = {
		name = "Ember", rarity = 3, price = 300,
		data = {
			color = Color3.fromRGB(230, 90, 30),
			particles = {
				{
					texture = FIRE, color = cseq({ 0, 255, 200, 80 }, { 0.5, 255, 90, 20 }, { 1, 180, 20, 10 }),
					rate = 60, lifetime = NumberRange.new(0.4, 1), speed = NumberRange.new(2, 5),
					size = pulse(1.0), transparency = NumberSequence.new(0.05, 1),
					acceleration = Vector3.new(0, 16, 0), spreadAngle = Vector2.new(20, 20),
					squash = NumberSequence.new(1.4), lightEmission = 1, brightness = 4,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(255, 180, 80), Color3.fromRGB(255, 60, 20)),
					rate = 30, lifetime = NumberRange.new(0.6, 1.3), speed = NumberRange.new(3, 7),
					size = NumberSequence.new(0.2, 0), transparency = NumberSequence.new(0, 1),
					acceleration = Vector3.new(0, 8, 0), spreadAngle = Vector2.new(60, 60),
					lightEmission = 1, brightness = 4, rotSpeed = NumberRange.new(-200, 200),
				},
			},
			bounce = burst(cseq({ 0, 255, 190, 80 }, { 1, 255, 60, 20 }), 14, 0.35),
		},
	},
	toxic = {
		name = "Toxic", rarity = 3, price = 300,
		data = {
			color = Color3.fromRGB(120, 255, 60),
			particles = {
				{
					texture = SMOKE, color = cseq({ 0, 200, 255, 140 }, { 1, 40, 160, 20 }),
					rate = 30, lifetime = NumberRange.new(0.9, 1.6), speed = NumberRange.new(0.6, 1.6),
					size = pulse(1.1), transparency = NumberSequence.new(0.3, 1),
					rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-120, 120),
					drag = 1.2, squash = NumberSequence.new(0.5), acceleration = Vector3.new(0, 3, 0),
					lightEmission = 0.6,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(180, 255, 90)),
					rate = 26, lifetime = NumberRange.new(0.4, 0.9), speed = NumberRange.new(2, 5),
					size = NumberSequence.new(0.25, 0), transparency = NumberSequence.new(0.1, 1),
					spreadAngle = Vector2.new(140, 140), lightEmission = 0.9, brightness = 2,
				},
			},
			bounce = burst(cseq({ 0, 200, 255, 120 }, { 1, 60, 200, 20 }), 12, 0.35),
		},
	},
	amethyst = {
		name = "Amethyst", rarity = 3, price = 320,
		data = {
			color = Color3.fromRGB(150, 80, 220),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 230, 180, 255 }, { 1, 120, 40, 220 }),
				rate = 40, lifetime = NumberRange.new(0.8, 1.5), speed = NumberRange.new(1, 2.5),
				size = pulse(0.6), transparency = NumberSequence.new(0.05, 1),
				spreadAngle = Vector2.new(80, 80), rotSpeed = NumberRange.new(200, 320),
				drag = 0.5, lightEmission = 1, brightness = 3,
			} },
			bounce = burst(cseq({ 0, 230, 180, 255 }, { 1, 120, 40, 220 }), 14, 0.35),
		},
	},
	frost = {
		name = "Frost", rarity = 3, price = 340,
		data = {
			color = Color3.fromRGB(180, 230, 255),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 245, 252, 255 }, { 1, 140, 205, 255 }),
				rate = 44, lifetime = NumberRange.new(1, 2), speed = NumberRange.new(0.5, 1.5),
				size = pulse(0.5), transparency = NumberSequence.new(0.05, 1),
				acceleration = Vector3.new(0, -4, 0), spreadAngle = Vector2.new(60, 60),
				rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-60, 60),
				lightEmission = 1, brightness = 2.5,
			} },
			bounce = burst(cseq({ 0, 245, 252, 255 }, { 1, 150, 210, 255 }), 14, 0.3),
		},
	},
	crimson = {
		name = "Crimson", rarity = 3, price = 320,
		data = {
			color = Color3.fromRGB(200, 30, 50),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 255, 120, 120 }, { 1, 180, 10, 30 }),
				rate = 40, lifetime = NumberRange.new(0.5, 1.1), speed = NumberRange.new(3, 6),
				size = NumberSequence.new(0.3, 0), transparency = NumberSequence.new(0, 1),
				spreadAngle = Vector2.new(100, 100), lightEmission = 1, brightness = 3,
			} },
			bounce = burst(cseq({ 0, 255, 120, 120 }, { 1, 180, 10, 30 }), 14, 0.35),
		},
	},
	jade = {
		name = "Jade", rarity = 3, price = 340,
		data = {
			color = Color3.fromRGB(40, 200, 130),
			particles = { {
				texture = SPARKLES, color = cseq({ 0, 180, 255, 210 }, { 1, 30, 180, 110 }),
				rate = 38, lifetime = NumberRange.new(0.8, 1.5), speed = NumberRange.new(1, 2.5),
				size = pulse(0.55), transparency = NumberSequence.new(0.05, 1),
				spreadAngle = Vector2.new(70, 70), rotSpeed = NumberRange.new(150, 260),
				lightEmission = 1, brightness = 3,
			} },
			bounce = burst(cseq({ 0, 180, 255, 210 }, { 1, 30, 180, 110 }), 14, 0.35),
		},
	},
	shadow = {
		name = "Shadow", rarity = 3, price = 360,
		data = {
			color = Color3.fromRGB(30, 28, 40),
			particles = { {
				texture = SMOKE, color = cseq({ 0, 90, 80, 120 }, { 1, 15, 12, 25 }),
				rate = 34, lifetime = NumberRange.new(0.9, 1.7), speed = NumberRange.new(0.5, 1.5),
				size = pulse(1.0), transparency = NumberSequence.new(0.3, 1),
				rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-90, 90),
				drag = 1.2, lightEmission = 0.2,
			} },
			bounce = burst(cseq({ 0, 140, 120, 180 }, { 1, 40, 30, 60 }), 12, 0.4),
			highlight = glow(Color3.fromRGB(150, 130, 210)), -- base is near-black; glow the smoke's violet
		},
	},

	------------------------------------------------------------------ Epic (loud, multi-layer)
	inferno = {
		name = "Inferno", rarity = 4, price = 750,
		data = {
			color = Color3.fromRGB(200, 30, 20),
			particles = {
				{
					texture = FIRE, color = cseq({ 0, 255, 210, 80 }, { 0.5, 255, 90, 20 }, { 1, 140, 10, 5 }),
					rate = 90, lifetime = NumberRange.new(0.5, 1.2), speed = NumberRange.new(3, 7),
					size = pulse(1.6), transparency = NumberSequence.new(0, 1),
					acceleration = Vector3.new(0, 24, 0), spreadAngle = Vector2.new(25, 25),
					squash = NumberSequence.new(1.8), lightEmission = 1, brightness = 5,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 40, 10)),
					rate = 50, lifetime = NumberRange.new(0.7, 1.6), speed = NumberRange.new(5, 12),
					size = NumberSequence.new(0.3, 0), transparency = NumberSequence.new(0, 1),
					acceleration = Vector3.new(0, 12, 0), spreadAngle = Vector2.new(90, 90),
					lightEmission = 1, brightness = 5, rotSpeed = NumberRange.new(-300, 300),
				},
				{
					texture = SMOKE, color = cseq({ 0, 60, 30, 20 }, { 1, 20, 15, 15 }),
					rate = 20, lifetime = NumberRange.new(1, 1.8), speed = NumberRange.new(1, 3),
					size = pulse(1.8), transparency = NumberSequence.new(0.5, 1),
					acceleration = Vector3.new(0, 10, 0), rotSpeed = NumberRange.new(-60, 60),
				},
			},
			bounce = burst(cseq({ 0, 255, 210, 90 }, { 1, 200, 30, 10 }), 22, 0.5, FIRE),
		},
	},
	voltage = {
		name = "Voltage", rarity = 4, price = 825,
		data = {
			color = Color3.fromRGB(90, 200, 255),
			particles = {
				{
					texture = SPARKLES, color = cseq({ 0, 230, 250, 255 }, { 1, 60, 150, 255 }),
					rate = 90, lifetime = NumberRange.new(0.15, 0.45), speed = NumberRange.new(6, 14),
					size = NumberSequence.new(0.4, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-720, 720),
					drag = 4, lightEmission = 1, brightness = 6,
				},
				{
					color = ColorSequence.new(Color3.fromRGB(120, 200, 255)),
					rate = 30, lifetime = NumberRange.new(0.3, 0.7), speed = NumberRange.new(0.5, 1.5),
					size = pulse(0.9), transparency = NumberSequence.new(0.4, 1),
					spreadAngle = Vector2.new(60, 60), lightEmission = 1, brightness = 4,
				},
			},
			bounce = burst(cseq({ 0, 235, 250, 255 }, { 1, 60, 150, 255 }), 20, 0.45),
		},
	},
	midas = {
		name = "Midas", rarity = 4, price = 950,
		data = {
			color = Color3.fromRGB(255, 200, 50),
			particles = {
				{
					texture = SPARKLES, color = cseq({ 0, 255, 245, 180 }, { 1, 235, 160, 20 }),
					rate = 60, lifetime = NumberRange.new(0.9, 1.8), speed = NumberRange.new(1, 3),
					size = pulse(0.5), transparency = NumberSequence.new(0, 1),
					acceleration = Vector3.new(0, -6, 0), spreadAngle = Vector2.new(70, 70),
					rotSpeed = NumberRange.new(-180, 180), lightEmission = 1, brightness = 5,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(255, 255, 220)),
					rate = 24, lifetime = NumberRange.new(0.4, 0.9), speed = NumberRange.new(3, 7),
					size = NumberSequence.new(0.3, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), lightEmission = 1, brightness = 6,
				},
			},
			bounce = burst(cseq({ 0, 255, 250, 200 }, { 1, 235, 160, 20 }), 22, 0.45),
			orbits = {
				orbit(2.0, 2.6, 0, Color3.fromRGB(255, 215, 80)),
				orbit(2.0, 2.6, 2.094, Color3.fromRGB(255, 230, 140)),
				orbit(2.0, 2.6, 4.188, Color3.fromRGB(255, 200, 50)),
			},
		},
	},
	plasma = {
		name = "Plasma", rarity = 4, price = 875,
		data = {
			color = Color3.fromRGB(230, 60, 255),
			particles = {
				{
					texture = SPARKLES, color = cseq({ 0, 255, 180, 255 }, { 0.5, 230, 60, 255 }, { 1, 120, 60, 255 }),
					rate = 80, lifetime = NumberRange.new(0.3, 0.8), speed = NumberRange.new(4, 9),
					size = NumberSequence.new(0.35, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-540, 540),
					drag = 3, lightEmission = 1, brightness = 6,
				},
				{
					color = ColorSequence.new(Color3.fromRGB(255, 120, 255)),
					rate = 26, lifetime = NumberRange.new(0.4, 0.8), speed = NumberRange.new(0.5, 1.5),
					size = pulse(0.9), transparency = NumberSequence.new(0.4, 1),
					lightEmission = 1, brightness = 4,
				},
			},
			bounce = burst(cseq({ 0, 255, 180, 255 }, { 1, 150, 60, 255 }), 20, 0.45),
			orbits = {
				orbit(2.1, 3.0, 0, Color3.fromRGB(255, 120, 255)),
				orbit(2.1, 3.0, 3.14159, Color3.fromRGB(150, 100, 255)),
			},
		},
	},
	aurora = {
		name = "Aurora", rarity = 4, price = 975,
		data = {
			color = Color3.fromRGB(60, 230, 180),
			particles = {
				{
					color = cseq({ 0, 120, 255, 180 }, { 0.5, 80, 255, 230 }, { 1, 160, 120, 255 }),
					rate = 50, lifetime = NumberRange.new(1, 2), speed = NumberRange.new(0.6, 1.8),
					size = pulse(1.3), transparency = NumberSequence.new(0.2, 1),
					spreadAngle = Vector2.new(45, 45), rotSpeed = NumberRange.new(40, 120),
					drag = 1, lightEmission = 1, brightness = 3.5,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(220, 255, 240)),
					rate = 36, lifetime = NumberRange.new(0.5, 1), speed = NumberRange.new(2, 5),
					size = NumberSequence.new(0.25, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), lightEmission = 1, brightness = 5,
				},
			},
			bounce = burst(cseq({ 0, 120, 255, 200 }, { 1, 160, 120, 255 }), 20, 0.45),
		},
	},
	obsidian = {
		name = "Obsidian", rarity = 4, price = 900,
		data = {
			color = Color3.fromRGB(24, 22, 34),
			particles = {
				{
					texture = SMOKE, color = cseq({ 0, 120, 60, 200 }, { 1, 20, 12, 40 }),
					rate = 40, lifetime = NumberRange.new(1, 1.8), speed = NumberRange.new(0.5, 1.5),
					size = pulse(1.4), transparency = NumberSequence.new(0.3, 1),
					rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(-80, 80),
					drag = 1, lightEmission = 0.4, brightness = 2,
				},
				{
					texture = SPARKLES, color = cseq({ 0, 200, 120, 255 }, { 1, 110, 40, 220 }),
					rate = 34, lifetime = NumberRange.new(0.4, 0.9), speed = NumberRange.new(3, 7),
					size = NumberSequence.new(0.28, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), lightEmission = 1, brightness = 5,
				},
			},
			bounce = burst(cseq({ 0, 200, 120, 255 }, { 1, 110, 40, 220 }), 20, 0.45),
			highlight = glow(Color3.fromRGB(180, 110, 245)), -- base is near-black; glow the epic violet
		},
	},

	------------------------------------------------------------------ Legendary (deliberately loud)
	nebula = {
		name = "Nebula", rarity = 5, price = 2000,
		data = {
			color = Color3.fromRGB(230, 60, 200),
			particles = {
				{
					color = cseq({ 0, 150, 90, 255 }, { 0.5, 255, 80, 210 }, { 1, 80, 200, 255 }),
					rate = 60, lifetime = NumberRange.new(1.2, 2.2), speed = NumberRange.new(1, 3),
					size = pulse(1.6), transparency = NumberSequence.new(0.1, 1),
					spreadAngle = Vector2.new(50, 50), rotSpeed = NumberRange.new(80, 180),
					drag = 0.8, lightEmission = 1, brightness = 4,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(180, 220, 255)),
					rate = 70, lifetime = NumberRange.new(0.3, 0.9), speed = NumberRange.new(4, 10),
					size = NumberSequence.new(0.35, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-360, 360),
					lightEmission = 1, brightness = 6,
				},
				{
					texture = SPARKLES, color = cseq({ 0, 255, 120, 230 }, { 1, 120, 90, 255 }),
					rate = 40, lifetime = NumberRange.new(0.8, 1.4), speed = NumberRange.new(0.5, 1.5),
					size = pulse(0.5), transparency = NumberSequence.new(0.05, 1),
					spreadAngle = Vector2.new(15, 15), rotSpeed = NumberRange.new(300, 420),
					lightEmission = 1, brightness = 5,
				},
			},
			bounce = burst(cseq({ 0, 255, 255, 255 }, { 0.5, 255, 80, 210 }, { 1, 80, 200, 255 }), 28, 0.5),
			orbits = {
				orbit(2.2, 2.5, 0, Color3.fromRGB(255, 120, 230)),
				orbit(2.2, 2.5, 2.094, Color3.fromRGB(120, 160, 255)),
				orbit(2.2, 2.5, 4.188, Color3.fromRGB(180, 120, 255)),
			},
		},
	},
	galaxy = {
		name = "Galaxy", rarity = 5, price = 2400,
		data = {
			color = Color3.fromRGB(60, 40, 120),
			particles = {
				{
					texture = SPARKLES, color = cseq({ 0, 255, 255, 255 }, { 0.6, 150, 180, 255 }, { 1, 120, 90, 255 }),
					rate = 80, lifetime = NumberRange.new(0.7, 1.6), speed = NumberRange.new(0.5, 2),
					size = pulse(0.45), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-180, 180),
					drag = 1, lightEmission = 1, brightness = 6,
				},
				{
					texture = SMOKE, color = cseq({ 0, 120, 60, 220 }, { 0.5, 60, 40, 140 }, { 1, 20, 15, 60 }),
					rate = 30, lifetime = NumberRange.new(1.4, 2.4), speed = NumberRange.new(0.6, 1.6),
					size = pulse(2.0), transparency = NumberSequence.new(0.35, 1),
					rotation = NumberRange.new(0, 360), rotSpeed = NumberRange.new(60, 140),
					drag = 0.8, squash = NumberSequence.new(0.6), lightEmission = 0.7, brightness = 2,
				},
				{
					texture = SPARKLES, color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(120, 160, 255)),
					rate = 24, lifetime = NumberRange.new(0.4, 1), speed = NumberRange.new(8, 16),
					size = NumberSequence.new(0.4, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), lightEmission = 1, brightness = 6,
				},
			},
			bounce = burst(cseq({ 0, 255, 255, 255 }, { 1, 120, 160, 255 }), 28, 0.5),
			orbits = {
				orbit(2.4, 2.0, 0, Color3.fromRGB(255, 255, 255)),
				orbit(2.4, 2.0, 2.094, Color3.fromRGB(150, 180, 255)),
				orbit(2.4, 2.0, 4.188, Color3.fromRGB(120, 90, 255)),
			},
			highlight = glow(Color3.fromRGB(140, 130, 255)), -- base is dark; glow a bright galactic blue-violet
		},
	},
	supernova = {
		name = "Supernova", rarity = 5, price = 2200,
		data = {
			color = Color3.fromRGB(255, 240, 200),
			particles = {
				{
					color = cseq({ 0, 255, 255, 230 }, { 0.5, 255, 170, 60 }, { 1, 255, 60, 20 }),
					rate = 90, lifetime = NumberRange.new(0.4, 1), speed = NumberRange.new(6, 14),
					size = NumberSequence.new(0.5, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), drag = 5, lightEmission = 1, brightness = 7,
				},
				{
					color = ColorSequence.new(Color3.fromRGB(255, 250, 230)),
					rate = 30, lifetime = NumberRange.new(0.3, 0.7), speed = NumberRange.new(0.5, 1.5),
					size = pulse(1.4), transparency = NumberSequence.new(0.3, 1),
					lightEmission = 1, brightness = 6,
				},
				{
					texture = SPARKLES, color = cseq({ 0, 255, 230, 160 }, { 1, 255, 90, 30 }),
					rate = 50, lifetime = NumberRange.new(0.6, 1.4), speed = NumberRange.new(4, 9),
					size = NumberSequence.new(0.35, 0), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-300, 300),
					lightEmission = 1, brightness = 6,
				},
			},
			bounce = burst(cseq({ 0, 255, 255, 230 }, { 1, 255, 80, 30 }), 30, 0.55),
			orbits = {
				orbit(2.4, 3.2, 0, Color3.fromRGB(255, 230, 160)),
				orbit(2.4, 3.2, 2.094, Color3.fromRGB(255, 160, 60)),
				orbit(2.4, 3.2, 4.188, Color3.fromRGB(255, 90, 40)),
			},
		},
	},
	prism = {
		name = "Prism", rarity = 5, price = 2800,
		data = {
			color = Color3.fromRGB(255, 255, 255),
			particles = {
				{
					texture = SPARKLES,
					color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 60, 60)),
						ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 220, 60)),
						ColorSequenceKeypoint.new(0.5, Color3.fromRGB(60, 255, 120)),
						ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 180, 255)),
						ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 80, 255)),
					}),
					rate = 90, lifetime = NumberRange.new(0.5, 1.2), speed = NumberRange.new(2, 6),
					size = pulse(0.6), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-360, 360),
					lightEmission = 1, brightness = 6,
				},
				{
					color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 120)),
						ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 255, 200)),
						ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 120, 255)),
					}),
					rate = 36, lifetime = NumberRange.new(0.8, 1.6), speed = NumberRange.new(0.5, 1.5),
					size = pulse(1.0), transparency = NumberSequence.new(0.2, 1),
					rotSpeed = NumberRange.new(80, 160), lightEmission = 1, brightness = 4,
				},
			},
			bounce = burst(ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 255, 160)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(160, 120, 255)),
			}), 30, 0.5),
			orbits = {
				orbit(2.2, 2.4, 0, Color3.fromRGB(255, 80, 80), 0.55, Enum.PartType.Block),
				orbit(2.2, 2.4, 2.094, Color3.fromRGB(80, 255, 160), 0.55, Enum.PartType.Block),
				orbit(2.2, 2.4, 4.188, Color3.fromRGB(120, 140, 255), 0.55, Enum.PartType.Block),
			},
		},
	},
}

function BallSkins.Get(id: string): BallSkin?
	return Skins[id]
end

function BallSkins.GetAll(): { [string]: BallSkin }
	return Skins
end

function BallSkins.GetDefaultId(): string
	return DEFAULT_SKIN_ID
end

function BallSkins.RarityColor(rarity: number): Color3
	return RARITY_COLORS[rarity] or RARITY_COLORS[1]
end

function BallSkins.RarityName(rarity: number): string
	return RARITY_NAMES[rarity] or "Common"
end

return BallSkins
