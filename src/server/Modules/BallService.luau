--!strict
-- Sole authority over ball existence. Nothing else constructs or destroys a
-- ball. The "Ball" tag is the seam other systems (ScoringService) watch; the
-- return value is for the caller that needs the reference directly.
--
-- Server owns ball physics (SetNetworkOwner(nil)), per the shared-ramp,
-- anti-cheat decision. This makes concurrent ball count the CPU ceiling, which
-- is why Spawn is written to be poolable later without changing its callers.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local Signal = require(RS.Shared.Signal)

local Config = require(RS.Shared.Config)

local BallService = {}

-- (ball: BasePart, ballInfo: BallInfo), fired when ball is spawned
BallService.BallSpawned = Signal.new()
-- (ball: BasePart), fired when ball is despawned
BallService.BallDespawned = Signal.new()

local liveBalls: { [BasePart]: true } = {}    -- ballInstance: true
local ownerCounts: { [number]: number } = {}

-- Weight slider (0 light .. 1 heavy) → physics. Heavy = denser and less elastic
-- (fewer, deader bounces); light = less dense and bouncier. Linear map between
-- these endpoints; tune to taste. Friction held constant for now.
local LIGHT_DENSITY, HEAVY_DENSITY = 5, 11
local LIGHT_ELASTICITY, HEAVY_ELASTICITY = 0.8, 0.15
local BALL_FRICTION = 0.6

export type SpawnOptions = {
	ownerUserId: number?,  -- nil = unowned/no score
	velocity: Vector3?,    -- initial velocity; nil = drop from rest
	initialValue: number?, -- initial ball value
	weight: number?,       -- 0 (light) .. 1 (heavy); sets density/elasticity
	size: number?,         -- scale factor applied to the prefab's base size
	skinId: string?,       -- which equipped-loadout skin this ball is; nil = caller has no
	                       -- opinion (CosmeticService falls back to the player's single
	                       -- VISUAL equipped skin)
}

export type BallInfo = {
	ownerUserId: number?,
	initialValue: number?,
	skinId: string?,
}

function BallService.Spawn(position: Vector3, options: SpawnOptions?): BasePart
	local opts: SpawnOptions = options or {}
	
	local ball = Config.Templates.Ball:Clone()
	ball.CFrame = CFrame.new(position)

	-- Size: scale the prefab's base size before it enters the world.
	if opts.size then
		ball.Size = ball.Size * opts.size
		ball:SetAttribute(Config.Attributes.Size, opts.size)
	end

	-- Weight: map the slider to density/elasticity (see endpoints above).
	if opts.weight then
		local w = math.clamp(opts.weight, 0, 1)
		local density = LIGHT_DENSITY + (HEAVY_DENSITY - LIGHT_DENSITY) * w
		local elasticity = LIGHT_ELASTICITY + (HEAVY_ELASTICITY - LIGHT_ELASTICITY) * w
		ball.CustomPhysicalProperties = PhysicalProperties.new(density, BALL_FRICTION, elasticity)
		ball:SetAttribute(Config.Attributes.Weight, w)
	end

	ball.Parent = game.Workspace

	if not ball.Anchored then
		ball:SetNetworkOwner(nil)
	end

	ball.AssemblyLinearVelocity = opts.velocity or ball.AssemblyLinearVelocity

	if (opts.ownerUserId) then
		ball:SetAttribute(Config.Attributes.OwnerUserId, opts.ownerUserId)
		ownerCounts[opts.ownerUserId] = (ownerCounts[opts.ownerUserId] or 0) + 1
	end
	
	liveBalls[ball] = true
	ball:AddTag(Config.Tags.Ball)

	local ballInfo: BallInfo = {
		ownerUserId = opts.ownerUserId,
		initialValue = opts.initialValue,
		skinId = opts.skinId,
	}
	
	BallService.BallSpawned:Fire(ball, ballInfo)
	
	return ball
end

function BallService.Despawn(ball: BasePart)
	if not liveBalls[ball] then
		return -- already gone; idempotent, prevents double-free
	end
	liveBalls[ball] = nil
	
	local ownerId: number = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number
	if ownerId then
		ownerCounts[ownerId] = math.max(ownerCounts[ownerId] - 1, 0)
	end		
	
	BallService.BallDespawned:Fire(ball)
	ball:Destroy()
end

function BallService.DespawnAll()
	for ball in liveBalls do
		BallService.Despawn(ball)
	end
end

-- Strip ownership from every live ball owned by userId: clears the OwnerUserId
-- attribute and zeroes the owner count, without despawning. Used by prestige so
-- balls already in flight can no longer bank into the (now-reset) account.
function BallService.RemoveOwnership(userId: number)
	for ball in liveBalls do
		if ball:GetAttribute(Config.Attributes.OwnerUserId) == userId then
			ball:SetAttribute(Config.Attributes.OwnerUserId, nil)
		end
	end
	ownerCounts[userId] = nil
end

function BallService.GetLiveCount(userId: number): number
	return ownerCounts[userId] or 0
end

function BallService.GetActiveBalls(): { [BasePart]: true }
	return liveBalls
end

function BallService.IsBallActive(ball: BasePart): boolean
	return liveBalls[ball] ~= nil
end

-- Clamp every live ball's speed to Config.Ball.MaxSpeed. Balls are server-owned
-- (SetNetworkOwner(nil)), so the server can cap their velocity each frame: after a
-- physics step we rescale any assembly moving faster than the cap back down to it,
-- bounding the next step's starting speed.
local function clampSpeeds()
	local maxSpeed = Config.Ball.MaxSpeed
	if maxSpeed <= 0 then
		return
	end
	local maxSq = maxSpeed * maxSpeed
	for ball in liveBalls do
		local v = ball.AssemblyLinearVelocity
		if v.X * v.X + v.Y * v.Y + v.Z * v.Z > maxSq then
			ball.AssemblyLinearVelocity = v.Unit * maxSpeed
		end
	end
end

function BallService.Init()
	RunService.Heartbeat:Connect(clampSpeeds)
end

return BallService