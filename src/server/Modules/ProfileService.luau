--!strict
-- Sole authority over per-player upgrade & loadout state.
--
-- Design rule: store RAW purchased state, derive effective stats on demand.
-- The profile holds upgrade *tiers* (integers) and loadout *positions*;
-- effective maxBet / V_JACK / flatPerBounce / baseAdditive / axis ranges are
-- pure functions of (tier, Config) computed by the derivers below. Never store
-- a derived value — that reintroduces the mirror-desync class of bug.
--
-- Two tables, deliberately different mutation semantics:
--   upgrades — purchased progression (§2 + §3 unlocks). Monotonic, cost-gated.
--              Only a purchase service should call SetUpgradeTier. Holds a tier
--              for every Config.Upgrades track AND every Config.Axes axis.
--   loadout  — the player's free choices (§3 positions + bet/N/phase). Set
--              freely within bounds the upgrades unlock; every setter validates.
--
-- Upgrades come in two flavors (see Config):
--   output-scaling (FlatRate, BaseAdditive) — scalar multipliers used in scoring
--   constraint     (MaxBet, Frequency, and every Config.Axes axis) — bound a
--                    paired loadout value's range/cap.
--
-- Currency lives in CurrencyService (spent, not upgraded). This module mirrors
-- CurrencyService's structure: per-userId table, Changed signal, lifecycle.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Config = require(RS.Shared.Config)
local Signal = require(RS.Shared.Signal)
-- Derivation lives in ProfileStats (pure). ProfileService → ProfileStats only;
-- ProfileStats does not require back, so there is no circular dependency.
local ProfileStats = require(RS.Shared.ProfileStats)

local ProfileService = {}

-- Tiers are keyed by string so adding a track/axis in Config needs no change
-- here. Named derivers (GetMaxBet, etc.) document the meaningful ones.
export type Upgrades = { [string]: number }

export type Loadout = {
	Bet: number,
	LaunchPhase: number,
	axes: { [string]: number }, -- continuous synergetic axis positions (Weight, Size, ...)
}

export type Profile = {
	upgrades: Upgrades,
	loadout: Loadout,
}

-- profiles[userId] = Profile
local profiles: { [number]: Profile } = {}

-- (player, profile) — fired after any mutation so UI/services can react.
ProfileService.Changed = Signal.new()
-- (player, profile) -- Fired along with ProfileService.Changed
local ProfileChangedRE: RemoteEvent = RS.Remote.ProfileChanged

-- (player, axis, value) -- Invoked by player, request to change axis value
local SetAxisRF: RemoteFunction = RS.Remote.SetAxis


--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function newProfile(): Profile
	local upgrades: Upgrades = {}
	-- Every upgrade track and every continuous axis starts at tier 0.
	for name in Config.Upgrades do
		upgrades[name] = 0
	end

	for name in Config.Axes do
		upgrades[name] = 0
	end

	-- Axis positions default from their single definition site (Config.Axes).
	local axes: { [string]: number } = {}
	for name, def in Config.Axes do
		axes[name] = def.Default
	end

	local d = Config.LoadoutDefaults
	return {
		upgrades = upgrades,
		loadout = {
			Bet = d.Bet,
			LaunchPhase = d.LaunchPhase,
			axes = axes,
		},
	}
end

-- Internal get-or-error. A profile always exists for an in-game player; a miss
-- means a lifecycle ordering bug, so surface it rather than silently defaulting.
local function get(player: Player): Profile
	local profile = profiles[player.UserId]
	assert(profile, "No profile for " .. player.Name .. " (lifecycle ordering?)")
	return profile
end

-- Re-clamp every bounded loadout value against current unlocked bounds. Called
-- after a tier change (a raised cap never invalidates, but a re-tuned Config or
-- future tier-down would, and this keeps derived state consistent regardless).
-- Defined before its first use; forward-declared local so SetUpgradeTier can
-- reference it.
local reclampLoadout: (profile: Profile) -> ()

--------------------------------------------------------------------------------
-- Raw access
--------------------------------------------------------------------------------

function ProfileService.Get(player: Player): Profile
	return get(player)
end

function ProfileService.GetUpgradeTier(player: Player, track: string): number
	return get(player).upgrades[track] or 0
end

