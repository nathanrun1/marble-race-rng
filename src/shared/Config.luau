local RS = game:GetService("ReplicatedStorage")

local Config = {}

Config.Sounds = {
	Upgrade = "rbxassetid://106356556379520",
	Collect1 = "rbxassetid://104023881731125",
	Collect2 = "rbxassetid://83285744063515",
	Jackpot = "rbxassetid://84581872132549",
	Launch = "rbxassetid://87587182495338",
	Combo = "rbxassetid://112485190367588",
	Combo2 = "rbxassetid://123849658867902",
	Bounce = "rbxassetid://107174499116544",
	Hot = "rbxassetid://115023474688736",
	Fire = "rbxassetid://105137237689649",
	Cold = "rbxassetid://116320134099218",
	Prestige = "rbxassetid://84051226507785",
	Music = "rbxassetid://9043887120"  
}

Config.BackgroundPlaylist = {
	"rbxassetid://80978440935539", --  De Chill, Mami
	"rbxassetid://1837347090", -- Push me Slow
	"rbxassetid://71174590381361", -- Electronics Heart
	"rbxassetid://102039057339088", -- Zero Gravity
	"rbxassetid://98191313530605", -- Orbital Drift
	"rbxassetid://106258110802472", -- Docking Sequence
	"rbxassetid://71057809016365", -- Re-Entry
	"rbxassetid://135680753939150", -- Digital Detox
	"rbxassetid://121501933641667" -- Flow State
}

Config.Tags = {
	ScoreTarget = "ScoreTarget",       -- Scores on ball collision
	DestroyTarget = "DestroyTarget",   -- Destroys ball on collision
	BounceTarget = "BounceTarget",      -- Counts towards bounce combo
	JackpotTarget = "JackpotTarget",   -- Multiplies the ball's banked value by Config.Scoring.JackpotMultiplier
	Ball = "Ball",
	AutoScale = "AutoScale",             -- GuiObject auto-scaled to viewport (see client AutoScale)
	Obstacle = "Obstacle",             -- An obstacle that has an active behaviour
	Obby = "Obby",                       -- An obby model auto-wired by ObbyService (see ObbyZone)
	GroupReward = "GroupReward",         -- A floor part that grants the group reward on touch (see GroupRewardService)
	UpgradeShop = "UpgradeShop",         -- A part that opens the upgrade shop on touch (Track attribute picks the track; see client UpgradeShop)
	Coin = "Coin",                       -- A collectible-coin spawn location (per-player; see CoinService server + CoinPickups client)
	CameraZone = "CameraZone",           -- A trigger volume: while the local player stands in it, the board camera turns on (client CameraZone)
}

Config.Attributes = {
	OwnerUserId = "OwnerUserId",       -- Ball owner's user ID
	Cooldown = "Cooldown",             -- Ball same-target repeat score cooldown

	PointMul = "PointMul",             -- If defined, a destroy target's point multiplier
	DestroyTargetID = "DestroyTargetID", -- Integer id identifying which destroy target (slot) a ball banked at
	PegHeat = "PegHeat",               -- Peg heat (signed): hot >0, cold <0. Accumulated per ball, applied value-proportionally at banking, scaled by the player's PegHeat tier.

	-- Per-ball config, set at spawn from the owner's loadout (see ProfileService)
	Value = "Value",                   -- Ball's value (B/N for this batch)
	Weight = "Weight",                 -- Weight slider 0 (light) .. 1 (heavy)
	Size = "Size",                     -- Size slider
	BatchId = "BatchId",               -- Batch this ball belongs to (per-player combo settlement)

	-- Obstacle Behaviour
	ObstacleRotate = "ORotate",                     -- Obstacle rotates by given angles (Vector3)
	ObstacleAlternation = "OAlternate",          	-- Obstacle "alternates", i.e. rotates this angle in one direction, then the other (from the original orientation), repeat
	OObstacleAlternationSpeed = "OAlternateSpeed",  -- Speed of alternation
}

