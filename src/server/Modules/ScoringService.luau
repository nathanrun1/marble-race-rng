--!strict
-- Server-authoritative hit detection. Owns the per-ball state map and drives the
-- collision loop (overlap query, hit debounce, stuck timeout, spawn/despawn).
-- Scoring math and payout live in ScoreHandler.
--
-- Targets: tag "ScoreTarget", Attribute PointValue, optional Cooldown.
-- Balls:   tag "Ball", Attribute OwnerUserId, set at spawn by BallService.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)
local BallService = require(SSS.Scripts.Modules.BallService)
local BallEffects = require(RS.Shared.BallEffects)
local ScoreHandler = require(SSS.Scripts.Modules.ScoreHandler)

local ScoringService = {}

-- Public surface lives on ScoreHandler; re-exposed here for existing consumers.
export type ScoreInfo = ScoreHandler.ScoreInfo
ScoringService.BallScored = ScoreHandler.BallScored
ScoringService.EffectiveValueChanged = ScoreHandler.EffectiveValueChanged
local GetEffectiveValueRF = RS.Remote.GetEffectiveBallValue

local ballState: { [BasePart]: ScoreHandler.BallState } = {}
local effectiveValue: { [BasePart]: number } = {}
local overlapParams = OverlapParams.new()

-- Per-pair debounce: a target re-scores a ball only after its Cooldown elapses.
local function canRegisterHit(ball: BasePart, target: Instance): boolean
	local state = ballState[ball]
	if not state then
		return false
	end
	local cooldown = (target:GetAttribute(Config.Attributes.Cooldown) :: number?) or Config.Scoring.DefaultCooldown
	local now = os.clock()
	local last = state.hits[target]
	if last and (now - last) < cooldown then
		return false
	end
	state.hits[target] = now
	return true
end

local function refreshTargetFilter()
	overlapParams.IncludeInstances = CollectionService:GetTagged(Config.Tags.ScoreTarget)
end

-- A ball that outlived MaxBallLifetime (wedged on geometry) is force-banked at 1×;
-- if its owner has left, just despawn it.
local function despawnStuck(ball: BasePart)
	local state = ballState[ball]
	local player = if state.ownerUserId then Players:GetPlayerByUserId(state.ownerUserId) else nil
	if player then
		ScoreHandler.BankBall(player, ball, state, state.value, 1, ball.Name, true)
	else
		BallService.Despawn(ball)
	end
end

local function onHeartbeat()
	local now = os.clock()
	for ball in BallService.GetActiveBalls() do
		local state = ballState[ball]
		if not state then
			continue
		end
		if (now - state.spawnClock) >= Config.Scoring.MaxBallLifetime then
			despawnStuck(ball)
			continue
		end
		for _, target in workspace:GetPartsInPart(ball, overlapParams) do
			if not BallService.IsBallActive(ball) then
				break
			end
			if canRegisterHit(ball, target) then
				ScoreHandler.ResolveHit(ball, target, state)
			end
		end
	end
end

local function onBallSpawn(ball: BasePart, ballInfo: BallService.BallInfo)
	local initial = ballInfo.initialValue or 0
	ballState[ball] = {
		value = initial,
		ownerUserId = ballInfo.ownerUserId,
		spawnClock = os.clock(),
		spawnValue = initial,
		hits = {},
		heat = 0,
		bounces = 0,
		hotPegs = 0,
		coldPegs = 0,
		neutralPegs = 0,
		jackpotHit = false,
	}
	effectiveValue[ball] = initial
	-- The value billboard is a client-side smooth-follow; push the initial value once
	-- the ball has replicated (deferred a frame so the ball arg isn't nil client-side).
	local player = if ballInfo.ownerUserId then Players:GetPlayerByUserId(ballInfo.ownerUserId) else nil
	if player then
		task.spawn(function()
			task.wait()
			if not BallService.IsBallActive(ball) then
				return
			end
			BallEffects.DoClientEffect(player, "SetValueUI", ball, initial)
		end)
	end
end

local function onBallDespawn(ball: BasePart)
	ballState[ball] = nil
	effectiveValue[ball] = nil
end

function ScoringService.GetEffectiveBallValue(player: Player, ball: BasePart): number?
	return effectiveValue[ball]
end

-- Open a no-score window of `seconds` for the player. Called by PrestigeService
-- before the reset so balls in flight during the transition can't bank. The window
-- is enforced at banking time in ScoreHandler (the ball still plays out normally,
-- it just gets destroyed instead of banked at a DestroyTarget).
function ScoringService.BeginNoScore(userId: number, seconds: number)
	ScoreHandler.BeginNoScore(userId, seconds)
end

-- Strip ownership from any tracked ball state owned by userId so those in-flight
-- balls stop crediting the player (paired with BallService.RemoveOwnership).
function ScoringService.ClearOwner(userId: number)
	for _, state in ballState do
		if state.ownerUserId == userId then
			state.ownerUserId = nil
		end
	end
end

function ScoringService.Init()
	BallService.BallSpawned:Connect(onBallSpawn)
	BallService.BallDespawned:Connect(onBallDespawn)

	CollectionService:GetInstanceAddedSignal(Config.Tags.ScoreTarget):Connect(refreshTargetFilter)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.ScoreTarget):Connect(refreshTargetFilter)
	refreshTargetFilter()

	RunService.Heartbeat:Connect(onHeartbeat)

	ScoreHandler.EffectiveValueChanged:Connect(function(ball: BasePart, effective: number) 
		effectiveValue[ball] = effective
	end)
	GetEffectiveValueRF.OnServerInvoke = ScoringService.GetEffectiveBallValue
end

return ScoringService
