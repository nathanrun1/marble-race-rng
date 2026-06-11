--!strict
-- Sole authority over ball existence. Nothing else constructs or destroys a
-- ball. The "Ball" tag is the seam other systems (ScoringService) watch; the
-- return value is for the caller that needs the reference directly.
--
-- Server owns ball physics (SetNetworkOwner(nil)), per the shared-ramp,
-- anti-cheat decision. This makes concurrent ball count the CPU ceiling, which
-- is why Spawn is written to be poolable later without changing its callers.

local CollectionService = game:GetService("CollectionService")
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local Signal = require(RS.Shared.Signal)

local Config = require(SSS.Modules.Config)

local BallService = {}

-- (ball: BasePart), fired when ball is spawned
BallService.BallSpawned = Signal.new()
-- (ball: BasePart), fired when ball is despawned
BallService.BallDespawned = Signal.new()

local liveBalls: { [BasePart]: true } = {}    -- ballInstance: true
local ballValue: { [BasePart]: number } = {} -- ballInstance: value
local ownerCounts: { [number]: number } = {}

export type SpawnOptions = {
	ownerUserId: number?,  -- credited by ScoringService; nil = unowned/no score
	velocity: Vector3?,    -- initial velocity; nil = drop from rest
	initialValue: number?, -- initial ball value
}

function BallService.Spawn(position: Vector3, options: SpawnOptions?): BasePart
	local opts: SpawnOptions = options or {}
	
	local ball = Config.Templates.Ball:Clone()
	ball.CFrame = CFrame.new(position)
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
	ballValue[ball] = opts.initialValue or 0
	ball:AddTag(Config.Tags.Ball)
	
	BallService.BallSpawned:Fire(ball)
	
	return ball
end

function BallService.Despawn(ball: BasePart)
	if not liveBalls[ball] then
		return -- already gone; idempotent, prevents double-free
	end
	liveBalls[ball] = nil
	ballValue[ball] = nil
	
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId)
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

function BallService.GetLiveCount(userId: number): number
	return ownerCounts[userId] or 0
end

function BallService.GetActiveBalls(): { [BasePart]: true }
	return liveBalls
end

function BallService.IsBallActive(ball: BasePart): boolean
	return liveBalls[ball] ~= nil
end

function BallService.GetBallValue(ball: BasePart): number
	if (not liveBalls[ball]) then
		warn("BasePart is not a valid ball!: "..ball.Name)
		return 0
	end
	return ballValue[ball]
end

function BallService.SetBallValue(ball: BasePart, value: number): number
	if (not liveBalls[ball]) then
		warn("BasePart is not a valid ball!: "..ball.Name)
		return 0
	end
	ballValue[ball] = value
	return value
end

function BallService.Init()
end

return BallService