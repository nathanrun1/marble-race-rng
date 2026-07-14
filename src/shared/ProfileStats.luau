--!strict
-- Pure derivation of effective gameplay stats from a player's raw upgrade tiers.
--
-- Stateless: every function takes the raw `upgrades` map (as stored by
-- ProfileService) plus Config, and returns a derived quantity. It deliberately
-- does NOT require ProfileService:
--   * ProfileService uses these for its own loadout clamping, so a dependency
--     back on ProfileService would be a circular require.
--   * Being pure, stats can be derived from any hypothetical upgrade set — e.g.
--     previewing what max bet *would* be after a purchase, without mutating.
--
-- Consumers fetch the upgrades from ProfileService and pass them in:
--   local stats = ProfileStats.GetMaxBet(ProfileService.GetUpgrades(player))

local RS = game:GetService("ReplicatedStorage")
local EconomyConfig = require(RS.Shared.Config.Economy)
local UpgradesConfig = require(RS.Shared.Config.Upgrades)
local StringUtils = require(RS.Shared.Utility.StringUtils)

local ProfileStats = {}

-- Raw tier map: { [trackOrAxisName] = tier }. Mirrors ProfileService's storage.
export type Upgrades = { [string]: number }

local function tier(upgrades: Upgrades, track: string): number
	return upgrades[track] or 0
end

-- Bet size at an arbitrary ladder tier (tier 0 = the free starting rung, no purchase
-- needed). Pure — no upgrades/ownership dependency — so callers can preview a tier the
-- player doesn't own yet (the client BetUI's "one rung ahead" locked preview, or the
-- board-appearance view scaling off a selected-but-not-yet-launched tier).
--   betSize(0)      = Economy.StartBetSize            (10)
--   betSize(t >= 1) = Economy.StartMaxBet * PerTier^(t - 1)   (tier 1 = 40, the old tier 0)
function ProfileStats.GetBetSizeAtTier(tier: number): number
	if tier <= 0 then
		return EconomyConfig.StartBetSize
	end
	return EconomyConfig.StartMaxBet * (UpgradesConfig.Tracks.MaxBet.PerTier ^ (tier - 1))
end

-- Effective max bet: the bet size at the tier the player actually OWNS (cap for
-- loadout.Bet, and the anchor VJack/Trickle scale off). Kept under this name so
-- existing call sites (VJack, Trickle, BallLaunchService, ProfileService clamps, ...)
-- don't need to change.
function ProfileStats.GetMaxBet(upgrades: Upgrades): number
	return ProfileStats.GetBetSizeAtTier(tier(upgrades, "MaxBet"))
end

-- V_JACK: value a single ball must carry to clear the jackpot gate (§1.3).
function ProfileStats.GetVJack(upgrades: Upgrades): number
	return EconomyConfig.VJackFraction * ProfileStats.GetMaxBet(upgrades)
end

-- Flat points paid per qualifying peg bounce (§1.4), output-scaling track.
function ProfileStats.GetFlatPerBounce(upgrades: Upgrades): number
	local track = UpgradesConfig.Tracks.FlatRate
	return track.Base * (track.PerTier ^ tier(upgrades, "FlatRate"))
end

-- Additive bonus fraction on final slot payout (§2), output-scaling track.
function ProfileStats.GetBaseAdditive(upgrades: Upgrades): number
	local t = tier(upgrades, "BaseAdditive")
	return UpgradesConfig.Tracks.BaseAdditive.Base + UpgradesConfig.Tracks.BaseAdditive.C1 * t + UpgradesConfig.Tracks.BaseAdditive.C2 * t^2 + UpgradesConfig.Tracks.BaseAdditive.C3 * t^3
end

