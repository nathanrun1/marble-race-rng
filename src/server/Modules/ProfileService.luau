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
	Bet: number,      -- derived: ProfileStats.GetBetSizeAtTier(BetTier). Set via SetBetTier
	                  -- (player-facing) or the dev-only SetBet (raw, bypasses the tier ladder).
	BetTier: number,  -- selected rung on the bet ladder, 0 .. the owned MaxBet tier
	LaunchPhase: number,
	axes: { [string]: number }, -- continuous synergetic axis positions (Weight, Size, ...)
}

export type Profile = {
	upgrades: Upgrades,
	loadout: Loadout,
	-- Track the player is mid-buying an "instant tiers" dev product on, if any.
	-- Persisted so a crash/rejoin between paying and the receipt processing still
	-- lets ProcessReceipt know which track to grant (see UpgradeService).
	pendingBoostTrack: string?,
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
			Bet = ProfileStats.GetBetSizeAtTier(0),
			BetTier = 0,
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

-- The track the player is mid-buying an instant-tiers product on (nil if none).
function ProfileService.GetPendingBoostTrack(player: Player): string?
	return get(player).pendingBoostTrack
end

-- Record (or clear, with nil) the pending instant-tiers track. Not a gameplay
-- mutation, so it doesn't fire Changed — nothing renders off it.
function ProfileService.SetPendingBoostTrack(player: Player, track: string?)
	get(player).pendingBoostTrack = track
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

-- Dev-only: set a raw continuous bet (0 .. effective max bet), bypassing the tier
-- ladder entirely. Never reachable from a client remote — DevService's chat commands
-- (BIG_BET stress-testing, /bet <n>) are the only callers, for statistical sampling
-- across bet sizes the ladder doesn't necessarily have a rung for. Does NOT touch
-- BetTier, so a later SetBetTier/upgrade purchase can still reclamp Bet back down to
-- whatever the actual selected rung derives to.
function ProfileService.SetBet(player: Player, bet: number)
	if type(bet) ~= "number" or bet ~= bet then
		return -- reject non-number / NaN
	end
	local profile = get(player)
	profile.loadout.Bet = math.clamp(bet, 0, ProfileStats.GetMaxBet(profile.upgrades))
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile)
end

-- Bet tier: 0 .. the player's owned MaxBet tier. A locked/unpurchased rung is never
-- settable here — the client's "one rung ahead" preview when Raise reaches an unowned
-- tier is a purely client-side visual; only Unlock's PurchaseUpgrade call can raise the
-- owned tier itself, after which the client re-selects it with another SetBetTier call.
-- Also derives loadout.Bet from the clamped tier so every existing consumer of
-- loadout.Bet (BallLaunchService, CurrencyService charge, ...) is unaffected. Returns
-- the actual (clamped) tier so the caller (a RemoteFunction) can hand it straight back.
function ProfileService.SetBetTier(player: Player, tier: number): number
	local profile = get(player)
	if type(tier) == "number" and tier == tier then
		local ownedBetTier = profile.upgrades.MaxBet or 0
		tier = math.clamp(math.floor(tier), 0, ownedBetTier)
		profile.loadout.BetTier = tier
		profile.loadout.Bet = ProfileStats.GetBetSizeAtTier(tier)
		ProfileService.Changed:Fire(player, profile)
		ProfileChangedRE:FireClient(player, profile)
	end
	return profile.loadout.BetTier
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

-- Wipes all upgrade tiers and resets the loadout to defaults. Used only by
-- PrestigeService — bypasses the monotonic guard intentionally.
function ProfileService.ResetProfile(player: Player)
	local profile = get(player)
	for name in Config.Upgrades do
		profile.upgrades[name] = 0
	end
	for name in Config.Axes do
		profile.upgrades[name] = 0
	end
	local axes: { [string]: number } = {}
	for name, def in Config.Axes do
		axes[name] = def.Default
	end
	local d = Config.LoadoutDefaults
	profile.loadout = { Bet = ProfileStats.GetBetSizeAtTier(0), BetTier = 0, LaunchPhase = d.LaunchPhase, axes = axes }
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile)
end

