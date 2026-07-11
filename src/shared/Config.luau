local RS = game:GetService("ReplicatedStorage")

local Config = {}

Config.Sounds = {
	Upgrade = "rbxassetid://106356556379520",
	Collect1 = "rbxassetid://104023881731125",
	Collect2 = "rbxassetid://83285744063515",
	Collect3 = "rbxassetid://100610043368485",
	Jackpot = "rbxassetid://84581872132549",
	Launch = "rbxassetid://87587182495338",
	Combo = "rbxassetid://112485190367588",
	Combo2 = "rbxassetid://123849658867902",
	Bounce = "rbxassetid://107174499116544",
	Hot = "rbxassetid://115023474688736",
	Fire = "rbxassetid://105137237689649",
	Cold = "rbxassetid://116320134099218",
	Prestige = "rbxassetid://84051226507785",
	Music = "rbxassetid://9043887120",
	Confirmation3 = "rbxassetid://87535825628082",
	Confirmation2 = "rbxassetid://124879887650269",
	Confirmation4 = "rbxassetid://80527877392020",
	Toggle2 = "rbxassetid://120678299885068",
	Switch2 = "rbxassetid://138551870543599"
}

-- The game's default UI click, played by SoundService.PlayClick(): every UIButton
-- without its own clickSound, plus the hand-wired shop/panel buttons. A full
-- SoundService.Play spec, so volume/pitch/jitter all tune here globally.
-- ("" soundId = silent, same placeholder convention as before.)
Config.Sounds.DefaultClick = {
	soundId = Config.Sounds.Switch2,
	pitch = 2.2,   -- PlaybackSpeed
	volume = 0.125, -- half the SoundService default (0.5)
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
	CosmeticsGui = "CosmeticsGui",       -- A SurfaceGui the cosmetics shop is built into (client CosmeticsShop)
	CosmeticBallSample = "CosmeticBallSample", -- A part; a sample ball of the selected cosmetic floats above it (client CosmeticBallSample)
	Teleport = "Teleport",               -- A pad that teleports a touching player to its Teleport attribute (Vector3; see TeleportPads)
	CashBalance = "CashBalance",         -- A TextLabel (or a container holding one) kept in sync with the player's Cash balance (client BalanceUIController)
	DiamondsBalance = "DiamondsBalance", -- A TextLabel (or a container holding one) kept in sync with the player's Diamonds balance (client BalanceUIController)
	Board = "Board",                     -- Any part of the physical board whose look scales with bet tier (client BoardAppearanceView)
	BoardFloor = "BoardFloor",           -- The floor parts marbles roll on (darker default; see Config.BoardAppearance)
	BoardSide = "BoardSide",             -- The barrier/side parts (lighter default; see Config.BoardAppearance)
	QuestUI = "QuestUI",                 -- A SurfaceGui the daily-quest panel is also built into (client QuestUI)
	FreeCratePad = "FreeCratePad",       -- A pad that claims the free Marble Box on touch (client CosmeticsShop builds its billboard/timer)
	DailyRewardPad = "DailyReward",      -- A pad that claims the daily reward on touch (client DailyRewardUI fills its authored Billboard.BillboardGui Title/Timer)
	UpgradeLock = "UpgradeLock",         -- A world lock Model gating upgrade tracks: attribute "UpgradeLock" lists the tracks, "Price" is the cash unlock cost, child "Pad" is the unlock pad (server UpgradeLockService + client UpgradeLocks)
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

-- Peg "heat sense" appearance, driven by the LOCAL player's PegHeat ("Heat Sense") upgrade
-- tier — client PegHeatView. The shared/server truth (PegService) always paints hot/cold
-- pegs the same purplish colors for everyone; this is a purely local repaint on top, so a
-- tier-0 player sees hot and cold pegs as an undifferentiated dull gray (can't heat-sense
-- yet), and each tier blends further toward the "true" hot/cold color, capped at MaxTier.
-- Hot/Cold true colors lean toward actual red/blue (vs. PegService's magenta/violet
-- gameplay colors) but deliberately don't go fully pure — a little of that identity stays.
Config.PegHeatAppearance = {
	MaxTier = 15,
	DullColor = Color3.fromRGB(140, 140, 145), -- tier 0: hot and cold look identical
	Hot = { Color = Color3.fromRGB(255, 89, 89) },  -- true hot at MaxTier
	Cold = { Color = Color3.fromRGB(98, 37, 209) }, -- true cold at MaxTier
	-- Normal (neither hot nor cold) pegs are flat DullColor at bet tier 0, blending toward this
	-- as the LOCAL viewer's selected bet tier rises to Config.BoardAppearance.MaxTier (same
	-- tier scale BoardAppearanceView uses) — a visual reward for betting bigger, independent of
	-- the PegHeat upgrade tier above.
	NormalBetColor = Color3.fromRGB(180, 128, 255),
	Particles = {
		MinTier = 1,     -- no particles at all below this tier (tier 0 is fully plain)
		HotSparkColor = Color3.fromRGB(255, 140, 40),  -- orange sparks
		ColdAuraColor = Color3.fromRGB(150, 205, 255), -- pale-blue "cold" puff
	},
	-- PegService silently promotes some hot pegs to a hidden "double-hot" (3x heat, no
	-- shared visual tell — see PegService.promoteDoubleHot). Below this tier a double-hot
	-- peg is indistinguishable from an ordinary hot one; at/above it, PegHeatView reveals
	-- the promotion locally with a Neon glow + Fire (fire is otherwise unused by peg
	-- appearance — reserved for this reveal).
	DoubleHotMinTier = 1,
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

-- The $/marble average (StatsService.GetAvgMoneyPerBall — HUD, leaderstat, global leaderboard):
-- an exponentially-weighted average over only the most recent Window balls banked. A ball older
-- than Window balls ago is dropped entirely (zero influence, not just decayed-small); within the
-- window, Decay^age weights recent balls higher. Decay is derived so the OLDEST ball still in the
-- window (age Window-1) carries ~1% of the newest ball's weight — Window alone can be retuned
-- and Decay follows automatically.
Config.BallAverage = {
	Window = 50,
}
Config.BallAverage.Decay = 0.01 ^ (1 / (Config.BallAverage.Window - 1))

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
	ValueMin = 50,            -- reward range (cash), inclusive both ends
	ValueMax = 1000,
	ValueStep = 25,           -- rewards snap to this increment
	ShineTopFraction = 0.25,  -- coins in the top this fraction of the value range also get a light
	RedTopFraction = 0.5,     -- coins in the top this fraction are tinted red (parts + decals)
	RewardWarnLifetime = 2,   -- seconds the "+$X" WarnUI banner stays up
	ValuePoissonMean = 6.8,   -- Poisson lambda (steps above ValueMin)

	-- Blue coins: rolled independently at spawn time, pay Diamonds (the cc cosmetics
	-- currency) instead of cash. BiasExponent > 1 skews the roll toward Min via
	-- random()^BiasExponent (1 = uniform, 2 = quadratic bias low, ...) — see CoinService.
	BlueChance = 0.20,
	BlueDiamonds = { Min = 1, Max = 5, BiasExponent = 2 },
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
Config.Admins = { 89831196 }

-- Custom day-by-day analytics (MetricsService): DAU, new players, sessions, playtime, and
-- D1/D7/D30 retention — the Roblox-dashboard numbers, minus the players below, because
-- dev/tester sessions distort a small game's stats and the official dashboard can't filter
-- them. Config.Admins are ALWAYS excluded on top of this list. Only live servers record;
-- print anywhere with /metrics [days] (needs API access enabled in Studio).
Config.Metrics = {
	ExcludedUserIds = { 338455474, 110797589, 1244172772, 245715627, 1244172772 },  -- extra user ids to exclude besides the admins
	ReportDays = 14,       -- default day rows /metrics prints
}

Config.WarnUI = {
	MaxStack = 5, -- banners visible at once; older ones are pruned to keep this cap (like ScoreUI)
}

-- Diamonds purchase packs (client DiamondsShopUI + product registration in CosmeticService).
-- Ordered smallest -> biggest; Diamonds-per-Robux IMPROVES up the ladder so bigger packs are
-- better value (RobuxHint is display-only fallback text — the real price comes from the dev
-- product once its id is set). PLACEHOLDER product ids ("0" = button prompts nothing).
Config.DiamondPacks = {
	{ Id = "Handful",  Name = "Handful of Diamonds",  Icon = "🤲", Diamonds = 100,  Product = "3608551478", RobuxHint = 50 },
	{ Id = "Crate",    Name = "Crate of Diamonds",    Icon = "📦", Diamonds = 350,  Product = "3608551532", RobuxHint = 149 },
	{ Id = "Pile",     Name = "Pile of Diamonds",     Icon = "💰", Diamonds = 900,  Product = "3608551575", RobuxHint = 349 },
	{ Id = "Mountain", Name = "Mountain of Diamonds", Icon = "⛰️", Diamonds = 3000, Product = "3608551623", RobuxHint = 999 },
}

Config.Prestige = {
	Scale      = 18820, -- denominator in PP formula (earnedPP = (creditedBanked/Scale)^Exponent).
	                       -- Divided ×10^3 from 18820000 to make rebirths easier: since required cash
	                       -- LB_n = Scale × cost(n)^(1/Exponent), this divides the lifetime-banked
	                       -- threshold for EVERY prestige level by 1000 while CostBase (still 50 PP for
	                       -- prestige #1) and the whole PP cost curve are untouched — only how much cash
	                       -- it takes to earn a given amount of PP changed, not the PP economy itself.
	Exponent   = 0.35,  -- sublinear compression
	CostBase   = 50,    -- PP cost of first prestige (computeCost is 1-indexed, so this IS prestige #1's
	                    -- cost). With Scale above, ~30 min for an optimal build on the S5 slot table
	                    -- (assumes the gate is cleared early, i.e. VJackFraction ≈ 0.55).
	-- Per-level cost growth. Constant time-to-prestige requires CostGrowth = MultPer^Exponent
	-- (because the LB needed for prestige N grows as CostGrowth^(N/Exponent) while the global
	-- multiplier only offsets it as MultPer^N). Break-even here is 1.25^0.35 ≈ 1.081. The old 2.0
	-- was WAY above it: requirement grew 7.25^N vs a 1.25^N multiplier, so late prestiges took
	-- exponentially longer AND the targeting build (which banks super-linearly in time) pulled
	-- ahead of combo. Current value targets the CASH requirement growing exactly 1.2× faster
	-- per level than the multiplier offsets it: CostGrowth = (1.2 × MultPer)^Exponent =
	-- 1.5^0.35 ≈ 1.1525, i.e. each prestige takes ~20% longer in real time than the previous
	-- one — every run stays a near-copy of run 0, with later prestiges a clear step up.
	CostGrowth = 1.1525,
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
	StartMaxBet = 40,          -- guideline §4; anchor for the MaxBet ladder from tier 1 up (see MaxBet below)
	StartBetSize = 10,         -- tier 0's bet size: the free starting rung, below StartMaxBet's old tier-0 value
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
		Name = "Max Bet", Short = "Bet", Desc = "Raise your betting ceiling.",
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
		Name = "Combo", Short = "Combo", Desc = "More cash per bounce during a combo ("..Config.Scoring.MinCombo.." or more)",
		Icon = "⚡"
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
		Name = "Mult Bonus", Short = "Base", Desc = "Boost the board's slot multipliers.",
		Icon = "➕"
	},
	-- Minimum delay between launches. PerTier 0.67→0.82: gentler throughput ramp. Cost growth
	-- 4.5→1.9: at 4.5 it was never ROI-positive (throughput investment was dead); now buyable.
	Frequency = {
		Base = 2, PerTier = 0.82,
		MaxTier = 12,
		Cost = { Base = 230, Growth = 1.9 },
		Name = "Launch Frequency", Short = "Freq", Desc = "Increase marbles launched per second.",
		Icon = "🔄",
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
	Icon: string?,
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
		Icon = "💨",
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
		Icon = "◯",
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
		Cost = { Base = 1500, Growth = Config.Economy.BasePriceGrowth },
		Name = "Launcher Swivel", Short = "Swivel", Desc = "Widen or tighten the possible launch angles.",
		Icon = "🎯",
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
	BallDropMaxBet = "3607663509",
}

-- Minimum seconds between auto-prompts of the UpgradeBoost (3×) purchase dialog when a player
-- clicks Buy and can't afford the upgrade (ShopUI's promptBoost, BallLaunchUI's attemptUnlock) —
-- otherwise repeatedly clicking Buy while broke would pop the Robux dialog every single click.
Config.UpgradeBoostPromptCooldown = 600

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

-- Ball Drop (Robux): a consumable dev product (Config.Products.BallDropMaxBet) that instantly
-- fires Count balls, each valued at the player's CURRENT max bet (not their chosen loadout.Bet) —
-- free, bypassing the launch cooldown/affordability check (see BallLaunchService.LaunchMaxBetBatch).
Config.BallDrop = {
	Count = 30,
}

-- Golden pegs (prestige perk): rebirths mark pegs on the board as "golden" on an escalating
-- schedule — peg k at prestige k(k+1)/2, i.e. 1, 3, 6, 10, ... (see GoldenPegService) —
-- FOR THAT PLAYER — the board is shared, so the set is per-player and only that player's
-- balls trigger it (their golden pegs are highlighted client-side by GoldenPegView). When
-- one of your balls hits one of your golden pegs (at most once per ball per peg), it rolls:
-- CloneChance → the ball is cloned into a second free ball of the same value; otherwise the
-- ball's live value is multiplied by BoostMult. See GoldenPegService (set + clone) /
-- ScoreHandler (trigger).
Config.GoldenPegs = {
	DoubleChance = 0.90, -- probability a golden hit boosts the ball's value (by BoostMult)
	CloneChance = 0.10,  -- probability a golden hit clones the ball instead
	BoostMult = 1.1,     -- value multiplier on a boost hit (was ×2 — nerfed, it dominated)
	MaxPegs = 10,        -- hard per-player cap; the unlock schedule stops here
}

-- Board look scales with the LOCAL player's current bet tier (client BoardAppearanceView) —
-- the board is shared, but each client repaints Config.Tags.Board/BoardFloor/BoardSide parts
-- to reflect its own viewer's bet size, same "local view of shared state" pattern as
-- GoldenPegView/BoardMultiplierView. Boring/plain at tier 0, maximally "leveled up" by
-- MaxTier — tiers beyond MaxTier all render at the MaxTier look (no further escalation).
--
-- Floor/Side are each a list of keyframes (ascending Tier). Between two keyframes, Color
-- lerps linearly by tier; Material has no in-between, so it holds the LOWER keyframe's
-- Material until the tier reaches the next one. A tier past the last keyframe holds that
-- keyframe's Color/Material. Keyframes are deliberately DENSE in the first ~10 tiers (every
-- 2) so the very first few raises already read as a real hue change, not a grayscale
-- flicker — spaced wider after that once the player has more time-per-tier to notice it.
Config.BoardAppearance = {
	MaxTier = 25,
	Floor = { -- a real color journey, not just darker/lighter: drab -> copper -> steel ->
		-- emerald -> violet -> crimson -> gold -> obsidian
		{ Tier = 0,  Color = Color3.fromRGB(58, 58, 62),   Material = Enum.Material.Concrete },
		{ Tier = 2,  Color = Color3.fromRGB(96, 62, 40),   Material = Enum.Material.SmoothPlastic },
		{ Tier = 4,  Color = Color3.fromRGB(150, 96, 40),  Material = Enum.Material.Metal },
		{ Tier = 6,  Color = Color3.fromRGB(40, 92, 150),  Material = Enum.Material.Marble },
		{ Tier = 9,  Color = Color3.fromRGB(24, 130, 84),  Material = Enum.Material.Granite },
		{ Tier = 12, Color = Color3.fromRGB(96, 32, 150),  Material = Enum.Material.Marble },
		{ Tier = 16, Color = Color3.fromRGB(150, 20, 44),  Material = Enum.Material.Slate },
		{ Tier = 20, Color = Color3.fromRGB(180, 140, 24), Material = Enum.Material.Metal },
		{ Tier = 25, Color = Color3.fromRGB(14, 12, 18),   Material = Enum.Material.Neon },
	},
	Side = { -- lighter/brighter counterpart to each Floor stage, same journey
		{ Tier = 0,  Color = Color3.fromRGB(235, 235, 235), Material = Enum.Material.SmoothPlastic },
		{ Tier = 2,  Color = Color3.fromRGB(235, 195, 150), Material = Enum.Material.Plastic },
		{ Tier = 4,  Color = Color3.fromRGB(255, 195, 110), Material = Enum.Material.Foil },
		{ Tier = 6,  Color = Color3.fromRGB(140, 195, 245), Material = Enum.Material.Marble },
		{ Tier = 9,  Color = Color3.fromRGB(130, 235, 185), Material = Enum.Material.Marble },
		{ Tier = 12, Color = Color3.fromRGB(205, 150, 245), Material = Enum.Material.Marble },
		{ Tier = 16, Color = Color3.fromRGB(255, 140, 165), Material = Enum.Material.Ice },
		{ Tier = 20, Color = Color3.fromRGB(255, 220, 110), Material = Enum.Material.Foil },
		{ Tier = 25, Color = Color3.fromRGB(255, 240, 200), Material = Enum.Material.Neon },
	},
}

-- Daily quests (QuestService + client QuestUI). Each UTC day every player gets Count quests
-- drawn (distinct) from Templates, with a random target snapped to Target.Step within
-- [Target.Min, Target.Max]. Rewards pay CC (the cosmetics currency, see Config.Cosmetics) —
-- flat amounts, since skin prices don't scale with prestige: reward = lerp(Reward.Min,
-- Reward.Max, t) where t is how far the rolled target sits in its range (bigger ask =
-- bigger payout), locked in at generation. For scale: a full quest day pays ~40–90 CC and
-- the cheapest skin costs 50. Progress persists via DataService and the whole set
-- regenerates at the UTC day rollover.
--   Kind "count" — progress accumulates toward the target (bank N marbles, N jackpots, ...)
--   Kind "best"  — progress is a high-water mark (best combo banked on a single marble)
Config.Quests = {
	Count = 3, -- quests per day
	Templates = {
		BankBalls    = { Kind = "count", Text = "Bank %d marbles",                 Icon = "🏦", Target = { Min = 60, Max = 160, Step = 10 }, Reward = { Min = 10, Max = 25 } },
		HitJackpots  = { Kind = "count", Text = "Hit the jackpot %d time(s)",      Icon = "💎", Target = { Min = 1, Max = 3, Step = 1 },     Reward = { Min = 15, Max = 40 } },
		BestCombo    = { Kind = "best",  Text = "Bank a marble with a %d+ combo",  Icon = "⚡", Target = { Min = 22, Max = 30, Step = 1 },   Reward = { Min = 12, Max = 28 } },
		HotPegHits   = { Kind = "count", Text = "Hit %d hot pegs",                 Icon = "🔥", Target = { Min = 100, Max = 250, Step = 25 }, Reward = { Min = 10, Max = 25 } },
		CollectCoins = { Kind = "count", Text = "Collect %d coins",                Icon = "🪙", Target = { Min = 3, Max = 6, Step = 1 },     Reward = { Min = 8, Max = 18 } },
		BuyUpgrades  = { Kind = "count", Text = "Buy %d upgrade tiers",            Icon = "🛒", Target = { Min = 3, Max = 8, Step = 1 },     Reward = { Min = 10, Max = 22 } },
		Rebirth      = { Kind = "count", Text = "Rebirth %d time(s)",              Icon = "🔄", Target = { Min = 1, Max = 2, Step = 1 },     Reward = { Min = 25, Max = 50 } },
	},
}

