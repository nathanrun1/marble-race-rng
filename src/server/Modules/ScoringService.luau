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
local BallEffects = require(RS.Shared.BallEffects)
local ScoreUI = require(RS.Shared.ScoreUI)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local Signal = require(RS.Shared.Signal)

local ScoringService = {}

-- Itemized breakdown of one ball's final payout, built when the ball hits a
-- DestroyTarget and emitted via BallScored. The contribution fields are additive
-- and reconstruct the total:
--   banked == base + heatBonus + comboBonus + additiveBonus + trickle + jackpot
-- Intended for analysis tooling (DevService's launch test) more than gameplay.
export type ScoreInfo = {
	targetName: string,       -- name of the DestroyTarget hit
	finalMultiplier: number?, -- the slot's × multiplier (nil if additive / no PointValue)
	initialValue: number,     -- ball value at spawn (the stake for this ball)
	base: number,             -- ball value at destruction, before heat/combo/additive
	heatBonus: number,        -- signed; accumulated peg heat applied at banking
	comboBonus: number,       -- flat-per-bounce combo payout (0 below MinCombo)
	additiveBonus: number,    -- base-additive upgrade contribution
	trickle: number,          -- unconditional per-launch income
	combo: number,            -- number of scoring bounces credited
	banked: number,           -- total credited to the player
	hotPegs: number,          -- hot peg hits (PegHeat > 0) registered this flight
	coldPegs: number,         -- cold peg hits (PegHeat < 0)
	neutralPegs: number,      -- neutral peg hits (PegHeat == 0)
	jackpot: number,          -- jackpot bonus added to banked (0 if no JackpotTarget hit)
	jackpotHit: boolean,      -- whether a JackpotTarget was hit this flight
}

-- (ball: BasePart, info: ScoreInfo) — fired once when a ball is banked at a
-- DestroyTarget, just before it despawns. The ball reference stays valid as a
-- table key for the duration of the fire.
ScoringService.BallScored = Signal.new()

-- (ball: BasePart, effectiveValue: number) — fired whenever a ball's effective
-- value changes (after each scoring hit). Effective value is the ball's current
-- value plus the combo and heat bonuses it has earned so far (see
-- GetEffectiveValue); it's what the UI shows and what the jackpot gate tests.
ScoringService.EffectiveValueChanged = Signal.new()

local MIN_HEAT_ACCUM = -0.75

-- All per-ball scoring state in one record (replaces the old parallel dicts).
-- Created on spawn, cleared on despawn; every field describes one in-flight ball.
type BallState = {
	-- os.clock() at spawn. Time alive = os.clock() - spawnClock; once it reaches
	-- Config.Scoring.MaxBallLifetime the ball is force-banked at 1× (see onHeartbeat).
	spawnClock: number,
	-- Ball value at spawn (the stake). Reported as ScoreInfo.initialValue.
	spawnValue: number,
	-- hits[target] = os.clock() of last credited hit on that target; per-pair debounce.
	hits: { [Instance]: number },
	-- Running sum of PegHeat over the pegs this ball has hit. Path-dependent and
	-- objective (the heat map is fixed); the player's PegHeat tier only scales how
	-- much it matters, applied once at banking. Kept out of ball value so it never
	-- feeds the (future) jackpot gate.
	heat: number,
	-- Number of scoring hits credited; the combo count. At banking, combo *
	-- flatPerBounce is awarded when it reaches Config.Scoring.MinCombo.
	bounces: number,
	-- Peg hits this flight, split by the peg's PegHeat sign (>0 hot, <0 cold, 0
	-- neutral). Counts registered hit events (post-cooldown), not distinct pegs.
	hotPegs: number,
	coldPegs: number,
	neutralPegs: number,
	-- Set once the ball hits any JackpotTarget; applied as a banked-value multiplier
	-- at banking (see buildScoreInfo). Persists until the ball is banked.
	jackpotHit: boolean,
}
local ballState: { [BasePart]: BallState } = {}

local overlapParams = OverlapParams.new()

-- Returns (newValue, popupLabel, multiplier). multiplier is the × factor when the
-- target is a point multiplier (nil for additive targets), so the caller can gate
-- high-point FX on its magnitude.
local function calculatePoints(cur: number, target: Instance): (number?, string?, number?)
	local pointValue: number? = target:GetAttribute(Config.Attributes.PointValue) :: number?
	if not pointValue then
		return nil, nil, nil
	end

	local isPointMul = target:GetAttribute(Config.Attributes.IsPointMul) :: boolean?
	if isPointMul then
		return cur * pointValue, "×" .. tostring(pointValue), pointValue
	else
		return cur + pointValue, "+" .. tostring(pointValue), nil
	end
end

