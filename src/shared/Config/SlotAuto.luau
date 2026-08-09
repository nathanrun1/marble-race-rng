--!strict
-- Per-slot AUTO launch: a free built-in toggle on every launch slot (no purchase),
-- flipped from the world AutoSign above each slot's Interact pad (client SlotInteract)
-- and enforced by BallLaunchService's auto sweep (server). AUTO on a slot makes it fire
-- itself whenever it's ready (unlocked + equipped + off cooldown). The on/off state
-- lives in the profile (autoSlots) so it persists across sessions.

local SlotAuto = {
	-- Seconds between server auto-launch sweeps. Only adds up to this much latency on
	-- top of the real gate (the slot's Frequency cooldown), so it stays coarse and cheap.
	SweepInterval = 0.25,
}

table.freeze(SlotAuto)

return SlotAuto
