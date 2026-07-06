--!strict
-- Shared ball-effects module. Required by both server and client.
--
-- Everything that only touches BasePart / Config / TweenService lives at module
-- scope and is callable from either context. Two small server-only blocks handle
-- the parts that genuinely need server dependencies:
--   * Lifecycle (BallSpawned/Despawned) — needs BallService + ProfileService.
--   * DoClientEffect — needs a RemoteEvent that only the server should create.
-- One client-only block wires up the receiving end of that RemoteEvent.

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(RS.Shared.Config)
local StringUtils = require(RS.Shared.StringUtils)
local SoundService = require(RS.Shared.SoundService)
local AutoScale = require(RS.Shared.AutoScale)
local BallSkins = require(RS.Shared.BallSkins)

local BallEffects = {}

local GetEffectiveBallValueRF = RS.Remote.GetEffectiveBallValue 

----------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------
local DEFAULT_BASE_COLOR = Color3.fromRGB(163, 163, 163)
local DEFAULT_MATERIAL   = Enum.Material.Plastic
local HEAVY_AT           = 0.66
-- Ownership visibility: every viewer sees a ball at UNOWNED_TRANSPARENCY (set
-- server-side, replicated). Each client then makes its OWN balls fully opaque
-- locally, so a player can pick their balls out from everyone else's.
local UNOWNED_TRANSPARENCY = 0.3
local OWNED_TRANSPARENCY    = 0
local FREQ_PARTICLE_AT   = 4
local HEAT_NEON_AT       = 1
local HEAT_FIRE_AT       = 2
local HEAT_COLD_AT       = -0.5
local COLD_MATERIAL      = Enum.Material.Slate
local BRIGHTNESS_PER_HEAT        = 0.08
local MIN_BRIGHTNESS, MAX_BRIGHTNESS = 0.35, 2.0
local FREQ_EMITTER_NAME  = "FreqParticles"
local FIRE_NAME          = "HeatFire"
local SKIN_EMITTER_NAME  = "SkinParticles" -- the cosmetic skin's ambient emitters (see BallSkins)
local BOUNCE_EMITTER_NAME = "SkinBounce"   -- burst-only emitter fired on bounce (skin.data.bounce)
local ORBIT_PART_NAME    = "SkinOrbit"     -- cosmetic parts that revolve around the ball (skin.data.orbits)
local HIGHLIGHT_NAME     = "SkinHighlight" -- the glow on "good" (rarer) skins (skin.data.highlight)
local HIGHLIGHT_MIN_RARITY = 3             -- rarity at/above which a skin auto-gets a glow
local POPUP_TWEEN        = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POPUP_OFFSET_START = Vector3.new(0, 2.5, 0)
local POPUP_OFFSET_END   = Vector3.new(0, 4.5, 0)
local HEAT_COLOR_POS     = Color3.fromRGB(255, 140, 0)
local HEAT_COLOR_NEG     = Color3.fromRGB(80, 160, 255)
-- Combo POPUP gating (the combo still PAYS from Config.Scoring.MinCombo; these only
-- govern the on-screen celebration so low combos stay silent and the FX tracks real
-- payout). Show the popup a few over the pay gate; "hot combo" (bigger popup + Combo2)
-- a bit higher still.
local MIN_COMBO_TO_SHOW  = Config.Scoring.MinCombo + 3
local HIGH_COMBO         = Config.Scoring.MinCombo + 8
-- Exponential follow rate for the value-UI anchor (higher = snappier / less lag,
-- lower = smoother). Frame-rate independent via 1 - exp(-rate * dt).
local VALUE_FOLLOW_RATE  = 30
local HEAT_EFFECT_SCALE_BY_FACTOR = 0.5  -- This * 1/heatFactor is how fast progress is made toward heat effects from heat accumulation
local MULT_COLORS = {
	[0.25] = Color3.fromRGB(86, 36, 36),
	[0.5]  = Color3.fromRGB(151, 0, 0),
	[1.0]  = Color3.fromRGB(151, 0, 0),
	[1.25]  = Color3.fromRGB(140, 91, 159),
	[2.0]  = Color3.fromRGB(98, 37, 209),
	[3.0]  = Color3.fromRGB(255, 0, 191),
	[6.0]  = Color3.fromRGB(255, 255, 255),
	[Config.Scoring.JackpotMultiplier] = Color3.fromRGB(255, 255, 255)
}

