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
local Config = require(RS.Shared.Config)

local ProfileStats = {}

-- Raw tier map: { [trackOrAxisName] = tier }. Mirrors ProfileService's storage.
export type Upgrades = { [string]: number }

local function tier(upgrades: Upgrades, track: string): number
	return upgrades[track] or 0
end

-- Effective max bet (cap for loadout.Bet). maxBet = StartMaxBet * PerTier^tier.
function ProfileStats.GetMaxBet(upgrades: Upgrades): number
	return Config.Economy.StartMaxBet * (Config.Upgrades.MaxBet.PerTier ^ tier(upgrades, "MaxBet"))
end

-- V_JACK: value a single ball must carry to clear the jackpot gate (§1.3).
function ProfileStats.GetVJack(upgrades: Upgrades): number
	return Config.Economy.VJackFraction * ProfileStats.GetMaxBet(upgrades)
end

-- Flat points paid per qualifying peg bounce (§1.4), output-scaling track.
function ProfileStats.GetFlatPerBounce(upgrades: Upgrades): number
	local track = Config.Upgrades.FlatRate
	return track.Base * (track.PerTier ^ tier(upgrades, "FlatRate"))
end

-- Additive bonus fraction on final slot payout (§2), output-scaling track.
function ProfileStats.GetBaseAdditive(upgrades: Upgrades): number
	return Config.Upgrades.BaseAdditive.PerTier * tier(upgrades, "BaseAdditive")
end

-- Cap on ball count N unlocked at the current frequency tier (§3 axis A). The
-- ceiling, not the chosen N (that is loadout.BallCount, ≤ this).
function ProfileStats.GetBallCountCap(upgrades: Upgrades): number
	local caps = Config.Upgrades.Frequency.Caps
	return caps[math.clamp(tier(upgrades, "Frequency") + 1, 1, #caps)]
end

-- Max launcher swivel (radians) at the current arc tier (§3 axis C). The launch
-- phase selects a direction within ±this; wider arc reaches the edge slots.
function ProfileStats.GetArcWidth(upgrades: Upgrades): number
	local widths = Config.Upgrades.Arc.Widths
	return widths[math.clamp(tier(upgrades, "Arc") + 1, 1, #widths)]
end

-- Sensitivity to accumulated peg heat (§1.5, simplified). 0 at tier 0 (heat does
-- nothing); banked payout is scaled by (1 + accumulatedHeat * this).
function ProfileStats.GetPegHeatFactor(upgrades: Upgrades): number
	return Config.Upgrades.PegHeat.PerTier * tier(upgrades, "PegHeat")
end

-- [Min,Max] a continuous axis (Weight, Size, ...) may move within, from its tier.
function ProfileStats.GetAxisRange(upgrades: Upgrades, axis: string): (number, number)
	local def = Config.Axes[axis]
	assert(def, "GetAxisRange: unknown axis '" .. tostring(axis) .. "'")
	local range = def.Ranges[math.clamp(tier(upgrades, axis) + 1, 1, #def.Ranges)]
	return range.Min, range.Max
end

-- Trickle income this batch (§1.2), scaled to current ceiling.
function ProfileStats.GetTrickle(upgrades: Upgrades): number
	return Config.Economy.TrickleFraction * ProfileStats.GetMaxBet(upgrades)
end

return ProfileStats
