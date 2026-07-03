--!strict
-- Pure scoring math: hit resolution, payout breakdown, effective value. Owns the
-- per-ball state and score-info types. ScoringService drives this from the
-- collision loop; nothing here touches ball lifecycle or the collision query.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local StringUtils = require(RS.Shared.StringUtils)
local BallEffects = require(RS.Shared.BallEffects)
local ScoreUI = require(RS.Shared.ScoreUI)
local SoundService = require(RS.Shared.SoundService)
local Signal = require(RS.Shared.Signal)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local BallService = require(SSS.Scripts.Modules.BallService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)
local StatsService = require(SSS.Scripts.Modules.StatsService)
local GoldenPegService = require(SSS.Scripts.Modules.GoldenPegService)

local ScoreHandler = {}

-- Itemized breakdown of one ball's payout, built at banking. The contributions are
-- additive: banked == base + heatBonus + comboBonus + additiveBonus + trickle.
export type ScoreInfo = {
	targetName: string,
	destroyTargetId: number?, -- the DestroyTargetID attribute of the slot banked at (nil if none / stuck)
	finalMultiplier: number?, -- slot's × multiplier (nil if additive / no PointValue)
	initialValue: number,     -- value at spawn (the stake)
	base: number,             -- value at destruction, before bonuses
	heatBonus: number,        -- signed peg-heat payout
	comboBonus: number,       -- flat-per-bounce payout (0 below MinCombo)
	additiveBonus: number,    -- base-additive upgrade contribution
	trickle: number,          -- unconditional per-launch income
	combo: number,            -- scoring bounces credited
	banked: number,           -- total credited
	hotPegs: number,
	coldPegs: number,
	neutralPegs: number,
	jackpot: number,          -- jackpot bonus (0 if no JackpotTarget hit)
	jackpotHit: boolean,
}

-- All per-ball scoring state. Created on spawn, cleared on despawn.
export type BallState = {
	value: number,            -- live ball value (mutated by scoring hits)
	ownerUserId: number?,
	spawnClock: number,       -- os.clock() at spawn; drives the stuck timeout
	spawnValue: number,       -- the stake
	hits: { [Instance]: number }, -- target -> os.clock() of last credited hit
	heat: number,             -- running sum of applied peg heat (>= 0)
	bounces: number,          -- combo count
	hotPegs: number,
	coldPegs: number,
	neutralPegs: number,
	jackpotHit: boolean,
	lastBounceBurst: number?, -- os.clock() of the last cosmetic bounce-burst (debounce)
}

-- (ball, info) — banked at a DestroyTarget, just before despawn.
ScoreHandler.BallScored = Signal.new()
-- (ball, effectiveValue) — after each non-destroying hit.
ScoreHandler.EffectiveValueChanged = Signal.new()

local MIN_HEAT_ACCUM = -0.75

-- Players in a post-prestige no-score window: userId -> os.clock() expiry. A ball
-- owned by such a player still plays out normally; it just gets destroyed instead
-- of banked when it reaches a DestroyTarget (exploit guard, see PrestigeService).
local noScoreUntil: { [number]: number } = {}

local function isNoScore(userId: number?): boolean
	if not userId then
		return false
	end
	local expiry = noScoreUntil[userId]
	return expiry ~= nil and os.clock() < expiry
end

-- Open a no-score window of `seconds` for the player.
function ScoreHandler.BeginNoScore(userId: number, seconds: number)
	noScoreUntil[userId] = os.clock() + seconds
end

function ScoreHandler.GetEffectiveValue(info: ScoreInfo): number
	return info.base + info.heatBonus
end

local function buildScoreInfo(player: Player, state: BallState, base: number, multiplier: number?, targetName: string, destroyTargetId: number?): ScoreInfo
	local upgrades = ProfileService.GetUpgrades(player)

	-- Base Bonus is folded into the multipliers rather than paid as a separate additive
	-- line: handleDestroy boosts the slot PointMul, and the jackpot multiplier is boosted
	-- here by the same rate. The board shows each player their own boosted values
	-- (client BoardMultiplierView).
	local jackpot = if state.jackpotHit
		then base * Config.Scoring.JackpotMultiplier * (1 + ProfileStats.GetBaseAdditive(upgrades))
		else 0
	base += jackpot

	local H = math.max(state.heat, MIN_HEAT_ACCUM)
	local heatPayout = base * math.max(0, 1 + H)
	local heatEffect = heatPayout - base

	local combo = state.bounces
	local comboBonus = if combo >= Config.Scoring.MinCombo then combo * ProfileStats.GetFlatPerBounce(upgrades) else 0
	local banked = heatPayout + comboBonus

	local trickle = ProfileStats.GetTrickle(upgrades)
	banked += trickle

	return {
		targetName = targetName,
		destroyTargetId = destroyTargetId,
		finalMultiplier = multiplier,
		initialValue = state.spawnValue,
		base = base,
		heatBonus = heatEffect,
		comboBonus = comboBonus,
		additiveBonus = 0, -- folded into the boosted multipliers; kept for breakdown-shape compat
		trickle = trickle,
		combo = combo,
		banked = banked,
		hotPegs = state.hotPegs,
		coldPegs = state.coldPegs,
		neutralPegs = state.neutralPegs,
		jackpot = jackpot,
		jackpotHit = state.jackpotHit,
	}