Config.Scoring = {
	DefaultCooldown = 1.5,
	MinCombo = 17,  -- lowered 8→5: the ball-speed cap cut bounce counts (~18→11), so combo needs an easier gate
	-- Minimum scoretarget multiplier (×) on a hit that triggers high-point FX.
	SpecialFXMinMultiplier = 1.25,
	-- Seconds a ball may stay alive before it is force-banked at 1× and despawned
	-- (a ball wedged on geometry must not live forever). Tune above a normal fall.
	MaxBallLifetime = 35,
	-- Jackpot payout: hitting a JackpotTarget adds JackpotMultiplier × the ball's
	-- otherwise-final banked value (so total = banked × (1 + this)). Tune.
	-- Lowered 20→12: the jackpot edge was >half the no-build slot EV (the bet-spam exploit).
	JackpotMultiplier = 12,
}

-- Peg-field heat values PegService writes to each peg's PegHeat attribute. Fixed
-- per category (we don't vary within hot or cold); ScoringService reads the sign
-- of the attribute to classify a hit (>0 hot, <0 cold, 0 neutral).
Config.Pegs = {
	HotHeat = 1.0,
	ColdHeat = -1.0,   -- TEMP: -1.0 for accurate EV testing; gameplay value was -1.1
	NeutralHeat = 0.0,
}

-- Destroy-target (slot) payouts, keyed by the part's DestroyTargetID attribute.
-- DestroyTargetService applies these on load: a number -> set the PointMul attribute;
-- the Jackpot sentinel -> tag the slot JackpotTarget (pays via Scoring.JackpotMultiplier)
-- instead of a PointMul. It also writes the multiplier onto the slot's
-- Parent.Display.SurfaceGui.TextLabel. Palindrome: id i and 17-i match.
Config.DestroyTargets = {
	Jackpot = "JACKPOT", -- sentinel: this slot is a JackpotTarget, not a PointMul slot
	Multipliers = {
		-- "S5" table. Non-jackpot slots (1..16) are tuned to a GENTLE EV ≈ 0.9 with a low
		-- variance (median ≈ 0.62, std ≈ 0.65) — so a non-targeting player bleeds slowly and
		-- steadily instead of riding a 0.25-median slot machine. Skewed outward: 4 winning
		-- slots/side (1.1 → 2.6) at the edges, losing center (0.4 → 0.62). The big 12× jackpot
		-- (slots 0/17) sits behind the value+heat gate (CollisionService), so its variance is
		-- quarantined to targeting builds that clear it (gate-open EV ≈ 1.34). See balance memory.
		[0] = "JACKPOT", [1] = 2.6, [2] = 1.8, [3] = 1.3, [4] = 1.1, [5] = 0.62,
		[6] = 0.52, [7] = 0.45, [8] = 0.4, [9] = 0.4, [10] = 0.45, [11] = 0.52,
		[12] = 0.62, [13] = 1.1, [14] = 1.3, [15] = 1.8, [16] = 2.6, [17] = "JACKPOT",
	} :: { [number]: number | string },
}

Config.Currency = {
	-- Cold-start onboarding: 100 couldn't afford a single core upgrade (cheapest was 230), so
	-- new players could only buy near-useless cheap axes and bled out. 1000 buys ~3 core tiers
	-- up front so the first decisions are impactful ones. Axes were repriced to ~1.5–2k so they
	-- sit ABOVE the core tracks (mid-game purchases), not below them.
	StartingBalance = 1000,
}

-- Per-player collectible coins. Each workspace part tagged Config.Tags.Coin is a spawn
-- LOCATION (shared geometry); the server (CoinService) owns which locations are "active" for
-- each player and what each is worth, while the client (CoinPickups) renders, animates, and
-- collects them locally — so coins are independent per player. Onboarding income that keeps
-- new players afloat while they figure out the upgrade loop.
Config.Coins = {
	MaxActive = 5,            -- most coins active for one player at a time
	InitialSpawn = 2,         -- coins handed to a player as soon as their client is ready
	SpawnIntervalMin = 30,    -- seconds between spawns (uniform random in [min, max]) per player
	SpawnIntervalMax = 60,
	ValueMin = 100,           -- reward range (cash), inclusive both ends
	ValueMax = 2000,
	ValueStep = 50,           -- rewards snap to this increment
	ShineTopFraction = 0.25,  -- coins in the top this fraction of the value range also get a light
	RedTopFraction = 0.5,     -- coins in the top this fraction are tinted red (parts + decals)
	RewardWarnLifetime = 2,   -- seconds the "+$X" WarnUI banner stays up
	ValuePoissonMean = 6.8    -- Poisson lambda (steps above ValueMin)
}

-- Playtime reward ladder (see PlaytimeBonusService). Cumulative seconds played -> claimable
-- cash bonus. Retention + early-game afloat. Rungs MUST be ascending by Time and are claimed
-- in order, so only APPEND new rungs (the persisted claimed-count assumes a stable order).
Config.PlaytimeBonuses = {
	Rungs = {
		{ Time = 3 * 60,   Reward = 1000 },
		{ Time = 15 * 60,  Reward = 5000 },
		{ Time = 45 * 60,  Reward = 20000 },
		{ Time = 90 * 60,  Reward = 50000 },
		{ Time = 180 * 60, Reward = 150000 },
		{ Time = 360 * 60, Reward = 500000 },
	},
}

-- Ball physics caps. MaxSpeed bounds a ball's velocity magnitude (studs/sec) while it
-- falls — BallService clamps each frame so a ball can't accelerate past it (keeps fast
-- drops/bounces from blowing through the board or feeling uncontrolled). Tune.
Config.Ball = {
	MaxSpeed = 100,
}

