--!strict
-- Manages ball appearance (cosmetic skins): a skin's base colour plus its single
-- ParticleEmitter. Applied to each ball on spawn from its owner's equipped skin.
--
-- Gameplay feedback (heat colour/material, value UI, popups) stays in BallEffects;
-- this owns only the cosmetic layer. A skin's colour becomes the ball's base colour
-- (via BallEffects.SetBaseColor), which BallEffects then brightens with heat.
--
-- Skeleton: equipped skins are in-memory and default for everyone. A later pass can
-- source them from the profile / a cosmetics inventory and add a purchase/equip flow.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local BallSkins = require(RS.Shared.BallSkins)
local BallEffects = require(RS.Shared.BallEffects)
local BallService = require(SSS.Scripts.Modules.BallService)

local CosmeticService = {}

local SKIN_EMITTER_NAME = "SkinParticles"
local DEFAULT_SKIN = BallSkins.GetDefaultId()

-- userId -> equipped skin id (in-memory for now)
local equipped: { [number]: string } = {}

-- Build/refresh the skin's single ParticleEmitter on the ball (or remove it when the
-- skin has none). Nil fields fall back to sensible defaults.
local function applyParticle(ball: BasePart, particle: BallSkins.ParticleData?)
	local existing = ball:FindFirstChild(SKIN_EMITTER_NAME) :: ParticleEmitter?
	if not particle then
		if existing then
			existing:Destroy()
		end
		return
	end
	local emitter = existing or Instance.new("ParticleEmitter")
	emitter.Name = SKIN_EMITTER_NAME
	emitter.Color = particle.color or ColorSequence.new(Color3.new(1, 1, 1))
	if particle.texture then
		emitter.Texture = particle.texture
	end
	emitter.Rate = particle.rate or 20
	emitter.Lifetime = particle.lifetime or NumberRange.new(0.5, 1)
	emitter.Speed = particle.speed or NumberRange.new(1, 2)
	emitter.Size = particle.size or NumberSequence.new(0.3, 0)
	emitter.Transparency = particle.transparency or NumberSequence.new(0.2, 1)
	emitter.SpreadAngle = particle.spreadAngle or Vector2.new(0, 0)
	emitter.LightEmission = particle.lightEmission or 0
	if particle.rotation then
		emitter.Rotation = particle.rotation
	end
	if particle.rotSpeed then
		emitter.RotSpeed = particle.rotSpeed
	end
	emitter.Parent = ball
end

-- Paint a ball with the given skin (falls back to default for an unknown id).
function CosmeticService.ApplySkin(ball: BasePart, skinId: string)
	local skin = BallSkins.Get(skinId) or BallSkins.Get(DEFAULT_SKIN)
	if not skin then
		return
	end
	BallEffects.SetBaseColor(ball, skin.data.color)
	applyParticle(ball, skin.data.particle)
end

function CosmeticService.GetEquipped(player: Player): string
	return equipped[player.UserId] or DEFAULT_SKIN
end

function CosmeticService.SetEquipped(player: Player, skinId: string): boolean
	if not BallSkins.Get(skinId) then
		return false
	end
	equipped[player.UserId] = skinId
	return true
end

local function onBallSpawn(ball: BasePart, ballInfo: BallService.BallInfo)
	local skinId = if ballInfo.ownerUserId then (equipped[ballInfo.ownerUserId] or DEFAULT_SKIN) else DEFAULT_SKIN
	CosmeticService.ApplySkin(ball, skinId)
end

function CosmeticService.Init()
	-- After BallEffects' own BallSpawned paint, so our skin colour overrides the
	-- default base colour (connection order = Init order in Services bootstrap).
	BallService.BallSpawned:Connect(onBallSpawn)
	Players.PlayerRemoving:Connect(function(player: Player)
		equipped[player.UserId] = nil
	end)
end

return CosmeticService
