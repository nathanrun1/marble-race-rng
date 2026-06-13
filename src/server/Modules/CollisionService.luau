--!strict
-- Owns the jackpot-gate collision rule.
--
-- The gate is a physical barrier in front of the jackpot. A ball is blocked by it
-- until the ball's *effective* value clears the player's jackpot threshold (V_JACK,
-- derived in ProfileStats). Effective value (current value + combo + heat bonuses)
-- is owned by ScoringService; once it's over the line, the ball phases through and
-- reaches the jackpot. This is enforced with collision groups, per ball, so each
-- player's gate behaves according to their own threshold.
--
-- Groups:
--   GATE_GROUP    — every gate part. NOT collidable with PASS_GROUP, so over-
--                   threshold balls pass straight through; collidable with
--                   BLOCKED_GROUP so it stops under-threshold balls.
--   PASS_GROUP    — a registered ball whose value is over threshold. Passes the
--                   gate; collides with the world (pegs, walls) but not other balls.
--   BLOCKED_GROUP — a registered ball whose value is at/under threshold. Stopped by
--                   the gate; collides with the world but not other balls.
--
-- Every ball lives in PASS_GROUP or BLOCKED_GROUP (never bare "Default"), and all
-- ball↔ball pairings are non-collidable, so balls never collide with each other.
--
-- Balls are registered off BallService.BallSpawned and re-evaluated on
-- ScoringService.EffectiveValueChanged; when a ball crosses the threshold its group
-- is flipped so the gate opens.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local BallService = require(SSS.Scripts.Modules.BallService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local ScoringService = require(SSS.Scripts.Modules.ScoringService)

local CollisionService = {}

local GATE_GROUP    = "JackpotGate"
local BLOCKED_GROUP = "JackpotGateBlocked"
local PASS_GROUP    = "JackpotGatePass" -- over-threshold balls; phases through the gate

-- Placeholder: the container whose BasePart descendants make up the gate. Set this
-- to the gate model/folder in the workspace; its parts are iterated at Init to put
-- them in GATE_GROUP.
local GATE_CONTAINER: Model? = game.Workspace:WaitForChild("Slanted Board"):WaitForChild("JackpotWall")

-- The set of balls currently subject to the gate rule. Effective value is tracked
-- via ScoringService.EffectiveValueChanged, so we only need membership here.
local registeredBalls: { [BasePart]: true } = {}

-- Jackpot threshold for this ball's owner. An unowned ball (or one whose owner has
-- left) can never jackpot, so its threshold is infinite — it stays blocked.
local function getThreshold(ball: BasePart): number
	local ownerId = ball:GetAttribute(Config.Attributes.OwnerUserId) :: number?
	if not ownerId then
		return math.huge
	end
	local player = Players:GetPlayerByUserId(ownerId)
	if not player then
		return math.huge
	end
	return ProfileStats.GetVJack(ProfileService.GetUpgrades(player))
end

-- Set the collision group on the ball (and any BasePart descendants, in case the
-- prefab is multi-part) without touching parts already in the target group.
local function setBallGroup(ball: BasePart, group: string)
	if ball.CollisionGroup ~= group then
		ball.CollisionGroup = group
	end
	for _, d in ball:GetDescendants() do
		if d:IsA("BasePart") and d.CollisionGroup ~= group then
			d.CollisionGroup = group
		end
	end
end

-- Effective value over threshold → pass (phases through gate); otherwise → blocked.
local function applyGroupForValue(ball: BasePart, effectiveValue: number)
	local group = if effectiveValue > getThreshold(ball) then PASS_GROUP else BLOCKED_GROUP
	setBallGroup(ball, group)
end

local function onBallSpawn(ball: BasePart)
	registeredBalls[ball] = true
	-- A fresh ball has no combo/heat yet, so its effective value equals its spawn
	-- value; the first scoring hit pushes an EffectiveValueChanged update.
	applyGroupForValue(ball, BallService.GetBallValue(ball))
end

local function onBallDespawn(ball: BasePart)
	registeredBalls[ball] = nil
end

-- A tracked ball's effective value changed; re-evaluate which side of the gate it's on.
local function onEffectiveValueChanged(ball: BasePart, effectiveValue: number)
	if registeredBalls[ball] then
		applyGroupForValue(ball, effectiveValue)
	end
end

-- Register the collision groups and their collidability once. Guarded so repeated
-- Studio play sessions don't error on an already-registered group.
local function setupGroups()
	for _, group in { GATE_GROUP, BLOCKED_GROUP, PASS_GROUP } do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	-- Gate physics: over-threshold balls (PASS_GROUP) phase through; under-threshold
	-- balls (BLOCKED_GROUP) are stopped. Both groups still collide with the world
	-- (Default) — pegs and walls — since cross-group collidability defaults to true.
	PhysicsService:CollisionGroupSetCollidable(GATE_GROUP, PASS_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(GATE_GROUP, BLOCKED_GROUP, true)
	-- Balls never collide with each other, on either side of the gate: every ball
	-- is in PASS_GROUP or BLOCKED_GROUP, so make all three ball pairings pass through.
	PhysicsService:CollisionGroupSetCollidable(PASS_GROUP, PASS_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(BLOCKED_GROUP, BLOCKED_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(PASS_GROUP, BLOCKED_GROUP, false)
end

-- Put every BasePart under the gate container into GATE_GROUP.
local function setupGateParts()
	if not GATE_CONTAINER then
		warn("CollisionService: GATE_CONTAINER unset; no gate parts grouped")
		return
	end
	for _, d in GATE_CONTAINER:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = GATE_GROUP
		end
	end
end

function CollisionService.Init()
	setupGroups()
	setupGateParts()

	BallService.BallSpawned:Connect(onBallSpawn)
	BallService.BallDespawned:Connect(onBallDespawn)
	ScoringService.EffectiveValueChanged:Connect(onEffectiveValueChanged)
end

return CollisionService
