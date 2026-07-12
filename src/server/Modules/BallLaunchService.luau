-- ServerScriptService/BallLaunchService (ModuleScript)
--!strict
-- Authority over launches. The server owns timing and trajectory; the client only
-- configures its loadout (Arc, Angle, ...) via ProfileService. The launcher swivels
-- continuously (aim ± Arc) driven by the clock; each ball is aimed by the swivel's
-- phase at fire time, around the player's Angle (aim center).
--
-- CORE LOOP REWORK: a launch request fires a BATCH — every ball in the player's
-- equipped loadout (LoadoutService), round-robined evenly across a fixed
-- Config.Launcher.BatchDelay window (see launchFor) — instead of one generic ball
-- valued at a chosen bet tier. A ball's value now comes from its own skin's rarity
-- (Config.Cosmetics.RarityValue), not a bet; launching is free (no currency charge).

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local BallService = require(SSS.Scripts.Modules.BallService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
local LoadoutService = require(SSS.Scripts.Modules.LoadoutService)
local BallSkins = require(RS.Shared.BallSkins)
local Config = require(RS.Shared.Config)

local requestLaunch = RS.Remote.RequestLaunch

local BallLaunchService = {}

-- Server-chosen trajectory constants. The client never touches these. (Spawn origin
-- and base aim live in Config.Launcher, shared with the client aim-line preview.)
local BATCH_SECONDS = Config.Launcher.BatchDelay -- fixed seconds per batch; server owns timing
local MAX_BALLS_PER_PLAYER = 160                 -- concurrency ceiling (well above max N)
local LAUNCHER_ROT_PERIOD = Config.Launcher.RotationPeriod  -- full swivel period (shared w/ client)

-- Launcher geometry — TUNE to the actual ramp. BASE_LAUNCH_DIR is the launcher's
-- neutral direction (aim 0, mid-phase), i.e. straight down the ramp; the swivel
-- rotates it left/right about the vertical axis. Two per-player loadout axes shape
-- the aim: Arc (swivel half-width) and Angle (the center the launcher swivels
-- around, default 0 = straight down). Both are passed into deriveLaunchVelocity.
local BASE_LAUNCH_DIR = Config.Launcher.BaseDirection   -- down-ramp; shared w/ client preview
local LAUNCH_SPEED = 60                          -- studs/s initial speed
local LAUNCH_SPEED_VARIATION = 0.2              -- Launch speed can vary by up to this portion
local LAUNCH_DIR_VARIATION = math.rad(10)                -- Launch angle can vary by up to this angle

-- os.clock() timestamp a player's NEXT batch may start (nil = never launched).
local nextBatchTime: { [number]: number } = {}

local function genLaunchSpeed(): number
	local variation = LAUNCH_SPEED * LAUNCH_SPEED_VARIATION
	return math.random(LAUNCH_SPEED - variation, LAUNCH_SPEED + variation)
end

local function genSpawnPos(): Vector3
	-- Shared with the client aim-line preview so they originate from the same point.
	return Config.Launcher.LaunchOrigin
end

-- Launcher swivels continuously: as phase runs 0→1 the aim sweeps aim ± arcWidth
-- (phase 0/0.5/1 = aim, 0.25 = +arcWidth, 0.75 = −arcWidth). The deterministic
-- swivel angle is ProfileStats.GetSwivelAngle; we add a small random jitter, then
-- rotate the base down-ramp vector about the vertical axis by the total angle.
local function deriveLaunchVelocity(phase: number, arcWidth: number, aimAngle: number): Vector3
	local angle = ProfileStats.GetSwivelAngle(arcWidth, aimAngle, phase)
		+ (math.random() * 2 - 1) * LAUNCH_DIR_VARIATION
	local dir = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(BASE_LAUNCH_DIR)
	return dir.Unit * genLaunchSpeed()
end

-- $ value a ball of this skin's rarity carries (CORE LOOP REWORK — replaces the old bet-tier
-- value; see Config.Cosmetics.RarityValue).
local function ballValueForSkin(skinId: string): number
	local skin = BallSkins.Get(skinId)
	local rarity = if skin then skin.rarity else 1
	return Config.Cosmetics.RarityValue[rarity] or Config.Cosmetics.RarityValue[1]
end

