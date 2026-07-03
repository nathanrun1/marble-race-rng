--!strict
-- Per-player persisted meta-state that several systems read/write but that doesn't
-- belong to Currency / Profile / Prestige:
--   * upgradesPurchased — lifetime count of upgrade tiers acquired (NOT reset by
--                         prestige). Gates starter-pack availability.
--   * cashMultiplier    — permanent global multiplier on banked cash (Robux perk).
--   * ownsStarterPack   — whether the one-time starter pack was bought (drives the
--                         post-prestige free-tier perk and hides the shop button).
--
-- Passive data service, same shape as CurrencyService: DataService owns the lifecycle
-- (ApplyData / SerializeData / Clear), this just holds state, mutates it, and pushes
-- changes. Pure data — registers no product handlers (that's MonetizationService), so
-- it has no dependency on the purchase/lifecycle services that depend on it.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Signal = require(RS.Shared.Signal)
local Config = require(RS.Shared.Config)
local BallAverage = require(RS.Shared.BallAverage)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

local StatsService = {}

export type Stats = {
	upgradesPurchased: number,
	cashMultiplier: number,
	ownsStarterPack: boolean,
	lastGroupRewardClaim: number, -- os.time() of the last group-reward claim (0 = never)
	completedTutorial: boolean,   -- whether the join tutorial has been finished/skipped
	-- Oldest-first, newest last; capped at Config.BallAverage.Window entries (PrestigeService
	-- empties this on rebirth). Feeds GetAvgMoneyPerBall via BallAverage.Compute.
	recentBalls: { number },
}

-- stats[userId] = Stats
local stats: { [number]: Stats } = {}

-- (player, stats) — fired after any change.
StatsService.Changed = Signal.new()

-- (player, avgMoneyPerBall) — fired on every ball banked, server-side only (no remote, no
-- StatsService.Changed announce: balls can bank many times a second, so this stays a cheap
-- in-process signal for consumers — the leaderstats column, the global leaderboard writer —
-- that want a fresh average without paying for a client round-trip on every ball).
StatsService.BallBanked = Signal.new()

-- (player, count) — fired only when upgrade tiers are actually acquired this session
-- (AddUpgradesPurchased), never on load. Consumers that must not mistake a loaded lifetime
-- total for fresh progress (QuestService) hook this instead of diffing Changed.
StatsService.UpgradesAdded = Signal.new()

local function defaults(): Stats
	return {
		upgradesPurchased = 0,
		cashMultiplier = 1,
		ownsStarterPack = false,
		lastGroupRewardClaim = 0,
		completedTutorial = false,
		recentBalls = {},
	}
end

-- Non-asserting: returns live state, or fresh defaults if the player isn't loaded yet
-- (so early readers — scoring, leaderboard — never error; they correct on Changed).
local function get(userId: number): Stats
	return stats[userId] or defaults()
end

local statsChangedRE: RemoteEvent? = nil

local function announce(player: Player)
	local s = get(player.UserId)
	StatsService.Changed:Fire(player, s)
	if statsChangedRE then
		statsChangedRE:FireClient(player, s)
	end
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

function StatsService.GetStats(player: Player): Stats
	return get(player.UserId)
end

function StatsService.GetUpgradesPurchased(player: Player): number
	return get(player.UserId).upgradesPurchased
end

function StatsService.GetCashMultiplier(player: Player): number
	return get(player.UserId).cashMultiplier
end

function StatsService.OwnsStarterPack(player: Player): boolean
	-- Admins never count as owning the starter pack, so none of its perks (post-prestige
	-- free tiers, etc.) apply to them, even if they own the game pass.
	if table.find(Config.Admins, player.UserId) then
		return false
	end
	return get(player.UserId).ownsStarterPack
end

-- os.time() of the player's last group-reward claim (0 if they've never claimed).
function StatsService.GetLastGroupRewardClaim(player: Player): number
	return get(player.UserId).lastGroupRewardClaim
end

function StatsService.HasCompletedTutorial(player: Player): boolean
	return get(player.UserId).completedTutorial
end

-- Server-authoritative $/marble: an exponentially-weighted average over only the last
-- Config.BallAverage.Window balls banked (see BallAverage/Config.BallAverage), 0 if none banked
-- yet this run. This is what feeds the global money/ball leaderboard — it can't be spoofed
-- since it's derived purely from banked cash the server itself credited.
function StatsService.GetAvgMoneyPerBall(player: Player): number
	return BallAverage.Compute(get(player.UserId).recentBalls)
end

--------------------------------------------------------------------------------
-- Writes (each announces)
--------------------------------------------------------------------------------

