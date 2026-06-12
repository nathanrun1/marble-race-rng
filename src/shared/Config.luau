local RS = game:GetService("ReplicatedStorage")

local Config = {}

Config.Tags = {
	ScoreTarget = "ScoreTarget",       -- Scores on ball collision
	DestroyTarget = "DestroyTarget",   -- Destroys ball on collision
	Ball = "Ball"
}

Config.Attributes = {
	OwnerUserId = "OwnerUserId",       -- Ball owner's user ID
	Cooldown = "Cooldown",             -- Ball same-target repeat score cooldown

	PointValue = "PointValue",         -- Score target value
	IsPointMul = "IsPointMultiplier",  -- Whether ball value is multiplied by PointValue (if not, PointValue is added directly)
	PegHeat = "PegHeat",               -- Peg heat (signed): hot >0, cold <0. Accumulated per ball, applied value-proportionally at banking, scaled by the player's PegHeat tier.

	-- Per-ball config, set at spawn from the owner's loadout (see ProfileService)
	Value = "Value",                   -- Ball's value (B/N for this batch)
	Weight = "Weight",                 -- Weight slider 0 (light) .. 1 (heavy)
	Size = "Size",                     -- Size slider
	BatchId = "BatchId",               -- Batch this ball belongs to (per-player combo settlement)
}

Config.Scoring = {
	DefaultCooldown = 1.5,
}

Config.Currency = {
	StartingBalance = 150,  -- NOTE: debug value; guideline §4 StartBank = 150
}

Config.Economy = {
	StartMaxBet = 40,        -- guideline §4; base for the MaxBet track
	TrickleFraction = 0.08,  -- × currentMaxBet, free per batch (§1.2)
	VJackFraction = 0.4,     -- V_JACK = this × currentMaxBet (§1.3 jackpot gate)
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
		PerTier = 2,
		Cost = { Base = 200, Growth = 2.3 },  -- Growth > 2 to outpace maxBet
		Name = "Max Bet", Desc = "Raise your betting ceiling.",
		Icon = "💰"
	},
	-- flatPerBounce = Base * (PerTier ^ tier)           [output-scaling]
	FlatRate = {
		Base = 0.5, PerTier = 2,
		Cost = { Base = 150, Growth = 2.0 },
		Name = "Flat Rate", Desc = "More points per peg bounce.",
		Icon = "⚡"
	},
	-- baseAdditive = PerTier * tier  (additive)         [output-scaling]
	BaseAdditive = {
		PerTier = 0.05,  -- INFERRED: guideline gives no exact per-tier %
		Cost = { Base = 200, Growth = 2.2 },
		Name = "Base Bonus", Desc = "Boost your final slot payout.",
		Icon = "➕"
	},
	-- max ball count N at each frequency tier (§3 axis A) [cap for loadout.BallCount]
	Frequency = {
		Caps = { 2, 3, 4, 6, 8, 12, 16 },
		Cost = { Base = 500, Growth = 2 },
		Name = "Frequency", Desc = "Launch more balls per batch.",
		Icon = "🔄"
	},
	-- max launcher swivel (radians) at each tier (§3 axis C) [scales launch direction].
	-- tier 0 keeps a small base width so phase aiming works day one; tiers widen
	-- the reachable sweep toward the edges. Phase 0..1 selects within ±width.
	Arc = {
		Widths = { math.rad(15), math.rad(30), math.rad(45), math.rad(60) },
		Cost = { Base = 400, Growth = 3 },
		Name = "Launcher Arc", Desc = "Widen your aiming sweep.",
		Icon = "🎯"
	},
	-- pegHeatFactor = PerTier * tier (additive). Sensitivity to peg heat (§1.5,
	-- simplified): tier 0 = heat has no effect; higher = aimed hot pegs pay more
	-- (and random cold paths cost more). Targeting channel; only pays with aim.
	PegHeat = {
		PerTier = 0.5,  -- INFERRED magnitude; tune against the heat map
		Cost = { Base = 250, Growth = 2.2 },
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
	Weight = {
		Default = 0.5,  -- 0 = light, 1 = heavy
		Ranges = {
			{ Min = 0.5, Max = 0.5 },    -- tier 0: locked at center
			{ Min = 0.25, Max = 0.75 },  -- tier 1: partial
			{ Min = 0.0, Max = 1.0 },    -- tier 2: full heavy↔light
		},
		Cost = { Base = 300, Growth = 2.5 },
		Name = "Ball Weight", Desc = "Unlock heavier and lighter balls.",
		Icon = "⚖️"
	},
	Size = {
		Default = 1.0,  -- full size; smaller is the upgrade direction (§3 B-adj)
		Ranges = {
			{ Min = 1.0, Max = 1.0 },   -- tier 0: locked at full
			{ Min = 0.75, Max = 1.0 },  -- tier 1
			{ Min = 0.5, Max = 1.0 },   -- tier 2
		},
		Cost = { Base = 300, Growth = 2.5 },
		Name = "Ball Size", Desc = "Unlock smaller balls.",
		Icon = "◯"
	},
} :: { [string]: AxisDef }

-- Default loadout for a fresh player (free choices, distinct from upgrades).
-- Continuous-axis positions (Weight, Size, ...) are not listed here — they
-- default to Config.Axes[name].Default, so axes have one definition site.
Config.LoadoutDefaults = {
	Bet = 1,           -- total bet B; player sets via UI
	BallCount = 1,     -- N
	LaunchPhase = 0.5, -- center of arc (no upgrade gate yet; Launcher Arc later)
}

Config.Templates = {
	Ball = RS.Assets.BallPrefab
}

table.freeze(Config.Tags)
table.freeze(Config.Attributes)
table.freeze(Config.Scoring)
table.freeze(Config.Currency)
table.freeze(Config.Economy)
table.freeze(Config.Upgrades)
table.freeze(Config.Axes)
return Config