-- Spawn one ball for this player wearing `skinId`, valued at that skin's rarity. This is the
-- trajectory core of a launch with no guards or currency side effects — launchFor wraps it
-- with those; the dev launch test reuses it raw. Phase is the launcher's continuous swivel
-- position at call time, derived from the clock and the rotation period; Arc (swivel width)
-- and Angle (aim center) are loadout axes.
local function spawnBall(player: Player, skinId: string): BasePart
	local loadout = ProfileService.GetLoadout(player)
	local arcWidth = loadout.axes.Arc
	local aimAngle = loadout.axes.Angle
	local phase = (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
	return BallService.Spawn(genSpawnPos(), {
		ownerUserId = player.UserId,
		velocity = deriveLaunchVelocity(phase, arcWidth, aimAngle),
		initialValue = ballValueForSkin(skinId),
		weight = 1 - loadout.axes.Elasticity,
		size = loadout.axes.Size,
		skinId = skinId,
	})
end

-- Fire a BATCH: every ball in the player's equipped loadout, round-robined evenly across
-- BATCH_SECONDS (e.g. 3 equipped balls over a 3s batch -> ball 1 immediately, ball 2 after
-- 1s, ball 3 after 2s; the next batch becomes available 1s later, i.e. exactly BATCH_SECONDS
-- after this one started). More equipped balls -> more balls launched per batch, without
-- changing the batch's own cadence. No cost: bet sizing is gone, a ball's own rarity value
-- IS its worth (see ballValueForSkin).
local function launchFor(player: Player)
	local userId = player.UserId
	if nextBatchTime[userId] and os.clock() < nextBatchTime[userId] then
		return -- previous batch still in flight / cooling down
	end

	local loadoutInfo = LoadoutService.GetInfo(player)
	local order: { string } = {}
	for slot = 1, LoadoutService.GetMaxSlots(player) do
		local skinId = loadoutInfo.loadout[tostring(slot)]
		if skinId then
			table.insert(order, skinId)
		end
	end
	if #order == 0 then
		return -- shouldn't happen (at least one ball is always equipped); defensive no-op
	end

	nextBatchTime[userId] = os.clock() + BATCH_SECONDS
	local stepDelay = BATCH_SECONDS / #order
	for i, skinId in order do
		task.delay(stepDelay * (i - 1), function()
			if player.Parent and BallService.GetLiveCount(userId) < MAX_BALLS_PER_PLAYER then
				spawnBall(player, skinId)
			end
		end)
	end
end

export type TestLaunchOptions = {
	phase: number?,   -- 0..1 swivel phase; nil = clock-derived
	weight: number?,  -- overrides loadout Elasticity-derived weight
	size: number?,    -- overrides loadout Size axis
	skinId: string?,  -- which skin's rarity values the ball; nil = the default (Classic) skin
}

-- Dev/test only: fire one ball immediately, bypassing the batch cooldown and the
-- concurrency cap. Returns the ball so the caller can match it against
-- ScoringService.BallScored.
function BallLaunchService.LaunchTest(player: Player, opts: TestLaunchOptions?): BasePart
	local o: TestLaunchOptions = opts or {}
	local loadout = ProfileService.GetLoadout(player)
	local phase = o.phase or (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
	return BallService.Spawn(genSpawnPos(), {
		ownerUserId = player.UserId,
		velocity = deriveLaunchVelocity(phase, loadout.axes.Arc, loadout.axes.Angle),
		initialValue = ballValueForSkin(o.skinId or BallSkins.GetDefaultId()),
		weight = o.weight or (1 - loadout.axes.Elasticity),
		size = o.size or loadout.axes.Size,
		skinId = o.skinId,
	})
end

-- Seconds between each ball in LaunchMaxBetBatch, so a dropped batch doesn't all spawn stacked
-- on the exact same point in the same instant.
local BALL_DROP_STAGGER = 0.12

-- Robux perk (Config.BallDrop): instantly fire `count` balls, free and bypassing the launch
-- cooldown, same spirit as LaunchTest. NOT updated for the core-loop rework (ball value now
-- comes from rarity, not a bet ceiling) — still values balls at the player's frozen MaxBet tier
-- (ProfileStats.GetMaxBet), since MaxBet purchases are gated but existing tiers/derivation are
-- untouched. Revisit once this Robux perk's value source is decided. Fires the balls in the
-- background (staggered) so the caller (the dev-product grant handler) can return immediately.
function BallLaunchService.LaunchMaxBetBatch(player: Player, count: number)
	local upgrades = ProfileService.GetUpgrades(player)
	local loadout = ProfileService.GetLoadout(player)
	local maxBet = ProfileStats.GetMaxBet(upgrades)
	task.spawn(function()
		for _ = 1, count do
			if not player.Parent then
				return -- player left mid-drop
			end
			if BallService.GetLiveCount(player.UserId) < MAX_BALLS_PER_PLAYER then
				local phase = (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
				BallService.Spawn(genSpawnPos(), {
					ownerUserId = player.UserId,
					velocity = deriveLaunchVelocity(phase, loadout.axes.Arc, loadout.axes.Angle),
					initialValue = maxBet,
					weight = 1 - loadout.axes.Elasticity,
					size = loadout.axes.Size,
				})
			end
			task.wait(BALL_DROP_STAGGER)
		end
	end)
end

-- Current launcher swivel phase (0..1). The client renders its own smooth swivel and
-- periodically resyncs to this so the visual matches the server's actual fire timing.
function BallLaunchService.GetPhase(): number
	return (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
end

-- Request a batch launch. Nothing to trust from the client anymore — the batch is entirely
-- derived from the player's server-held loadout; any legacy/extra args the client still sends
-- are ignored.
local function onRequest(player: Player)
	launchFor(player)
end

function BallLaunchService.Init()
	requestLaunch.OnServerEvent:Connect(onRequest)

	-- Lets the client sync its visual launcher rotation to the server's phase.
	local getPhaseRF = Instance.new("RemoteFunction")
	getPhaseRF.Name = "GetLauncherPhase"
	getPhaseRF.Parent = RS.Remote
	getPhaseRF.OnServerInvoke = function()
		return BallLaunchService.GetPhase()
	end
end

return BallLaunchService
