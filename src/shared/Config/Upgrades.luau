--!strict
-- Upgrade tracks + continuous axes + the fresh-player loadout defaults.
--
-- ProfileService stores the *tier* (an integer); the effective stat is derived from
-- these constants. Single source of truth is the tier, never the derived value. Each
-- track owns its own Base so derivation has no cross-table dependency.
--
-- Two kinds live in Tracks:
--   Output-scaling — scalar multipliers applied in scoring, gate no loadout
--                    value: FlatRate, BaseAdditive.
--   Cap — bound a paired loadout value: MaxBet (Bet), Frequency (BallCount).
-- Continuous constraint axes (Weight, Size, ...) live in Axes below.
-- Each entry is the *whole* definition of an upgrade: its derivation params, its
-- cost curve, and UI display strings. Adding an upgrade is one entry here (plus a
-- ProfileStats deriver if it produces a gameplay stat). UpgradeService prices and
-- sells every entry generically — no per-track code there.
--
-- Cost = { Base, Growth }: price to buy tier t->t+1 is Base * Growth^t. Geometric
-- (not polynomial): first tier costs Base, and Growth > 2 keeps Max Bet's cost
-- ahead of its doubling benefit (the anti-snowball lever). Tune in playtest.

local Economy = require(script.Parent.Economy)
local Scoring = require(script.Parent.Scoring)

export type TrackDef = {
	Cost: { Base: number, Growth: number },
	Name: string,
	Short: string,
	Desc: string,
	Icon: string,
	MaxTier: number?,
	[string]: any, -- per-track derivation params (Base, PerTier, LuckGrowth, ...)
}

export type AxisDef = {
	Default: number,
	Ranges: { { Min: number, Max: number } },
	Cost: { Base: number, Growth: number }?,
	Name: string?,
	Short: string?,
	Desc: string?,
	Icon: string?,
}