-- Build the full payout breakdown for a ball at a given base value and slot
-- multiplier, from its current accumulated state (heat, bounces) and the owner's
-- upgrades. Pure: no side effects, so it's reused both live (current value, no
-- slot multiplier — see updateEffectiveValue) and at banking (the final slot).
local function buildScoreInfo(player: Player, ball: BasePart, base: number, multiplier: number?, targetName: string): ScoreInfo
	local state = ballState[ball]
	local upgrades = ProfileService.GetUpgrades(player)

	local jackpotHit = if state then state.jackpotHit else false
	local jackpot = if jackpotHit then base * Config.Scoring.JackpotMultiplier else 0
	base += jackpot

	local H: number = math.max(if state then state.heat else 0, MIN_HEAT_ACCUM)
	local heatPayout: number = base * math.max(0, 1 + H)
	local heatEffect: number = heatPayout - base

	local combo = if state then state.bounces else 0
	local comboBonus = 0
	if combo >= Config.Scoring.MinCombo then
		comboBonus = combo * ProfileStats.GetFlatPerBounce(upgrades)
	end
	local banked = heatPayout + comboBonus

	local baseAdditive = ProfileStats.GetBaseAdditive(upgrades) * banked
	banked += baseAdditive
	local trickle = ProfileStats.GetTrickle(upgrades)
	banked += trickle

	return {
		targetName = targetName,
		finalMultiplier = multiplier,
		initialValue = if state then state.spawnValue else base,
		base = base,
		heatBonus = heatEffect,
		comboBonus = comboBonus,
		additiveBonus = baseAdditive,
		trickle = trickle,
		combo = combo,
		banked = banked,
		hotPegs = if state then state.hotPegs else 0,
		coldPegs = if state then state.coldPegs else 0,
		neutralPegs = if state then state.neutralPegs else 0,
		jackpot = jackpot,
		jackpotHit = jackpotHit,
	}
end

-- The value a ball "feels" worth in flight
function ScoringService.GetEffectiveValue(info: ScoreInfo): number
	return info.base + info.heatBonus
end

