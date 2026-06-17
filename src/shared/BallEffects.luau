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

local BallEffects = {}

local GetEffectiveBallValueRF = RS.Remote.GetEffectiveBallValue 

----------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------
local DEFAULT_BASE_COLOR = Color3.fromRGB(163, 163, 163)
local DEFAULT_MATERIAL   = Enum.Material.Plastic
local HEAVY_AT           = 0.66
local LIGHT_AT           = 0.34
local LIGHT_TRANSPARENCY = 0.45
local FREQ_PARTICLE_AT   = 4
local HEAT_NEON_AT       = 1
local HEAT_FIRE_AT       = 2
local HEAT_COLD_AT       = -0.5
local COLD_MATERIAL      = Enum.Material.Slate
local BRIGHTNESS_PER_HEAT        = 0.08
local MIN_BRIGHTNESS, MAX_BRIGHTNESS = 0.35, 2.0
local FREQ_EMITTER_NAME  = "FreqParticles"
local FIRE_NAME          = "HeatFire"
local POPUP_TWEEN        = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POPUP_OFFSET_START = Vector3.new(0, 2.5, 0)
local POPUP_OFFSET_END   = Vector3.new(0, 4.5, 0)
local HEAT_COLOR_POS     = Color3.fromRGB(255, 140, 0)
local HEAT_COLOR_NEG     = Color3.fromRGB(80, 160, 255)
local MIN_COMBO_TO_SHOW  = 5
-- Exponential follow rate for the value-UI anchor (higher = snappier / less lag,
-- lower = smoother). Frame-rate independent via 1 - exp(-rate * dt).
local VALUE_FOLLOW_RATE  = 30

-- Per-ball base color resolved at spawn (server-populated; client reads default).
local baseColors: { [BasePart]: Color3 } = {}

----------------------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------------------
local function applyTransparency(ball: BasePart, weight: number)
	ball.Transparency = if weight <= LIGHT_AT then LIGHT_TRANSPARENCY else 0
end

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
-- Public API (both contexts)
----------------------------------------------------------------------------------
function BallEffects.ApplyHeat(ball: BasePart, heat: number)
	if not ball.Parent then return end
	local base = baseColors[ball] or DEFAULT_BASE_COLOR
	local weight = (ball:GetAttribute(Config.Attributes.Weight) :: number?) or 0.5
	applyColor(ball, base, heat)
	applyMaterial(ball, weight, heat)
	applyHeatParticles(ball, heat)
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
		f.label.Text = tostring(value)
	end
end

function BallEffects.ShowValuePopup(ball: BasePart?, cframe: CFrame, label: string, color: Color3?)
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

local COMBO_COLOR_NORMAL = Color3.new(1, 1, 1)
local COMBO_COLOR_HOT    = Color3.fromRGB(255, 60, 60)

function BallEffects.ShowComboPopup(ball: BasePart?, cframe: CFrame, combo: number)
	if combo < MIN_COMBO_TO_SHOW then return end
	if combo < Config.Scoring.MinCombo then
		BallEffects.ShowValuePopup(ball, cframe, "BOUNCE x" .. combo, COMBO_COLOR_NORMAL)
	else
		BallEffects.ShowValuePopup(ball, cframe, "COMBO! x" .. combo, COMBO_COLOR_HOT)
	end
	
end

function BallEffects.ShowHeatPopup(ball: BasePart?, heatDelta: number)
	if heatDelta == 0 or not ball or not ball.Parent then return end
	local label = string.format("%+.1f", heatDelta)
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
function BallEffects.ShowHighPointFX(ball: BasePart?)
	if not ball or not ball.Parent then return end

	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(ball.CFrame.Position)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Brightness = 4
	emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
	emitter.Lifetime = NumberRange.new(1.0, HIGH_POINT_MAX_LIFETIME)
	emitter.Speed = NumberRange.new(22, 30)
	emitter.SpreadAngle = Vector2.new(18, 18)
	emitter.Size = NumberSequence.new(1.0, 0)
	emitter.Transparency = NumberSequence.new(0.05, 1)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(0, 18, 0)
	emitter.Rate = HIGH_POINT_PARTICLE_COUNT / HIGH_POINT_EMIT_TIME
	emitter.Enabled = true
	emitter.Parent = anchor

	-- Stop emitting after the burst window; clear the anchor once the last
	-- particle has lived out its max lifetime.
	task.delay(HIGH_POINT_EMIT_TIME, function()
		emitter.Enabled = false
	end)
	Debris:AddItem(anchor, HIGH_POINT_EMIT_TIME + HIGH_POINT_MAX_LIFETIME + 0.2)
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
		local weight = (ball:GetAttribute(Config.Attributes.Weight) :: number?) or 0.5
		applyTransparency(ball, weight)
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
	local localUserId = Players.LocalPlayer.UserId

	local function onBallTagged(ball: BasePart)
		if ball:GetAttribute(Config.Attributes.OwnerUserId) == localUserId then
			BallEffects.AttachValueUI(ball)
			local effectiveValue = GetEffectiveBallValueRF:InvokeServer(ball)
			if effectiveValue then
				BallEffects.SetValueUI(ball, effectiveValue)
			end
		end
	end

	function BallEffects.Init()
		local remote = RS.Remote:WaitForChild("BallEffect") :: RemoteEvent
		remote.OnClientEvent:Connect(function(effect: string, ball: BasePart?, ...: any)
			local fn = (BallEffects :: any)[effect]
			if fn then fn(ball, ...) end
		end)

		-- Attach to our own balls already present, and any that appear later.
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
	end
end

return BallEffects