local Upgrades = {
	Tracks = {
		-- Bet size is now a discrete ladder the player steps through with Raise/Lower (client
		-- BetUI), not a continuous value up to a "ceiling" — but it's still stored/priced as an
		-- ordinary upgrade track named MaxBet (kept as-is so nothing else needs renaming), reintroduced
		-- as a purchasable upgrade-shop kiosk track alongside BetUI's own raise/lower flow.
		--
		-- betSize(0) = Economy.StartBetSize (10, free, no purchase needed)
		-- betSize(tier>=1) = Economy.StartMaxBet * (PerTier ^ (tier - 1))   [see ProfileStats.GetMaxBet]
		-- i.e. the whole old ladder shifted up one rung: new tier 1 (40) is the old tier 0. The
		-- geometric cost curve (Base * Growth^tier) is untouched and now applies uniformly from
		-- tier 0 (no more Cost.Initial override) — tier 0->1 costs Base*Growth^0 = Base = 250,
		-- exactly a quarter of the old flat 1000 unlock, and every tier after that prices exactly
		-- like it did before the shift.
		MaxBet = {
			PerTier = 1.5,
			Cost = { Base = 250, Growth = 1.9 },
			Name = "Zone", Short = "Zone", Desc = "Move to the next zone; increase your marble value.",
			Icon = "💰",
		},
		-- flatPerBounce = Base * (PerTier ^ tier)           [output-scaling]
		-- Combo bonus is an ABSOLUTE point add (combo × this), free of the bet — the low-bet/high-
		-- combo "chaos" lever (big bouncy balls bounce a lot). Base is deliberately TINY so the
		-- tier-0/untiered bonus is negligible (a few points) and can't carry no-build/early play
		-- past the intended bleed — you must INVEST. The steep PerTier (1.85, uncapped) does the
		-- work: by endgame the flat combo income keeps pace with the bet-exponential economy. Cost
		-- grows 1.9× so it's gated, not a runaway.
		FlatRate = {
			Base = 0.2, PerTier = 1.85,
			Cost = { Base = 260, Growth = 1.9 },
			Name = "Combo", Short = "Combo", Desc = "More cash per bounce during a combo (" .. Scoring.MinCombo .. " or more)",
			Icon = "⚡",
		},
		-- baseAdditive = Base + C1 * tier + C2 * tier^2 + C3 * tier^3
		-- Flattened to linear +5%/tier (was cubic → ×26 at tier 12, which dwarfed every other
		-- lever and exploded income). Now +60% at max: a real lever, not a runaway.
		-- Applied as a MULTIPLIER boost: the player's effective slot multipliers (and the
		-- jackpot multiplier) are scaled by (1 + rate) at banking (ScoreHandler), and the
		-- board labels show each player their own boosted values (client BoardMultiplierView)
		-- — not a separate additive line on the payout anymore.
		BaseAdditive = {
			Base = 0.0, C1 = 0.05, C2 = 0.0, C3 = 0.0,
			Cost = { Base = 300, Growth = 1.7 },
			Name = "Mult Bonus", Short = "Mult", Desc = "Boost the board's slot multipliers.",
			Icon = "➕",
		},
		-- launchDelay = Base * (PerTier ^ tier) — seconds a launch slot stays on cooldown after
		-- firing (PER-SLOT LAUNCH REWORK: each slot launches independently off its Interact pad;
		-- this one delay applies to every slot the player owns — see ProfileStats.GetLaunchDelay).
		-- Slot COUNT is the separate NumSlots track below.
		Frequency = {
			Base = 2, PerTier = 0.82,
			MaxTier = 12,
			Cost = { Base = 230, Growth = 1.9 },
			Name = "Frequency", Short = "Freq", Desc = "Launch marbles more often.",
			Icon = "🔄",
		},
		-- slots = BaseSlots + SlotsPerTier * tier (ProfileStats.GetMaxSlots): how many launch/equip
		-- slots the player owns. THE authority on slot count (there is no separate config constant;
		-- see ProfileStats.GetMaxSlotsCap for the MaxTier-derived ceiling). Sold through the locked
		-- slot Interact buttons in the world (client SlotInteract's "Unlock - $X" flow), not an
		-- upgrade-shop kiosk. Keep MaxTier matched to the authored world slot models (1 base + 9).
		NumSlots = {
			BaseSlots = 1, -- slots at tier 0
			SlotsPerTier = 1, -- +1 slot per tier purchased
			MaxTier = 9,
			Cost = { Base = 400, Growth = 2.2 },
			Name = "Add Slot", Short = "Slot", Desc = "Unlock another launch slot.",
			Icon = "🔓",
		},
		-- pegHeatFactor = PerTier * tier (additive). Sensitivity to peg heat (§1.5,
		-- simplified): tier 0 = heat has no effect; higher = aimed hot pegs pay more
		-- (and random cold paths cost more). Targeting channel; only pays with aim.
		PegHeat = {
			PerTier = 0.05, -- INFERRED magnitude; tune against the heat map
			Cost = { Base = 220, Growth = 1.7 },
			Name = "Heat Sense", Short = "Heat", Desc = "Hot and cold obstacles affect you more strongly.",
			Icon = "🔥",
		},
		-- luck = LuckGrowth^tier - 1 (see ProfileStats.GetLuck; tier 0 = 0, no bias). Biases
		-- crate/free-roll rarity sampling toward rarer results (CosmeticService's rollRarity)
		-- without changing the displayed base "1 in X" odds. EXPONENTIAL on purpose: for the
		-- thin tail rarities, P(hit) ≈ (luck+1) × base odds, so a linear per-tier luck would
		-- feel logarithmic (each tier a smaller relative gain) — doubling per tier makes every
		-- tier double your effective tail odds instead. PLACEHOLDER magnitudes — tune in playtest.
		--
		-- Luck is the odd one out: priced in DIAMONDS (Currency below; UpgradeService charges
		-- CosmeticService's CC instead of cash) and it SURVIVES rebirth (PersistsRebirth;
		-- ProfileService.ResetProfile skips it) — it's the permanent meta-progression track,
		-- sold from the cosmetics shop's LUCK tab rather than a cash kiosk.
		Luck = {
			LuckGrowth = 2,
			Cost = { Base = 200, Growth = 1.8 },
			Currency = "Diamonds",
			PersistsRebirth = true,
			Name = "Luck", Short = "Luck", Desc = "Improves your odds of rolling rarer balls.",
			Icon = "🍀",
		},
	} :: { [string]: TrackDef },

	-- Continuous synergetic axes (§3). Each is a constraint upgrade paired with a
	-- loadout position: the upgrade *tier* unlocks a [Min,Max] range (Ranges indexed
	-- by tier+1); the player sets the position freely within it. ProfileService
	-- handles any axis listed here generically — adding one later (e.g. Skew, when
	-- it returns; Launcher Arc) is a Config entry and nothing else.
	--
	-- Typed with a string indexer so consumers can index by a dynamic axis name
	-- (Axes[axisName]) under --!strict, not just by literal field.
	--
	-- Axes are purchasable upgrades too: the tier unlocks a wider Ranges entry, so
	-- each carries the same Cost/Name/Desc as a Tracks entry. UpgradeService
	-- sells Tracks and Axes uniformly, so a listed axis needs a Cost.
	Axes = {
		Elasticity = {
			Default = 0.5, -- 0 = low elasticity, 1 = high elasticity
			Ranges = {
				{ Min = 0.5, Max = 0.5 },
				{ Min = 0.45, Max = 0.55 },
				{ Min = 0.41, Max = 0.59 },
				{ Min = 0.37, Max = 0.63 },
				{ Min = 0.33, Max = 0.67 },
				{ Min = 0.29, Max = 0.71 },
				{ Min = 0.25, Max = 0.75 },
				{ Min = 0.2, Max = 0.8 },
				{ Min = 0.16, Max = 0.84 },
				{ Min = 0.12, Max = 0.88 },
				{ Min = 0.08, Max = 0.92 },
				{ Min = 0.04, Max = 0.96 },
				{ Min = 0.0, Max = 1.0 },
			},
			Cost = { Base = 1500, Growth = Economy.BasePriceGrowth },
			Name = "Bounciness", Short = "Bounce", Desc = "How bouncy the marble is.",
			Icon = "💨",
		},
		Size = {
			Default = 1.0, -- full size; smaller is the upgrade direction (§3 B-adj)
			Ranges = {
				{ Min = 0.75, Max = 0.75 },
				{ Min = 0.72, Max = 0.77 },
				{ Min = 0.7, Max = 0.79 },
				{ Min = 0.67, Max = 0.81 },
				{ Min = 0.65, Max = 0.83 },
				{ Min = 0.63, Max = 0.85 },
				{ Min = 0.61, Max = 0.87 },
				{ Min = 0.59, Max = 0.89 },
				{ Min = 0.57, Max = 0.91 }, -- (Size ranges unchanged)
				{ Min = 0.55, Max = 0.94 },
				{ Min = 0.53, Max = 0.96 },
				{ Min = 0.51, Max = 0.98 },
				{ Min = 0.5, Max = 1 },
			},
			Cost = { Base = 2000, Growth = 1.8 },
			Name = "Marble Size", Short = "Size", Desc = "Unlock different marble sizes.",
			Icon = "◯",
		},
		Angle = {
			Default = 0.0,
			Ranges = {
				{ Min = -math.rad(0.0), Max = math.rad(0.0) },
				{ Min = -math.rad(10.0), Max = math.rad(10.0) },
				{ Min = -math.rad(13.7), Max = math.rad(13.7) },
				{ Min = -math.rad(16.0), Max = math.rad(16.0) },
				{ Min = -math.rad(18.7), Max = math.rad(18.7) },
				{ Min = -math.rad(21.9), Max = math.rad(21.9) },
				{ Min = -math.rad(25.5), Max = math.rad(25.5) },
				{ Min = -math.rad(29.8), Max = math.rad(29.8) },
				{ Min = -math.rad(34.9), Max = math.rad(34.9) },
				{ Min = -math.rad(40.8), Max = math.rad(40.8) },
				{ Min = -math.rad(47.6), Max = math.rad(47.6) },
				{ Min = -math.rad(55.7), Max = math.rad(55.7) },
				{ Min = -math.rad(65.0), Max = math.rad(65.0) },
			},
			Cost = { Base = 1500, Growth = Economy.BasePriceGrowth },
			Name = "Angle", Short = "Angle", Desc = "Tune the launch direction.",
			Icon = "🏹",
		},
		Arc = {
			Default = math.rad(15),
			Ranges = {
				{ Min = math.rad(5), Max = math.rad(15.0) },
				{ Min = math.rad(5), Max = math.rad(17.3) },
				{ Min = math.rad(5), Max = math.rad(19.9) },
				{ Min = math.rad(5), Max = math.rad(22.8) },
				{ Min = math.rad(5), Max = math.rad(26.3) },
				{ Min = math.rad(5), Max = math.rad(30.2) },
				{ Min = math.rad(5), Max = math.rad(34.7) },
				{ Min = math.rad(5), Max = math.rad(39.9) },
				{ Min = math.rad(5), Max = math.rad(45.8) },
				{ Min = math.rad(5), Max = math.rad(52.7) },
				{ Min = math.rad(5), Max = math.rad(60.6) },
				{ Min = math.rad(5), Max = math.rad(69.6) },
				{ Min = math.rad(5), Max = math.rad(80.0) },
			},
			Cost = { Base = 1500, Growth = Economy.BasePriceGrowth },
			Name = "Launcher Swivel", Short = "Swivel", Desc = "Widen or tighten the possible launch angles.",
			Icon = "🎯",
		},
	} :: { [string]: AxisDef },

	-- Default loadout for a fresh player (free choices, distinct from upgrades).
	-- Continuous-axis positions (Weight, Size, ...) are not listed here — they
	-- default to Axes[name].Default, so axes have one definition site.
	LoadoutDefaults = {
		Bet = 10, -- total bet B; player sets via UI
		BallCount = 1, -- N
	},
}

table.freeze(Upgrades.Tracks)
table.freeze(Upgrades.Axes)

return Upgrades