-- Daily login reward (server DailyRewardService + client DailyRewardUI): once per UTC day, a
-- centered prompt offers a claim; claiming rolls a weighted prize from Pool and reveals it via
-- a horizontal slot-style reel spin. Granting/rendering a reward Kind is a small registry in
-- each of DailyRewardService (server, rolls+grants) and DailyRewardUI (client, cell/result
-- display) — add a new Kind by extending Pool + both registries, nothing else changes.
--   Diamonds : flat Min..Max Diamonds, boosted by the login-streak Luck Bonus (below).
--   Cash     : Multiplier × the player's HIGHEST-OWNED MaxBet tier's bet size (NOT their
--              currently selected bet) — scales with progression without its own tier/config.
--   Crate    : a free UNOPENED Marble Box (BoxId picks which) banked into the player's
--              stash — they open it at the cosmetics shop whenever they like.
Config.DailyReward = {
	-- Ordered worst -> best; Weight falls as the prize's value rises, so probability actually
	-- tracks how good a roll is (10 > 8 > 5 > 4 > 2 > 1.5 > 1). The rare/top Diamonds tier is
	-- the "lucky end": ~10 Diamonds max, deliberately modest next to a free Basic Box (150
	-- Diamonds' worth) or the big Cash multiplier — Diamonds/day is meant to trickle, not
	-- race a player to a Marble Box (rebirthing is the intended main Diamonds source).
	Pool = {
		{ Kind = "Diamonds", Weight = 10, Min = 2, Max = 4 },
		{ Kind = "Cash", Weight = 8, Multiplier = 1 },
		{ Kind = "Diamonds", Weight = 5, Min = 4, Max = 7 },
		{ Kind = "Cash", Weight = 4, Multiplier = 3 },
		{ Kind = "Diamonds", Weight = 2, Min = 7, Max = 10 },
		{ Kind = "Cash", Weight = 1.5, Multiplier = 8 },
		{ Kind = "Crate", Weight = 1, BoxId = "Basic" },
		{ Kind = "Crate", Weight = 0.4, BoxId = "Silver" },
	},
	-- Diamonds-only streak bonus ("Luck Bonus" in the UI): +StreakBonusPerDay per consecutive
	-- login day beyond the first, capped at MaxBonusDays (so it doesn't grow forever) — e.g.
	-- day 4 -> +15% at the default 5%/day. Missing a day resets the streak to 1 (no bonus).
	StreakBonusPerDay = 0.05,
	MaxBonusDays = 20, -- caps the bonus at +100% (20 × 5%)
	-- Slot-reel visuals (client DailyRewardUI): a horizontal strip of decorative filler cells
	-- spins past and decelerates onto the true (server-rolled) result, which sits
	-- CellsAfterResult cells before the strip's end (so it doesn't look like it just happened
	-- to land on the very last one).
	Reel = {
		FillerCells = 24,
		CellsAfterResult = 3,
		CellSize = Vector2.new(140, 140),
		CellPadding = 12,
		SpinTime = 3.2,
	},
}

-- Starter pack (Robux): a one-time new-player boost. Grants Balance cash, Diamonds,
-- and Crates.Count free openings of the Crates.BoxId box. Only offered while the
-- player has fewer than MaxUpgrades total upgrade tiers and hasn't already bought it.
-- Once owned, every prestige thereafter grants PostPrestigeFreeTier on all tracks.
Config.StarterPack = {
	Balance = 75000,           -- cash granted on purchase
	Diamonds = 100,            -- Diamonds granted on purchase
	Crates = { BoxId = "Silver", Count = 2 }, -- free crate rolls granted on purchase
	Boost = { Mult = 1.5, Hours = 24 }, -- timed cash multiplier granted on purchase
	MaxUpgrades = 20,           -- hide the pack once the player has this many total upgrades
	PostPrestigeFreeTier = 1,  -- free tier on all tracks after each prestige (owners only)
}

-- Beginner's Luck: a one-time, free timed cash boost for brand-new accounts only (granted by
-- DataService.onPlayerAdded the moment it finds no saved data at all — never re-granted on a
-- later session). Reuses the same timed-boost slot as Config.StarterPack.Boost
-- (StatsService.GrantCashBoost/GetCashBoost) rather than a separate mechanism; a real
-- starter-pack purchase during the window simply overwrites it (last grant wins), which is
-- fine since a first-minute player won't have bought it yet. Exists to nudge a fresh default
-- build's board EV (~0.95-1.0x) just over 1.0x so the first autonomous minutes aren't a
-- coinflip that ends most sessions before the player is invested.
Config.BeginnersLuck = {
	Mult = 1.15,        -- multiplier on banked cash while active
	Seconds = 15 * 60,  -- window length from first join
}

