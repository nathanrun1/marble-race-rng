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

local ScoringService = {}

local MIN_HEAT_ACCUM = -0.75

-- hitRecord[ball][target] = os.clock() of last credited hit; per-pair debounce.
local hitRecord: { [BasePart]: { [Instance]: number } } = {}

-- heatAccum[ball] = running sum of PegHeat over the pegs this ball has hit.
-- Path-dependent and objective (the heat map is fixed); the player's PegHeat
-- tier only scales how much it matters, applied once at banking. Kept separate
-- from ball value so it never feeds the (future) jackpot gate.
local heatAccum: { [BasePart]: number } = {}

-- bounceCount[ball] = number of scoring hits this ball has credited. Used for
-- the combo system: at banking, combo * flatPerBounce is awarded when count >=
-- Config.Scoring.MinCombo.
local bounceCount: { [BasePart]: number } = {}

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
		BallEffects.SetValueUI(ball, newValue)
		BallEffects.DoClientEffect(player, "ShowValuePopup", ball, ball.CFrame, popupLabel)
		-- High-point hit: a big enough multiplier earns the special FX (runs on
		-- the server; the emitter replicates to all clients).
		if multiplier and multiplier >= Config.Scoring.SpecialFXMinMultiplier then
			BallEffects.ShowHighPointFX(ball)
		end
	end

	if target:HasTag(Config.Tags.BounceTarget) then
		bounceCount[ball] = (bounceCount[ball] or 0) + 1
		local combo = bounceCount[ball]
		local flatRate = ProfileStats.GetFlatPerBounce(ProfileService.GetUpgrades(player))
		if flatRate > 0 then
			BallEffects.DoClientEffect(player, "ShowComboPopup", ball, ball.CFrame, combo)
		end
	end

	-- Peg heat: accumulate this peg's signed heat onto the ball. Always recorded
	-- (the heat map is objective); the player's tier scales the effect at banking.
	local pegHeat: number? = target:GetAttribute(Config.Attributes.PegHeat)
	if pegHeat then
		local heatFactor: number = ProfileStats.GetPegHeatFactor(ProfileService.GetUpgrades(player))
		local heatDelta = pegHeat * heatFactor
		heatAccum[ball] = math.max((heatAccum[ball] or 0) + heatDelta, 0)
		if heatFactor ~= 0 then
			BallEffects.ApplyHeat(ball, heatAccum[ball] / heatFactor)  -- Normalize by heat factor for cosmetic
		end
		BallEffects.DoClientEffect(player, "ShowHeatPopup", ball, heatDelta)
	end

	if target:HasTag(Config.Tags.DestroyTarget) then
		-- Read state BEFORE Despawn clears heatAccum/bounceCount.
		local upgrades = ProfileService.GetUpgrades(player)
		local base: number = newValue or curValue
		local H: number = math.max(heatAccum[ball] or 0, MIN_HEAT_ACCUM)
		local heatPayout: number = base * math.max(0, 1 + H)
		local heatEffect: number = heatPayout - base

		local combo = bounceCount[ball] or 0
		local comboBonus = 0
		if combo >= Config.Scoring.MinCombo then
			comboBonus = combo * ProfileStats.GetFlatPerBounce(upgrades)
		end
		local banked = heatPayout + comboBonus

		local baseAdditive = ProfileStats.GetBaseAdditive(upgrades) * banked
		banked += baseAdditive
		banked += ProfileStats.GetTrickle(upgrades)

		ScoreUI.PostMessage(player, "Ball scored! $" .. math.floor(base), Color3.new(1, 1, 1))
		if math.abs(heatEffect) >= 0.5 then
			if heatEffect > 0 then
				ScoreUI.PostMessage(player,
					string.format("Heat Bonus! %s$%d", if heatEffect >= 0 then "+" else "-", math.floor(math.abs(heatEffect))),
					Color3.fromRGB(255, 140, 0))
			else
				ScoreUI.PostMessage(player,
					string.format("Cold Penalty: %s$%d", if heatEffect >= 0 then "+" else "-", math.floor(math.abs(heatEffect))),
					Color3.fromRGB(80, 160, 255))
			end
		end
		if comboBonus > 0 then
			ScoreUI.PostMessage(player, "Combo! +$" .. math.floor(comboBonus) .. " ("..combo..")", Color3.fromRGB(255, 60, 60))
		end
		if baseAdditive > 0 then
			ScoreUI.PostMessage(player, "Additive Bonus! +$" .. math.floor(baseAdditive), Color3.fromRGB(98, 37, 209))
		end

		BallService.Despawn(ball)
		CurrencyService.AddPoints(player, banked, "Ball destroyed at target: " .. target.Name)
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
	bounceCount[ball] = 0
end

local function onBallDespawn(ball: BasePart)
	hitRecord[ball] = nil
	heatAccum[ball] = nil
	bounceCount[ball] = nil
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