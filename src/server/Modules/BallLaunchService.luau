-- ServerScriptService/BallLaunchService (ModuleScript)
--!strict
-- Authority over player-triggered launches. The client's request is intent
-- only; this module decides whether the launch is permitted and supplies the
-- trajectory itself. Two independent jobs: anti-abuse (rate + concurrency) and
-- handing BallService server-chosen spawn parameters.

local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local BallService = require(SSS.Modules.BallService)
local CurrencyService = require(SSS.Modules.CurrencyService)

local requestLaunch = RS.Remote.RequestLaunch

local BallLaunchService = {}

-- Server-chosen trajectory. The client never touches these.
local SPAWN_POS = Vector3.new(43.859, 190.14, 332.272)
local LAUNCH_VELOCITY = Vector3.zero          -- drop from rest; set if launched
local SERVER_COOLDOWN = 0.1                    -- authoritative; > client cooldown  -- TODO: make dependent on upgrades
local MAX_BALLS_PER_PLAYER = 15                 -- concurrency cap; the real ceiling

local lastLaunch: { [number]: number } = {}    -- userId -> os.clock()

local function genSpawnPos(): Vector3
	local left: number = 43.859
	local right: number = -1.218
	
	--return Vector3.new(math.random(right, left), SPAWN_POS.Y, SPAWN_POS.Z)
	return Vector3.new((right + left) / 2, SPAWN_POS.Y, SPAWN_POS.Z)
end

local function canLaunch(player: Player, initialValue: number): boolean
	local userId = player.UserId
	local now = os.clock()
	-- Authoritative cooldown. A modified client firing faster than its local
	-- cooldown is caught here; the local one was only saving wire traffic.
	if (lastLaunch[userId]) and (now - lastLaunch[userId] < SERVER_COOLDOWN) then
		return false
	end
	if BallService.GetLiveCount(userId) >= MAX_BALLS_PER_PLAYER then
		return false
	end
	if CurrencyService.GetPoints(player) < initialValue then
		return false
	end
	CurrencyService.AddPoints(player, -initialValue)
	return true
end

local function onRequest(player: Player, initialValue: number)
	if not canLaunch(player, initialValue) then
		return -- silently drop; do not trust, do not error back
	end
	local userId = player.UserId
	lastLaunch[userId] = os.clock()
	
	local ball: BasePart = BallService.Spawn(genSpawnPos(), {
		ownerUserId = userId,
		velocity = LAUNCH_VELOCITY,
		initialValue = initialValue
	})
end

function BallLaunchService.Init()
	requestLaunch.OnServerEvent:Connect(onRequest)
	Players.PlayerRemoving:Connect(function(player)
		lastLaunch[player.UserId] = nil
	end)
end

return BallLaunchService