Config.Groups = {
	GroupId = 559054633,
	ScoreBoost = 0.10, -- multiplier bonus for group members (0.10 = +10%)
}

-- Admin UserIds: granted dev commands (DevService) and hidden from every leaderboard.
Config.Admins = { 89831196, 338455474, 110797589, 245715627 }

Config.Prestige = {
	Scale      = 10000, -- denominator in PP formula
	Exponent   = 0.35,  -- sublinear compression
	CostBase   = 700,   -- PP cost of first prestige (~30 min for an optimal build on the S5 slot table;
	                    -- assumes the gate is cleared early, i.e. VJackFraction ≈ 0.55. Re-tune DOWN if
	                    -- VJackFraction is raised so the jackpot is targeting-gated later in a run.)
	-- Per-level cost growth. Constant time-to-prestige requires CostGrowth = MultPer^Exponent
	-- (because the LB needed for prestige N grows as CostGrowth^(N/Exponent) while the global
	-- multiplier only offsets it as MultPer^N). Break-even here is 1.25^0.35 ≈ 1.08. The old 2.0
	-- was WAY above it: requirement grew 7.25^N vs a 1.25^N multiplier, so late prestiges took
	-- exponentially longer AND the targeting build (which banks super-linearly in time) pulled
	-- ahead of combo. Sitting just above break-even keeps every run a near self-similar copy of
	-- run 0 — so whatever build balance holds at prestige 0 holds forever — with a gentle (~6%/level)
	-- lengthening so later prestiges still feel like a step up.
	CostGrowth = 1.15,
	MultPer    = 1.25,  -- global banked multiplier per prestige (multiplicative)
	-- Anti-hoard: available PP is an earn/spend currency. Banking stops crediting PP once you hold
	-- this many × the next prestige's cost, so you can buffer at most ~one extra prestige and can't
	-- farm lifetime banked into a stockpile of prestiges. Prestige SPENDS the cost (see PrestigeService).
	HoldCapMult = 1.5,
	-- Once banking is capped (no more PP credited), nag the player to rebirth at most this
	-- often (seconds) via WarnUI, since further play is wasted PP until they prestige.
	LimitWarnInterval = 20,
	NoScoreSeconds = 5, -- post-prestige no-score window (exploit guard)
}