end

local function getGroupBoostMult(player: Player): number
	return if player:IsInGroupAsync(Config.Groups.GroupId) then Config.Groups.ScoreBoost else 0
end

local function updateEffectiveValue(player: Player, ball: BasePart, state: BallState)
	local info = buildScoreInfo(player, state, state.value, nil, "")
	local effective = ScoreHandler.GetEffectiveValue(info)
	BallEffects.DoClientEffect(player, "SetValueUI", ball, math.floor(effective))
	ScoreHandler.EffectiveValueChanged:Fire(ball, effective)
end

function ScoreHandler.BankBall(player: Player, ball: BasePart, state: BallState, base: number, multiplier: number?, targetName: string, stuck: boolean, destroyTargetId: number?)
	local info = buildScoreInfo(player, state, base, multiplier, targetName, destroyTargetId)
	ScoreHandler.BallScored:Fire(ball, info)

	ScoreUI.PostMessage(player, (if stuck then "Ball stuck: " else "Ball scored! ") .. StringUtils.FormatMoney(base), Color3.new(1, 1, 1))
	if math.abs(info.heatBonus) >= 0.5 then
		if info.heatBonus > 0 then
			ScoreUI.PostMessage(player, "Heat Bonus! +" .. StringUtils.FormatMoney(info.heatBonus), Color3.fromRGB(255, 140, 0))
		else
			ScoreUI.PostMessage(player, "Cold Penalty: -" .. StringUtils.FormatMoney(math.abs(info.heatBonus)), Color3.fromRGB(80, 160, 255))
		end
	end
	if info.comboBonus > 0 then
		ScoreUI.PostMessage(player, "Combo! +" .. StringUtils.FormatMoney(info.comboBonus) .. " (" .. info.combo .. ")", Color3.fromRGB(255, 60, 60))
	end
	if info.jackpotHit then
		ScoreUI.PostMessage(player, "JACKPOT! " .. StringUtils.FormatMoney(info.jackpot), Color3.fromRGB(255, 105, 180))
	end

	local groupBoostMult = getGroupBoostMult(player)
	if groupBoostMult > 0 then
		local boost = info.banked * groupBoostMult
		info.banked += boost
		ScoreUI.PostMessage(player, "Group Boost! +" .. StringUtils.FormatMoney(boost), Color3.fromRGB(160, 60, 255))
	end

	-- Prestige is the final global multiplier: it scales the whole breakdown
	-- (including the group boost). Surface its contribution so the posted messages
	-- reconcile with the credited balance instead of looking "off".
	local prestigeMult = PrestigeService.GetMultiplier(player)
	if prestigeMult > 1 then
		local prestigeBonus = info.banked * (prestigeMult - 1)
		info.banked += prestigeBonus
		ScoreUI.PostMessage(player, string.format("Rebirth Multiplier! +%s (×%s)", StringUtils.FormatMoney(prestigeBonus), StringUtils.FormatShort(prestigeMult)), Color3.fromRGB(124, 58, 237))
	end

	-- Cash multiplier (Robux perk): another flat global multiplier on the whole payout.
	local cashMult = StatsService.GetCashMultiplier(player)
	if cashMult > 1 then
		local cashBonus = info.banked * (cashMult - 1)
		info.banked += cashBonus
		ScoreUI.PostMessage(player, string.format("Cash Multiplier! +%s (×%d)", StringUtils.FormatMoney(cashBonus), cashMult), Color3.fromRGB(255, 196, 0))
	end

	PrestigeService.AddLifetimeBanked(player, info.banked)
	BallService.Despawn(ball)
	CurrencyService.AddPoints(player, info.banked, if stuck then "Ball stuck (timeout): " .. ball.Name else "Ball destroyed at target: " .. targetName)
end

-- Hit sub-handlers. Each mutates state and fires effects for one concern.

