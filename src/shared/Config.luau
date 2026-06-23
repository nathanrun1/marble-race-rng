local RS = game:GetService("ReplicatedStorage")

local Config = {}

Config.Sounds = {
	Upgrade = "rbxassetid://106356556379520",
	Collect1 = "rbxassetid://104023881731125",
	Collect2 = "rbxassetid://83285744063515",
	Jackpot = "rbxassetid://84581872132549",
	Launch = "rbxassetid://87587182495338",
	Combo = "rbxassetid://112485190367588",
	Bounce = "rbxassetid://107174499116544",
	Hot = "rbxassetid://115023474688736",
	Fire = "rbxassetid://105137237689649",
	Cold = "rbxassetid://116320134099218",
	Prestige = "rbxassetid://84051226507785",
	Music = "rbxassetid://9043887120"  
}

Config.Tags = {
	ScoreTarget = "ScoreTarget",       -- Scores on ball collision
	DestroyTarget = "DestroyTarget",   -- Destroys ball on collision
	BounceTarget = "BounceTarget",      -- Counts towards bounce combo
	JackpotTarget = "JackpotTarget",   -- Multiplies the ball's banked value by Config.Scoring.JackpotMultiplier
	Ball = "Ball",
	AutoScale = "AutoScale",             -- GuiObject auto-scaled to viewport (see client AutoScale)
	Obstacle = "Obstacle",             -- An obstacle that has an active behaviour
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

	-- Obstacle Behaviour
	ObstacleRotate = "ORotate"         -- Obstacle rotates by given angles (Vector3)
}

