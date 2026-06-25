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

local Signal = require(RS.Shared.Signal)

local StatsService = {}

export type Stats = {
	upgradesPurchased: number,
	cashMultiplier: number,
	ownsStarterPack: boolean,
	lastGroupRewardClaim: number, -- os.time() of the last group-reward claim (0 = never)
}

-- stats[userId] = Stats
local stats: { [number]: Stats } = {}

-- (player, stats) — fired after any change.
StatsService.Changed = Signal.new()

local function defaults(): Stats
	return { upgradesPurchased = 0, cashMultiplier = 1, ownsStarterPack = false, lastGroupRewardClaim = 0 }
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
	return get(player.UserId).ownsStarterPack
end

-- os.time() of the player's last group-reward claim (0 if they've never claimed).
function StatsService.GetLastGroupRewardClaim(player: Player): number
	return get(player.UserId).lastGroupRewardClaim
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

function StatsService.Init()
	local re = Instance.new("RemoteEvent")
	re.Name = "StatsChanged"
	re.Parent = RS.Remote
	statsChangedRE = re

	local rf = Instance.new("RemoteFunction")
	rf.Name = "GetStats"
	rf.Parent = RS.Remote
	rf.OnServerInvoke = function(player: Player)
		return StatsService.GetStats(player)
	end
end

return StatsService