-- Per-ball base color resolved at spawn (server-populated; client reads default).
local baseColors: { [BasePart]: Color3 } = {}

----------------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------------
local function applyFreqParticles(ball: BasePart, n: number)
	local existing = ball:FindFirstChild(FREQ_EMITTER_NAME)
	if n >= FREQ_PARTICLE_AT then
		if not existing then
			local p = Instance.new("ParticleEmitter")
			p.Name = FREQ_EMITTER_NAME
			p.Color = ColorSequence.new(Color3.new(1, 1, 1))
			p.Lifetime = NumberRange.new(0.4, 0.7)
			p.Rate = 25
			p.Speed = NumberRange.new(1, 2)
			p.Size = NumberSequence.new(0.3, 0)
			p.Transparency = NumberSequence.new(0.2, 1)
			p.Parent = ball
		end
	elseif existing then
		existing:Destroy()
	end
end

-- Build the cosmetic skin's ParticleEmitters on the ball. A skin may LAYER several; each becomes a
-- "SkinParticles<i>" emitter. Only the fields a skin sets are applied; the rest stay default.
-- (Moved here from CosmeticService so ApplyAppearance owns the whole cosmetic layer.)
local function clearSkinParticles(ball: BasePart)
	for _, child in ball:GetChildren() do
		if child:IsA("ParticleEmitter") and child.Name:sub(1, #SKIN_EMITTER_NAME) == SKIN_EMITTER_NAME then
			child:Destroy()
		end
	end
end

local function buildSkinEmitter(p: BallSkins.ParticleData): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Color = p.color or ColorSequence.new(Color3.new(1, 1, 1))
	if p.texture then e.Texture = p.texture end
	e.Rate = p.rate or 20
	e.Lifetime = p.lifetime or NumberRange.new(0.5, 1)
	e.Speed = p.speed or NumberRange.new(1, 2)
	e.Size = p.size or NumberSequence.new(0.3, 0)
	e.Transparency = p.transparency or NumberSequence.new(0.2, 1)
	e.SpreadAngle = p.spreadAngle or Vector2.new(0, 0)
	e.LightEmission = p.lightEmission or 0
	if p.lightInfluence ~= nil then e.LightInfluence = p.lightInfluence end
	if p.rotation then e.Rotation = p.rotation end
	if p.rotSpeed then e.RotSpeed = p.rotSpeed end
	if p.acceleration then e.Acceleration = p.acceleration end
	if p.drag ~= nil then e.Drag = p.drag end
	if p.velocityInheritance ~= nil then e.VelocityInheritance = p.velocityInheritance end
	if p.emissionDirection then e.EmissionDirection = p.emissionDirection end
	if p.zOffset ~= nil then e.ZOffset = p.zOffset end
	if p.squash then e.Squash = p.squash end
	if p.orientation then e.Orientation = p.orientation end
	if p.brightness ~= nil then e.Brightness = p.brightness end
	if p.shape then e.Shape = p.shape end
	return e
end

local function applySkinParticles(ball: BasePart, particles: { BallSkins.ParticleData }?)
	clearSkinParticles(ball)
	if not particles then
		return
	end
	for i, p in particles do
		local e = buildSkinEmitter(p)
		e.Name = SKIN_EMITTER_NAME .. tostring(i)
		e.Parent = ball
	end
end

-- A burst-only emitter for the skin's bounce effect (skin.data.bounce). Kept at Rate 0 / disabled;
-- BallEffects.EmitBounce fires a one-off Emit() of BurstCount particles on each bounce.
local function applyBounceEmitter(ball: BasePart, bounce: BallSkins.ParticleData?)
	local existing = ball:FindFirstChild(BOUNCE_EMITTER_NAME)
	if existing then
		existing:Destroy()
	end
	if not bounce then
		return
	end
	local e = buildSkinEmitter(bounce)
	e.Name = BOUNCE_EMITTER_NAME
	e.Rate = 0
	e.Enabled = false
	e:SetAttribute("BurstCount", bounce.burstCount or 14)
	e.Parent = ball
end

-- Cosmetic parts that revolve around the ball (skin.data.orbits). Each is an anchored, non-colliding
-- part; its orbit params live as attributes so the per-frame positioner (UpdateOrbits) — run by the
-- client ball animator and the shop sample — can move it without touching the skin table.
local function clearOrbits(ball: BasePart)
	for _, child in ball:GetChildren() do
		if child:IsA("BasePart") and child.Name:sub(1, #ORBIT_PART_NAME) == ORBIT_PART_NAME then
			child:Destroy()
		end
	end
end

local function applyOrbits(ball: BasePart, orbits: { BallSkins.OrbitData }?)
	clearOrbits(ball)
	if not orbits then
		return
	end
	for i, o in orbits do
		local p = Instance.new("Part")
		p.Name = ORBIT_PART_NAME .. tostring(i)
		p.Shape = o.shape or Enum.PartType.Ball
		p.Size = o.size or Vector3.new(0.6, 0.6, 0.6)
		p.Color = o.color or Color3.fromRGB(255, 255, 255)
		p.Material = o.material or Enum.Material.Neon
		p.Transparency = if o.transparency ~= nil then o.transparency else 0.4
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p:SetAttribute("OrbitAxis", o.axis or Vector3.yAxis)
		p:SetAttribute("OrbitOffset", o.offset or Vector3.new(2, 0, 0))
		p:SetAttribute("OrbitSpeed", o.speed or 2)
		p:SetAttribute("OrbitPhase", o.phase or 0)
		if o.spin then
			p:SetAttribute("OrbitSpin", o.spin)
		end
		p.Parent = ball
	end
end

-- The glow on rarer skins. A Highlight Adorned to the ball; colours default to the skin's base colour
-- (so it's "appropriate" without per-skin config), overridable via skin.data.highlight. DepthMode is
-- Occluded by default, so the glow is hidden behind walls rather than X-raying through them.
local function applyHighlight(ball: BasePart, hl: BallSkins.HighlightData?, baseColor: Color3)
	local existing = ball:FindFirstChild(HIGHLIGHT_NAME) :: Highlight?
	if not hl then
		if existing then
			existing:Destroy()
		end
		return
	end
	local h = existing or Instance.new("Highlight")
	h.Name = HIGHLIGHT_NAME
	h.Adornee = ball
	h.FillColor = hl.fillColor or baseColor
	h.OutlineColor = hl.outlineColor or baseColor
	h.FillTransparency = if hl.fillTransparency ~= nil then hl.fillTransparency else 0.75
	h.OutlineTransparency = if hl.outlineTransparency ~= nil then hl.outlineTransparency else 0
	h.DepthMode = hl.depthMode or Enum.HighlightDepthMode.Occluded
	h.Parent = ball
end

local function applyHeatParticles(ball: BasePart, heat: number)
	local fire = ball:FindFirstChild(FIRE_NAME)
	if heat >= HEAT_FIRE_AT then
		if not fire then
			local f = Instance.new("Fire")
			f.Name = FIRE_NAME
			f.Heat = 10
			f.Size = 5
			f.Parent = ball
		end
	elseif fire then
		fire:Destroy()
	end
end

local function applyColor(ball: BasePart, base: Color3, heat: number)
	local b = math.clamp(1 + heat * BRIGHTNESS_PER_HEAT, MIN_BRIGHTNESS, MAX_BRIGHTNESS)
	ball.Color = Color3.new(
		math.clamp(base.R * b, 0, 1),
		math.clamp(base.G * b, 0, 1),
		math.clamp(base.B * b, 0, 1)
	)
end

local function applyHeatMatAndSound(ball: BasePart, weight: number, heat: number)
	if heat <= HEAT_COLD_AT then
		ball.Material = COLD_MATERIAL
	elseif heat >= HEAT_NEON_AT then
		ball.Material = Enum.Material.Neon
	elseif weight >= HEAVY_AT then
		ball.Material = Enum.Material.Metal
	else
		ball.Material = DEFAULT_MATERIAL
	end
end

----------------------------------------------------------------------------------
-- Public API (both contexts)
----------------------------------------------------------------------------------
function BallEffects.ApplyHeat(ball: BasePart, heat: number, heatFactor: number)
	if not ball.Parent then return end
	if heatFactor == nil then heatFactor = 1 end
	heat = (heat / heatFactor) * HEAT_EFFECT_SCALE_BY_FACTOR
	local base = baseColors[ball] or DEFAULT_BASE_COLOR
	local weight = (ball:GetAttribute(Config.Attributes.Weight) :: number?) or 0.5
	applyColor(ball, base, heat)
	applyHeatMatAndSound(ball, weight, heat)
	applyHeatParticles(ball, heat)
end

-- Set the ball's cosmetic base colour (e.g. from a ball skin) and repaint at neutral
-- heat. Heat applied later still brightens from this base. Used by CosmeticService.
function BallEffects.SetBaseColor(ball: BasePart, color: Color3)
	baseColors[ball] = color
	applyColor(ball, color, 0)
end

-- One entry point for ALL of a ball's appearance: cosmetic skin (base colour + particles) plus the
-- tuning look (size scale, elasticity→weight material) plus the heat paint. Shared by the live ball
-- spawn (CosmeticService), the cosmetic shop sample, and the ball-tuning preview, so they can't
-- drift. Only the fields you pass are applied (size needs baseSize; an omitted weight is left alone).
export type Appearance = {
	skinId: string?,    -- cosmetic skin id (BallSkins); nil/unknown -> default
	weight: number?,    -- 0..1, heavy -> metal material (typically 1 - elasticity)
	sizeScale: number?, -- multiply baseSize by this (requires baseSize)
	baseSize: Vector3?, -- the unscaled size to scale from
	heat: number?,      -- accumulated heat to paint (default 0)
}
function BallEffects.ApplyAppearance(ball: BasePart, appearance: Appearance)
	local skin = BallSkins.Get(appearance.skinId or BallSkins.GetDefaultId())
		or BallSkins.Get(BallSkins.GetDefaultId())
	if skin then
		baseColors[ball] = skin.data.color
		applySkinParticles(ball, skin.data.particles)
		applyBounceEmitter(ball, skin.data.bounce)
		applyOrbits(ball, skin.data.orbits)
		local hl = skin.data.highlight
		if not hl and skin.rarity >= HIGHLIGHT_MIN_RARITY then
			hl = {} -- auto-glow for "good" skins, coloured by the skin's base colour
		end
		applyHighlight(ball, hl, skin.data.color)
	end
	if appearance.weight ~= nil then
		ball:SetAttribute(Config.Attributes.Weight, appearance.weight)
	end
	if appearance.sizeScale and appearance.baseSize then
		ball.Size = appearance.baseSize * appearance.sizeScale
	end
	-- Paints colour (from the skin base), material (weight + heat) and heat particles.
	BallEffects.ApplyHeat(ball, appearance.heat or 0, 1)
end

-- Fire the skin's bounce burst (a one-off Emit of the SkinBounce emitter), if the equipped skin has
-- one. Safe to call from either context; the burst renders for whoever calls it (so the owner's
-- client fires it on bounce, and the cosmetic sample fires it on the showcase timer).
function BallEffects.EmitBounce(ball: BasePart?)
	if not ball then
		return
	end
	local e = ball:FindFirstChild(BOUNCE_EMITTER_NAME) :: ParticleEmitter?
	if e then
		e:Emit((e:GetAttribute("BurstCount") :: number?) or 14)
	end
end

-- Per-frame positioner for a ball's orbiting cosmetic parts: each revolves around the ball about its
-- OrbitAxis at OrbitSpeed (offset by OrbitOffset), optionally spinning on its own (OrbitSpin). Called
-- every frame by the client ball animator and by the cosmetic sample, so it works for any ball.
function BallEffects.UpdateOrbits(ball: BasePart)
	local t = os.clock()
	local ballCF = ball.CFrame
	for _, p in ball:GetChildren() do
		if p:IsA("BasePart") and p.Name:sub(1, #ORBIT_PART_NAME) == ORBIT_PART_NAME then
			local axis = (p:GetAttribute("OrbitAxis") :: Vector3?) or Vector3.yAxis
			local offset = (p:GetAttribute("OrbitOffset") :: Vector3?) or Vector3.new(2, 0, 0)
			local speed = (p:GetAttribute("OrbitSpeed") :: number?) or 2
			local phase = (p:GetAttribute("OrbitPhase") :: number?) or 0
			local spin = p:GetAttribute("OrbitSpin") :: Vector3?
			local cf = ballCF * CFrame.fromAxisAngle(axis, t * speed + phase) * CFrame.new(offset)
			if spin then
				cf = cf * CFrame.Angles(t * spin.X, t * spin.Y, t * spin.Z)
			end
			p.CFrame = cf
		end
	end
end

-- Play heat transition sound if applicable
function BallEffects.PlayHeatSound(ball: BasePart, prevHeat: number, curHeat: number, heatFactor: number)
	if heatFactor == nil then heatFactor = 1 end
	prevHeat = (prevHeat / heatFactor) * HEAT_EFFECT_SCALE_BY_FACTOR
	curHeat = (curHeat / heatFactor) * HEAT_EFFECT_SCALE_BY_FACTOR
	if prevHeat < HEAT_NEON_AT and curHeat >= HEAT_NEON_AT then
		SoundService.Play({ soundId = Config.Sounds.Hot, position = ball.CFrame.Position, volume = 1.5 })
	elseif prevHeat < HEAT_FIRE_AT and curHeat >= HEAT_FIRE_AT then
		SoundService.Play({ soundId = Config.Sounds.Fire, position = ball.CFrame.Position, volume = 1.5 })
	elseif prevHeat >= HEAT_NEON_AT and curHeat < HEAT_NEON_AT then
		SoundService.Play({ soundId = Config.Sounds.Cold, position = ball.CFrame.Position, volume = 1.5})
	end
end

-- Per-ball smooth-follow value UI. The ball itself carries no ValueUI; AttachValueUI
-- spawns an anchored part that lerps toward the ball each frame and holds a clone of
-- Assets.ValueUI, so the billboard glides instead of jittering with the ball's
-- physics replication. Keyed by ball for SetValueUI updates and cleanup. Per context
-- (a client follower and a server follower for the same ball are independent).
local valueFollowers: { [BasePart]: { anchor: BasePart, label: TextLabel, conn: RBXScriptConnection } } = {}

local function removeValueFollower(ball: BasePart)
	local f = valueFollowers[ball]
	if not f then return end
	valueFollowers[ball] = nil
	f.conn:Disconnect()
	f.anchor:Destroy()
end

-- Instantiate an anchored part that smoothly follows `ball`, carrying a clone of
-- ReplicatedStorage.Assets.ValueUI (a BillboardGui). Decouples the value billboard
-- from the ball's jittery motion. Callable from client or server (e.g. via
-- DoClientEffect); the follower lives only in the calling context and
-- self-destructs when the ball is gone. Idempotent: a second call replaces the
-- existing follower. Returns the anchor, or nil if the ball isn't present (e.g. a
-- DoClientEffect arrived before the ball replicated).
function BallEffects.AttachValueUI(ball: BasePart?): BasePart?
	if not ball or not ball.Parent then return nil end
	removeValueFollower(ball)

	local anchor = Instance.new("Part")
	anchor.Name = "ValueFollower"
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false   -- invisible to ScoringService overlap queries
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Position = ball.Position
	anchor.Parent = workspace

	local ui = (RS.Assets:WaitForChild("ValueUI") :: BillboardGui):Clone()
	ui.Parent = anchor
	local label = ui:FindFirstChild("TextLabel") :: TextLabel
	label.Font = Enum.Font.FredokaOne -- match the runtime popups (the Studio asset is authored in Gotham)

	-- RenderStepped on the client (smoothest, pre-render); Heartbeat on the server.
	local stepped = if RunService:IsClient() then RunService.RenderStepped else RunService.Heartbeat
	local conn = stepped:Connect(function(dt: number)
		if not ball.Parent then
			removeValueFollower(ball) -- ball despawned/destroyed; clean up
			return
		end
		local alpha = 1 - math.exp(-VALUE_FOLLOW_RATE * dt)
		anchor.Position = anchor.Position:Lerp(ball.Position, alpha)
	end)

	valueFollowers[ball] = { anchor = anchor, label = label, conn = conn }
	return anchor
end

-- Update the follower's text. No-op if AttachValueUI hasn't been called for this
-- ball in this context (the ball has no ValueUI of its own).
function BallEffects.SetValueUI(ball: BasePart, value: number)
	local f = valueFollowers[ball]
	if f then
		f.label.Text = StringUtils.FormatMoney(value)
	end
end

function BallEffects.ShowValuePopup(ball: BasePart?, cframe: CFrame, label: string, color: Color3?, strokeColor: Color3?)
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.CFrame = cframe
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 150, 0, 75)
	billboard.StudsOffset = POPUP_OFFSET_START
	billboard.AlwaysOnTop = true
	billboard.Parent = anchor

	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.Text = label
	text.TextColor3 = color or Color3.new(1, 1, 1)
	text.TextStrokeColor3 = Color3.new(0, 0, 0)
	text.TextStrokeTransparency = 0.4
	text.TextScaled = true
	text.Font = Enum.Font.FredokaOne
	text.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = strokeColor or Color3.new(0, 0, 0)
	stroke.Parent = text

	-- Shrink the popup on smaller viewports (sizes authored at 1080p).
	AutoScale.Apply(text)

	local t1 = TweenService:Create(billboard, POPUP_TWEEN, { StudsOffset = POPUP_OFFSET_END })
	local t2 = TweenService:Create(text, POPUP_TWEEN, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	local t3 = TweenService:Create(stroke, POPUP_TWEEN, {
		Transparency = 1,
	})
	t1:Play()
	t2:Play()
	t3:Play()
	t2.Completed:Connect(function()
		anchor:Destroy()
	end)
end

local COMBO_COLOR_NORMAL = Color3.fromRGB(222, 9, 9)
local COMBO_COLOR_HOT    = Color3.fromRGB(223, 13, 226)
local COMBO_STROKE_COLOR_HOT = Color3.fromRGB(252, 205, 35)

function BallEffects.ShowComboPopup(ball: BasePart?, cframe: CFrame, combo: number, flatRate: number)
	if RunService:IsClient() then
		SoundService.Play({ soundId = Config.Sounds.Bounce, position = cframe.Position, jitter = 0.06, volume = 1.5 })
	end

	if combo < MIN_COMBO_TO_SHOW then return end

	local color: Color3
	local strokeColor: Color3
	local comboSoundId: string
	if combo < HIGH_COMBO then
		color = COMBO_COLOR_NORMAL
		comboSoundId = Config.Sounds.Combo
	else
		color = COMBO_COLOR_HOT
		strokeColor = COMBO_STROKE_COLOR_HOT
		comboSoundId = Config.Sounds.Combo2
	end
	BallEffects.ShowValuePopup(ball, cframe, "COMBO x"..combo.."! (+"..StringUtils.FormatMoney(combo * flatRate)..")", color, strokeColor)
	if RunService:IsClient() then
		SoundService.Play({ soundId = comboSoundId, position = cframe.Position, jitter = 0.06, volume = 1.5 })
	end
end

function BallEffects.ShowHeatPopup(ball: BasePart?, heatDelta: number)
	if heatDelta == 0 or not ball or not ball.Parent then return end
	local label = if heatDelta > 0 then string.format("+%.0f%%", heatDelta * 100) else string.format("%.0f%%", heatDelta * 100)
	local color = if heatDelta > 0 then HEAT_COLOR_POS else HEAT_COLOR_NEG
	BallEffects.ShowValuePopup(ball, ball.CFrame, label, color)
end

local HIGH_POINT_PARTICLE_COUNT = 40
local HIGH_POINT_EMIT_TIME      = 0.4  -- window the emitter runs to lay down the burst
local HIGH_POINT_MAX_LIFETIME   = 1.5

-- Burst of white particles thrown upward from the ball. Marks a high-point hit.
-- Meant to be invoked server-side (the emitter replicates to every client), so no
-- DoClientEffect round-trip. The ball is usually destroyed right after the scoring
-- hit, so the emitter rides an independent anchor part in workspace (snapshot of
-- the ball's position) rather than the ball itself — same trick as ShowValuePopup.
--
-- The burst is driven by Rate + Enabled, NOT ParticleEmitter:Emit(): Emit() does
-- not replicate from server to client, so a server-side Emit produces nothing on
-- any player's screen. Rate/Enabled DO replicate, so we run a high rate for a brief
-- window then switch it off — every client renders the same burst.
function BallEffects.ShowPointFX(ball: BasePart?, cframe: CFrame, multiplier: number)
	if not (cframe and multiplier) then return end

	local isJackpot = multiplier == Config.Scoring.JackpotMultiplier

	-- Honest juice: only a real GAIN is celebrated. A non-positive slot (<= 1x — you broke
	-- even or lost) plays no sound and throws no particles; the "x0.3" value popup (posted
	-- separately) is the only, honest, feedback.
	if not isJackpot and multiplier <= 1.0 then
		return
	end

	-- Lower positive (1x .. SpecialFXMin): a quiet collect, no particle burst. Higher
	-- positive: the second collect sound + burst. Jackpot: the jackpot sound + burst.
	if isJackpot then
		SoundService.Play({ soundId = Config.Sounds.Jackpot, position = cframe.Position, volume = 2.5})
	elseif multiplier < Config.Scoring.SpecialFXMinMultiplier then
		SoundService.Play({ soundId = Config.Sounds.Collect1, position = cframe.Position, volume = 1.5 })
		return
	else
		SoundService.Play({ soundId = Config.Sounds.Collect2, position = cframe.Position, volume = 1.5 })
	end

	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(cframe.Position)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Brightness = 4
	if isJackpot then
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 0, 191))
		emitter.Lifetime = NumberRange.new(1.0, HIGH_POINT_MAX_LIFETIME * 2)
		emitter.Speed = NumberRange.new(32, 40)
		emitter.SpreadAngle = Vector2.new(22, 22)
		emitter.Rate = (HIGH_POINT_PARTICLE_COUNT / HIGH_POINT_EMIT_TIME) * 2
	else
		emitter.Color = ColorSequence.new(MULT_COLORS[multiplier] or Color3.fromRGB(255, 255, 255))
		emitter.Lifetime = NumberRange.new(1.0, HIGH_POINT_MAX_LIFETIME)
		emitter.Speed = NumberRange.new(22, 30)
		emitter.SpreadAngle = Vector2.new(18, 18)
		emitter.Rate = HIGH_POINT_PARTICLE_COUNT / HIGH_POINT_EMIT_TIME
	end
	emitter.Size = NumberSequence.new(1.0, 0)
	emitter.Transparency = NumberSequence.new(0.05, 1)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, 18, 0)
	emitter.Enabled = true
	emitter.Parent = anchor

	-- Stop emitting after the burst window; clear the anchor once the last
	-- particle has lived out its max lifetime.
	task.delay(HIGH_POINT_EMIT_TIME, function()
		emitter.Enabled = false
	end)
	Debris:AddItem(anchor, HIGH_POINT_EMIT_TIME + HIGH_POINT_MAX_LIFETIME + 0.2)