-- Sets an upgrade tier outright. Intended for a purchase service that has
-- already validated cost; this module owns no cost logic. Clamped non-decreasing
-- (upgrades are monotonic). Re-clamps loadout, since raising a tier can change a
-- paired bound.
function ProfileService.SetUpgradeTier(player: Player, track: string, tier: number)
	local profile = get(player)
	if profile.upgrades[track] == nil then
		warn("SetUpgradeTier: unknown track '" .. tostring(track) .. "'")
		return
	end
	profile.upgrades[track] = math.max(tier, profile.upgrades[track])
	reclampLoadout(profile)
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile)
end

function ProfileService.GetLoadout(player: Player): Loadout
	return get(player).loadout
end

--------------------------------------------------------------------------------
-- Raw state access for derivation
--------------------------------------------------------------------------------
-- Derived stats (max bet, V_JACK, flat-per-bounce, ...) live in ProfileStats.
-- Gameplay derives via: ProfileStats.GetMaxBet(ProfileService.GetUpgrades(player)).

-- The raw tier map, for ProfileStats to derive from. Returned by reference;
-- mutate only through SetUpgradeTier.
function ProfileService.GetUpgrades(player: Player): ProfileStats.Upgrades
	return get(player).upgrades
end

-- Current position of a continuous axis (raw loadout read, not a derivation).
function ProfileService.GetAxis(player: Player, axis: string): number
	return get(player).loadout.axes[axis]
end

--------------------------------------------------------------------------------
-- Loadout setters (validated server-side, within unlocked bounds)
--------------------------------------------------------------------------------

-- Bet: 0 .. effective max bet.
function ProfileService.SetBet(player: Player, bet: number)
	if type(bet) ~= "number" or bet ~= bet then
		return -- reject non-number / NaN
	end
	local profile = get(player)
	profile.loadout.Bet = math.clamp(bet, 0, ProfileStats.GetMaxBet(profile.upgrades))
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile)
end

-- -- Ball count N: 1 .. unlocked frequency cap.
-- function ProfileService.SetBallCount(player: Player, n: number)
-- 	if type(n) ~= "number" or n ~= n then
-- 		return
-- 	end
-- 	local profile = get(player)
-- 	profile.loadout.BallCount = math.clamp(math.floor(n), 1, ProfileStats.GetBallCountCap(profile.upgrades))
-- 	ProfileService.Changed:Fire(player, profile)
-- end

-- Launch phase: 0 .. 1 (no upgrade gate yet; becomes an axis with Launcher Arc).
function ProfileService.SetLaunchPhase(player: Player, phase: number)
	if type(phase) ~= "number" or phase ~= phase then
		return
	end
	local profile = get(player)
	profile.loadout.LaunchPhase = math.clamp(phase, 0, 1)
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile)
end

-- Generic continuous-axis setter (Weight, Size, ...): clamps to the tier range.
function ProfileService.SetAxis(player: Player, axis: string, value: number): boolean
	if Config.Axes[axis] == nil then
		warn("SetAxis: unknown axis '" .. tostring(axis) .. "'")
		return false
	end
	if type(value) ~= "number" or value ~= value then
		return false
	end
	local profile = get(player)
	local min, max = ProfileStats.GetAxisRange(profile.upgrades, axis)
	profile.loadout.axes[axis] = math.clamp(value, min, max)
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile) -- authoritative value back to the client (e.g. UI revert)
	return true
end

-- (definition for the forward-declared local above; assigns the local, not a
-- global, so the reference in SetUpgradeTier resolves)
reclampLoadout = function(profile: Profile)
	local upgrades = profile.upgrades
	profile.loadout.Bet = math.clamp(profile.loadout.Bet, 0, ProfileStats.GetMaxBet(upgrades))
	for axis in Config.Axes do
		local min, max = ProfileStats.GetAxisRange(upgrades, axis)
		profile.loadout.axes[axis] = math.clamp(profile.loadout.axes[axis], min, max)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	profiles[player.UserId] = newProfile()
	-- later: profiles[player.UserId] = DataService.LoadProfile(player)
	ProfileService.Changed:Fire(player, profiles[player.UserId])
	ProfileChangedRE:FireClient(player, profiles[player.UserId])
end

local function onPlayerRemoving(player: Player)
	-- later: DataService.SaveProfile(player, profiles[player.UserId])
	profiles[player.UserId] = nil
end

function ProfileService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	RS.Remote.GetProfile.OnServerInvoke = get
	SetAxisRF.OnServerInvoke = ProfileService.SetAxis
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end
end

return ProfileService