Config.Economy = {
	StartMaxBet = 40,         -- guideline §4; base for the MaxBet track
	TrickleFraction = 0.05,    -- × currentMaxBet, free per batch (§1.2)
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
	-- maxBet grows 1.5×/tier (was 4.05): ×4 per tier made income explode far past cost,
	-- so bet-spam snowballed instantly. Cost grows 1.9× so tiers gate on time, not trivially.
	MaxBet = {
		PerTier = 1.5,
		Cost = { Base = 250, Growth = 1.9 },
		Name = "Max Bet", Short = "Bet", Desc = "Raise your betting ceiling.",
		Icon = "💰"
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
		Name = "Combo", Short = "Combo", Desc = "More cash per bounce during a combo ("..Config.Scoring.MinCombo.." or more)",
		Icon = "⚡"
	},
	-- baseAdditive = Base + C1 * tier + C2 * tier^2 + C3 * tier^3
	-- Flattened to linear +5%/tier (was cubic → ×26 at tier 12, which dwarfed every other
	-- lever and exploded income). Now +60% at max: a real lever, not a runaway.
	BaseAdditive = {
		Base = 0.0, C1 = 0.05, C2 = 0.0, C3 = 0.0,
		Cost = { Base = 300, Growth = 1.7 },
		Name = "Base Bonus", Short = "Base", Desc = "Boost your marble cash payout.",
		Icon = "➕"
	},
	-- Minimum delay between launches. PerTier 0.67→0.82: gentler throughput ramp. Cost growth
	-- 4.5→1.9: at 4.5 it was never ROI-positive (throughput investment was dead); now buyable.
	Frequency = {
		Base = 2, PerTier = 0.82,
		MaxTier = 12,
		Cost = { Base = 230, Growth = 1.9 },
		Name = "Launch Delay", Short = "Freq", Desc = "Decrease time between launches",
		Icon = "🔄"
	},
	-- pegHeatFactor = PerTier * tier (additive). Sensitivity to peg heat (§1.5,
	-- simplified): tier 0 = heat has no effect; higher = aimed hot pegs pay more
	-- (and random cold paths cost more). Targeting channel; only pays with aim.
	PegHeat = {
		PerTier = 0.05,  -- INFERRED magnitude; tune against the heat map
		Cost = { Base = 220, Growth = 1.7 },
		Name = "Heat Sense", Short = "Heat", Desc = "Hot and cold obstacles affect you more strongly.",
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
	Short: string?,
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
		Cost = { Base = 1500, Growth = Config.Economy.BasePriceGrowth },
		Name = "Bounciness", Short = "Bounce", Desc = "How bouncy the marble is.",
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
			{ Min = 0.57, Max = 0.91 },  -- (Size ranges unchanged)
			{ Min = 0.55, Max = 0.94 },
			{ Min = 0.53, Max = 0.96 },
			{ Min = 0.51, Max = 0.98 },
			{ Min = 0.5, Max = 1 },
		},
		Cost = { Base = 2000, Growth = 1.8 },
		Name = "Marble Size", Short = "Size", Desc = "Unlock different marble sizes.",
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
		Cost = { Base = 1500, Growth = Config.Economy.BasePriceGrowth },
		Name = "Angle", Short = "Angle", Desc = "Tune the launch direction.",
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
		Cost = { Base = 1500, Growth = Config.Economy.BasePriceGrowth },
		Name = "Launcher Swivel", Short = "Swivel", Desc = "Widen or tighten the possible launch angles.",
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
	MaxUpgrades = 20,           -- hide the pack once the player has this many total upgrades
	PostPrestigeFreeTier = 1,  -- free tier on all tracks after each prestige (owners only)
}

Config.Obby = {
	DefaultWalkSpeed = 32,  -- restored when a player leaves the obby area
	ObbyWalkSpeed = 16,     -- forced while inside the Checkpoints.In volume
}

-- Group reward (a part tagged Config.Tags.GroupReward, walked on to claim). Group
-- members get Fraction of their current balance, then can't reclaim for Cooldown
-- seconds. The server owns the cooldown + grant; the client only renders the sign.
Config.GroupReward = {
	Fraction = 0.15,             -- fraction of current balance granted per claim
	Cooldown = 5 * 60 * 60,      -- seconds between claims (5 hours)
	LabelColor = Color3.fromRGB(93, 214, 84), -- "Claim Group Reward" sign colour
	MsgColor = Color3.fromRGB(230,230,230),
}

-- Day/night cycle (server DayNightCycle behaviour). Lighting.ClockTime runs from SunriseTime up
-- to SunsetTime over DayMinutes of real time, then SunsetTime back round to SunriseTime over
-- NightMinutes — so the two halves can last different real durations. Servers start at sunrise.
Config.DayNight = {
	DayMinutes   = 8,   -- real minutes for the day half (sunrise -> sunset)
	NightMinutes = 4,   -- real minutes for the night half (sunset -> sunrise)
	SunriseTime  = 6,   -- ClockTime (hour, 0-24) the day starts at
	SunsetTime   = 18,  -- ClockTime (hour, 0-24) the night starts at
	StartTime    = 9.4, -- ClockTime the cycle begins at when the server starts
}

