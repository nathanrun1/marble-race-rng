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

local Signal = require(RS.Shared.Utility.Signal)
local StatsNet = require(RS.Shared.Remote.StatsNet)
local AdminConfig = require(RS.Shared.Config.Admin)
local BallAverageConfig = require(RS.Shared.Config.BallAverage)
local BallAverage = require(RS.Shared.BallAverage)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)

local StatsService = {}

export type Stats = {
	upgradesPurchased: number,
	cashMultiplier: number,
	-- Timed cash boost (starter pack): multiplies banked cash while os.time() < boostUntil.
	boostMult: number,
	boostUntil: number,
	ownsStarterPack: boolean,
	lastGroupRewardClaim: number, -- os.time() of the last group-reward claim (0 = never)
	completedTutorial: boolean,   -- whether the join tutorial has been finished/skipped
	completedCosmeticTutorial: boolean, -- the later afford-a-Marble-Box cosmetics-shop tutorial
	completedTuningTutorial: boolean,   -- the first-axis-upgrade ball-tuning tutorial
	completedLoadoutTutorial: boolean,  -- the first-new-skin loadout tutorial
	-- Oldest-first, newest last; capped at BallAverageConfig.Window entries (PrestigeService
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
		boostMult = 1,
		boostUntil = 0,
		ownsStarterPack = false,
		lastGroupRewardClaim = 0,
		completedTutorial = false,
		completedCosmeticTutorial = false,
		completedTuningTutorial = false,
		completedLoadoutTutorial = false,
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

-- The timed boost's multiplier if its window is still running, else 1.
function StatsService.GetCashBoost(player: Player): number
	local s = get(player.UserId)
	return if os.time() < s.boostUntil then s.boostMult else 1
end

function StatsService.OwnsStarterPack(player: Player): boolean
	-- Admins never count as owning the starter pack, so none of its perks (post-prestige
	-- free tiers, etc.) apply to them, even if they own the game pass.
	if AdminConfig.IsAdmin(player.UserId) then
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
-- BallAverageConfig.Window balls banked (see BallAverage/BallAverageConfig), 0 if none banked
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

-- Start (or restart) a timed cash boost: `mult`× banked cash for `seconds` from now.
-- A fresh grant of a lower multiplier still applies — last grant wins.
function StatsService.GrantCashBoost(player: Player, mult: number, seconds: number)
	local s = stats[player.UserId]
	if not s or mult <= 0 or seconds <= 0 then
		return
	end
	s.boostMult = mult
	s.boostUntil = os.time() + seconds
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

-- Same for the later cosmetics-shop tutorial (fires at 50 Diamonds). Idempotent.
function StatsService.SetCompletedCosmeticTutorial(player: Player)
	local s = stats[player.UserId]
	if not s or s.completedCosmeticTutorial then
		return
	end
	s.completedCosmeticTutorial = true
	announce(player)
end

-- Same for the loadout tutorial (fires on the first non-default skin). Idempotent.
function StatsService.SetCompletedLoadoutTutorial(player: Player)
	local s = stats[player.UserId]
	if not s or s.completedLoadoutTutorial then
		return
	end
	s.completedLoadoutTutorial = true
	announce(player)
end

-- Same for the ball-tuning tutorial (fires on the first axis-tier upgrade). Idempotent.
function StatsService.SetCompletedTuningTutorial(player: Player)
	local s = stats[player.UserId]
	if not s or s.completedTuningTutorial then
		return
	end
	s.completedTuningTutorial = true
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
	s.recentBalls = table.create(BallAverageConfig.Window, avg)
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
		if type(saved.boostMult) == "number" and saved.boostMult > 0 then
			s.boostMult = saved.boostMult
		end
		if type(saved.boostUntil) == "number" then
			s.boostUntil = saved.boostUntil
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
		if type(saved.completedCosmeticTutorial) == "boolean" then
			s.completedCosmeticTutorial = saved.completedCosmeticTutorial
		end
		if type(saved.completedTuningTutorial) == "boolean" then
			s.completedTuningTutorial = saved.completedTuningTutorial
		end
		if type(saved.completedLoadoutTutorial) == "boolean" then
			s.completedLoadoutTutorial = saved.completedLoadoutTutorial
		end
		if type(saved.recentBalls) == "table" then
			for _, v in saved.recentBalls do
				if type(v) == "number" then
					table.insert(s.recentBalls, v)
				end
			end
			-- Window may have shrunk since this was saved; trim from the front (oldest) so it
			-- reads back as exactly the last Window balls, same as Push would produce live.
			while #s.recentBalls > BallAverageConfig.Window do
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
	statsChangedRE = StatsNet.StatsChanged

	StatsNet.GetStats.OnServerInvoke = function(player: Player)
		return StatsService.GetStats(player)
	end

	-- Client tells us once a tutorial is finished or skipped, so it never replays. `which`
	-- picks the flag: "cosmetic" for the 50-Diamonds tutorial, "tuning" for the ball-tuning
	-- one, anything else (incl. the old no-arg call) for the join tutorial.
	StatsNet.CompleteTutorial.OnServerEvent:Connect(function(player: Player, which: any)
		if which == "cosmetic" then
			StatsService.SetCompletedCosmeticTutorial(player)
		elseif which == "tuning" then
			StatsService.SetCompletedTuningTutorial(player)
		elseif which == "loadout" then
			StatsService.SetCompletedLoadoutTutorial(player)
		else
			StatsService.SetCompletedTutorial(player)
		end
	end)
end

return StatsService