-- Compute a ball's final payout from its accumulated state, emit the ScoreInfo,
-- post the player-facing breakdown, then despawn the ball and credit the bank.
-- Shared by the DestroyTarget hit and the stuck-timeout path; they differ only in
-- `base`/`multiplier` (the slot's, or current-value/1× for a stuck ball), the
-- targetName, and the headline label.
local function bankBall(player: Player, ball: BasePart, base: number, multiplier: number?, targetName: string, stuck: boolean)
	local info = buildScoreInfo(player, ball, base, multiplier, targetName)
	local heatEffect = info.heatBonus
	local comboBonus = info.comboBonus
	local baseAdditive = info.additiveBonus
	local combo = info.combo
	local banked = info.banked

	ScoringService.BallScored:Fire(ball, info)

	ScoreUI.PostMessage(player, (if stuck then "Ball stuck: $" else "Ball scored! $") .. math.floor(base), Color3.new(1, 1, 1))
	if math.abs(heatEffect) >= 0.5 then
		if heatEffect > 0 then
			ScoreUI.PostMessage(player, string.format("Heat Bonus! +$%d", math.floor(heatEffect)), Color3.fromRGB(255, 140, 0))
		else
			ScoreUI.PostMessage(player, string.format("Cold Penalty: -$%d", math.floor(math.abs(heatEffect))), Color3.fromRGB(80, 160, 255))
		end
	end
	if comboBonus > 0 then
		ScoreUI.PostMessage(player, "Combo! +$" .. math.floor(comboBonus) .. " ("..combo..")", Color3.fromRGB(255, 60, 60))
	end
	if baseAdditive > 0 then
		ScoreUI.PostMessage(player, "Additive Bonus! +$" .. math.floor(baseAdditive), Color3.fromRGB(98, 37, 209))
	end
	if info.jackpotHit then
		ScoreUI.PostMessage(player, "JACKPOT! $" .. math.floor(info.jackpot), Color3.fromRGB(255, 105, 180))
	end

	BallService.Despawn(ball)
	CurrencyService.AddPoints(player, banked, if stuck then "Ball stuck (timeout): " .. ball.Name else "Ball destroyed at target: " .. targetName)
end

-- Recompute a still-in-flight ball's effective value from its current state and
-- broadcast it: refreshes the on-ball UI and notifies CollisionService (jackpot
-- gate). Called after every scoring hit that doesn't despawn the ball.
local function updateEffectiveValue(player: Player, ball: BasePart)
	local info = buildScoreInfo(player, ball, BallService.GetBallValue(ball), nil, "")
	local effective = ScoringService.GetEffectiveValue(info)
	-- The value billboard is a client-side smooth-follow (see BallEffects.AttachValueUI),
	-- so update it on the owner's client rather than server-side.
	BallEffects.DoClientEffect(player, "SetValueUI", ball, math.floor(effective))
	ScoringService.EffectiveValueChanged:Fire(ball, effective)
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
	local newValue, popupLabel, multiplier = calculatePoints(curValue, target)
	if newValue and popupLabel then
		BallService.SetBallValue(ball, newValue)
		-- UI is refreshed below via updateEffectiveValue (effective value, not raw).
		BallEffects.DoClientEffect(player, "ShowValuePopup", ball, ball.CFrame, popupLabel)
		-- High-point hit: a big enough multiplier earns the special FX (runs on
		-- the server; the emitter replicates to all clients).
		if multiplier and multiplier >= Config.Scoring.SpecialFXMinMultiplier then
			BallEffects.ShowHighPointFX(ball)
		end
	end

	local state = ballState[ball]

	if target:HasTag(Config.Tags.BounceTarget) and state then
		state.bounces += 1
		local flatRate = ProfileStats.GetFlatPerBounce(ProfileService.GetUpgrades(player))
		if flatRate > 0 then
			BallEffects.DoClientEffect(player, "ShowComboPopup", ball, ball.CFrame, state.bounces)
		end
	end

	-- Peg heat: accumulate this peg's signed heat onto the ball. Always recorded
	-- (the heat map is objective); the player's tier scales the effect at banking.
	local pegHeat: number? = target:GetAttribute(Config.Attributes.PegHeat)
	if pegHeat and state then
		if pegHeat > 0 then
			state.hotPegs += 1
		elseif pegHeat < 0 then
			state.coldPegs += 1
		else
			state.neutralPegs += 1
		end
		local heatFactor: number = ProfileStats.GetPegHeatFactor(ProfileService.GetUpgrades(player))
		local heatDelta = pegHeat * heatFactor
		state.heat = math.max(state.heat + heatDelta, 0)
		if heatFactor ~= 0 then
			BallEffects.ApplyHeat(ball, state.heat / heatFactor)  -- Normalize by heat factor for cosmetic
		end
		BallEffects.DoClientEffect(player, "ShowHeatPopup", ball, heatDelta)
	end

	-- Jackpot: mark the ball; the bonus is applied to its banked value at banking.
	-- Persists if this isn't also the destroy target.
	if target:HasTag(Config.Tags.JackpotTarget) and state then
		state.jackpotHit = true
	end

	if target:HasTag(Config.Tags.DestroyTarget) then
		bankBall(player, ball, newValue or curValue, multiplier, target.Name, false)
		return
	end

	-- Ball still alive: refresh its effective value (value + combo + heat) for the
	-- on-ball UI and the jackpot gate.
	updateEffectiveValue(player, ball)
end

local function canRegisterHit(ball: BasePart, target: Instance): boolean
	local state = ballState[ball]
	if not state then
		return false -- ball not registered
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
	local targets: {Instance} = CollectionService:GetTagged(Config.Tags.ScoreTarget)
	overlapParams.IncludeInstances = targets
end

-- Force-bank a ball that has outlived MaxBallLifetime (wedged on geometry) at 1×,
-- so it never lives forever. If the owner has left, just despawn it.
local function despawnStuck(ball: BasePart)
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
	local player = if ownerId then Players:GetPlayerByUserId(ownerId) else nil
	if player then
		bankBall(player, ball, BallService.GetBallValue(ball), 1, ball.Name, true)
	else
		BallService.Despawn(ball)
	end
end

local function onHeartbeat()
	local now = os.clock()
	for ball in BallService.GetActiveBalls() do
		local state = ballState[ball]
		if state and (now - state.spawnClock) >= Config.Scoring.MaxBallLifetime then
			despawnStuck(ball)
			continue
		end
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
	ballState[ball] = {
		spawnClock = os.clock(),
		spawnValue = BallService.GetBallValue(ball),
		hits = {},
		heat = 0,
		bounces = 0,
		hotPegs = 0,
		coldPegs = 0,
		neutralPegs = 0,
		jackpotHit = false,
	}
	-- The value billboard is a client-side smooth-follow attached by the owner's
	-- client off the Ball tag (see BallEffects). Push the initial value once the ball
	-- has replicated (deferred a frame so the ball arg isn't nil on the client).
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
	local player = if ownerId then Players:GetPlayerByUserId(ownerId) else nil
	if player then
		task.spawn(function()
			task.wait()
			if not BallService.IsBallActive(ball) then return end -- despawned within the frame
			BallEffects.DoClientEffect(player, "SetValueUI", ball, BallService.GetBallValue(ball))
		end)
	end
end

local function onBallDespawn(ball: BasePart)
	ballState[ball] = nil
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