-- Credit `count` acquired upgrade tiers (purchased or granted). Lifetime; never
-- decreases (prestige doesn't touch it).
function StatsService.AddUpgradesPurchased(player: Player, count: number)
	if count <= 0 then
		return
	end
	local s = stats[player.UserId]
	if not s then
		return
	end
	s.upgradesPurchased += count
	StatsService.UpgradesAdded:Fire(player, count)
	announce(player)
end

-- Raise the cash multiplier to `value` (never lowers it).
function StatsService.SetCashMultiplier(player: Player, value: number)
	local s = stats[player.UserId]
	if not s or value <= s.cashMultiplier then
		return
	end
	s.cashMultiplier = value
	announce(player)
end

-- Stamp the group-reward claim time to now (server-authoritative cooldown anchor).
function StatsService.SetGroupRewardClaimedNow(player: Player)
	local s = stats[player.UserId]
	if not s then
		return
	end
	s.lastGroupRewardClaim = os.time()
	announce(player)
end

-- Mark the join tutorial as done (finished or skipped). Idempotent.
function StatsService.SetCompletedTutorial(player: Player)
	local s = stats[player.UserId]
	if not s or s.completedTutorial then
		return
	end
	s.completedTutorial = true
	announce(player)
end

-- Dev only (DevService /avgball): force $/marble by filling the whole window with `avg` — a
-- weighted average of identical entries equals that entry regardless of weighting, so this
-- reads back as exactly avg. Everything derives from recentBalls — GetAvgMoneyPerBall, the
-- GetStats remote, and the BallBanked consumers (leaderstat column, luck leaderstat, overhead
-- billboard, global leaderboard writer) — so firing BallBanked propagates the forced value
-- everywhere at once. Future real banks then evict these forced entries one at a time.
function StatsService.SetAvgMoneyPerBall(player: Player, avg: number)
	local s = stats[player.UserId]
	if not s then
		return
	end
	avg = math.max(avg, 0)
	s.recentBalls = table.create(Config.BallAverage.Window, avg)
	StatsService.BallBanked:Fire(player, avg)
	announce(player)
end

-- Called by PrestigeService on a successful prestige: empties recentBalls so $/marble (the HUD
-- readout, the leaderstat, the global leaderboard) reflects the new run immediately instead of
-- carrying the old average forward.
function StatsService.ResetBallAverage(player: Player)
	local s = stats[player.UserId]
	if not s then
		return
	end
	table.clear(s.recentBalls)
	StatsService.BallBanked:Fire(player, 0)
	announce(player)
end

function StatsService.SetOwnsStarterPack(player: Player, owns: boolean)
	local s = stats[player.UserId]
	if not s or s.ownsStarterPack == owns then
		return
	end
	s.ownsStarterPack = owns
	announce(player)
end

--------------------------------------------------------------------------------
-- Lifecycle (driven by DataService)
--------------------------------------------------------------------------------

function StatsService.ApplyData(player: Player, saved: Stats?)
	local s = defaults()
	if saved then
		if type(saved.upgradesPurchased) == "number" then
			s.upgradesPurchased = saved.upgradesPurchased
		end
		if type(saved.cashMultiplier) == "number" then
			s.cashMultiplier = saved.cashMultiplier
		end
		if type(saved.ownsStarterPack) == "boolean" then
			s.ownsStarterPack = saved.ownsStarterPack
		end
		if type(saved.lastGroupRewardClaim) == "number" then
			s.lastGroupRewardClaim = saved.lastGroupRewardClaim
		end
		if type(saved.completedTutorial) == "boolean" then
			s.completedTutorial = saved.completedTutorial
		end
		if type(saved.recentBalls) == "table" then
			for _, v in saved.recentBalls do
				if type(v) == "number" then
					table.insert(s.recentBalls, v)
				end
			end
			-- Window may have shrunk since this was saved; trim from the front (oldest) so it
			-- reads back as exactly the last Window balls, same as Push would produce live.
			while #s.recentBalls > Config.BallAverage.Window do
				table.remove(s.recentBalls, 1)
			end
		end
	end
	stats[player.UserId] = s
	announce(player)
end

function StatsService.SerializeData(player: Player): Stats
	return get(player.UserId)
end

function StatsService.Clear(player: Player)
	stats[player.UserId] = nil
end

-- Same "Ball ..." reason convention CurrencyService uses for ball-bank credits (see
-- MoneyPerBallUI's isBallBank on the client) — everything else (coins, playtime, starter
-- pack, ...) uses a different reason and must not count toward the average.
local function isBallBank(reason: any): boolean
	return typeof(reason) == "string" and string.match(reason, "^Ball ") ~= nil
end

function StatsService.Init()
	local re = Instance.new("RemoteEvent")
	re.Name = "StatsChanged"
	re.Parent = RS.Remote

	-- Track recent ball earnings server-side (authoritative — CurrencyService only fires this
	-- from server-side banking logic, so it can't be spoofed by a client remote).
	CurrencyService.Changed:Connect(function(player: Player, _newBalance: number, delta: number, reason: any)
		if not isBallBank(reason) or delta <= 0 then
			return
		end
		local s = stats[player.UserId]
		if not s then
			return
		end
		BallAverage.Push(s.recentBalls, delta)
		StatsService.BallBanked:Fire(player, BallAverage.Compute(s.recentBalls))
	end)
	statsChangedRE = re

	local rf = Instance.new("RemoteFunction")
	rf.Name = "GetStats"
	rf.Parent = RS.Remote
	rf.OnServerInvoke = function(player: Player)
		return StatsService.GetStats(player)
	end

	-- Client tells us once the join tutorial is finished or skipped, so it never replays.
	local tutorialRE = Instance.new("RemoteEvent")
	tutorialRE.Name = "CompleteTutorial"
	tutorialRE.Parent = RS.Remote
	tutorialRE.OnServerEvent:Connect(function(player: Player)
		StatsService.SetCompletedTutorial(player)
	end)
end

return StatsService