-- Cap on ball count N unlocked at the current frequency tier (§3 axis A). The
-- ceiling, not the chosen N (that is loadout.BallCount, ≤ this).
-- function ProfileStats.GetBallCountCap(upgrades: Upgrades): number
-- 	local caps = UpgradesConfig.Tracks.Frequency.Caps
-- 	return caps[math.clamp(tier(upgrades, "Frequency") + 1, 1, #caps)]
-- end

-- Seconds a launch slot stays on cooldown after firing (PER-SLOT LAUNCH REWORK: every
-- owned slot launches independently; this one Frequency-scaled delay applies to each).
function ProfileStats.GetLaunchDelay(upgrades: Upgrades): number
	return math.max(1/60, UpgradesConfig.Tracks.Frequency.Base * (UpgradesConfig.Tracks.Frequency.PerTier ^ tier(upgrades, "Frequency")))
end

-- Launch/equip slots unlocked by the NumSlots tier (PER-SLOT LAUNCH REWORK: slot count is
-- its own track, bought through the world slot Interact buttons; Frequency is back to delay).
function ProfileStats.GetMaxSlots(upgrades: Upgrades): number
	local track = UpgradesConfig.Tracks.NumSlots
	return track.BaseSlots + track.SlotsPerTier * math.min(tier(upgrades, "NumSlots"), track.MaxTier)
end

-- The absolute slot ceiling: the slot count at NumSlots' MaxTier. The NumSlots track is
-- THE authority on slot count (there is no separate cosmetics-config slot constant);
-- world slot models and the loadout UI are authored to match this.
function ProfileStats.GetMaxSlotsCap(): number
	local track = UpgradesConfig.Tracks.NumSlots
	return track.BaseSlots + track.SlotsPerTier * track.MaxTier
end

-- Luck: biases crate/free-roll rarity sampling toward rarer results (CosmeticService's
-- rollRarity) without changing the displayed base "1 in X" odds. Exponential in tier
-- (LuckGrowth^t - 1) because effective tail-rarity odds scale ~(luck+1): each tier bought
-- multiplies your rare-hit rate by LuckGrowth, instead of adding a vanishing sliver.
function ProfileStats.GetLuck(upgrades: Upgrades): number
	local track = UpgradesConfig.Tracks.Luck
	return track.LuckGrowth ^ tier(upgrades, "Luck") - 1
end

-- Launcher swivel angle (radians) for a given phase. The launcher sweeps its aim
-- ± arcWidth as phase runs 0→1: angle = aim + arcWidth·sin(2π·phase). Phase
-- 0/0.5/1 fire straight down the aim line; 0.25 = +arcWidth, 0.75 = −arcWidth.
-- Both arcWidth (loadout.axes.Arc) and aim (loadout.axes.Angle) are continuous
-- loadout axes the player sets within their unlocked range — this is pure geometry
-- over them and the clock-derived phase, no upgrade/loadout fetch.
function ProfileStats.GetSwivelAngle(arcWidth: number, aimAngle: number, phase: number): number
	return (-aimAngle) + arcWidth * math.sin(2 * math.pi * phase)
end

-- Sensitivity to accumulated peg heat (§1.5, simplified). 0 at tier 0 (heat does
-- nothing); banked payout is scaled by (1 + accumulatedHeat * this).
function ProfileStats.GetPegHeatFactor(upgrades: Upgrades): number
	return UpgradesConfig.Tracks.PegHeat.PerTier * tier(upgrades, "PegHeat")
end

-- [Min,Max] a continuous axis (Weight, Size, ...) may move within, from its tier.
function ProfileStats.GetAxisRange(upgrades: Upgrades, axis: string): (number, number)
	local def = UpgradesConfig.Axes[axis]
	assert(def, "GetAxisRange: unknown axis '" .. tostring(axis) .. "'")
	local range = def.Ranges[math.clamp(tier(upgrades, axis) + 1, 1, #def.Ranges)]
	return range.Min, range.Max
end

-- Trickle income this batch (§1.2), scaled to current ceiling.
function ProfileStats.GetTrickle(upgrades: Upgrades): number
	return EconomyConfig.TrickleFraction * ProfileStats.GetMaxBet(upgrades)
end

-- Human-readable value string for a given upgrade track at a given tier. Intended
-- for the shop UI to show current and next values without duplicating derivation
-- logic. Builds a one-entry upgrades map so the existing getters can be reused.
--
-- Format per track type:
--   MaxBet      → integer coin amount      e.g. "80"
--   FlatRate    → decimal                  e.g. "1.00"
--   BaseAdditive→ percentage               e.g. "+5%"
--   Frequency   → per-slot cooldown        e.g. "1.64s delay"
--   NumSlots    → slot count               e.g. "3 slots"
--   PegHeat     → multiplier               e.g. "0.5×"
--   Angle/Arc   → degree range             e.g. "-15° – 15°" (stored in radians)
--   Axes        → range                    e.g. "0.25 – 0.75"

-- Axes whose stored value is an angle in radians; displayed in degrees.
local ANGLE_AXES: { [string]: boolean } = { Angle = true, Arc = true }

function ProfileStats.GetDisplayString(track: string, tier: number): string
	local u: Upgrades = { [track] = tier }
	if track == "MaxBet" then
		return StringUtils.FormatShort(ProfileStats.GetMaxBet(u))
	elseif track == "FlatRate" then
		return StringUtils.FormatMoney(ProfileStats.GetFlatPerBounce(u), false, 2)
	elseif track == "BaseAdditive" then
		return string.format("+%.0f%%", ProfileStats.GetBaseAdditive(u) * 100)
	elseif track == "Frequency" then
		return string.format("%.2fs delay", ProfileStats.GetLaunchDelay(u))
	elseif track == "NumSlots" then
		return string.format("%d slots", ProfileStats.GetMaxSlots(u))
	elseif track == "Luck" then
		-- Shown as the effective rare-odds multiplier (P(thin tail) ≈ (luck+1) × base).
		return "×" .. StringUtils.FormatShort(ProfileStats.GetLuck(u) + 1)
	elseif track == "PegHeat" then
		return string.format("%.2f×", ProfileStats.GetPegHeatFactor(u))
	else
		-- Axis tracks (Weight, Size, ...)
		if UpgradesConfig.Axes[track] then
			local min, max = ProfileStats.GetAxisRange(u, track)
			if ANGLE_AXES[track] then
				return string.format("%d° – %d°", math.round(math.deg(min)), math.round(math.deg(max)))
			end
			return string.format("%.2f – %.2f", min, max)
		end
	end
	return ""
end

return ProfileStats
