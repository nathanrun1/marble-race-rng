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
	-- Slots in the bonus loadout. Every slotted skin contributes its bonus; the total is
	-- one global money multiplier applied at banking (ScoreHandler): ×(1 + sum of bonuses).
	LoadoutSlots = 5,
	-- Base money bonus per skin by rarity (1..9). A full early loadout of commons is a
	-- noticeable-but-small +10%; the 6-9 tiers (Mythic/Celestial/Divine/Transcendent)
	-- are the whale-tail chase — Gold Box exclusive, tiny odds.
	RarityBonus = { 0.02, 0.05, 0.12, 0.30, 0.75, 1.8, 4, 9, 20 },
	-- CORE LOOP REWORK: base $ value a ball of this rarity (1..9) carries into ScoreHandler's
	-- multiplier chain (replaces the old bet-tier/MaxBet ladder as the value input — see
	-- BallLaunchService.spawnBall). PLACEHOLDER magnitudes, roughly ~2.4x per rarity like
	-- RarityBonus above; tune in playtest.
	RarityValue = { 10, 25, 60, 150, 375, 900, 2200, 5000, 12000 },
	-- Duplicate copies star a skin up: ★k at StarDupes[k] DUPLICATES (copies beyond the
	-- first). Triangular like the golden peg schedule: 0, 1, 3, 6, 10.
	StarDupes = { 0, 1, 3, 6, 10 },
	-- Bonus multiplier at ★1..★5: a ★5 common (+8%) rivals a fresh epic (+30%)... almost.
	StarMults = { 1, 1.5, 2, 3, 4 },
}

table.freeze(Cosmetics)

return Cosmetics
