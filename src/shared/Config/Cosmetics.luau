--!strict
-- Cosmetics (ball skins) economy. Skins themselves live in shared/BallSkins; this holds the
-- currency tuning. CC (Cosmetic Coins) is earned by rebirthing — RebirthCCRatio × the RP spent on
-- each rebirth — and spent on skins. The yellow-themed shop lives on a SurfaceGui tagged
-- Tags.CosmeticsGui, with a floating sample ball over Tags.CosmeticBallSample.
-- RarityProducts (one Robux dev product per rarity) is the direct-buy path shown ONLY to
-- paid-random-items-restricted players (crates/Diamond packs are Robux-blocked for them).

local Cosmetics = {
	RebirthCCRatio = 1.0, -- CC granted per 1 RP spent on a rebirth
	-- One dev product per rarity (index = rarity 1..5). For paid-random-items-restricted
	-- players (PolicyGate) the index footer offers this deterministic direct purchase of
	-- the selected skin; everyone else unlocks from crates only. Rarities without an id
	-- (6+, or a "0" placeholder) simply show no direct-buy button.
	RarityProducts = {
		"3607562563",
		"3607562601",
		"3607562664",
		"3607562701",
		"3607562744",
	},

	----------------------------------------------------------------------------
	-- Skin power (crate/loadout progression, shared math in CosmeticBonus)
	----------------------------------------------------------------------------
	-- NOTE: slot COUNT has no constant here — the NumSlots upgrade track is the authority
	-- (ProfileStats.GetMaxSlots / GetMaxSlotsCap). Every slotted skin contributes its bonus;
	-- the total is one global money multiplier applied at banking (ScoreHandler): ×(1 + sum).
	-- Base money bonus per skin by rarity (1..12). A full early loadout of commons is a
	-- noticeable-but-small +10%; the 6+ tiers (Mythic through Omega) are the whale-tail
	-- chase — tiny odds, Luck-compressed (10-12 continue the ~×2.2 ladder).
	RarityBonus = { 0.02, 0.05, 0.12, 0.30, 0.75, 1.8, 4, 9, 20, 45, 100, 220 },
	-- PER-SLOT LAUNCH REWORK: a launched ball's $ value = the player's current bet size ×
	-- this factor^(rarity-1) (see CosmeticBonus.RarityBetMult / BallLaunchService). Rarity is a
	-- MULTIPLIER on bet sizing now, not a standalone value: common ×1, uncommon ×1.5,
	-- rare ×2.25, ... From RarityBetRoundFrom up, the multiplier is rounded UP to the
	-- nearest multiple of RarityBetRoundStep (7.59 -> 8, 11.39 -> 12, ...) so top-tier
	-- values read clean.
	RarityBetFactor = 1.5,
	RarityBetRoundFrom = 6,
	RarityBetRoundStep = 2,
	-- Hand-tuned exceptions to the formula (rarity -> multiplier): Epic/Legendary read
	-- cleaner as 3.5/5 than the raw 3.375/5.0625.
	RarityBetOverrides = { [4] = 3.5, [5] = 5 } :: { [number]: number },
	-- Duplicate copies star a skin up: ★k at StarDupes[k] DUPLICATES (copies beyond the
	-- first). Triangular like the golden peg schedule: 0, 1, 3, 6, 10.
	StarDupes = { 0, 1, 3, 6, 10 },
	-- Bonus multiplier at ★1..★5: a ★5 common (+8%) rivals a fresh epic (+30%)... almost.
	StarMults = { 1, 1.5, 2, 3, 4 },
}

table.freeze(Cosmetics)

return Cosmetics
