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

-- A cosmetic part FIXED to the ball at an offset/orientation (vs. orbits, which revolve).
-- Purely visual: anchored, non-colliding, massless, positioned per-frame by each client —
-- the ball's physics/hitbox are untouched, so a "skin" can stop looking like a ball
-- entirely (crowns, wings, saucers...) while playing identically.
export type ShapeData = {
	shape: Enum.PartType?,     -- Ball / Block / Cylinder / Wedge / CornerWedge (default Block)
	size: Vector3?,            -- default (0.8, 0.8, 0.8)
	offset: Vector3?,          -- from the ball centre, studs (default (0, 1.2, 0))
	orientation: Vector3?,     -- degrees (default (0, 0, 0))
	color: Color3?,
	material: Enum.Material?,  -- default Neon
	transparency: number?,     -- default 0
	followRotation: boolean?,  -- true = inherits the ball's spin (tumbles with it);
	                           -- default false (stays upright while the marble rolls)
}

export type SkinData = {
	color: Color3,                -- ball base colour (BallEffects brightens this with heat)
	particles: { ParticleData }?, -- ambient emitters (layered); nil = none
	bounce: ParticleData?,        -- short burst Emit()'d on each bounce / showcased on the sample
	orbits: { OrbitData }?,       -- cosmetic parts that revolve around the ball (nil = none)
	shapes: { ShapeData }?,       -- cosmetic parts fixed to the ball (nil = none)
	highlight: HighlightData?,    -- glow; rarity >= 3 auto-gets one (base colour) unless set here
}