end

-- Make a ball (and everything under it) render nothing: BasePart/Decal/Texture go
-- fully transparent and every emitter/trail/beam/light/fire is disabled. One-way
-- ("vanish") — it doesn't remember prior values, so it isn't a reversible toggle on
-- its own. The client ball-hide toggle (see SetBallsHidden) uses local-destroy
-- instead, which also drops the replication/interpolation cost; this is the lighter,
-- reversible-by-recolour alternative kept available for cosmetic use.
function BallEffects.SetBallInvisible(ball: BasePart)
	ball.Transparency = 1
	for _, d in ball:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
			d.Transparency = 1
		elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam")
			or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Light") then
			d.Enabled = false
		end
	end
end

----------------------------------------------------------------------------------
-- Server-only: lifecycle + client dispatch
----------------------------------------------------------------------------------
if RunService:IsServer() then
	local Players = game:GetService("Players")
	local SSS = game:GetService("ServerScriptService")
	local ProfileService = require(SSS.Scripts.Modules.ProfileService)
	local BallService = require(SSS.Scripts.Modules.BallService)

	local effectRemote: RemoteEvent? = nil

	-- Fires a named effect function on the given player's client for a specific
	-- ball. The client Init listener calls BallEffects[effect](ball, ...).
	function BallEffects.DoClientEffect(player: Player, effect: string, ball: BasePart, ...: any)
		(effectRemote :: RemoteEvent):FireClient(player, effect, ball, ...)
	end

	local function onBallSpawn(ball: BasePart)
		local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
		local player = if ownerId then Players:GetPlayerByUserId(ownerId) else nil
		baseColors[ball] = if player then DEFAULT_BASE_COLOR else DEFAULT_BASE_COLOR
		-- Default everyone sees; the owning client overrides to opaque (see client block).
		ball.Transparency = UNOWNED_TRANSPARENCY
		BallEffects.ApplyHeat(ball, 0)
	end

	local function onBallDespawn(ball: BasePart)
		baseColors[ball] = nil
	end

	function BallEffects.Init()
		local re = Instance.new("RemoteEvent")
		re.Name = "BallEffect"
		re.Parent = RS.Remote
		effectRemote = re

		BallService.BallSpawned:Connect(onBallSpawn)
		BallService.BallDespawned:Connect(onBallDespawn)
	end
