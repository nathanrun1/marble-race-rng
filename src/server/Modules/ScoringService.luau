--!strict
-- Server-authoritative hit detection & scoring
--
-- Data contract:
--   Targets: CollectionService tag "ScoreTarget", Attributes PointValue:number,
--            optional Cooldown:number.
--   Balls:   tag "Ball", Attribute OwnerUserId:number, set at spawn by BallService.
--            (If a ball is a Model, tag and read position from its PrimaryPart.)

local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(SSS.Modules.Config)
local CurrencyService = require(SSS.Modules.CurrencyService)
local BallService = require(SSS.Modules.BallService)
local BallEffects = require(SSS.Modules.BallEffects)

local ScoringService = {}

-- hitRecord[ball][target] = os.clock() of last credited hit; per-pair debounce.
local hitRecord: { [BasePart]: { [Instance]: number } } = {}

local overlapParams = OverlapParams.new()

local function calculatePoints(cur: number, target: Instance): number?
	local pointValue: number? = target:GetAttribute(Config.Attributes.PointValue)
	if not pointValue then
		return nil
	end
	
	local isPointMul: boolean? = target:GetAttribute(Config.Attributes.IsPointMul)
	if isPointMul ~= nil and isPointMul then
		return cur * pointValue
	else
		return cur + pointValue
	end
end

local function resolveHit(ball: BasePart, target: Instance)
	print("resolving hit")
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
	if not ownerId then
		return
	end
	local player = Players:GetPlayerByUserId(ownerId)
	if not player then
		return -- owner left mid-flight; points dropped.
	end
	local curValue: number = BallService.GetBallValue(ball)
	local newValue: number? = calculatePoints(curValue, target)
	if (newValue) then
		BallService.SetBallValue(ball, newValue)
		BallEffects.SetValueUI(ball, newValue)
	end
	
	if (target:HasTag(Config.Tags.DestroyTarget)) then
		print("Destroying ball")
		BallService.Despawn(ball)
		CurrencyService.AddPoints(player, newValue or curValue, "Ball destroyed at target: "..target.Name)
	end
end

local function canRegisterHit(ball: BasePart, target: Instance): boolean
	local record = hitRecord[ball]
	if not record then
		return false -- ball not registered
	end
	local cooldown = (target:GetAttribute(Config.Attributes.Cooldown) :: number?) or Config.Scoring.DefaultCooldown
	local now = os.clock()
	local last = record[target]
	if last and (now - last) < cooldown then
		return false
	end
	record[target] = now
	return true
end

local function refreshTargetFilter()
	local targets: {Instance} = CollectionService:GetTagged(Config.Tags.ScoreTarget)
	overlapParams.IncludeInstances = targets
end

local function onHeartbeat()
	for ball in BallService.GetActiveBalls() do
		for _, target in workspace:GetPartsInPart(ball, overlapParams) do
			if not BallService.IsBallActive(ball) then
				break
			end
			if canRegisterHit(ball, target) then
				resolveHit(ball, target)
			end
		end
	end
end

local function onBallSpawn(ball: BasePart)
	BallEffects.SetValueUI(ball, BallService.GetBallValue(ball))
	hitRecord[ball] = {}
end

local function onBallDespawn(ball: BasePart)
	hitRecord[ball] = nil
end

function ScoringService.Init()
	BallService.BallSpawned:Connect(onBallSpawn)
	BallService.BallDespawned:Connect(onBallDespawn)
	
	CollectionService:GetInstanceAddedSignal(Config.Tags.ScoreTarget):Connect(refreshTargetFilter)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.ScoreTarget):Connect(refreshTargetFilter)
	RunService.Heartbeat:Connect(onHeartbeat)
end

return ScoringService