export type BallSkin = {
	name: string,
	rarity: number,            -- 1 (common) .. 9 (Transcendent, rarest)
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
	[6] = Color3.fromRGB(255, 80, 90),   -- Mythic (crimson)
	[7] = Color3.fromRGB(110, 225, 255), -- Celestial (ice cyan)
	[8] = Color3.fromRGB(255, 240, 150), -- Divine (radiant gold-white)
	[9] = Color3.fromRGB(255, 90, 230),  -- Transcendent (hyper magenta)
}
local RARITY_NAMES: { [number]: string } = {
	[1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary",
	[6] = "Mythic", [7] = "Celestial", [8] = "Divine", [9] = "Transcendent",
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
	----------------------------------------------------------------------------
	-- Rarity 6+ (Gold Box exclusives): shape-built skins — these stop looking like
	-- balls entirely (the hitbox is still just the marble; shapes never collide).
	----------------------------------------------------------------------------
	crown = {
		name = "Royal Crown", rarity = 6, price = 5000,
		data = {
			color = Color3.fromRGB(255, 200, 60),
			shapes = {
				-- band
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.28, 1.5, 1.5), offset = Vector3.new(0, 1.05, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 200, 60), material = Enum.Material.Metal },
				-- prongs
				{ size = Vector3.new(0.2, 0.6, 0.2), offset = Vector3.new(0.55, 1.5, 0), color = Color3.fromRGB(255, 210, 80) },
				{ size = Vector3.new(0.2, 0.6, 0.2), offset = Vector3.new(-0.55, 1.5, 0), color = Color3.fromRGB(255, 210, 80) },
				{ size = Vector3.new(0.2, 0.6, 0.2), offset = Vector3.new(0, 1.5, 0.55), color = Color3.fromRGB(255, 210, 80) },
				{ size = Vector3.new(0.2, 0.6, 0.2), offset = Vector3.new(0, 1.5, -0.55), color = Color3.fromRGB(255, 210, 80) },
				-- ruby
				{ shape = Enum.PartType.Ball, size = Vector3.new(0.45, 0.45, 0.45), offset = Vector3.new(0, 1.95, 0), color = Color3.fromRGB(255, 60, 80) },
			},
			bounce = burst(cseq({ 0, 255, 220, 120 }, { 1, 255, 80, 90 }), 22, 0.45),
		},
	},
	demoncore = {
		name = "Demon Core", rarity = 6, price = 5000,
		data = {
			color = Color3.fromRGB(30, 8, 10),
			shapes = {
				-- horns
				{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.9, 0.5), offset = Vector3.new(0.55, 1.15, 0), orientation = Vector3.new(0, 0, -24), color = Color3.fromRGB(255, 70, 70), material = Enum.Material.Metal },
				{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.9, 0.5), offset = Vector3.new(-0.55, 1.15, 0), orientation = Vector3.new(0, 180, 24), color = Color3.fromRGB(255, 70, 70), material = Enum.Material.Metal },
			},
			particles = {
				{
					texture = SMOKE, color = cseq({ 0, 255, 60, 60 }, { 1, 40, 0, 0 }),
					rate = 26, lifetime = NumberRange.new(0.7, 1.3), speed = NumberRange.new(0.8, 2),
					size = pulse(1.2), transparency = NumberSequence.new(0.3, 1),
					rotSpeed = NumberRange.new(-120, 120), lightEmission = 0.9, brightness = 3,
				},
			},
			bounce = burst(cseq({ 0, 255, 90, 60 }, { 1, 120, 0, 0 }), 26, 0.5),
		},
	},
	saturn = {
		name = "Saturn", rarity = 7, price = 8000,
		data = {
			color = Color3.fromRGB(120, 200, 235),
			shapes = {
				-- tilted ice ring around the marble itself
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.1, 3.1, 3.1), offset = Vector3.zero, orientation = Vector3.new(18, 0, 90), color = Color3.fromRGB(160, 230, 255), transparency = 0.35 },
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.06, 3.7, 3.7), offset = Vector3.zero, orientation = Vector3.new(18, 0, 90), color = Color3.fromRGB(110, 200, 255), transparency = 0.6 },
			},
			bounce = burst(cseq({ 0, 200, 245, 255 }, { 1, 110, 200, 255 }), 24, 0.45),
		},
	},
	seraph = {
		name = "Seraph", rarity = 7, price = 8000,
		data = {
			color = Color3.fromRGB(250, 250, 255),
			shapes = {
				-- wings
				{ shape = Enum.PartType.Wedge, size = Vector3.new(0.18, 1.1, 1.7), offset = Vector3.new(0.95, 0.55, 0), orientation = Vector3.new(0, 90, 30), color = Color3.fromRGB(255, 255, 255), transparency = 0.15 },
				{ shape = Enum.PartType.Wedge, size = Vector3.new(0.18, 1.1, 1.7), offset = Vector3.new(-0.95, 0.55, 0), orientation = Vector3.new(0, -90, 30), color = Color3.fromRGB(255, 255, 255), transparency = 0.15 },
				-- halo
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.09, 1.35, 1.35), offset = Vector3.new(0, 1.7, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 230, 120), transparency = 0.1 },
			},
			bounce = burst(cseq({ 0, 255, 255, 255 }, { 1, 255, 230, 120 }), 24, 0.45),
		},
	},
	ufo = {
		name = "UFO", rarity = 8, price = 15000,
		data = {
			color = Color3.fromRGB(140, 255, 170),
			shapes = {
				-- saucer disc under the "dome" (the marble)
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.35, 3.0, 3.0), offset = Vector3.new(0, -0.35, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(170, 180, 200), material = Enum.Material.Metal },
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.18, 1.7, 1.7), offset = Vector3.new(0, -0.62, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(120, 130, 150), material = Enum.Material.Metal },
			},
			orbits = {
				-- rim running-lights
				orbit(1.45, 5, 0, Color3.fromRGB(140, 255, 170), 0.22),
				orbit(1.45, 5, 2.094, Color3.fromRGB(255, 240, 120), 0.22),
				orbit(1.45, 5, 4.188, Color3.fromRGB(120, 200, 255), 0.22),
			},
			bounce = burst(cseq({ 0, 140, 255, 170 }, { 1, 120, 200, 255 }), 26, 0.5),
		},
	},
	monolith = {
		name = "Monolith", rarity = 8, price = 15000,
		data = {
			color = Color3.fromRGB(255, 240, 150),
			shapes = {
				-- glowing octahedron-ish shell the marble floats inside
				{ size = Vector3.new(1.9, 1.9, 1.9), offset = Vector3.zero, orientation = Vector3.new(45, 45, 0), color = Color3.fromRGB(255, 240, 150), transparency = 0.55 },
				{ size = Vector3.new(1.4, 1.4, 1.4), offset = Vector3.zero, orientation = Vector3.new(0, 22, 45), color = Color3.fromRGB(255, 255, 255), transparency = 0.7 },
			},
			bounce = burst(cseq({ 0, 255, 255, 255 }, { 1, 255, 240, 150 }), 28, 0.5),
		},
	},
	singularity = {
		name = "Singularity", rarity = 9, price = 25000,
		data = {
			color = Color3.fromRGB(10, 6, 16),
			shapes = {
				-- accretion disc
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.08, 3.4, 3.4), offset = Vector3.zero, orientation = Vector3.new(24, 0, 90), color = Color3.fromRGB(255, 90, 230), transparency = 0.25 },
			},
			particles = {
				{
					texture = SPARKLES, color = cseq({ 0, 255, 90, 230 }, { 1, 90, 60, 255 }),
					rate = 60, lifetime = NumberRange.new(0.5, 1.1), speed = NumberRange.new(1, 3),
					size = pulse(0.5), transparency = NumberSequence.new(0, 1),
					spreadAngle = Vector2.new(180, 180), rotSpeed = NumberRange.new(-360, 360),
					lightEmission = 1, brightness = 6,
				},
			},
			orbits = {
				orbit(2.0, 6, 0, Color3.fromRGB(255, 90, 230), 0.3),
				orbit(2.4, 4.2, 3.14, Color3.fromRGB(160, 90, 255), 0.3),
			},
			bounce = burst(cseq({ 0, 255, 90, 230 }, { 1, 40, 0, 80 }), 32, 0.55),
		},
	},
	marblegod = {
		name = "Marble God", rarity = 9, price = 25000,
		data = {
			color = Color3.fromRGB(255, 255, 255),
			shapes = {
				-- crown
				{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.24, 1.4, 1.4), offset = Vector3.new(0, 1.1, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 210, 80), material = Enum.Material.Metal },
				{ shape = Enum.PartType.Ball, size = Vector3.new(0.4, 0.4, 0.4), offset = Vector3.new(0, 1.6, 0), color = Color3.fromRGB(255, 90, 230) },
				-- wings
				{ shape = Enum.PartType.Wedge, size = Vector3.new(0.16, 1.3, 2.0), offset = Vector3.new(1.05, 0.6, 0), orientation = Vector3.new(0, 90, 32), color = Color3.fromRGB(255, 245, 200), transparency = 0.1 },
				{ shape = Enum.PartType.Wedge, size = Vector3.new(0.16, 1.3, 2.0), offset = Vector3.new(-1.05, 0.6, 0), orientation = Vector3.new(0, -90, 32), color = Color3.fromRGB(255, 245, 200), transparency = 0.1 },
			},
			orbits = {
				orbit(2.3, 3, 0, Color3.fromRGB(255, 210, 80), 0.35),
				orbit(2.3, 3, 3.14, Color3.fromRGB(255, 90, 230), 0.35),
			},
			bounce = burst(cseq({ 0, 255, 255, 255 }, { 0.5, 255, 210, 80 }, { 1, 255, 90, 230 }), 34, 0.6),
		},
	},
	----------------------------------------------------------------------------
	-- Shape pack: 25 skins built purely from fixed shapes. Variants of one style sit
	-- at the same rarity. followRotation = true makes the shell TUMBLE with the
	-- rolling marble (great for cubes/spikes/rings); omitted = stays upright.
	----------------------------------------------------------------------------
	-- Cubes (Rare)
	cube = {
		name = "Cube", rarity = 3, price = 350,
		data = { color = Color3.fromRGB(160, 170, 190), shapes = {
			{ size = Vector3.new(1.5, 1.5, 1.5), offset = Vector3.zero, color = Color3.fromRGB(180, 190, 210), transparency = 0.35, followRotation = true },
		} },
	},
	twincube = {
		name = "Twin Cubes", rarity = 3, price = 350,
		data = { color = Color3.fromRGB(120, 190, 230), shapes = {
			{ size = Vector3.new(0.7, 0.7, 0.7), offset = Vector3.new(0, 1.0, 0), color = Color3.fromRGB(120, 190, 230), followRotation = true },
			{ size = Vector3.new(0.7, 0.7, 0.7), offset = Vector3.new(0, -1.0, 0), color = Color3.fromRGB(230, 190, 120), followRotation = true },
		} },
	},
	cubecluster = {
		name = "Cube Cluster", rarity = 3, price = 350,
		data = { color = Color3.fromRGB(190, 140, 230), shapes = {
			{ size = Vector3.new(0.5, 0.5, 0.5), offset = Vector3.new(0.8, 0.8, 0.8), color = Color3.fromRGB(190, 140, 230), followRotation = true },
			{ size = Vector3.new(0.5, 0.5, 0.5), offset = Vector3.new(-0.8, 0.8, -0.8), color = Color3.fromRGB(140, 230, 190), followRotation = true },
			{ size = Vector3.new(0.5, 0.5, 0.5), offset = Vector3.new(-0.8, -0.8, 0.8), color = Color3.fromRGB(230, 190, 140), followRotation = true },
			{ size = Vector3.new(0.5, 0.5, 0.5), offset = Vector3.new(0.8, -0.8, -0.8), color = Color3.fromRGB(140, 190, 230), followRotation = true },
		} },
	},
	dice = {
		name = "Dice", rarity = 3, price = 400,
		data = { color = Color3.fromRGB(245, 245, 245), shapes = {
			{ size = Vector3.new(1.5, 1.5, 1.5), offset = Vector3.zero, color = Color3.fromRGB(250, 250, 250), material = Enum.Material.SmoothPlastic, transparency = 0.25, followRotation = true },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(0, 0, -0.78), color = Color3.fromRGB(20, 20, 20), material = Enum.Material.SmoothPlastic, followRotation = true },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(0.35, 0.78, 0.35), color = Color3.fromRGB(20, 20, 20), material = Enum.Material.SmoothPlastic, followRotation = true },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(-0.35, 0.78, -0.35), color = Color3.fromRGB(20, 20, 20), material = Enum.Material.SmoothPlastic, followRotation = true },
		} },
	},
	bolt = {
		name = "Bolt", rarity = 3, price = 400,
		data = { color = Color3.fromRGB(255, 230, 90), shapes = {
			{ size = Vector3.new(0.35, 0.9, 0.35), offset = Vector3.new(0, 1.25, 0), orientation = Vector3.new(0, 0, 18), color = Color3.fromRGB(255, 230, 90) },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.35, 0.5, 0.5), offset = Vector3.new(0.2, 1.85, 0), orientation = Vector3.new(0, 0, 198), color = Color3.fromRGB(255, 230, 90) },
		} },
	},
	-- Spikes (Epic)
	spikeball = {
		name = "Spikeball", rarity = 4, price = 900,
		data = { color = Color3.fromRGB(90, 95, 110), shapes = {
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.7, 0.4), offset = Vector3.new(0, 1.05, 0), color = Color3.fromRGB(200, 205, 220), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.7, 0.4), offset = Vector3.new(0, -1.05, 0), orientation = Vector3.new(180, 0, 0), color = Color3.fromRGB(200, 205, 220), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.7, 0.4), offset = Vector3.new(1.05, 0, 0), orientation = Vector3.new(0, 0, -90), color = Color3.fromRGB(200, 205, 220), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.7, 0.4), offset = Vector3.new(-1.05, 0, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(200, 205, 220), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.7, 0.4), offset = Vector3.new(0, 0, 1.05), orientation = Vector3.new(-90, 0, 0), color = Color3.fromRGB(200, 205, 220), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.3, 0.7, 0.4), offset = Vector3.new(0, 0, -1.05), orientation = Vector3.new(90, 0, 0), color = Color3.fromRGB(200, 205, 220), material = Enum.Material.Metal, followRotation = true },
		} },
	},
	morningstar = {
		name = "Morningstar", rarity = 4, price = 900,
		data = { color = Color3.fromRGB(60, 55, 70), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.2, 1.6, 1.6), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(120, 110, 140), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.25, 0.6, 0.35), offset = Vector3.new(0, 1.05, 0), color = Color3.fromRGB(255, 120, 90), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.25, 0.6, 0.35), offset = Vector3.new(0, -1.05, 0), orientation = Vector3.new(180, 0, 0), color = Color3.fromRGB(255, 120, 90), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.25, 0.6, 0.35), offset = Vector3.new(0, 0, 1.05), orientation = Vector3.new(-90, 0, 0), color = Color3.fromRGB(255, 120, 90), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.25, 0.6, 0.35), offset = Vector3.new(0, 0, -1.05), orientation = Vector3.new(90, 0, 0), color = Color3.fromRGB(255, 120, 90), material = Enum.Material.Metal, followRotation = true },
		} },
	},
	satellite = {
		name = "Satellite", rarity = 4, price = 950,
		data = { color = Color3.fromRGB(210, 215, 230), shapes = {
			{ size = Vector3.new(1.5, 0.08, 0.8), offset = Vector3.new(1.6, 0, 0), color = Color3.fromRGB(40, 80, 200), transparency = 0.1 },
			{ size = Vector3.new(1.5, 0.08, 0.8), offset = Vector3.new(-1.6, 0, 0), color = Color3.fromRGB(40, 80, 200), transparency = 0.1 },
			{ size = Vector3.new(0.12, 0.9, 0.12), offset = Vector3.new(0, 1.3, 0), color = Color3.fromRGB(220, 220, 230), material = Enum.Material.Metal },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.25, 0.25, 0.25), offset = Vector3.new(0, 1.8, 0), color = Color3.fromRGB(255, 80, 80) },
		} },
	},
	radar = {
		name = "Radar", rarity = 4, price = 950,
		data = { color = Color3.fromRGB(120, 200, 160), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.15, 1.3, 1.3), offset = Vector3.new(0, 1.35, 0), orientation = Vector3.new(50, 0, 90), color = Color3.fromRGB(220, 230, 235), material = Enum.Material.Metal },
			{ size = Vector3.new(0.12, 0.7, 0.12), offset = Vector3.new(0, 0.85, 0), color = Color3.fromRGB(160, 170, 180), material = Enum.Material.Metal },
		} },
	},
	jester = {
		name = "Jester", rarity = 4, price = 900,
		data = { color = Color3.fromRGB(220, 80, 140), shapes = {
			{ size = Vector3.new(0.18, 0.8, 0.18), offset = Vector3.new(0.5, 1.25, 0), orientation = Vector3.new(0, 0, -25), color = Color3.fromRGB(255, 90, 90) },
			{ size = Vector3.new(0.18, 0.8, 0.18), offset = Vector3.new(-0.5, 1.25, 0), orientation = Vector3.new(0, 0, 25), color = Color3.fromRGB(90, 200, 90) },
			{ size = Vector3.new(0.18, 0.8, 0.18), offset = Vector3.new(0, 1.35, 0.5), orientation = Vector3.new(25, 0, 0), color = Color3.fromRGB(90, 130, 255) },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(0.78, 1.85, 0), color = Color3.fromRGB(255, 220, 90) },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(-0.78, 1.85, 0), color = Color3.fromRGB(255, 220, 90) },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(0, 1.95, 0.78), color = Color3.fromRGB(255, 220, 90) },
		} },
	},
	-- Gyro rings (Legendary)
	gyroring = {
		name = "Gyro Ring", rarity = 5, price = 2500,
		data = { color = Color3.fromRGB(255, 170, 80), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.12, 2.6, 2.6), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 170, 80), transparency = 0.25, followRotation = true },
		} },
	},
	gyrotwin = {
		name = "Gyro Twin", rarity = 5, price = 2500,
		data = { color = Color3.fromRGB(90, 220, 255), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.12, 2.6, 2.6), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(90, 220, 255), transparency = 0.25, followRotation = true },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.12, 2.6, 2.6), offset = Vector3.zero, orientation = Vector3.new(90, 0, 90), color = Color3.fromRGB(255, 120, 200), transparency = 0.25, followRotation = true },
		} },
	},
	gyrotri = {
		name = "Gyro Tri", rarity = 5, price = 2700,
		data = { color = Color3.fromRGB(180, 255, 140), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.12, 2.6, 2.6), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(180, 255, 140), transparency = 0.25, followRotation = true },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.12, 2.6, 2.6), offset = Vector3.zero, orientation = Vector3.new(90, 0, 90), color = Color3.fromRGB(255, 200, 120), transparency = 0.25, followRotation = true },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.12, 2.6, 2.6), offset = Vector3.zero, orientation = Vector3.new(0, 90, 0), color = Color3.fromRGB(150, 150, 255), transparency = 0.25, followRotation = true },
		} },
	},
	drill = {
		name = "Drill", rarity = 5, price = 2500,
		data = { color = Color3.fromRGB(200, 200, 210), shapes = {
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.5, 0.9, 0.5), offset = Vector3.new(0, -1.1, 0), orientation = Vector3.new(180, 0, 0), color = Color3.fromRGB(230, 230, 240), material = Enum.Material.Metal },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.35, 1.1, 1.1), offset = Vector3.new(0, 0.75, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 190, 60), material = Enum.Material.Metal },
		} },
	},
	lantern = {
		name = "Lantern", rarity = 5, price = 2500,
		data = { color = Color3.fromRGB(60, 45, 35), shapes = {
			{ size = Vector3.new(0.8, 0.8, 0.8), offset = Vector3.new(0, 1.5, 0), color = Color3.fromRGB(255, 210, 110), transparency = 0.2 },
			{ size = Vector3.new(1.0, 0.12, 1.0), offset = Vector3.new(0, 2.0, 0), color = Color3.fromRGB(70, 60, 50), material = Enum.Material.Metal },
			{ size = Vector3.new(1.0, 0.12, 1.0), offset = Vector3.new(0, 1.05, 0), color = Color3.fromRGB(70, 60, 50), material = Enum.Material.Metal },
		} },
	},
	-- Blades (Mythic)
	shuriken = {
		name = "Shuriken", rarity = 6, price = 5000,
		data = { color = Color3.fromRGB(40, 40, 50), shapes = {
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.15, 0.9, 0.9), offset = Vector3.new(0, 1.15, 0), color = Color3.fromRGB(180, 190, 210), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.15, 0.9, 0.9), offset = Vector3.new(0, -1.15, 0), orientation = Vector3.new(180, 0, 0), color = Color3.fromRGB(180, 190, 210), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.15, 0.9, 0.9), offset = Vector3.new(1.15, 0, 0), orientation = Vector3.new(0, 0, -90), color = Color3.fromRGB(180, 190, 210), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.15, 0.9, 0.9), offset = Vector3.new(-1.15, 0, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(180, 190, 210), material = Enum.Material.Metal, followRotation = true },
		} },
	},
	bladeorb = {
		name = "Blade Orb", rarity = 6, price = 5000,
		data = { color = Color3.fromRGB(120, 20, 30), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.18, 2.2, 2.2), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(90, 90, 100), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.14, 0.8, 1.1), offset = Vector3.new(0, 1.4, 0), color = Color3.fromRGB(255, 80, 90), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.14, 0.8, 1.1), offset = Vector3.new(0, -1.4, 0), orientation = Vector3.new(180, 0, 0), color = Color3.fromRGB(255, 80, 90), material = Enum.Material.Metal, followRotation = true },
		} },
	},
	obelisk = {
		name = "Obelisk", rarity = 6, price = 5000,
		data = { color = Color3.fromRGB(25, 25, 35), shapes = {
			{ size = Vector3.new(0.55, 1.6, 0.55), offset = Vector3.new(0, 1.9, 0), color = Color3.fromRGB(80, 240, 200), transparency = 0.15 },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.55, 0.45, 0.55), offset = Vector3.new(0, 2.9, 0), color = Color3.fromRGB(80, 240, 200), transparency = 0.15 },
		} },
	},
	-- Ice (Celestial)
	icecrystal = {
		name = "Ice Crystal", rarity = 7, price = 8000,
		data = { color = Color3.fromRGB(190, 235, 255), shapes = {
			{ size = Vector3.new(0.4, 1.7, 0.4), offset = Vector3.new(0.5, 0.9, 0.3), orientation = Vector3.new(12, 0, -18), color = Color3.fromRGB(190, 235, 255), material = Enum.Material.Glass, transparency = 0.35 },
			{ size = Vector3.new(0.3, 1.3, 0.3), offset = Vector3.new(-0.55, 0.8, -0.2), orientation = Vector3.new(-10, 0, 22), color = Color3.fromRGB(160, 220, 255), material = Enum.Material.Glass, transparency = 0.35 },
			{ size = Vector3.new(0.25, 1.0, 0.25), offset = Vector3.new(0, 0.7, -0.6), orientation = Vector3.new(-24, 0, 0), color = Color3.fromRGB(220, 245, 255), material = Enum.Material.Glass, transparency = 0.35 },
		} },
	},
	snowflake = {
		name = "Snowflake", rarity = 7, price = 8000,
		data = { color = Color3.fromRGB(235, 250, 255), shapes = {
			{ size = Vector3.new(0.14, 2.8, 0.14), offset = Vector3.zero, color = Color3.fromRGB(220, 245, 255), transparency = 0.15, followRotation = true },
			{ size = Vector3.new(0.14, 2.8, 0.14), offset = Vector3.zero, orientation = Vector3.new(0, 0, 60), color = Color3.fromRGB(220, 245, 255), transparency = 0.15, followRotation = true },
			{ size = Vector3.new(0.14, 2.8, 0.14), offset = Vector3.zero, orientation = Vector3.new(0, 0, -60), color = Color3.fromRGB(220, 245, 255), transparency = 0.15, followRotation = true },
		} },
	},
	cometcore = {
		name = "Comet Core", rarity = 7, price = 8500,
		data = { color = Color3.fromRGB(150, 220, 255), shapes = {
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.7, 0.7, 1.8), offset = Vector3.new(0, 0.25, 1.35), orientation = Vector3.new(180, 0, 0), color = Color3.fromRGB(110, 200, 255), transparency = 0.35 },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.45, 0.45, 1.2), offset = Vector3.new(0, -0.2, 1.7), color = Color3.fromRGB(180, 235, 255), transparency = 0.5 },
		} },
	},
	-- Machines (Divine)
	reactor = {
		name = "Reactor", rarity = 8, price = 15000,
		data = { color = Color3.fromRGB(120, 255, 210), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.16, 2.9, 2.9), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(120, 255, 210), transparency = 0.3, followRotation = true },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.16, 2.9, 2.9), offset = Vector3.zero, orientation = Vector3.new(90, 0, 90), color = Color3.fromRGB(255, 240, 130), transparency = 0.3, followRotation = true },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.5, 0.5, 0.5), offset = Vector3.new(0, 1.6, 0), color = Color3.fromRGB(255, 255, 255) },
			{ shape = Enum.PartType.Ball, size = Vector3.new(0.5, 0.5, 0.5), offset = Vector3.new(0, -1.6, 0), color = Color3.fromRGB(255, 255, 255) },
		} },
	},
	haloarray = {
		name = "Halo Array", rarity = 8, price = 15000,
		data = { color = Color3.fromRGB(255, 245, 210), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.09, 1.5, 1.5), offset = Vector3.new(0, 1.45, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 230, 120), transparency = 0.1 },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.09, 1.1, 1.1), offset = Vector3.new(0, 1.95, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 240, 170), transparency = 0.2 },
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.09, 0.7, 0.7), offset = Vector3.new(0, 2.4, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 250, 220), transparency = 0.3 },
		} },
	},
	-- Impossible objects (Transcendent)
	hypercube = {
		name = "Hypercube", rarity = 9, price = 25000,
		data = { color = Color3.fromRGB(255, 90, 230), shapes = {
			{ size = Vector3.new(1.6, 1.6, 1.6), offset = Vector3.zero, color = Color3.fromRGB(255, 90, 230), transparency = 0.45, followRotation = true },
			{ size = Vector3.new(2.3, 2.3, 2.3), offset = Vector3.zero, orientation = Vector3.new(45, 45, 0), color = Color3.fromRGB(140, 90, 255), transparency = 0.75, followRotation = true },
		} },
	},
	chaosengine = {
		name = "Chaos Engine", rarity = 9, price = 25000,
		data = { color = Color3.fromRGB(15, 10, 20), shapes = {
			{ shape = Enum.PartType.Cylinder, size = Vector3.new(0.14, 2.7, 2.7), offset = Vector3.zero, orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 90, 230), transparency = 0.25, followRotation = true },
			{ size = Vector3.new(0.6, 0.6, 0.6), offset = Vector3.new(0, 1.5, 0), orientation = Vector3.new(45, 0, 45), color = Color3.fromRGB(255, 90, 230), transparency = 0.2, followRotation = true },
			{ size = Vector3.new(0.6, 0.6, 0.6), offset = Vector3.new(0, -1.5, 0), orientation = Vector3.new(0, 45, 45), color = Color3.fromRGB(90, 230, 255), transparency = 0.2, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.2, 0.7, 0.7), offset = Vector3.new(1.5, 0, 0), orientation = Vector3.new(0, 0, -90), color = Color3.fromRGB(255, 240, 120), material = Enum.Material.Metal, followRotation = true },
			{ shape = Enum.PartType.Wedge, size = Vector3.new(0.2, 0.7, 0.7), offset = Vector3.new(-1.5, 0, 0), orientation = Vector3.new(0, 0, 90), color = Color3.fromRGB(255, 240, 120), material = Enum.Material.Metal, followRotation = true },
		} },
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
