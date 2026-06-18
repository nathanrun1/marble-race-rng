local RS = game:GetService("ReplicatedStorage")

local Config = {}

Config.Tags = {
	ScoreTarget = "ScoreTarget",       -- Scores on ball collision
	DestroyTarget = "DestroyTarget",   -- Destroys ball on collision
	BounceTarget = "BounceTarget",      -- Counts towards bounce combo
	JackpotTarget = "JackpotTarget",   -- Multiplies the ball's banked value by Config.Scoring.JackpotMultiplier
	Ball = "Ball"
}

Config.Attributes = {
	OwnerUserId = "OwnerUserId",       -- Ball owner's user ID
	Cooldown = "Cooldown",             -- Ball same-target repeat score cooldown

	PointMul = "PointMul",             -- If defined, a destroy target's point multiplier
	PegHeat = "PegHeat",               -- Peg heat (signed): hot >0, cold <0. Accumulated per ball, applied value-proportionally at banking, scaled by the player's PegHeat tier.

	-- Per-ball config, set at spawn from the owner's loadout (see ProfileService)
	Value = "Value",                   -- Ball's value (B/N for this batch)
	Weight = "Weight",                 -- Weight slider 0 (light) .. 1 (heavy)
	Size = "Size",                     -- Size slider
	BatchId = "BatchId",               -- Batch this ball belongs to (per-player combo settlement)
}

Config.Scoring = {
	DefaultCooldown = 1.5,
	MinCombo = 20,
	-- Minimum scoretarget multiplier (×) on a hit that triggers high-point FX.
	SpecialFXMinMultiplier = 0.25, -- temp value
	-- Seconds a ball may stay alive before it is force-banked at 1× and despawned
	-- (a ball wedged on geometry must not live forever). Tune above a normal fall.
	MaxBallLifetime = 25,
	-- Jackpot payout: hitting a JackpotTarget adds JackpotMultiplier × the ball's
	-- otherwise-final banked value (so total = banked × (1 + this)). Tune.
	JackpotMultiplier = 25,
}

