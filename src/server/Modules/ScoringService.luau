--!strict
-- Server-authoritative hit detection & scoring
--
-- Data contract:
--   Targets: CollectionService tag "ScoreTarget", Attributes PointValue:number,
--            optional Cooldown:number.
--   Balls:   tag "Ball", Attribute OwnerUserId:number, set at spawn by BallService.
--            (If a ball is a Model, tag and read position from its PrimaryPart.)

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local BallService = require(SSS.Scripts.Modules.BallService)
local BallEffects = require(SSS.Scripts.Modules.BallEffects)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)

local ScoringService = {}

-- hitRecord[ball][target] = os.clock() of last credited hit; per-pair debounce.
local hitRecord: { [BasePart]: { [Instance]: number } } = {}

-- heatAccum[ball] = running sum of PegHeat over the pegs this ball has hit.
-- Path-dependent and objective (the heat map is fixed); the player's PegHeat
-- tier only scales how much it matters, applied once at banking. Kept separate
-- from ball value so it never feeds the (future) jackpot gate.
local heatAccum: { [BasePart]: number } = {}

local overlapParams = OverlapParams.new()

local function calculatePoints(cur: number, target: Instance): (number?, string?)
	local pointValue: number? = target:GetAttribute(Config.Attributes.PointValue) :: number?
	if not pointValue then
		return nil, nil
	end

	local isPointMul = target:GetAttribute(Config.Attributes.IsPointMul) :: boolean?
	if isPointMul then
		return cur * pointValue, "×" .. tostring(pointValue)
	else
		return cur + pointValue, "+" .. tostring(pointValue)
	end
end

local function resolveHit(ball: BasePart, target: Instance)
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
	if not ownerId then
		return
	end
	local player = Players:GetPlayerByUserId(ownerId)
	if not player then
		return -- owner left mid-flight; points dropped.
	end
	local curValue: number = BallService.GetBallValue(ball)
	local newValue, popupLabel = calculatePoints(curValue, target)
	if newValue and popupLabel then
		BallService.SetBallValue(ball, newValue)
		BallEffects.SetValueUI(ball, newValue)
		BallEffects.ShowValuePopup(ball, popupLabel)
	end

	-- Peg heat: accumulate this peg's signed heat onto the ball. Always recorded
	-- (the heat map is objective); the player's tier scales the effect at banking.
	local pegHeat: number? = target:GetAttribute(Config.Attributes.PegHeat)
	if pegHeat then
		local heatFactor: number = ProfileStats.GetPegHeatFactor(ProfileService.GetUpgrades(player))
		local heatDelta = pegHeat * heatFactor
		heatAccum[ball] = (heatAccum[ball] or 0) + heatDelta
		BallEffects.ApplyHeat(ball, heatAccum[ball])
		BallEffects.ShowHeatPopup(ball, heatDelta)
	end

	if (target:HasTag(Config.Tags.DestroyTarget)) then
		-- Apply accumulated heat as a value-proportional multiplier on the final
		-- payout, scaled by the player's PegHeat tier. Read H BEFORE Despawn,
		-- which clears heatAccum via onBallDespawn. Clamp ≥ 0 so a cold path
		-- can zero the payout but never go negative.
		local base: number = newValue or curValue
		local H: number = heatAccum[ball] or 0
		local banked: number = base * math.max(0, 1 + H)

		BallService.Despawn(ball)
		CurrencyService.AddPoints(player, banked, "Ball destroyed at target: "..target.Name)
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
	heatAccum[ball] = 0
end

local function onBallDespawn(ball: BasePart)
	hitRecord[ball] = nil
	heatAccum[ball] = nil
end

function ScoringService.Init()
	BallService.BallSpawned:Connect(onBallSpawn)
	BallService.BallDespawned:Connect(onBallDespawn)
	
	CollectionService:GetInstanceAddedSignal(Config.Tags.ScoreTarget):Connect(refreshTargetFilter)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.ScoreTarget):Connect(refreshTargetFilter)
	refreshTargetFilter() -- snapshot targets already tagged at startup

	RunService.Heartbeat:Connect(onHeartbeat)
end

return ScoringService