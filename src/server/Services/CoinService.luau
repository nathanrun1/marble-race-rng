--!strict
-- Per-player collectible coins. Each workspace part tagged TagsConfig.Coin is a spawn
-- LOCATION (shared geometry); this service owns, per player, which locations are currently
-- "active" and what each is worth. Activations/deactivations are sent to that one player's
-- client (CoinPickups), which renders, animates, and detects the pickup locally — so coins
-- are independent per player even though the parts are shared. The client requests a claim;
-- the server validates it against that player's active set, awards the cash, deactivates,
-- and announces the reward. Spawn cadence, cap, value range, etc. live in CoinsConfig.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local CoinsConfig = require(RS.Shared.Config.Coins)
local SoundsConfig = require(RS.Shared.Config.Sounds)
local TagsConfig = require(RS.Shared.Config.Tags)
local CoinNet = require(RS.Shared.Remote.CoinNet)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local WarnUI = require(RS.Shared.WarnUI)
local SoundService = require(RS.Shared.SoundService)
local StringUtils = require(RS.Shared.Utility.StringUtils)

local CoinService = {}

local REWARD_COLOR = Color3.fromRGB(255, 210, 60)
local DIAMOND_REWARD_COLOR = Color3.fromRGB(255, 210, 60) -- matches the Diamonds theme elsewhere (CosmeticsShop YELLOW)

type CoinEntry = { value: number, isBlue: boolean } -- isBlue: pays Diamonds instead of cash

type PlayerState = {
	active: { [Instance]: CoinEntry }, -- coin location -> reward
	count: number,
	ready: boolean,                 -- client has announced it's listening (CoinReady)
	nextSpawn: number,              -- os.clock() of the next scheduled spawn (huge until ready)
}

local states: { [Player]: PlayerState } = {}

-- Remotes (created in Init).
local activateRE: RemoteEvent
local deactivateRE: RemoteEvent
local claimRE: RemoteEvent
local readyRE: RemoteEvent

local function coinLocations(): { Instance }
	return CollectionService:GetTagged(TagsConfig.Coin)
end

-- Sample a Poisson(lambda) count via Knuth's algorithm.
local function samplePoisson(lambda: number): number
	local L = math.exp(-lambda)
	local k = 0
	local p = 1
	repeat
		k += 1
		p *= math.random()
	until p <= L
	return k - 1
end

-- Random reward snapped to ValueStep, inclusive of both ends of the range.
local function rollValue(): number
	local c = CoinsConfig
	local steps = math.floor((c.ValueMax - c.ValueMin) / c.ValueStep)
	local k = math.min(samplePoisson(c.ValuePoissonMean), steps)
	return c.ValueMin + k * c.ValueStep
end

-- Blue-coin Diamonds reward: integer in [Min, Max], skewed toward Min via
-- random()^BiasExponent (1 = uniform; higher = more mass near Min).
local function rollBlueDiamonds(): number
	local d = CoinsConfig.BlueDiamonds
	local t = math.random() ^ d.BiasExponent
	return d.Min + math.floor(t * (d.Max - d.Min + 1))
end

local function rollCoin(): CoinEntry
	if math.random() < CoinsConfig.BlueChance then
		return { value = rollBlueDiamonds(), isBlue = true }
	end
	return { value = rollValue(), isBlue = false }
end

local function scheduleNext(state: PlayerState)
	local c = CoinsConfig
	state.nextSpawn = os.clock() + c.SpawnIntervalMin
		+ math.random() * (c.SpawnIntervalMax - c.SpawnIntervalMin)
end

