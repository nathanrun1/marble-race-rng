--!strict
-- Owns the jackpot-gate collision rule.
--
-- The gate is a physical barrier in front of the jackpot. A ball is blocked by it
-- until the ball's value clears the player's jackpot threshold (V_JACK, derived in
-- ProfileStats); once it's over the line, the ball phases through and reaches the
-- jackpot. This is enforced with collision groups, per ball, so each player's gate
-- behaves according to their own threshold.
--
-- Groups:
--   GATE_GROUP    — every gate part. By default NOT collidable with "Default", so
--                   ordinary parts (and over-threshold balls, which we leave in
--                   Default) pass straight through.
--   BLOCKED_GROUP — a registered ball whose value is at/under threshold. Collidable
--                   with GATE_GROUP, so the gate stops it. Still collides with the
--                   rest of the world (pegs, walls) like a normal ball.
--
-- Balls are registered off BallService.BallSpawned and re-evaluated on
-- BallService.BallValueChanged; when a ball crosses the threshold its group is
-- flipped so the gate opens.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local Config = require(RS.Shared.Config)
local ProfileStats = require(RS.Shared.ProfileStats)
local BallService = require(SSS.Scripts.Modules.BallService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)

local CollisionService = {}

local GATE_GROUP    = "JackpotGate"
local BLOCKED_GROUP = "JackpotGateBlocked"
local PASS_GROUP    = "Default" -- built-in; not collidable with GATE_GROUP

-- Placeholder: the container whose BasePart descendants make up the gate. Set this
-- to the gate model/folder in the workspace; its parts are iterated at Init to put
-- them in GATE_GROUP.
local GATE_CONTAINER: Model? = game.Workspace:WaitForChild("Slanted Board"):WaitForChild("JackpotWall")

-- The set of balls currently subject to the gate rule. A ball's value is tracked
-- via BallService.BallValueChanged, so we only need membership here.
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

-- Over threshold → pass (Default, phases through gate); otherwise → blocked.
local function applyGroupForValue(ball: BasePart, value: number)
	local group = if value > getThreshold(ball) then PASS_GROUP else BLOCKED_GROUP
	setBallGroup(ball, group)
end

local function onBallSpawn(ball: BasePart)
	registeredBalls[ball] = true
	applyGroupForValue(ball, BallService.GetBallValue(ball))
end

local function onBallDespawn(ball: BasePart)
	registeredBalls[ball] = nil
end

-- A tracked ball's value changed; re-evaluate which side of the gate it's on.
local function onBallValueChanged(ball: BasePart, value: number)
	if registeredBalls[ball] then
		applyGroupForValue(ball, value)
	end
end

-- Register the collision groups and their collidability once. Guarded so repeated
-- Studio play sessions don't error on an already-registered group.
local function setupGroups()
	if not PhysicsService:IsCollisionGroupRegistered(GATE_GROUP) then
		PhysicsService:RegisterCollisionGroup(GATE_GROUP)
	end
	if not PhysicsService:IsCollisionGroupRegistered(BLOCKED_GROUP) then
		PhysicsService:RegisterCollisionGroup(BLOCKED_GROUP)
	end
	-- By default the gate doesn't collide with anything in Default (so over-
	-- threshold balls pass through); it only stops balls in the blocked group.
	PhysicsService:CollisionGroupSetCollidable(GATE_GROUP, PASS_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(GATE_GROUP, BLOCKED_GROUP, true)
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
	BallService.BallValueChanged:Connect(onBallValueChanged)
end

return CollisionService