-- Peg-field heat values PegService writes to each peg's PegHeat attribute. Fixed
-- per category (we don't vary within hot or cold); ScoringService reads the sign
-- of the attribute to classify a hit (>0 hot, <0 cold, 0 neutral).
Config.Pegs = {
	HotHeat = 1.0,
	ColdHeat = -1.0,   -- TEMP: -1.0 for accurate EV testing; gameplay value was -1.1
	NeutralHeat = 0.0,
}

Config.Currency = {
	StartingBalance = 100,
}

Config.Groups = {
	GroupId = 559054633,
	ScoreBoost = 0.10, -- multiplier bonus for group members (0.10 = +10%)
}

Config.Economy = {
	StartMaxBet = 40,         -- guideline §4; base for the MaxBet track
	TrickleFraction = 0.1,    -- × currentMaxBet, free per batch (§1.2)
	VJackFraction = 0.55,     -- V_JACK = this × currentMaxBet (§1.3 jackpot gate)
}

-- Upgrade tracks. ProfileService stores the *tier* (an integer); the effective
-- stat is derived from these constants. Single source of truth is the tier,
-- never the derived value. Each track owns its own Base so derivation has no
-- cross-table dependency.
--
-- Two kinds live here:
--   Output-scaling — scalar multipliers applied in scoring, gate no loadout
--                    value: FlatRate, BaseAdditive.
--   Cap — bound a paired loadout value: MaxBet (Bet), Frequency (BallCount).
-- Continuous constraint axes (Weight, Size, ...) live in Config.Axes below.
-- Each entry is the *whole* definition of an upgrade: its derivation params, its
-- cost curve, and UI display strings. Adding an upgrade is one entry here (plus a
-- ProfileStats deriver if it produces a gameplay stat). UpgradeService prices and
-- sells every entry generically — no per-track code there.
--
-- Cost = { Base, Growth }: price to buy tier t->t+1 is Base * Growth^t. Geometric
-- (not polynomial): first tier costs Base, and Growth > 2 keeps Max Bet's cost
-- ahead of its doubling benefit (the anti-snowball lever). Tune in playtest.
-- Caps/Widths lists also cap the tier; unlisted tracks are unbounded.
Config.Upgrades = {
	-- maxBet = Economy.StartMaxBet * (PerTier ^ tier)   [cap for loadout.Bet]
	MaxBet = {
		PerTier = 3.2,
		Cost = { Base = 250, Growth = 3.2 },  -- Growth > 2 to outpace maxBet
		Name = "Max Bet", Desc = "Raise your betting ceiling.",
		Icon = "💰"
	},
	-- flatPerBounce = Base * (PerTier ^ tier)           [output-scaling]
	FlatRate = {
		Base = 1.5, PerTier = 3.2,
		Cost = { Base = 215, Growth = 3.2 },
		Name = "Combo", Desc = "More points per bounce during a combo.",
		Icon = "⚡"
	},
	-- baseAdditive = PerTier * tier  (additive)         [output-scaling]
	BaseAdditive = {
		Base = 0.05, PerTier = 1.66,
		Cost = { Base = 215, Growth = 3.2 },
		Name = "Base Bonus", Desc = "Boost your final slot payout.",
		Icon = "➕"
	},
	-- Minimum delay between launches
	Frequency = {
		Base = 2, PerTier = 0.67,
		MaxTier = 12,
		Cost = { Base = 230, Growth = 3.2 },
		Name = "Launch Delay", Desc = "Decrease time between launches",
		Icon = "🔄"
	},
	-- pegHeatFactor = PerTier * tier (additive). Sensitivity to peg heat (§1.5,
	-- simplified): tier 0 = heat has no effect; higher = aimed hot pegs pay more
	-- (and random cold paths cost more). Targeting channel; only pays with aim.
	PegHeat = {
		PerTier = 0.05,  -- INFERRED magnitude; tune against the heat map
		Cost = { Base = 180, Growth = 3.2 },
		Name = "Peg Sense", Desc = "Hot and cold pegs affect you more strongly.",
		Icon = "🔥"
	},
}

-- Continuous synergetic axes (§3). Each is a constraint upgrade paired with a
-- loadout position: the upgrade *tier* unlocks a [Min,Max] range (Ranges indexed
-- by tier+1); the player sets the position freely within it. ProfileService
-- handles any axis listed here generically — adding one later (e.g. Skew, when
-- it returns; Launcher Arc) is a Config entry and nothing else.
--
-- Typed with a string indexer so consumers can index by a dynamic axis name
-- (Config.Axes[axisName]) under --!strict, not just by literal field.
--
-- Axes are purchasable upgrades too: the tier unlocks a wider Ranges entry, so
-- each carries the same Cost/Name/Desc as a Config.Upgrades track. UpgradeService
-- sells Config.Upgrades and Config.Axes uniformly, so a listed axis needs a Cost.
type AxisDef = {
	Default: number,
	Ranges: { { Min: number, Max: number } },
	Cost: { Base: number, Growth: number }?,
	Name: string?,
	Desc: string?,
	Icon: string?
}
Config.Axes = {
	Elasticity = {
		Default = 0.5,  -- 0 = low elasticity, 1 = high elasticity
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
		Cost = { Base = 105, Growth = 3.2 },
		Name = "Bounciness", Desc = "How bouncy the ball is. More bounciness increases variance.",
		Icon = "💨"
	},
	Size = {
		Default = 1.0,  -- full size; smaller is the upgrade direction (§3 B-adj)
		Ranges = {
			{ Min = 0.75, Max = 0.75 },
			{ Min = 0.72, Max = 0.77 },
			{ Min = 0.7, Max = 0.79 },
			{ Min = 0.67, Max = 0.81 },
			{ Min = 0.65, Max = 0.83 },
			{ Min = 0.63, Max = 0.85 },
			{ Min = 0.61, Max = 0.87 },
			{ Min = 0.59, Max = 0.89 },
			{ Min = 0.57, Max = 0.91 },
			{ Min = 0.55, Max = 0.94 },
			{ Min = 0.53, Max = 0.96 },
			{ Min = 0.51, Max = 0.98 },
			{ Min = 0.5, Max = 1 },
		},
		Cost = { Base = 105, Growth = 3.2 },
		Name = "Ball Size", Desc = "Unlock different ball sizes.",
		Icon = "◯"
	},
	Angle = {
		Default = 0.0,  -- full size; smaller is the upgrade direction (§3 B-adj)
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
		Cost = { Base = 105, Growth = 3.2 },
		Name = "Angle", Desc = "Launch angle.",
		Icon = "🏹"
	},
	Arc = {
		Default = math.rad(15),
		Ranges = {
			{ Min = math.rad(0), Max = math.rad(15.0) },
			{ Min = math.rad(0), Max = math.rad(17.3) },
			{ Min = math.rad(0), Max = math.rad(19.9) },
			{ Min = math.rad(0), Max = math.rad(22.8) },
			{ Min = math.rad(0), Max = math.rad(26.3) },
			{ Min = math.rad(0), Max = math.rad(30.2) },
			{ Min = math.rad(0), Max = math.rad(34.7) },
			{ Min = math.rad(0), Max = math.rad(39.9) },
			{ Min = math.rad(0), Max = math.rad(45.8) },
			{ Min = math.rad(0), Max = math.rad(52.7) },
			{ Min = math.rad(0), Max = math.rad(60.6) },
			{ Min = math.rad(0), Max = math.rad(69.6) },
			{ Min = math.rad(0), Max = math.rad(80.0) },
		},
		Cost = { Base = 105, Growth = 3.2 },
		Name = "Launcher Swivel", Desc = "Widen or tighten the possible launch angles.",
		Icon = "🎯"
	},
} :: { [string]: AxisDef }

-- Default loadout for a fresh player (free choices, distinct from upgrades).
-- Continuous-axis positions (Weight, Size, ...) are not listed here — they
-- default to Config.Axes[name].Default, so axes have one definition site.
Config.LoadoutDefaults = {
	Bet = 10,           -- total bet B; player sets via UI
	BallCount = 1,     -- N
}

Config.Templates = {
	Ball = RS.Assets.BallPrefab
}

table.freeze(Config.Tags)
table.freeze(Config.Attributes)
table.freeze(Config.Scoring)
table.freeze(Config.Pegs)
table.freeze(Config.Currency)
table.freeze(Config.Groups)
table.freeze(Config.Economy)
table.freeze(Config.Upgrades)
table.freeze(Config.Axes)
return Config