local BOUNCE_BURST_INTERVAL = 0.12 -- min seconds between cosmetic bounce bursts per ball (dense peg
                                   -- fields would otherwise spam them, and flood the owner's client)

local function handleBounce(ball: BasePart, player: Player, state: BallState)
	state.bounces += 1
	local flatRate = ProfileStats.GetFlatPerBounce(ProfileService.GetUpgrades(player))
	if flatRate > 0 then
		BallEffects.DoClientEffect(player, "ShowComboPopup", ball, ball.CFrame, state.bounces, flatRate)
	end
	-- Cosmetic skin bounce burst (owner-only, debounced). The client Emits the SkinBounce emitter,
	-- which is a no-op if the equipped skin has no bounce effect set.
	local now = os.clock()
	if now - (state.lastBounceBurst or 0) >= BOUNCE_BURST_INTERVAL then
		state.lastBounceBurst = now
		BallEffects.DoClientEffect(player, "EmitBounce", ball)
	end
end

local function handlePegHeat(ball: BasePart, player: Player, state: BallState, pegHeat: number)
	if pegHeat > 0 then
		state.hotPegs += 1
	elseif pegHeat < 0 then
		state.coldPegs += 1
	else
		state.neutralPegs += 1
	end
	local heatFactor = ProfileStats.GetPegHeatFactor(ProfileService.GetUpgrades(player))
	local heatDelta = pegHeat * heatFactor
	local prevHeat: number = state.heat
	state.heat = math.max(state.heat + heatDelta, 0)
	if heatFactor ~= 0 then
		BallEffects.ApplyHeat(ball, state.heat, heatFactor)
	end
	if prevHeat > 0 or heatDelta > 0 then
		BallEffects.DoClientEffect(player, "ShowHeatPopup", ball, heatDelta)
		BallEffects.DoClientEffect(player, "PlayHeatSound", ball, prevHeat, state.heat, heatFactor)
	end
end

-- Golden peg (prestige perk): if this peg is golden for the owner and this ball hasn't
-- consumed it yet, roll the outcome (Config.GoldenPegs). Double mutates the LIVE ball
-- value (so it compounds into the slot multiplier at banking, and the caller's
-- updateEffectiveValue pushes the new value to the gate + value billboard); clone spawns
-- a second free ball of the same value via GoldenPegService.
local GOLD = Color3.fromRGB(255, 200, 40)

local function handleGoldenPeg(ball: BasePart, player: Player, state: BallState, target: Instance)
	local effect = GoldenPegService.TryConsume(ball, target, state.ownerUserId)
	if effect == "double" then
		state.value *= 2
		BallEffects.DoClientEffect(player, "ShowValuePopup", ball, ball.CFrame, "GOLD ×2!", GOLD)
		SoundService.PlayForClient(player, { soundId = Config.Sounds.Collect2 })
	elseif effect == "clone" then
		GoldenPegService.SpawnClone(ball, state.value, player.UserId)
		BallEffects.DoClientEffect(player, "ShowValuePopup", ball, ball.CFrame, "GOLD CLONE!", GOLD)
		SoundService.PlayForClient(player, { soundId = Config.Sounds.Jackpot })
	end
end

-- Returns true if the ball was banked (caller should not continue processing).
local function handleDestroy(ball: BasePart, player: Player, state: BallState, target: Instance): boolean
	if not target:HasTag(Config.Tags.DestroyTarget) then
		return false
	end
	-- Post-prestige no-score window: the ball reached a DestroyTarget but must not
	-- bank into the (reset) account. Just remove it.
	if isNoScore(player.UserId) then
		BallService.Despawn(ball)
		return true
	end
	if target:HasTag(Config.Tags.JackpotTarget) then
		state.jackpotHit = true
	end
	local multiplier = target:GetAttribute(Config.Attributes.PointMul) :: number?
	if multiplier then
		-- Base Bonus: raises this player's effective slot multipliers (the board labels
		-- show the boosted values locally — see client BoardMultiplierView).
		multiplier *= 1 + ProfileStats.GetBaseAdditive(ProfileService.GetUpgrades(player))
	end
	local base = if multiplier then state.value * multiplier else state.value
	if multiplier or state.jackpotHit then
		local effMultiplier = multiplier :: number
		-- Jackpot FX keys off the RAW jackpot multiplier (ShowPointFX infers isJackpot by
		-- equality with Config.Scoring.JackpotMultiplier), so it stays unboosted here.
		if state.jackpotHit then effMultiplier = Config.Scoring.JackpotMultiplier end
		BallEffects.DoClientEffect(player, "ShowValuePopup", ball, ball.CFrame, "×" .. StringUtils.FormatShort(effMultiplier))
		BallEffects.DoClientEffect(player, "ShowPointFX", ball, ball.CFrame, effMultiplier)
	end
	local destroyTargetId = target:GetAttribute(Config.Attributes.DestroyTargetID) :: number?
	ScoreHandler.BankBall(player, ball, state, base, multiplier, target.Name, false, destroyTargetId)
	return true
end

function ScoreHandler.ResolveHit(ball: BasePart, target: Instance, state: BallState)
	local player = if state.ownerUserId then Players:GetPlayerByUserId(state.ownerUserId) else nil
	if not player then
		return
	end

	if target:HasTag(Config.Tags.BounceTarget) then
		handleBounce(ball, player, state)
	end

	local pegHeat = target:GetAttribute(Config.Attributes.PegHeat) :: number?
	if pegHeat then
		handlePegHeat(ball, player, state, pegHeat)
		handleGoldenPeg(ball, player, state, target)
	end

	if handleDestroy(ball, player, state, target) then
		return
	end

	updateEffectiveValue(player, ball, state)
end

return ScoreHandler
