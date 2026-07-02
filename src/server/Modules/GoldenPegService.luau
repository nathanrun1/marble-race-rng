--!strict
-- Golden pegs (prestige perk, Config.GoldenPegs): every rebirth marks one more peg on the
-- board as "golden" for that player. The board is shared, so the set is PER-PLAYER: only
-- the owner's balls trigger their golden pegs, and only the owner sees them highlighted
-- (client GoldenPegView, fed by the GoldenPegsChanged remote + GetGoldenPegs snapshot).
--
-- This service owns the per-player set (grown on PrestigeService.Changed, stable within a
-- session otherwise) and the trigger bookkeeping: a golden peg fires at most once per ball
-- per peg, rolling clone (Config.GoldenPegs.CloneChance) vs double. The gameplay effect is
-- applied by ScoreHandler (it owns ball value); this service only rolls the outcome and
-- spawns the clone ball on request.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Config = require(RS.Shared.Config)
local BallService = require(SSS.Scripts.Modules.BallService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)

local GoldenPegService = {}

-- Mirrors BallLaunchService's per-player concurrency ceiling: a clone is skipped (the
-- double/clone roll is still consumed) when the owner is already at the cap.
local MAX_BALLS_PER_PLAYER = 160

-- Clone separation: the copy spawns nudged sideways with a slightly perturbed velocity so
-- the pair visibly splits instead of falling as one (balls don't collide with each other).
local CLONE_VELOCITY_JITTER = 4 -- studs/s of random horizontal velocity added to the copy

local pegs: { BasePart } = {}

-- userId -> set of that player's golden pegs.
local goldenSets: { [number]: { [BasePart]: true } } = {}
-- ball -> set of golden pegs this ball has already consumed (once per ball per peg).
local consumed: { [BasePart]: { [BasePart]: true } } = {}

local changedRE: RemoteEvent? = nil

local function gatherPegs()
	table.clear(pegs)
	local folder = workspace:FindFirstChild("Pegs")
	if not folder then
		warn("GoldenPegService: no Workspace.Pegs folder; golden pegs disabled")
		return
	end
	for _, inst in folder:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(pegs, inst)
		end
	end
end

local function setToArray(set: { [BasePart]: true }): { BasePart }
	local arr: { BasePart } = {}
	for peg in set do
		table.insert(arr, peg)
	end
	return arr
end

local function pushToClient(player: Player)
	if changedRE then
		changedRE:FireClient(player, setToArray(goldenSets[player.UserId] or {}))
	end
end

-- Grow (or rebuild) the player's golden set to match their prestige count. Growth keeps
-- the existing pegs and adds random new ones, so the set is stable within a session; a
-- count DECREASE (dev reset) rebuilds from scratch.
local function syncSet(player: Player, prestigeCount: number)
	local want = math.min(prestigeCount, Config.GoldenPegs.MaxPegs, #pegs)
	local set = goldenSets[player.UserId]
	if not set then
		set = {}
		goldenSets[player.UserId] = set
	end
	local have = 0
	for _ in set do
		have += 1
	end
	if want == have then
		return
	end
	if want < have then
		table.clear(set)
		have = 0
	end
	-- Add (want - have) random pegs not already golden for this player.
	local candidates: { BasePart } = {}
	for _, peg in pegs do
		if not set[peg] then
			table.insert(candidates, peg)
		end
	end
	for _ = have + 1, want do
		if #candidates == 0 then
			break
		end
		local idx = math.random(#candidates)
		set[table.remove(candidates, idx) :: BasePart] = true
	end
	pushToClient(player)
end

-- Whether this peg is golden for the ball's owner AND hasn't been consumed by this ball
-- yet; if so, consume it and roll the outcome. Called by ScoreHandler on every peg hit.
function GoldenPegService.TryConsume(ball: BasePart, peg: Instance, ownerUserId: number?): ("double" | "clone")?
	if not ownerUserId or not peg:IsA("BasePart") then
		return nil
	end
	local set = goldenSets[ownerUserId]
	if not set or not set[peg] then
		return nil
	end
	local ballConsumed = consumed[ball]
	if ballConsumed and ballConsumed[peg] then
		return nil
	end
	if not ballConsumed then
		ballConsumed = {}
		consumed[ball] = ballConsumed
	end
	ballConsumed[peg] = true
	return if math.random() < Config.GoldenPegs.CloneChance then "clone" else "double"
end

-- Spawn the "clone" outcome: a second free ball of the same (current) value, copying the
-- original's size/weight, next to it with a nudged velocity. Returns whether it spawned
-- (skipped at the concurrency cap so a clone chain can't run away).
function GoldenPegService.SpawnClone(ball: BasePart, value: number, ownerUserId: number): boolean
	if BallService.GetLiveCount(ownerUserId) >= MAX_BALLS_PER_PLAYER then
		return false
	end
	local angle = math.random() * 2 * math.pi
	local sideways = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local jitter = sideways * (math.random() * CLONE_VELOCITY_JITTER)
	BallService.Spawn(ball.Position + sideways * (ball.Size.X * 0.75 + 0.2), {
		ownerUserId = ownerUserId,
		velocity = ball.AssemblyLinearVelocity + jitter,
		initialValue = value,
		weight = ball:GetAttribute(Config.Attributes.Weight) :: number?,
		size = ball:GetAttribute(Config.Attributes.Size) :: number?,
	})
	return true
end

function GoldenPegService.Init()
	gatherPegs()

	local re = Instance.new("RemoteEvent")
	re.Name = "GoldenPegsChanged"
	re.Parent = RS.Remote
	changedRE = re

	-- Snapshot for a client that binds after its set was pushed (join-time race).
	local rf = Instance.new("RemoteFunction")
	rf.Name = "GetGoldenPegs"
	rf.Parent = RS.Remote
	rf.OnServerInvoke = function(player: Player)
		return setToArray(goldenSets[player.UserId] or {})
	end

	-- Changed fires on join load, every banking, and every prestige — the set self-heals
	-- to the current count without a dedicated "prestiged" hook.
	PrestigeService.Changed:Connect(function(player: Player, info: PrestigeService.PrestigeInfo)
		syncSet(player, info.count)
	end)
	for _, player in Players:GetPlayers() do
		syncSet(player, PrestigeService.GetCount(player))
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		goldenSets[player.UserId] = nil
	end)
	BallService.BallDespawned:Connect(function(ball: BasePart)
		consumed[ball] = nil
	end)
end

return GoldenPegService