-- (definition for the forward-declared local above; assigns the local, not a
-- global, so the reference in SetUpgradeTier resolves)
reclampLoadout = function(profile: Profile)
	local upgrades = profile.upgrades
	profile.loadout.Bet = math.clamp(profile.loadout.Bet, 0, ProfileStats.GetMaxBet(upgrades))
	profile.loadout.BetTier = math.clamp(profile.loadout.BetTier, 0, upgrades.MaxBet or 0)
	for axis in Config.Axes do
		local min, max = ProfileStats.GetAxisRange(upgrades, axis)
		profile.loadout.axes[axis] = math.clamp(profile.loadout.axes[axis], min, max)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Build a profile from saved data, overlaying it on a fresh default so newly added
-- tracks/axes get their defaults and unknown saved keys are ignored. Loadout is
-- re-clamped to the unlocked bounds. Called by DataService on join.
function ProfileService.ApplyData(player: Player, saved: Profile?)
	local profile = newProfile()
	if saved then
		if saved.upgrades then
			for name in profile.upgrades do
				local tier = saved.upgrades[name]
				if type(tier) == "number" then
					profile.upgrades[name] = tier
				end
			end
		end
		if type(saved.pendingBoostTrack) == "string" then
			profile.pendingBoostTrack = saved.pendingBoostTrack
		end
		if saved.loadout then
			local sl = saved.loadout
			if type(sl.Bet) == "number" then
				profile.loadout.Bet = sl.Bet
			end
			if type(sl.BetTier) == "number" then
				profile.loadout.BetTier = sl.BetTier
			else
				-- Migrating an old save with no BetTier field: default to the owned
				-- MaxBet tier (players habitually maxed their bet under the old
				-- continuous system) rather than the fresh-profile default of 0,
				-- overriding the stale raw Bet number above with that tier's size.
				profile.loadout.BetTier = profile.upgrades.MaxBet or 0
				profile.loadout.Bet = ProfileStats.GetBetSizeAtTier(profile.loadout.BetTier)
			end
			if type(sl.LaunchPhase) == "number" then
				profile.loadout.LaunchPhase = sl.LaunchPhase
			end
			if sl.axes then
				for name in profile.loadout.axes do
					local v = sl.axes[name]
					if type(v) == "number" then
						profile.loadout.axes[name] = v
					end
				end
			end
		end
	end
	profiles[player.UserId] = profile
	reclampLoadout(profile)
	ProfileService.Changed:Fire(player, profile)
	ProfileChangedRE:FireClient(player, profile)
end

-- The profile to persist for this player.
function ProfileService.SerializeData(player: Player): Profile
	return get(player)
end

function ProfileService.Clear(player: Player)
	profiles[player.UserId] = nil
end

-- SetBetTier isn't Studio-authored under RS.Remote like GetProfile/SetAxis are, so
-- create it on demand (same create-if-missing pattern UpgradeService/CosmeticService
-- use for their remotes).
local function getRemoteFunction(name: string): RemoteFunction
	local existing = RS.Remote:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing :: RemoteFunction
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = RS.Remote
	return rf
end

function ProfileService.Init()
	RS.Remote.GetProfile.OnServerInvoke = get
	SetAxisRF.OnServerInvoke = ProfileService.SetAxis
	-- Client (RaiseBtn/LowerBtn) sends the tier it wants; returns the actual
	-- (server-clamped) tier so the UI can just render whatever comes back.
	getRemoteFunction("SetBetTier").OnServerInvoke = function(player: Player, tier: any)
		if type(tier) ~= "number" then
			return get(player).loadout.BetTier
		end
		return ProfileService.SetBetTier(player, tier)
	end
end

return ProfileService
