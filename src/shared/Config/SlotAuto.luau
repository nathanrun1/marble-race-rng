--!strict
-- Per-slot AUTO launch: a one-time cash purchase per launch slot, sold from the world
-- AutoSign above each slot's Interact pad (client SlotInteract) and enforced by
-- BallLaunchService's auto sweep (server). Owning AUTO on a slot makes that slot fire
-- itself whenever it's ready (unlocked + equipped + off cooldown). Ownership lives in
-- the profile (autoSlots) so it persists across sessions and resets on rebirth, same
-- as the world upgrade locks.

local SlotAuto = {
	-- price(slot) = PriceBase * PriceGrowth^(slot - 1): higher slots cost more, same
	-- geometric shape as every other cost curve. PLACEHOLDER magnitudes — tune in playtest.
	PriceBase = 500,
	PriceGrowth = 2.0,
	-- Seconds between server auto-launch sweeps. Only adds up to this much latency on
	-- top of the real gate (the slot's Frequency cooldown), so it stays coarse and cheap.
	SweepInterval = 0.25,
}

function SlotAuto.PriceFor(slot: number): number
	return math.floor(SlotAuto.PriceBase * SlotAuto.PriceGrowth ^ (slot - 1))
end

table.freeze(SlotAuto)

return SlotAuto
