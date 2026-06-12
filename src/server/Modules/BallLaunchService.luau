-- ServerScriptService/BallLaunchService (ModuleScript)
--!strict
-- Authority over launches. The server owns timing (a fixed batch clock) and
-- trajectory; the client only configures its loadout (bet, N, phase, ...) via
-- ProfileService. Each batch, a player launches N balls (their frequency)
-- spaced BATCH_SECONDS/N apart, each worth bet/N, aimed by the launcher's swivel
-- at that ball's phase.

local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local BallService = require(SSS.Scripts.Modules.BallService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)

local requestLaunch = RS.Remote.RequestLaunch

local BallLaunchService = {}

-- Server-chosen trajectory constants. The client never touches these.
local SPAWN_POS = Vector3.new(43.859, 190.14, 332.272)
local BATCH_SECONDS = 5                         -- seconds per batch; server owns timing
local MAX_BALLS_PER_PLAYER = 40                 -- concurrency ceiling (well above max N)

-- Launcher geometry — TUNE to the actual ramp. BASE_LAUNCH_DIR is the "center"
-- (phase 0.5) launch direction, i.e. straight down the ramp; the swivel rotates
-- it left/right about the vertical axis. The max swivel (the launcher's
-- "rotation radius") is per-player — ProfileStats.GetArcWidth, from the Arc
-- upgrade — and passed into deriveLaunchVelocity per batch.
local BASE_LAUNCH_DIR = Vector3.new(0, 0, -1)   -- down-ramp; align with real geometry
local LAUNCH_SPEED = 20                          -- studs/s initial speed
local LAUNCH_SPEED_VARIATION = 0.2              -- Launch speed can vary by up to this portion
local LAUNCH_DIR_VARIATION = math.rad(10)                -- Launch angle can vary by up to this angle

local function genLaunchSpeed(): number
	local variation = LAUNCH_SPEED * LAUNCH_SPEED_VARIATION
	return math.random(LAUNCH_SPEED - variation, LAUNCH_SPEED + variation)
end

local function genSpawnPos(): Vector3
	local left: number = 43.859
	local right: number = -1.218

	--return Vector3.new(math.random(right, left), SPAWN_POS.Y, SPAWN_POS.Z)
	return Vector3.new((right + left) / 2, SPAWN_POS.Y, SPAWN_POS.Z)
end

-- Launcher swivels once per batch: phase 0 = center, 0.25 = right, 0.5 = center,
-- 0.75 = left, 1 = center. angle(phase) = arcWidth · sin(2π·phase), so the
-- default phase 0.5 fires straight down the center (angle 0). Direction is the
-- base down-ramp vector rotated about the vertical axis by that angle.
local function deriveLaunchVelocity(phase: number, arcWidth: number): Vector3
	local angle = arcWidth * math.sin(2 * math.pi * phase) + math.random(-LAUNCH_DIR_VARIATION, LAUNCH_DIR_VARIATION)
	local dir = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(BASE_LAUNCH_DIR)
	return dir.Unit * genLaunchSpeed()
end

-- Launch one player's batch: pay trickle, then fire N balls over the window.
-- Runs in its own thread (the per-ball waits must not block other players or
-- the master clock). The last ball fires at (N-1)/N · BATCH_SECONDS, so a batch
-- always finishes before the next one starts.
local function launchBatchFor(player: Player)
	local userId = player.UserId
	local upgrades = ProfileService.GetUpgrades(player)
	local loadout = ProfileService.GetLoadout(player)

	-- Trickle income, unconditional, once per batch (§1.2).
	CurrencyService.AddPoints(player, ProfileStats.GetTrickle(upgrades), "Trickle")

	-- Snapshot config at batch start; a mid-batch loadout change must not re-aim
	-- or re-price balls already committed to this batch.
	local n = loadout.BallCount
	if n < 1 then
		return
	end
	local perBallValue = loadout.Bet / n
	local interval = BATCH_SECONDS / n
	local basePhase = loadout.LaunchPhase
	local arcWidth = ProfileStats.GetArcWidth(upgrades)
	local weight = loadout.axes.Weight
	local size = loadout.axes.Size

	for i = 0, n - 1 do
		-- Re-check per ball: concurrency cap and affordability (a leaver/score
		-- mid-batch can change either). Skip remaining balls if either fails.
		if BallService.GetLiveCount(userId) >= MAX_BALLS_PER_PLAYER then
			break
		end
		if CurrencyService.GetPoints(player) < perBallValue then
			break
		end
		CurrencyService.AddPoints(player, -perBallValue)

		-- Ball i fires at phase (basePhase + i/N): one big aimed ball pins to the
		-- chosen phase; many balls spread evenly across the full sweep.
		local phase = (basePhase + i / n) % 1
		BallService.Spawn(genSpawnPos(), {
			ownerUserId = userId,
			velocity = deriveLaunchVelocity(phase, arcWidth),
			initialValue = perBallValue,
			weight = weight,
			size = size,
		})

		if i < n - 1 then
			task.wait(interval)
		end
	end
end

-- Client configures its bet (intent only); the server clamps and stores it on
-- the profile. The launch itself is driven by the batch clock, not this event.
local function onRequest(player: Player, bet: number)
	if type(bet) ~= "number" or bet ~= bet or bet < 0 then
		return -- reject NaN/negative/non-number; do not trust the client
	end
	ProfileService.SetBet(player, bet)
end

function BallLaunchService.Init()
	requestLaunch.OnServerEvent:Connect(onRequest)

	-- Server-authoritative batch clock: every BATCH_SECONDS, kick off each
	-- player's batch in its own thread so their staggered launches run in
	-- parallel and never block the clock.
	task.spawn(function()
		while true do
			task.wait(BATCH_SECONDS)
			for _, player in Players:GetPlayers() do
				task.spawn(launchBatchFor, player)
			end
		end
	end)
end

return BallLaunchService
