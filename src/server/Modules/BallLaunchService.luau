-- ServerScriptService/BallLaunchService (ModuleScript)
--!strict
-- Authority over launches. The server owns timing (the launch-delay cooldown) and
-- trajectory; the client only configures its loadout (bet, Arc, Angle, ...) via
-- ProfileService. Launches are manual: each request fires one ball. The launcher
-- swivels continuously (aim ± Arc) driven by the clock; the ball is aimed by the
-- swivel's phase at fire time, around the player's Angle (aim center).

local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local BallService = require(SSS.Scripts.Modules.BallService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
local WarnUI = require(RS.Shared.WarnUI)
local Config = require(RS.Shared.Config)

local requestLaunch = RS.Remote.RequestLaunch

local BallLaunchService = {}

-- Server-chosen trajectory constants. The client never touches these. (Spawn origin
-- and base aim live in Config.Launcher, shared with the client aim-line preview.)
local BATCH_SECONDS = 3                         -- seconds per batch; server owns timing
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

-- Most recent launch from player with given user ID
local lastLaunch: { [number]: number } = {}

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

-- Spawn one ball for this player using their current loadout. This is the
-- trajectory/loadout core of a launch with no guards or currency side effects —
-- launchFor wraps it with those; the dev launch test reuses it raw. Phase is the
-- launcher's continuous swivel position at call time, derived from the clock and
-- the rotation period; Arc (swivel width) and Angle (aim center) are loadout axes.
local function spawnBall(player: Player): BasePart
	local loadout = ProfileService.GetLoadout(player)
	local arcWidth = loadout.axes.Arc
	local aimAngle = loadout.axes.Angle
	local phase = (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
	return BallService.Spawn(genSpawnPos(), {
		ownerUserId = player.UserId,
		velocity = deriveLaunchVelocity(phase, arcWidth, aimAngle),
		initialValue = loadout.Bet,
		weight = 1 - loadout.axes.Elasticity,
		size = loadout.axes.Size,
	})
end

-- Fire one ball for a manual launch: enforce the launch-delay cooldown, charge
-- the bet, and respect the concurrency cap, then spawn. (Launches are manual now
-- — the old per-batch clock was dropped in favor of a shrinkable launch delay.)
local function launchFor(player: Player)
	local userId = player.UserId
	local upgrades = ProfileService.GetUpgrades(player)
	local loadout = ProfileService.GetLoadout(player)

	if lastLaunch[userId] and os.clock() - lastLaunch[userId] < ProfileStats.GetLaunchDelay(upgrades) then return end  -- Launch too early
	if CurrencyService.GetPoints(player) < loadout.Bet then
		-- Can't afford: stamp the cooldown anyway so an auto-launcher only warns once per
		-- launch-delay instead of spamming the notice every request.
		lastLaunch[userId] = os.clock()
		WarnUI.Warn(player, "Can't afford bet size!")
		return
	end
	if BallService.GetLiveCount(userId) >= MAX_BALLS_PER_PLAYER then return end  -- Too many balls live

	lastLaunch[userId] = os.clock()
	CurrencyService.AddPoints(player, -loadout.Bet)
	spawnBall(player)
end

export type TestLaunchOptions = {
	phase: number?,   -- 0..1 swivel phase; nil = clock-derived
	weight: number?,  -- overrides loadout Elasticity-derived weight
	size: number?,    -- overrides loadout Size axis
}

-- Dev/test only: fire one ball immediately, bypassing the cooldown, the
-- affordability check, the concurrency cap, and the bet charge. Returns the ball
-- so the caller can match it against ScoringService.BallScored.
function BallLaunchService.LaunchTest(player: Player, opts: TestLaunchOptions?): BasePart
	local o = opts or {}
	local loadout = ProfileService.GetLoadout(player)
	local phase = o.phase or (os.clock() % LAUNCHER_ROT_PERIOD) / LAUNCHER_ROT_PERIOD
	return BallService.Spawn(genSpawnPos(), {
		ownerUserId = player.UserId,
		velocity = deriveLaunchVelocity(phase, loadout.axes.Arc, loadout.axes.Angle),
		initialValue = loadout.Bet,
		weight = o.weight or (1 - loadout.axes.Elasticity),
		size = o.size or loadout.axes.Size,
	})
end

-- Seconds between each ball in LaunchMaxBetBatch, so a dropped batch doesn't all spawn stacked
-- on the exact same point in the same instant.
local BALL_DROP_STAGGER = 0.12

-- Robux perk (Config.BallDrop): instantly fire `count` balls valued at the player's CURRENT max
-- bet (ProfileStats.GetMaxBet — NOT their chosen loadout.Bet), free and bypassing the launch
-- cooldown/affordability check, same spirit as LaunchTest. Fires the balls in the background
-- (staggered) so the caller (the dev-product grant handler) can return immediately.
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

-- Fire one ball at the player's current server-authoritative bet. Bet size is no
-- longer sent by the client at all — it's a discrete tier the player picks ahead of
-- time via RaiseBtn/LowerBtn (ProfileService.SetBetTier), stored on the profile.
-- launchFor reads loadout.Bet directly, so there is nothing left here to trust from
-- the client; any legacy/extra args the client still sends are ignored.
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

	-- Server-authoritative batch clock: every BATCH_SECONDS, kick off each
	-- player's batch in its own thread so their staggered launches run in
	-- parallel and never block the clock.
	-- task.spawn(function()
	-- 	while true do
	-- 		task.wait(BATCH_SECONDS)
	-- 		for _, player in Players:GetPlayers() do
	-- 			task.spawn(launchBatchFor, player)
	-- 		end
	-- 	end
	-- end)
end

return BallLaunchService