Config.Scoring = {
	DefaultCooldown = 1.5,
	MinCombo = 24,
	-- Minimum scoretarget multiplier (×) on a hit that triggers high-point FX.
	SpecialFXMinMultiplier = 1.25,
	-- Seconds a ball may stay alive before it is force-banked at 1× and despawned
	-- (a ball wedged on geometry must not live forever). Tune above a normal fall.
	MaxBallLifetime = 25,
	-- Jackpot payout: hitting a JackpotTarget adds JackpotMultiplier × the ball's
	-- otherwise-final banked value (so total = banked × (1 + this)). Tune.
	JackpotMultiplier = 20	,
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

Config.Prestige = {
	Scale      = 10000, -- denominator in PP formula
	Exponent   = 0.35,  -- sublinear compression
	CostBase   = 30,    -- PP cost of first prestige (3× the prior 10; triples every tier)
	CostGrowth = 2.0,  -- geometric cost multiplier per prestige level
	MultPer    = 1.25,  -- global banked multiplier per prestige (multiplicative)
	NoScoreSeconds = 5, -- post-prestige no-score window (exploit guard)
}

Config.Economy = {
	StartMaxBet = 40,         -- guideline §4; base for the MaxBet track
	TrickleFraction = 0.01,    -- × currentMaxBet, free per batch (§1.2)
	VJackFraction = 0.55,     -- V_JACK = this × currentMaxBet (§1.3 jackpot gate)
	BasePriceGrowth = 4.5,    -- default upgrade Cost.Growth (price multiplier per tier)
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
		PerTier = Config.Economy.BasePriceGrowth * 0.9,
		Cost = { Base = 250, Growth = Config.Economy.BasePriceGrowth },  -- Growth > 2 to outpace maxBet
		Name = "Max Bet", Desc = "Raise your betting ceiling.",
		Icon = "💰"
	},
	-- flatPerBounce = Base * (PerTier ^ tier)           [output-scaling]
	FlatRate = {
		Base = 0.1, PerTier = Config.Economy.BasePriceGrowth * 0.5,
		Cost = { Base = 215, Growth = Config.Economy.BasePriceGrowth },
		Name = "Combo", Desc = "More points per bounce during a combo.",
		Icon = "⚡"
	},
	-- baseAdditive = Base + C1 * tier + C2 * tier^2 + C3 * tier^3
	BaseAdditive = {
		Base = 0.05, C1 = 0.05, C2 = 0.05, C3 = 0.01,
		Cost = { Base = 215, Growth = Config.Economy.BasePriceGrowth },
		Name = "Base Bonus", Desc = "Boost your final slot payout.",
		Icon = "➕"
	},
	-- Minimum delay between launches
	Frequency = {
		Base = 2, PerTier = 0.67,
		MaxTier = 12,
		Cost = { Base = 230, Growth = Config.Economy.BasePriceGrowth },
		Name = "Launch Delay", Desc = "Decrease time between launches",
		Icon = "🔄"
	},
	-- pegHeatFactor = PerTier * tier (additive). Sensitivity to peg heat (§1.5,
	-- simplified): tier 0 = heat has no effect; higher = aimed hot pegs pay more
	-- (and random cold paths cost more). Targeting channel; only pays with aim.
	PegHeat = {
		PerTier = 0.05,  -- INFERRED magnitude; tune against the heat map
		Cost = { Base = 180, Growth = Config.Economy.BasePriceGrowth },
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
		Cost = { Base = 105, Growth = Config.Economy.BasePriceGrowth },
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
		Cost = { Base = 105, Growth = Config.Economy.BasePriceGrowth },
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
		Cost = { Base = 105, Growth = Config.Economy.BasePriceGrowth },
		Name = "Angle", Desc = "Launch angle.",
		Icon = "🏹"
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
		Cost = { Base = 105, Growth = Config.Economy.BasePriceGrowth },
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

-- "Better view" camera angle the player can toggle to (see CameraService).
-- Placeholder — set Position/Orientation to the board-facing shot you want.
-- Orientation is in degrees, matching a Part's Orientation property (Y, X, Z order).
Config.Camera = {
	Position = Vector3.new(22.273, 237.588, -39.821),
	Orientation = Vector3.new(-47, 180, 0),
	FieldOfView = 70,
}

Config.BallTuningCamera = {
	Position = Vector3.new(21.45, 190, 300),
	Orientation = Vector3.new(-65, 0, 0),
	FieldOfView = 70
}

-- The 3D launcher model, rotated client-side (LauncherView) to match the player's
-- live aim. Orientation is yaw-only (X/Z = 0): default faces straight down the ramp,
-- and the swivel deflects it between the right and left extremes.
local functionalFolder = workspace:FindFirstChild("Functional")
Config.Launcher = {
	Model = functionalFolder and functionalFolder:FindFirstChild("Launcher"), -- workspace.Functional.Launcher
	RotationPeriod = 3, -- seconds for one full swivel cycle (shared with BallLaunchService)
	SyncInterval = 30,  -- seconds between client→server phase resyncs
	DefaultOrientation = Vector3.new(0, 90, 0), -- straight (swivel 0)
	RightOrientation = Vector3.new(0, 0, 0),    -- full right (left facing the board)
	LeftOrientation = Vector3.new(0, 180, 0),   -- full left (right facing the launcher)
	-- Launch geometry, shared by the server (actual launches) and the client (aim-line
	-- preview) so they can't drift. BaseDirection is the neutral aim (down the ramp);
	-- the swivel rotates it about +Y. LaunchOrigin is where balls spawn / lines start.
	BaseDirection = Vector3.new(0, 0, -1),
	LaunchOrigin = Vector3.new(21.3205, 172.855, 295.361),
}

-- Ball-tuning preview (client, shown while the tuning menu is open): three aim lines
-- from the launch origin (green = center aim, blue = the two arc extremes) and an
-- appearance-only ball that reflects the Size / Elasticity axes.
Config.BallTuningPreview = {
	LineLength = 45,
	LineThickness = 0.35,
	LineTransparency = 0.55,
	CenterColor = Color3.fromRGB(70, 230, 110), -- center aim
	SideColor = Color3.fromRGB(70, 150, 255),   -- arc extremes
	BallPosition = Vector3.new(30, 172.855, 295.361), -- right of the launcher (tune to taste)
}

-- Robux developer products. Logical key -> product id. The server (MonetizationService)
-- registers a grant handler per id; client UI prompts a purchase by looking the id up
-- here. Fill in real product ids from the Creator Dashboard.
Config.Products = {
	-- e.g. UpgradeBoost = 0,
	UpgradeBoost  = "3605952101",
	Multiplier2x  = "3605951905",
	Multiplier4x  = "3605951969",
	Multiplier8x  = "3605951998",
	Multiplier16x = "3605952025",
}

-- Robux game passes (permanent, one-time ownership — distinct from consumable dev
-- products above). Granted via ownership, not ProcessReceipt (see ProductService).
Config.GamePasses = {
	StarterPack = "1882812049",
}

-- Cash multiplier (Robux): a permanent global multiplier on banked cash. Each level
-- is its own dev product (Config.Products["Multiplier"..level.."x"]); the shop button
-- offers the next level in order, and disappears once the top one is owned.
Config.CashMultiplier = {
	Levels = { 2, 4, 8, 16 }, -- purchasable multipliers, ascending; last = max
}

-- Starter pack (Robux): a one-time new-player boost. Grants UpgradeTiers on every
-- upgrade track and Balance cash. Only offered while the player has fewer than
-- MaxUpgrades total upgrade tiers and hasn't already bought it. Once owned, every
-- prestige thereafter grants PostPrestigeFreeTier on all tracks.
Config.StarterPack = {
	Balance = 50000,           -- cash granted on purchase
	UpgradeTiers = 2,          -- tier every upgrade track is raised to
	MaxUpgrades = 4,           -- hide the pack once the player has this many total upgrades
	PostPrestigeFreeTier = 1,  -- free tier on all tracks after each prestige (owners only)
}

table.freeze(Config.Tags)
table.freeze(Config.Attributes)
table.freeze(Config.Scoring)
table.freeze(Config.Pegs)
table.freeze(Config.Currency)
table.freeze(Config.Groups)
table.freeze(Config.Prestige)
table.freeze(Config.Economy)
table.freeze(Config.Upgrades)
table.freeze(Config.Axes)
table.freeze(Config.Sounds)
table.freeze(Config.Camera)
table.freeze(Config.BallTuningCamera)
table.freeze(Config.Launcher)
table.freeze(Config.BallTuningPreview)
table.freeze(Config.Products)
table.freeze(Config.GamePasses)
table.freeze(Config.CashMultiplier)
table.freeze(Config.StarterPack)
return Config