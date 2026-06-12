--!strict
-- Owns ball cosmetic appearance. Two trigger paths, deliberately separated:
--   * Spawn (self-connected to BallService.BallSpawned): reads the owner's
--     profile and applies upgrade/loadout-driven looks — weight, frequency, base
--     color — then the baseline heat look (heat 0).
--   * Heat change (BallEffects.ApplyHeat, called by ScoringService): applies the
--     heat-driven looks only — color brightness, material, fire. NO profile read;
--     it uses the cached base color and the ball's Weight attribute.
--
-- Effects are independent per-property where the engine allows. Two properties
-- are inherently shared and have resolvers that read both inputs:
--   * Color    = base color (profile) scaled by heat brightness.
--   * Material = weight baseline (heavy→metal, else plastic), overridden by heat
--                (cold→boring, hot→neon).
-- Everything else (transparency, frequency particles, fire) is standalone.
--
-- Size is intentionally NOT handled here (BallService scales it at spawn).
-- Existing modules are otherwise untouched: appearance is driven by signals and
-- a single ApplyHeat call from ScoringService.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local Config = require(RS.Shared.Config)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local BallService = require(SSS.Scripts.Modules.BallService)

local BallEffects = {}

----------------------------------------------------------------------------------
-- Tunable look constants
----------------------------------------------------------------------------------
-- Default appearance matches the prefab: gray plastic, no particles.
local DEFAULT_BASE_COLOR = Color3.fromRGB(163, 163, 163)
local DEFAULT_MATERIAL = Enum.Material.Plastic

-- Weight (0 light .. 1 heavy)
local HEAVY_AT = 0.66        -- weight >= → metallic
local LIGHT_AT = 0.34        -- weight <= → translucent
local LIGHT_TRANSPARENCY = 0.45

-- Frequency: white trail particles once the batch is this many balls or more.
local FREQ_PARTICLE_AT = 4

-- Heat (signed, accumulated peg heat)
local HEAT_NEON_AT = 3       -- heat >= → neon material
local HEAT_FIRE_AT = 6       -- heat >= → fire particle
local HEAT_COLD_AT = -3      -- heat <= → cold/boring material
local COLD_MATERIAL = Enum.Material.Slate
-- Heat scales the brightness applied to all three channels of the base color.
local BRIGHTNESS_PER_HEAT = 0.08
local MIN_BRIGHTNESS, MAX_BRIGHTNESS = 0.35, 2.0

local FREQ_EMITTER_NAME = "FreqParticles"
local FIRE_NAME = "HeatFire"

-- BallEffects-owned per-ball state: base color resolved at spawn so heat updates
-- need no profile lookup. Cleared on despawn.
local baseColors: { [BasePart]: Color3 } = {}

----------------------------------------------------------------------------------
-- Base color (forward-compatible with an unlocked-color cosmetic)
----------------------------------------------------------------------------------
-- The player's unlocked base color. No cosmetic-unlock field exists yet, so this
-- returns the default; swap to a profile read when that system lands.
local function getBaseColor(_player: Player?): Color3
	return DEFAULT_BASE_COLOR
end

----------------------------------------------------------------------------------
-- Independent per-property effects
----------------------------------------------------------------------------------
-- Weight → transparency. Light balls are translucent; heavier are solid.
local function applyTransparency(ball: BasePart, weight: number)
	ball.Transparency = if weight <= LIGHT_AT then LIGHT_TRANSPARENCY else 0
end

