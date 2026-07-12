--!strict
-- Per-player collectible coins. Each workspace part tagged Tags.Coin is a spawn
-- LOCATION (shared geometry); the server (CoinService) owns which locations are "active" for
-- each player and what each is worth, while the client (CoinPickups) renders, animates, and
-- collects them locally — so coins are independent per player. Onboarding income that keeps
-- new players afloat while they figure out the upgrade loop.

local Coins = {
	MaxActive = 5, -- most coins active for one player at a time
	InitialSpawn = 2, -- coins handed to a player as soon as their client is ready
	SpawnIntervalMin = 30, -- seconds between spawns (uniform random in [min, max]) per player
	SpawnIntervalMax = 60,
	ValueMin = 50, -- reward range (cash), inclusive both ends
	ValueMax = 1000,
	ValueStep = 25, -- rewards snap to this increment
	ShineTopFraction = 0.25, -- coins in the top this fraction of the value range also get a light
	RedTopFraction = 0.5, -- coins in the top this fraction are tinted red (parts + decals)
	RewardWarnLifetime = 2, -- seconds the "+$X" WarnUI banner stays up
	ValuePoissonMean = 6.8, -- Poisson lambda (steps above ValueMin)

	-- Blue coins: rolled independently at spawn time, pay Diamonds (the cc cosmetics
	-- currency) instead of cash. BiasExponent > 1 skews the roll toward Min via
	-- random()^BiasExponent (1 = uniform, 2 = quadratic bias low, ...) — see CoinService.
	BlueChance = 0.20,
	BlueDiamonds = { Min = 1, Max = 5, BiasExponent = 2 },
}

return Coins