table.freeze(Config.Tags)
table.freeze(Config.Attributes)
table.freeze(Config.Scoring)
table.freeze(Config.Pegs)
table.freeze(Config.DestroyTargets)
table.freeze(Config.DestroyTargets.Multipliers)
table.freeze(Config.Currency)
table.freeze(Config.Ball)
table.freeze(Config.Groups)
table.freeze(Config.Admins)
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

Config.Animations = {
	ElectroSwing = "81301976341047",
	FancyFeet = "88664003295065",
	Pumpernickel = "81151223555196"
}

-- Rebirths podium (the top-3 statues by Workspace.Leaderboards.Rebirths.Podium). Each statue
-- loops an animation — a KeyframeSequence by NAME under ReplicatedStorage.Assets.Animations
-- (no upload needed; played client-side via AnimationService). Leave "" for no animation.
Config.Podium = {
	Animations = {
		First = Config.Animations.ElectroSwing,  -- 1st place
		Second = Config.Animations.FancyFeet,      -- 2nd place
		Third = Config.Animations.Pumpernickel,            -- 3rd place
	},
}

-- Tutorial sequence, played once on join (client TutorialService) until the player completes
-- or skips it. Each step shows a medium-large message in a box with Skip / Next buttons, and
-- can darken the screen except for a highlighted spot. Steps transition smoothly into one
-- another.
--   text        : the message (string).
--   boxPosition : UDim2 centre of the message box (Scale). Defaults to lower-centre.
--   highlight   : optional { Position = UDim2 (centre of the spot), Size = UDim2 (spot size) }.
--                 Present = dim everything except this rect; absent = no dimming. The UDim2s
--                 resolve like any screen UDim2 (Scale × viewport) but the Offset is multiplied
--                 by the AutoScale factor — so you can author the spot in 1080p offset pos/size
--                 to line up with AutoScaled UI elements (use the element's own UDim2 + size).
--   camera      : optional { Position = Vector3, Orientation = Vector3 (deg), FieldOfView = number? }
--                 scripted camera shot for the step (smoothly tweened); absent = default camera.
-- UI Positions/sizes are Scale-based (0..1 of the screen) so they're resolution-independent.
Config.Tutorial = {
	Steps = {
		{
			text = "Welcome to Marble Race! Let's run through the basics.",
			boxPosition = UDim2.fromScale(0.5, 0.5),
		},
		{
			text = "Click this button to launch marbles. You can automatically launch by enabling Auto Mode.",
			boxPosition = UDim2.fromScale(0.5, 0.6),
			highlight = { Position = UDim2.fromScale(0.5, 0.895), Size = UDim2.fromScale(0.294, 0.199) },
		},
		{
			text = "Land in the slots to bank cash. The bigger the slot multiplier, the better!",
			camera = {
				Position = Vector3.new(15.014, 47.023, -45.051),
				Orientation = Vector3.new(-22.981, -179.694, -0),
				FieldOfView = 70,
			},
		},
		{
			text = "Adjust your bet size here. Bet big to make more money!",
			boxPosition = UDim2.fromScale(0.3, 0.6),
			highlight = { Position = UDim2.fromOffset(198, 971), Size = UDim2.fromOffset(376, 214)},
		},
		{
			text = "Tune your marble here: its size, bounciness, and aim.",
			boxPosition = UDim2.fromScale(0.3, 0.5),
			highlight = { Position = UDim2.fromOffset(135, 825), Size = UDim2.fromOffset(250, 90) },
		},
		{
			text = "Spend your cash on upgrades, then rebirth for permanent boosts.",
			camera = {
				Position = Vector3.new(-9.47156047821045, 145.8722381591797, -165.1833038330078),
				Orientation = Vector3.new(-17.448, 117.043, 0),
				FieldOfView = 70,
			},
		},
		{
			text = "If you run out of cash, complete these obbies to earn more. There are also coins available around the map to collect. Good luck!",
			boxPosition = UDim2.fromScale(0.5, 0.8),
			camera = {
				Position = Vector3.new(13.617, 154, -135.484),
				Orientation = Vector3.new(-14.94, -20.121, 0),
				FieldOfView = 70,
			},

		}
	},
}

table.freeze(Config.Animations)
table.freeze(Config.DayNight)
table.freeze(Config.Obby)
table.freeze(Config.GroupReward)
table.freeze(Config.Podium)
table.freeze(Config.Podium.Animations)
table.freeze(Config.Tutorial)
return Config