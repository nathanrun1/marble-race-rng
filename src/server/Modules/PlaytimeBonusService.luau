--!strict
-- Tracks each player's cumulative playtime and grants escalating, claimable cash bonuses from
-- Config.PlaytimeBonuses. Retention + early-game afloat: keep playing / come back, hit a time
-- rung, claim the cash.
--
-- Persistence goes through DataService (ApplyData / SerializeData / Clear) — this service
-- NEVER touches a DataStore directly, for orthogonality. Persisted data is { total, claimed }:
-- cumulative seconds played, and how many ladder rungs have been claimed. Rungs are ascending
-- by Time and claimed in order; a rung is "available" once total >= its Time and it isn't yet
-- claimed. Claiming grants every available rung at once.
--
-- This is the backend only. GetInfo / Claim / Changed (+ the three remotes) are the surface a
-- future Playtime UI will consume; nothing here is wired to any UI yet.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local Config = require(RS.Shared.Config)
local Signal = require(RS.Shared.Signal)
local StringUtils = require(RS.Shared.StringUtils)
local WarnUI = require(RS.Shared.WarnUI)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

local CLAIM_WARN_COLOR = Color3.fromRGB(90, 220, 120) -- green
local CLAIM_WARN_LIFETIME = 2.5

local PlaytimeBonusService = {}

-- (player, info) — fired when a rung becomes available, is claimed, or on load.
PlaytimeBonusService.Changed = Signal.new()

export type PlaytimeData = {
	total: number,      -- cumulative seconds played (persisted; the live value adds the session)
	claimed: { number }, -- indices of ladder rungs already claimed (rungs claim independently)
}

type State = {
	base: number,         -- persisted seconds at load
	sessionStart: number, -- os.clock() captured at load; session elapsed = now - this
	claimed: { [number]: boolean }, -- set of claimed rung indices
	lastReached: number,  -- last reachedCount we pushed a Changed for (rung-crossing throttle)
}

local states: { [Player]: State } = {}

local changedRE: RemoteEvent

local function rungs(): { { Time: number, Reward: number } }
	return Config.PlaytimeBonuses.Rungs
end

-- Live cumulative playtime = persisted base + this session's elapsed.
local function liveTotal(state: State): number
	return state.base + (os.clock() - state.sessionStart)
end

-- How many rungs the total has reached (rungs ascending by Time, so stop at the first miss).
local function reachedCount(total: number): number
	local n = 0
	for _, rung in rungs() do
		if total >= rung.Time then
			n += 1
		else
			break
		end
	end
	return n
end

export type RungInfo = { time: number, reward: number, reached: boolean, claimed: boolean }

export type Info = {
	total: number,           -- live cumulative seconds
	claimedCount: number,
	availableCount: number,  -- reached but unclaimed
	availableReward: number, -- cash claimable right now
	nextTime: number?,       -- Time of the next unreached rung (nil if all reached)
	rungs: { RungInfo },
}

local function buildInfo(state: State): Info
	local total = liveTotal(state)
	local reached = reachedCount(total)
	local rungInfos: { RungInfo } = {}
	local availableReward = 0
	local availableCount = 0
	local claimedCount = 0
	local nextTime: number? = nil
	for i, rung in rungs() do
		local isReached = i <= reached
		local isClaimed = state.claimed[i] == true
		rungInfos[i] = { time = rung.Time, reward = rung.Reward, reached = isReached, claimed = isClaimed }
		if isClaimed then
			claimedCount += 1
		end
		if isReached and not isClaimed then
			availableReward += rung.Reward
			availableCount += 1
		end
		if not isReached and nextTime == nil then
			nextTime = rung.Time
		end
	end
	return {
		total = total,
		claimedCount = claimedCount,
		availableCount = availableCount,
		availableReward = availableReward,
		nextTime = nextTime,
		rungs = rungInfos,
	}
end

local function fireChanged(player: Player, state: State)
	PlaytimeBonusService.Changed:Fire(player, buildInfo(state))
end