-- Frequency → white particles, created/removed once (N is fixed for a ball's life).
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

-- Hot fire particle past a threshold.
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

----------------------------------------------------------------------------------
-- Shared-property resolvers (read more than one input)
----------------------------------------------------------------------------------
-- Color = base color scaled by heat brightness (hot brightens, cold darkens).
local function applyColor(ball: BasePart, base: Color3, heat: number)
	local b = math.clamp(1 + heat * BRIGHTNESS_PER_HEAT, MIN_BRIGHTNESS, MAX_BRIGHTNESS)
	ball.Color = Color3.new(
		math.clamp(base.R * b, 0, 1),
		math.clamp(base.G * b, 0, 1),
		math.clamp(base.B * b, 0, 1)
	)
end

-- Material = heat override (cold→boring, hot→neon) if heat is significant, else
-- the weight baseline (heavy→metal, else plastic).
local function applyMaterial(ball: BasePart, weight: number, heat: number)
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
-- Public API
----------------------------------------------------------------------------------
-- Re-apply the heat-driven looks. Called by ScoringService whenever a ball's
-- accumulated heat changes, and once at spawn (heat 0). No profile read.
function BallEffects.ApplyHeat(ball: BasePart, heat: number)
	if not ball.Parent then
		return -- despawned
	end
	local base = baseColors[ball] or DEFAULT_BASE_COLOR
	local weight = (ball:GetAttribute(Config.Attributes.Weight) :: number?) or 0.5
	applyColor(ball, base, heat)
	applyMaterial(ball, weight, heat)
	applyHeatParticles(ball, heat)
end

local POPUP_TWEEN = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POPUP_OFFSET_START = Vector3.new(0, 2.5, 0)
local POPUP_OFFSET_END   = Vector3.new(0, 4.5, 0)

-- Spawns a floating label above the ball showing what just happened (e.g. "+100"
-- or "×2"). Snapshots the ball's position into an invisible anchor Part parented
-- to workspace so the popup outlives ball destruction, then tweens it upward while
-- fading out and cleans up the anchor when done.
function BallEffects.ShowValuePopup(ball: BasePart, label: string, color: Color3?)
	if not ball.Parent then return end

	-- Snapshot world position now; the ball may be destroyed before the tween ends.
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.CFrame = ball.CFrame
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 100, 0, 50)
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
	text.Font = Enum.Font.GothamBold
	text.Parent = billboard

	local t1 = TweenService:Create(billboard, POPUP_TWEEN, { StudsOffset = POPUP_OFFSET_END })
	local t2 = TweenService:Create(text, POPUP_TWEEN, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	t1:Play()
	t2:Play()
	t2.Completed:Connect(function()
		anchor:Destroy()
	end)
end

local HEAT_COLOR_POS = Color3.fromRGB(255, 140, 0)  -- orange: hot peg
local HEAT_COLOR_NEG = Color3.fromRGB(80, 160, 255)  -- blue:   cold peg

function BallEffects.ShowHeatPopup(ball: BasePart, heatDelta: number)
	if heatDelta == 0 then return end
	local label = string.format("%+.1f", heatDelta)
	local color = if heatDelta > 0 then HEAT_COLOR_POS else HEAT_COLOR_NEG
	BallEffects.ShowValuePopup(ball, label, color)
end

function BallEffects.SetValueUI(ball: BasePart, value: number): ()
	if not ball then
		return
	end

	local textLabel: TextLabel = (ball:FindFirstChild("ValueUI") :: Instance):FindFirstChild("TextLabel") :: TextLabel
	textLabel.Text = tostring(value)
end

----------------------------------------------------------------------------------
-- Lifecycle (self-connected; existing modules are not modified for spawn looks)
----------------------------------------------------------------------------------
local function onBallSpawn(ball: BasePart)
	-- Resolve the owner for profile-driven looks; fall back to defaults if gone.
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
	local player = if ownerId then Players:GetPlayerByUserId(ownerId) else nil

	local base = getBaseColor(player)
	baseColors[ball] = base

	local weight = (ball:GetAttribute(Config.Attributes.Weight) :: number?) or 0.5
	applyTransparency(ball, weight)

	local n = if player then ProfileService.GetLoadout(player).BallCount else 1
	applyFreqParticles(ball, n)

	-- Baseline heat look (heat starts at 0): sets color + material, no fire.
	BallEffects.ApplyHeat(ball, 0)
end

local function onBallDespawn(ball: BasePart)
	baseColors[ball] = nil
end

function BallEffects.Init()
	BallService.BallSpawned:Connect(onBallSpawn)
	BallService.BallDespawned:Connect(onBallDespawn)
end

return BallEffects
