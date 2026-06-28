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
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

local PlaytimeBonusService = {}

-- (player, info) — fired when a rung becomes available, is claimed, or on load.
PlaytimeBonusService.Changed = Signal.new()

export type PlaytimeData = {
	total: number,   -- cumulative seconds played (persisted; the live value adds the session)
	claimed: number, -- number of ladder rungs already claimed
}

type State = {
	base: number,         -- persisted seconds at load
	sessionStart: number, -- os.clock() captured at load; session elapsed = now - this
	claimed: number,
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
	local nextTime: number? = nil
	for i, rung in rungs() do
		local isReached = i <= reached
		local isClaimed = i <= state.claimed
		rungInfos[i] = { time = rung.Time, reward = rung.Reward, reached = isReached, claimed = isClaimed }
		if isReached and not isClaimed then
			availableReward += rung.Reward
		end
		if not isReached and nextTime == nil then
			nextTime = rung.Time
		end
	end
	return {
		total = total,
		claimedCount = state.claimed,
		availableCount = math.max(0, reached - state.claimed),
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

-- Claim every reached-but-unclaimed rung at once. Returns the cash granted (0 if none).
function PlaytimeBonusService.Claim(player: Player): number
	local state = states[player]
	if not state then
		return 0
	end
	local reached = reachedCount(liveTotal(state))
	if reached <= state.claimed then
		return 0
	end
	local reward = 0
	for i = state.claimed + 1, reached do
		reward += rungs()[i].Reward
	end
	state.claimed = reached
	state.lastReached = reached
	if reward > 0 then
		CurrencyService.AddPoints(player, reward, "Playtime bonus")
	end
	fireChanged(player, state)
	return reward
end

----------------------------------------------------------------
-- Data lifecycle (DataService-driven; never a direct DataStore call).
----------------------------------------------------------------
function PlaytimeBonusService.ApplyData(player: Player, saved: PlaytimeData?)
	local base = (saved and saved.total) or 0
	local state: State = {
		base = base,
		sessionStart = os.clock(),
		claimed = (saved and saved.claimed) or 0,
		lastReached = reachedCount(base),
	}
	states[player] = state
	fireChanged(player, state)
end

function PlaytimeBonusService.SerializeData(player: Player): PlaytimeData
	local state = states[player]
	if not state then
		return { total = 0, claimed = 0 }
	end
	return { total = liveTotal(state), claimed = state.claimed }
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
	;(getRemote("ClaimPlaytimeBonus", "RemoteFunction") :: RemoteFunction).OnServerInvoke = function(player: Player)
		local granted = PlaytimeBonusService.Claim(player)
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