-- Activate one currently-inactive location for this player, if there's room and a free spot.
local function spawnFor(player: Player, state: PlayerState)
	if state.count >= CoinsConfig.MaxActive then
		return
	end
	local candidates: { Instance } = {}
	for _, coin in coinLocations() do
		if not state.active[coin] then
			table.insert(candidates, coin)
		end
	end
	if #candidates == 0 then
		return
	end
	local coin = candidates[math.random(1, #candidates)]
	local entry = rollCoin()
	state.active[coin] = entry
	state.count += 1
	activateRE:FireClient(player, coin, entry.value, entry.isBlue)
end

-- Force one immediate activation for `player`, bypassing the normal spawn timer — used by the
-- tutorial's "collect a coin" step so it never has to wait out a real spawn interval. A no-op
-- (returns false) if the player isn't ready yet, is already at MaxActive, or there's no free
-- location; otherwise behaves exactly like a normal spawn (same activateRE push).
function CoinService.ForceSpawn(player: Player): boolean
	local state = states[player]
	if not state or not state.ready then
		return false
	end
	local before = state.count
	spawnFor(player, state)
	return state.count > before
end

-- Client is listening: seed its initial coins and start its spawn timer. Re-ready (e.g. a
-- client re-init) just replays the current active set so nothing is lost.
local function onReady(player: Player)
	local state = states[player]
	if not state then
		return
	end
	if state.ready then
		for coin, entry in state.active do
			activateRE:FireClient(player, coin, entry.value, entry.isBlue)
		end
		return
	end
	state.ready = true
	for _ = 1, CoinsConfig.InitialSpawn do
		spawnFor(player, state)
	end
	scheduleNext(state)
end

-- Client touched a coin and wants to claim it. Validate against this player's active set,
-- award, announce, and deactivate. Always deactivate on the client so a stray/stale claim
-- can't leave a coin stuck hidden.
local function onClaim(player: Player, coin: Instance)
	local state = states[player]
	if not state then
		return
	end
	local entry = state.active[coin]
	if not entry then
		deactivateRE:FireClient(player, coin)
		return
	end
	state.active[coin] = nil
	state.count -= 1
	if entry.isBlue then
		CosmeticService.AddCC(player, entry.value)
		WarnUI.Warn(player, "+" .. StringUtils.FormatShort(entry.value) .. " Diamonds", DIAMOND_REWARD_COLOR, CoinsConfig.RewardWarnLifetime)
	else
		CurrencyService.AddPoints(player, entry.value, "Coin pickup")
		WarnUI.Warn(player, "+$" .. StringUtils.FormatShort(entry.value), REWARD_COLOR, CoinsConfig.RewardWarnLifetime)
	end
	SoundService.PlayForClient(player, { soundId = SoundsConfig.Collect3 })
	deactivateRE:FireClient(player, coin)
end

local function onPlayerAdded(player: Player)
	states[player] = { active = {}, count = 0, ready = false, nextSpawn = math.huge }
end

local function onPlayerRemoving(player: Player)
	states[player] = nil
end

-- Coins must never interfere with the ball simulation or block players (visibility is per
-- player, handled on the client). Make them inert + static, authoritatively, for everyone.
local function makeInert(coin: Instance)
	if coin:IsA("BasePart") then
		coin.CanCollide = false
		coin.Anchored = true
	end
	for _, d in coin:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Anchored = true
		end
	end
end

function CoinService.Init()
	activateRE = CoinNet.CoinActivate
	deactivateRE = CoinNet.CoinDeactivate
	claimRE = CoinNet.CoinClaim
	readyRE = CoinNet.CoinReady
	local forceSpawnRE = CoinNet.ForceSpawnCoin

	for _, coin in coinLocations() do
		makeInert(coin)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.Coin):Connect(makeInert)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.Coin):Connect(function(coin)
		for _, state in states do
			if state.active[coin] then
				state.active[coin] = nil
				state.count -= 1
			end
		end
	end)

	claimRE.OnServerEvent:Connect(function(player, coin)
		if typeof(coin) == "Instance" then
			onClaim(player, coin)
		end
	end)
	readyRE.OnServerEvent:Connect(onReady)
	forceSpawnRE.OnServerEvent:Connect(function(player: Player)
		CoinService.ForceSpawn(player)
	end)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Spawn ticker: once a ready player's timer elapses, activate a coin and reschedule.
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for player, state in states do
			if state.ready and now >= state.nextSpawn then
				spawnFor(player, state)
				scheduleNext(state)
			end
		end
	end)
end

return CoinService
