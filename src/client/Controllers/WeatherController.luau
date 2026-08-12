--!strict
-- Renders the ACTIVE weather's falling particles (Config/Weather.Presets[x].Particle).
-- Atmosphere/Lighting/Sky themselves need no client code — WeatherService sets them
-- server-side and they replicate automatically as networked instances; this controller
-- only has to (a) learn which preset name is active (WeatherNet) and (b) keep a particle rig
-- raining/snowing/leaf-falling overhead of whatever's actually on screen.
--
-- The rig is one flat, invisible, anchored plane (WeatherConfig.RigSpan studs square) that
-- follows workspace.CurrentCamera every Heartbeat, WeatherConfig.RigHeight studs overhead —
-- cheap (one CFrame set/frame) and guarantees the sky above the CAMERA is always covered
-- (not the character, which can be off-screen or far from the camera in some views) without
-- world-sized emitters. It's flipped 180° so its local "up" faces world-down, which is what
-- makes the emitter's default emission direction fall toward the ground at Speed studs/sec
-- instead of shooting upward.
--
-- Standalone: nothing drives WeatherService.SetWeather yet (see its header) — this just
-- renders whatever it's told.

local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local WeatherConfig = require(RS.Shared.Config.Weather)
local WeatherNet = require(RS.Shared.Remote.WeatherNet)

local WeatherController = {}

local rig: BasePart? = nil
local emitter: ParticleEmitter? = nil

-- Mild randomized launch cone so particles don't all fall in a razor-straight grid — every
-- preset gets the same small spread; presets vary look via color/size/speed/rotation instead.
local SPREAD_ANGLE = Vector2.new(6, 6)

local function buildRig(): (BasePart, ParticleEmitter)
	local part = Instance.new("Part")
	part.Name = "WeatherRig"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(WeatherConfig.RigSpan, 1, WeatherConfig.RigSpan)
	part.Parent = workspace

	local e = Instance.new("ParticleEmitter")
	e.Name = "Fall"
	e.Enabled = false
	e.SpreadAngle = SPREAD_ANGLE
	e.LightEmission = 0
	e.LightInfluence = 1
	e.Parent = part

	return part, e
end

-- Apply one preset's look to the emitter (or disable it for Clear / an unknown name).
local function applyParticle(p: WeatherConfig.ParticlePreset?)
	local e = emitter
	if not e then
		return
	end
	if not p then
		e.Enabled = false
		return
	end
	e.Texture = p.Texture
	e.Color = ColorSequence.new(p.Color)
	-- The envelope (3rd keypoint arg) gives per-particle random variance around the base
	-- value — SizeVariance/Transparency don't have a native NumberRange like Speed does.
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, p.Size, p.SizeVariance),
		NumberSequenceKeypoint.new(1, p.Size, p.SizeVariance),
	})
	e.Transparency = NumberSequence.new(p.Transparency)
	e.Lifetime = NumberRange.new(math.max(p.Lifetime - 0.3, 0.1), p.Lifetime + 0.3)
	e.Speed = NumberRange.new(math.max(p.Speed - p.SpeedVariance, 0), p.Speed + p.SpeedVariance)
	e.Rate = p.Rate
	e.RotSpeed = NumberRange.new(-p.RotSpeed, p.RotSpeed)
	e.Acceleration = p.Wind or Vector3.zero
	e.Enabled = true
end

local function onWeatherChanged(name: unknown)
	local preset = if type(name) == "string" then WeatherConfig.Presets[name] else nil
	applyParticle(if preset then preset.Particle else nil)
end

local function followCamera()
	local r = rig
	local camera = workspace.CurrentCamera
	if not (r and camera) then
		return
	end
	-- Flip 180° about X: the emitter's local "up" (default emission direction) now points
	-- world-down, so Speed sends particles falling instead of launching into the sky.
	r.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, WeatherConfig.RigHeight, 0)) * CFrame.Angles(math.pi, 0, 0)
end

function WeatherController.Init()
	local part, e = buildRig()
	rig = part
	emitter = e

	RunService.Heartbeat:Connect(followCamera)

	;(WeatherNet.WeatherChanged :: RemoteEvent).OnClientEvent:Connect(onWeatherChanged)

	task.spawn(function()
		local ok, current = pcall(function()
			return (WeatherNet.GetWeather :: RemoteFunction):InvokeServer()
		end)
		if ok then
			onWeatherChanged(current)
		end
	end)
end

return WeatherController