end

----------------------------------------------------------------------------------
-- Client-only: receive server effect calls, and self-attach the value UI to our
-- own balls. The attach is driven off the Ball tag rather than a server remote:
-- CollectionService's added signal fires only once the ball has replicated to this
-- client, so the ball is always present — no spawn-time replication race.
----------------------------------------------------------------------------------
if RunService:IsClient() then
	local Players = game:GetService("Players")
	local CollectionService = game:GetService("CollectionService")
local TouchInputService = game:GetService("TouchInputService")
	local localUserId = Players.LocalPlayer.UserId

	local function isOwnBall(ball: BasePart): boolean
		return ball:GetAttribute(Config.Attributes.OwnerUserId) == localUserId
	end

	-- Ball-hide toggle (the "ball visible" button). When on, every OTHER player's ball
	-- is destroyed locally (our own balls are always kept) — this is client-only, so
	-- the server keeps its authoritative copy and gameplay/scoring is untouched; we
	-- just stop rendering and interpolating it on this machine (the real lag win — the
	-- server still streams its CFrame, but with no local instance those updates are
	-- simply dropped). It's one-way for balls already in flight: the server won't
	-- re-replicate an existing instance, so toggling back on only restores balls
	-- spawned from then on (fine — balls are short-lived, so the board repopulates
	-- within seconds).
	local ballsHidden = false

	local function hideBall(ball: BasePart)
		ball:Destroy()
	end

	-- Balls that carry orbiting cosmetic parts, animated locally every frame (everyone sees them).
	local orbitBalls: { [BasePart]: boolean } = {}
	local function trackOrbits(ball: BasePart)
		-- Orbit parts may replicate a moment after the ball, so scan now and watch for late ones.
		local function check(child: Instance)
			if child:IsA("BasePart") and child.Name:sub(1, #ORBIT_PART_NAME) == ORBIT_PART_NAME then
				orbitBalls[ball] = true
			end
		end
		for _, c in ball:GetChildren() do
			check(c)
		end
		ball.ChildAdded:Connect(check)
	end

	local function onBallTagged(ball: BasePart)
		local own = isOwnBall(ball)
		if ballsHidden and not own then
			hideBall(ball)   -- only other players' balls are hidden
			return
		end
		if own then
			-- Our own ball: make it fully opaque for us (local-only; others keep 0.5).
			ball.Transparency = OWNED_TRANSPARENCY
			BallEffects.AttachValueUI(ball)
			local effectiveValue = GetEffectiveBallValueRF:InvokeServer(ball)
			if effectiveValue then
				BallEffects.SetValueUI(ball, effectiveValue)
			end
		end
		trackOrbits(ball) -- orbiting cosmetic parts are visible to everyone
	end

	-- Toggle whether OTHER players' balls are shown. Turning it on destroys every
	-- non-owned ball currently on the board; new ones are destroyed as they replicate
	-- in (see onBallTagged). Our own balls are never touched.
	function BallEffects.SetBallsHidden(hidden: boolean)
		ballsHidden = hidden
		if hidden then
			for _, ball in CollectionService:GetTagged(Config.Tags.Ball) do
				if ball:IsA("BasePart") and not isOwnBall(ball) then
					hideBall(ball)
				end
			end
		end
	end

	function BallEffects.AreBallsHidden(): boolean
		return ballsHidden
	end

	function BallEffects.Init()
		local remote = RS.Remote:WaitForChild("BallEffect") :: RemoteEvent
		remote.OnClientEvent:Connect(function(effect: string, ball: BasePart?, ...: any)
			local fn = (BallEffects :: any)[effect]
			if fn then fn(ball, ...) end
		end)

		-- Attach to our own balls already present, and any that appear later (and
		-- destroy them instead while the hide toggle is on).
		for _, ball in CollectionService:GetTagged(Config.Tags.Ball) do
			if ball:IsA("BasePart") then
				onBallTagged(ball)
			end
		end
		CollectionService:GetInstanceAddedSignal(Config.Tags.Ball):Connect(function(inst)
			if inst:IsA("BasePart") then
				onBallTagged(inst)
			end
		end)
		CollectionService:GetInstanceRemovedSignal(Config.Tags.Ball):Connect(function(inst)
			orbitBalls[inst :: BasePart] = nil
		end)

		-- Animate orbiting cosmetic parts each frame (local to this client; the parts are server-
		-- created and replicated, so every viewer sees the orbit).
		RunService.RenderStepped:Connect(function()
			for ball in orbitBalls do
				if ball.Parent then
					BallEffects.UpdateOrbits(ball)
				else
					orbitBalls[ball] = nil
				end
			end
		end)
	end
end

return BallEffects