function PlaytimeBonusService.GetInfo(player: Player): Info?
	local state = states[player]
	if not state then
		return nil
	end
	return buildInfo(state)
end

-- Claim one specific rung (by index), if it's reached and not already claimed. Returns the
-- cash granted (0 if it wasn't claimable).
function PlaytimeBonusService.Claim(player: Player, index: number): number
	local state = states[player]
	if not state then
		return 0
	end
	local rung = rungs()[index]
	if not rung then
		return 0
	end
	if state.claimed[index] then
		return 0 -- already claimed
	end
	if liveTotal(state) < rung.Time then
		return 0 -- not reached yet
	end
	state.claimed[index] = true
	CurrencyService.AddPoints(player, rung.Reward, "Playtime bonus")
	WarnUI.Warn(player, "Playtime Bonus Claimed: $" .. StringUtils.FormatShort(rung.Reward), CLAIM_WARN_COLOR, CLAIM_WARN_LIFETIME)
	fireChanged(player, state)
	return rung.Reward
end

-- Dev only: set cumulative playtime directly (re-anchors the session so liveTotal == seconds).
function PlaytimeBonusService.SetPlaytime(player: Player, seconds: number)
	local state = states[player]
	if not state then
		return
	end
	state.base = seconds
	state.sessionStart = os.clock()
	state.lastReached = reachedCount(seconds)
	fireChanged(player, state)
end

----------------------------------------------------------------
-- Data lifecycle (DataService-driven; never a direct DataStore call).
----------------------------------------------------------------
function PlaytimeBonusService.ApplyData(player: Player, saved: PlaytimeData?)
	local base = (saved and saved.total) or 0
	local claimedSet: { [number]: boolean } = {}
	local savedClaimed = saved and (saved :: any).claimed
	if type(savedClaimed) == "number" then
		-- Legacy in-order count: the first N rungs were claimed.
		for i = 1, savedClaimed do
			claimedSet[i] = true
		end
	elseif type(savedClaimed) == "table" then
		for _, idx in savedClaimed do
			if type(idx) == "number" then
				claimedSet[idx] = true
			end
		end
	end
	local state: State = {
		base = base,
		sessionStart = os.clock(),
		claimed = claimedSet,
		lastReached = reachedCount(base),
	}
	states[player] = state
	fireChanged(player, state)
end

function PlaytimeBonusService.SerializeData(player: Player): PlaytimeData
	local state = states[player]
	if not state then
		return { total = 0, claimed = {} }
	end
	local arr: { number } = {}
	for idx, on in state.claimed do
		if on then
			table.insert(arr, idx)
		end
	end
	table.sort(arr)
	return { total = liveTotal(state), claimed = arr }
end

function PlaytimeBonusService.Clear(player: Player)
	states[player] = nil
end

local function getRemote(name: string, class: string): Instance
	local existing = RS.Remote:FindFirstChild(name)
	if existing then
		return existing
	end
	local r = Instance.new(class)
	r.Name = name
	r.Parent = RS.Remote
	return r
end

function PlaytimeBonusService.Init()
	changedRE = getRemote("PlaytimeChanged", "RemoteEvent") :: RemoteEvent
	;(getRemote("GetPlaytimeInfo", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		return PlaytimeBonusService.GetInfo(player)
	end
	;(getRemote("ClaimPlaytimeBonus", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player, index: any)
		local granted = if type(index) == "number" then PlaytimeBonusService.Claim(player, index) else 0
		return { granted = granted, info = PlaytimeBonusService.GetInfo(player) }
	end

	PlaytimeBonusService.Changed:Connect(function(player: Player, info: Info)
		changedRE:FireClient(player, info)
	end)

	-- Push an update the moment a new rung becomes available (so a future UI can glow the
	-- button), without per-frame spam: only when reachedCount actually increases.
	RunService.Heartbeat:Connect(function()
		for player, state in states do
			local reached = reachedCount(liveTotal(state))
			if reached > state.lastReached then
				state.lastReached = reached
				fireChanged(player, state)
			end
		end
	end)
end

return PlaytimeBonusService