-- Cosmetics (ball skins) economy. Skins themselves live in shared/BallSkins; this holds the
-- currency tuning. CC (Cosmetic Coins) is earned by rebirthing — RebirthCCRatio × the RP spent on
-- each rebirth — and spent on skins. The yellow-themed shop lives on a SurfaceGui tagged
-- Config.Tags.CosmeticsGui, with a floating sample ball over Config.Tags.CosmeticBallSample.
-- RarityProducts (one Robux dev product per rarity) is the direct-buy path shown ONLY to
-- paid-random-items-restricted players (crates/Diamond packs are Robux-blocked for them).
Config.Cosmetics = {
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
		"3607562744"
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
	-- Duplicate copies star a skin up: ★k at StarDupes[k] DUPLICATES (copies beyond the
	-- first). Triangular like the golden peg schedule: 0, 1, 3, 6, 10.
	StarDupes = { 0, 1, 3, 6, 10 },
	-- Bonus multiplier at ★1..★5: a ★5 common (+8%) rivals a fresh epic (+30%)... almost.
	StarMults = { 1, 1.5, 2, 3, 4 },
}

-- Marble Boxes: crate rolls are the main way to get skins (the shop's direct-purchase flow
-- is retired in favour of the index tab). Weights are per-rarity (1..5) relative chances.
-- Pity: rolling Every times without hitting rarity >= MinRarity forces one; the counter
-- resets whenever a roll (natural or forced) lands MinRarity+. Counters persist per box.
-- The Free box is never purchasable: it's granted on a session timer (FirstDelay after
-- join, then every Interval after each claim) and claimed from the shop's crates tab.
Config.Crates = {
	-- Weights are per-rarity (1..9); rarities 6-9 only drop from the Gold Box.
	-- Product: a Robux dev product that opens ONE box of this type (pity ticks as usual).
	-- PLACEHOLDER ids — fill in real product ids from the Creator Dashboard ("0" = hidden).
	-- Every tier carries a TINY tail into higher rarities than its bread-and-butter range
	-- (Free→Legendary, Basic→Mythic, Silver→Divine): barely moves the distribution, but
	-- even the cheapest box can dream.
	Boxes = {
		{ Id = "Basic",  Name = "Basic Box",  Cost = 150,  Product = "3608526615", Weights = { 60, 30, 9, 1, 0.25, 0.05, 0, 0, 0 },  Pity = { Every = 10, MinRarity = 3 } },
		{ Id = "Silver", Name = "Silver Box", Cost = 400,  Product = "3608536989", Weights = { 30, 40, 22, 7, 1, 0.2, 0.06, 0.02, 0 }, Pity = { Every = 15, MinRarity = 4 } },
		{ Id = "Gold",   Name = "Gold Box",   Cost = 1000, Product = "3608537009", Weights = { 0, 25, 45, 24, 5, 0.7, 0.2, 0.08, 0.02 }, Pity = { Every = 20, MinRarity = 5 } },
	},
	Free = {
		Id = "FreeBox",
		Name = "Free Box",
		Weights = { 75, 20, 4.5, 0.5, 0.08 },
		FirstDelay = 0, -- seconds after join until the FIRST free box (0 = instant hook)
		Interval = 180, -- delay after every claim
	},
	-- Crate-opening reel (CrateRollUI): slot-style strip of possible skins that decelerates
	-- onto the rolled one. Fillers are drawn from the crate's OWN Weights, so what spins
	-- past honestly previews that crate's odds. Same shape as Config.DailyReward.Reel.
	Reel = {
		FillerCells = 36,     -- 1.5× the daily reward's; paired with 1.5× SpinTime the strip
		CellsAfterResult = 3, -- travels at a similar speed, just half again as long
		CellSize = Vector2.new(140, 140),
		CellPadding = 12,
		SpinTime = 4.8,
	},
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
	Enabled      = false, -- Whether day/night cycle is enabled
	DayMinutes   = 9,   -- real minutes for the day half (sunrise -> sunset)
	NightMinutes = 3,   -- real minutes for the night half (sunset -> sunrise)
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
table.freeze(Config.GoldenPegs)
table.freeze(Config.Quests)
table.freeze(Config.Quests.Templates)
table.freeze(Config.StarterPack)
table.freeze(Config.BeginnersLuck)
table.freeze(Config.Cosmetics)
table.freeze(Config.Crates)

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

-- Tutorial sequence, played once on join (client TutorialService) until every step's
-- objective auto-completes — there is NO Skip/Next button; each step defines its own
-- completion trigger and the client advances the instant it's satisfied. Three concerns are
-- deliberately orthogonal, so any step can mix any combination:
--   presentation (text/boxPosition/highlight/camera) — what's shown, unrelated to...
--   arrow                                            — an optional physical world pointer, and...
--   complete                                         — what finishes the step and advances.
--
--   text        : the message (string).
--   boxPosition : UDim2 centre of the message box (Scale). Defaults to lower-centre.
--   highlight   : optional; present = dim everything except the spot. Two forms:
--                 { Element = "MainGui.LeftBar.TriggerQuad.LoadoutTriggerHost", Padding = px? }
--                   — surround a live GuiObject (dot path under PlayerGui; path segments fall
--                   back to a recursive find, so container frames can be skipped) with Padding
--                   px (default 10) around it. PREFERRED: reads the element's live absolute
--                   rect, so it's immune to resolution / inset differences (Studio vs Player).
--                 { Position = UDim2, Size = UDim2, Anchor = Vector2?, RespectInset = boolean? }
--                   — hand-authored rect. Anchor picks which point of the spot Position refers
--                   to, like GuiObject.AnchorPoint (default centre). RespectInset = true shifts
--                   the spot by the topbar GUI inset for coords copied from an inset-respecting
--                   ScreenGui. The UDim2s resolve like any screen UDim2 (Scale × viewport) but
--                   the Offset is multiplied by the AutoScale factor — author in 1080p offsets.
--   camera      : optional { Position = Vector3, Orientation = Vector3 (deg), FieldOfView = number? }
--                 scripted camera shot for the step (smoothly tweened); absent = default camera.
--   arrow       : optional physical world-arrow target (client WorldArrow), floating near the
--                 player's character and pointing at a live target position. Kinds:
--                   { Kind = "UpgradeShopTrack", Track = string } -- the world kiosk for that
--                                                                     upgrade track (matches the
--                                                                     Track attribute UpgradeShop
--                                                                     kiosks use)
--                   { Kind = "NearestCoin" }                       -- the player's nearest active
--                                                                     coin, force-spawning one if
--                                                                     none are currently active
--                   { Kind = "CosmeticsShop" }                     -- the part carrying the
--                                                                     CosmeticsGui-tagged storefront
--                   { Kind = "FreeCratePad" }                      -- the free-marble-box claim pad
--                                                                     (first FreeCratePad-tagged part)
--   complete    : REQUIRED — what finishes the step. Kinds:
--                   { Kind = "LaunchBalls", Count = number } -- N of the player's own marbles launch
--                   { Kind = "BuyUpgrade", Track = string }  -- that track's upgrade tier increases
--                   { Kind = "CollectCoin" }                  -- the player claims any coin
--                   { Kind = "ScoreBalls", Count = number? } -- N of the player's own marbles bank/score (default 1)
--                   { Kind = "BuySkin" }                      -- any skin gets ADDED to the owned set (bought or otherwise earned)
--                   { Kind = "OpenTuningMenu" }               -- the ball-tuning menu gets opened
--                   { Kind = "TouchFreeCratePad" }            -- the player steps on the free-box pad
-- Adding a new arrow/complete Kind is one handler function + one registry entry in
-- TutorialService — nothing else in the stepping/rendering logic changes.
--
-- NOTE: the "highlight" rect below for the launch controls is a placeholder (rough
-- bottom-center guess) — the bet UI was reworked to LaunchBtn/RaiseBtn/LowerBtn/AutoBtn
-- since this was last tuned; re-measure their actual Studio-authored Position/Size and
-- update this rect (in 1080p offset pos/size, matching the element's own UDim2) once you can
-- check it visually.
Config.Tutorial = {
	Steps = {
		{
			text = "Launch a marble for cash!",
			highlight = { Position = UDim2.fromOffset(960, 986), Size = UDim2.fromOffset(528,183), HighlightDim = 0.9 },
			complete = { Kind = "LaunchBalls", Count = 1 },
			boxPosition = UDim2.fromScale(0.5, 0.62)
		},
		{
			-- Nudges toward the board-camera toggle (MainGui.LeftBar.Tools.CamButtonHost,
			-- CameraService.Toggle) without forcing the view switch ourselves — a soft
			-- highlight so a player who wants to actually see the drop can find the button,
			-- but the step still completes on its own via ScoreBalls either way.
			text = "Watch where the marble drops... (try the camera button!)",
			highlight = { Element = "MainGui.LeftBar.Tools.CamButtonHost", Padding = 6 },
			complete = { Kind = "ScoreBalls", Count = 1 },
			boxPosition = UDim2.fromScale(0.75, 0.80)
		},
		{
			text = "Upgrade Base Bonus to increase multipliers.",
			arrow = { Kind = "UpgradeShopTrack", Track = "BaseAdditive" },
			complete = { Kind = "BuyUpgrade", Track = "BaseAdditive" },
			boxPosition = UDim2.fromScale(0.75, 0.80)
		},
		{
			text = "Upgrade your bet size to make more cash!",
			arrow = { Kind = "UpgradeShopTrack", Track = "MaxBet" },
			complete = { Kind = "BuyUpgrade", Track = "MaxBet" },
			boxPosition = UDim2.fromScale(0.75, 0.80)
		},
		{
			text = "Launch two more marbles.",
			highlight = { Position = UDim2.fromOffset(960, 986), Size = UDim2.fromOffset(528,183), HighlightDim = 0.9 },
			complete = { Kind = "LaunchBalls", Count = 2 },
			boxPosition = UDim2.fromScale(0.5, 0.62)
		},
		{
			text = "Step on the pad to claim your FREE marble box!",
			arrow = { Kind = "FreeCratePad" },
			complete = { Kind = "TouchFreeCratePad" },
			boxPosition = UDim2.fromScale(0.5, 0.62)
		}
	},
	-- How dark the screen goes around a step's highlighted rect: the BackgroundTransparency of
	-- the four mask panels while a highlight is up (0 = fully black, 1 = no dim at all). A
	-- highlight table can override this per step (highlight.HighlightDim).
	HighlightDim = 0.45,
	-- Second, later tutorial: starts once the player's Diamonds balance reaches
	-- DiamondTrigger (never before the join tutorial is over), pointing them at the
	-- cosmetics shop. Same step shape as Steps above, same Skip button; finishing or
	-- skipping persists separately (Stats.completedCosmeticTutorial) so it runs once ever.
	Cosmetic = {
		-- Trigger: enough Diamonds for the CHEAPEST Marble Box (derived from Config.Crates,
		-- so crate price tuning moves the tutorial with it).
		DiamondTrigger = (function()
			local cheapest = math.huge
			for _, box in Config.Crates.Boxes do
				cheapest = math.min(cheapest, box.Cost)
			end
			return cheapest
		end)(),
		Steps = {
			{
				text = "You can afford a Marble Box! Roll one at the cosmetics shop.",
				boxPosition = UDim2.fromScale(0.75, 0.80), -- same lower-right spot as the upgrade steps
				arrow = { Kind = "CosmeticsShop" },
				complete = { Kind = "RollCrate" }, -- any box opening (bought or free)
			},
		},
	},
	-- Third tutorial: fires the first time a skin other than the default Classic is
	-- unlocked — step 1 opens the LOADOUT menu (auto-completes if it's already open),
	-- step 2 waits for a skin to land in a bonus slot. Run-once
	-- (Stats.completedLoadoutTutorial).
	Loadout = {
		Steps = {
			{
				text = "You unlocked a new marble! Open the LOADOUT menu.",
				boxPosition = UDim2.fromScale(0.75, 0.80),
				highlight = { Element = "MainGui.LeftBar.TriggerQuad.LoadoutTriggerHost" },
				complete = { Kind = "OpenLoadout" },
			},
			{
				text = "Equip the best possible loadout for maximum bonus cash.",
				boxPosition = UDim2.fromScale(0.75, 0.80),
				highlight = { Element = "LoadoutGui.Panel.EquipBestHost" },
				complete = { Kind = "EquipLoadoutSlot" },
			},
		},
	},
	-- Fourth tutorial: fires the first time ANY ball-tuning axis (a Config.Axes track: Arc,
	-- Angle, Size, Elasticity) gains a tier — highlights the ball-tuning menu trigger and
	-- waits for the player to open it. Run-once (Stats.completedTuningTutorial).
	Tuning = {
		Steps = {
			{
				text = "You've upgraded a tuning axis! Open the ball tuning menu to use it.",
				boxPosition = UDim2.fromScale(0.75, 0.80),
				-- PLACEHOLDER rect (rough guess at the left bar's TuneTriggerHost) — re-measure
				-- its real 1080p-authored position/size and update.
				highlight = { Position = UDim2.fromOffset(285, 870), Size = UDim2.fromOffset(201, 121) },
				complete = { Kind = "OpenTuningMenu" },
			},
		},
	},
	-- Physical world-arrow look/feel (client WorldArrow) — tunable independent of any step. A
	-- chain of BillboardGui chevrons floats between the player and the target, each screen-
	-- rotated to point along the chain and fading from large/NearColor (by the player) to
	-- small/FarColor (by the target) — a directional trail, not a single pointer.
	Arrow = {
		Spacing = 3,                                 -- studs between chevrons; the chain divides the distance evenly, so the count scales with it
		MaxSegments = 65,                            -- hard cap on chevrons however far the target is (raised with the tighter Spacing so long trails keep their reach)
		NearColor = Color3.fromRGB(255, 40, 90),     -- by the player: hot pink/red
		FarColor = Color3.fromRGB(255, 160, 40),     -- by the target: orange
		NearSize = 52,                               -- chevron pixel size by the player
		FarSize = 24,                                -- chevron pixel size by the target
		TargetHeightOffset = 3,                      -- studs above the target the chain ends at (it starts at the player's center)
	},
}

table.freeze(Config.Animations)
table.freeze(Config.DayNight)
table.freeze(Config.Obby)
table.freeze(Config.GroupReward)
table.freeze(Config.Podium)
table.freeze(Config.Podium.Animations)
table.freeze(Config.Tutorial)
table.freeze(Config.WarnUI)
table.freeze(Config.DiamondPacks)
return Config
