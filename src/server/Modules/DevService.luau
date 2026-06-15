--!strict
-- Dev-only testing tool: set upgrade tiers and loadout values live via chat,
-- bypassing cost and the shop. Studio-only by default (plus an optional UserId
-- allowlist for live servers), so it is inert in production. Uses only public
-- ProfileService / CurrencyService APIs — no other module is modified.
--
-- Chat commands (type in the in-game chat):
--   /tier <Track> <n>      set an upgrade tier (raises only; rejoin to lower)
--   /maxall                max every upgrade tier (unlocks all ranges)
--   /bet <n>               set total bet (clamps to current max bet)
--   /axis <Name> <v>       set a continuous axis (Arc, Angle, Size, Elasticity)
--   /money <n>             set balance
--   /preset <name>         targeting | chaos | hybrid
--   /test <n> [interval]   fire n test balls (your loadout), print payout stats
--   /comprtest <n>         sweep all builds (Arc/Angle/Size/Elasticity), n balls each
--   /show                  print current tiers + loadout to the server console
--   /help                  list commands
--
-- To reset everything, restart the playtest (no persistence yet, so a rejoin
-- returns the profile to defaults). Tiers only raise, so /maxall is a one-way
-- door within a session — by design, that mirrors real upgrade monotonicity.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Config = require(RS.Shared.Config)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local ScoringService = require(SSS.Scripts.Modules.ScoringService)
local BallLaunchService = require(SSS.Scripts.Modules.BallLaunchService)

local DevService = {}

-- Add your UserId here to enable the commands in a live (non-Studio) server.
local ALLOWED_USERIDS: { number } = {}

local MAX_TIER = 5    -- /maxall and presets set every track to this (caps self-clamp)
local BIG_BET = 1e9   -- SetBet clamps this down to the player's current max bet

-- /test tuning.
local TEST_INTERVAL = 0.02   -- default seconds between launches; spaced so balls don't pile up
local TEST_TIMEOUT = 45      -- max seconds to wait for stragglers after the last launch
local TEST_MAX_BALLS = 1000  -- hard cap on n, so a typo can't spawn forever

-- /comprtest tuning. The only independent variables (everything that shapes where
-- a ball lands and what it hits) are these four axes; one batch is fired per
-- combination of their sampled levels (a "build").
local COMPR_AXES = { "Arc", "Angle", "Size", "Elasticity" }
local COMPR_LEVELS = 3        -- evenly-spaced samples per axis across its full range (=> LEVELS^#axes builds)
local COMPR_MAX_TOTAL_BALLS = 10000  -- safety: builds × N may not exceed this

-- Loose indexer views for dynamic (string-keyed) access under --!strict.
local UPGRADES: { [string]: any } = Config.Upgrades :: any
local AXES: { [string]: any } = Config.Axes :: any

-- Case-insensitive name lookups. tierByLower covers every purchasable tier key
-- (Config.Upgrades tracks AND Config.Axes axes, e.g. /tier Size 2). axisByLower
-- is just the continuous axes, for setting a loadout position (/axis Size 0.75).
local tierByLower: { [string]: string } = {}
local axisByLower: { [string]: string } = {}
for track in UPGRADES do
	tierByLower[track:lower()] = track
end
for axis in AXES do
	tierByLower[axis:lower()] = axis
	axisByLower[axis:lower()] = axis
end

local function isDev(player: Player): boolean
	return RunService:IsStudio() or table.find(ALLOWED_USERIDS, player.UserId) ~= nil
end

local function setAllTiers(player: Player, value: number)
	for track in UPGRADES do
		ProfileService.SetUpgradeTier(player, track, value)
	end
	for axis in AXES do -- axis unlock tiers too, else preset axis values clamp to tier 0
		ProfileService.SetUpgradeTier(player, axis, value)
	end
end

-- Set a continuous axis to a fraction of its currently-unlocked range
-- (0 = min, 0.5 = mid, 1 = max). Lets presets express "tightest / widest /
-- centered" without hardcoding unit values that the range gate would clamp.
local function setAxisFrac(player: Player, axis: string, frac: number)
	local min, max = ProfileStats.GetAxisRange(ProfileService.GetUpgrades(player), axis)
	ProfileService.SetAxis(player, axis, min + (max - min) * frac)
end

-- Presets unlock all tiers, then set the loadout axes that define the build. The
-- four landing axes (Arc / Angle / Size / Elasticity) are what shape play; maxing
-- tiers just removes the range gates so the extremes are reachable.
local PRESETS: { [string]: (Player) -> () } = {
	targeting = function(player)
		setAllTiers(player, MAX_TIER)
		setAxisFrac(player, "Arc", 0)         -- tightest swivel (precise)
		setAxisFrac(player, "Angle", 0.5)     -- centered aim
		setAxisFrac(player, "Size", 0)        -- smallest ball
		setAxisFrac(player, "Elasticity", 0)  -- least bounce / variance
		ProfileService.SetBet(player, BIG_BET)
	end,
	chaos = function(player)
		setAllTiers(player, MAX_TIER)
		setAxisFrac(player, "Arc", 1)         -- widest swivel (spread)
		setAxisFrac(player, "Angle", 0.5)     -- centered; arc does the spreading
		setAxisFrac(player, "Size", 1)        -- largest ball
		setAxisFrac(player, "Elasticity", 1)  -- bounciest / most variance
		ProfileService.SetBet(player, BIG_BET)
	end,
	hybrid = function(player)
		setAllTiers(player, MAX_TIER)
		setAxisFrac(player, "Arc", 0.5)
		setAxisFrac(player, "Angle", 0.5)
		setAxisFrac(player, "Size", 0.5)
		setAxisFrac(player, "Elasticity", 0.5)
		ProfileService.SetBet(player, BIG_BET)
	end,
}

local function showState(player: Player)
	local up = ProfileService.GetUpgrades(player)
	print("===== Dev: " .. player.Name .. " =====")
	print("-- Upgrades --")
	for track in UPGRADES do
		print(string.format("  %s: tier %d", track, up[track] or 0))
	end
	local lo = ProfileService.GetLoadout(player)
	print(string.format("-- Loadout -- bet=%.1f", lo.Bet))
	for axis, v in lo.axes do
		print(string.format("  axis %s = %.2f", axis, v))
	end
	print(string.format("-- Balance -- %.0f", CurrencyService.GetPoints(player)))
end

-- Population mean & variance of a sample (variance over N, not N-1 — descriptive,
-- not inferential). Returns (0, 0) for an empty sample.
local function meanVar(xs: { number }): (number, number)
	local n = #xs
	if n == 0 then
		return 0, 0
	end
	local sum = 0
	for _, x in xs do
		sum += x
	end
	local mean = sum / n
	local sq = 0
	for _, x in xs do
		sq += (x - mean) ^ 2
	end
	return mean, sq / n
end

-- The per-ball numeric fields we summarize, in print order. Each adds up across
-- balls; `banked` is the sum of base + heatBonus + comboBonus + additiveBonus +
-- trickle (and the test prints all of them so the breakdown is verifiable).
local STAT_ORDER = {
	"initialValue", "base", "heatBonus", "comboBonus",
	"additiveBonus", "trickle", "banked", "combo",
}

-- Bucket every STAT_ORDER field of the results into a flat array of samples
-- (dynamic key access, hence the string-indexer type).
local function statArrays(results: { ScoringService.ScoreInfo }): { [string]: { number } }
	local arrays: { [string]: { number } } = {}
	for _, name in STAT_ORDER do
		arrays[name] = {}
	end
	for _, info in results do
		table.insert(arrays.initialValue, info.initialValue)
		table.insert(arrays.base, info.base)
		table.insert(arrays.heatBonus, info.heatBonus)
		table.insert(arrays.comboBonus, info.comboBonus)
		table.insert(arrays.additiveBonus, info.additiveBonus)
		table.insert(arrays.trickle, info.trickle)
		table.insert(arrays.banked, info.banked)
		table.insert(arrays.combo, info.combo)
	end
	return arrays
end

-- Print mean / variance / std for every STAT_ORDER field, one line each, prefixed
-- by `indent`. Shared by the full /test report and the per-build /comprtest summary.
local function printStatLines(results: { ScoringService.ScoreInfo }, indent: string)
	local arrays = statArrays(results)
	for _, name in STAT_ORDER do
		local mean, var = meanVar(arrays[name])
		print(string.format("%s%-14s mean=%11.2f  var=%13.2f  std=%10.2f", indent, name, mean, var, math.sqrt(var)))
	end
end

local function printReport(player: Player, results: { ScoringService.ScoreInfo }, launched: number)
	local n = #results
	local bar = string.rep("=", 52)
	print(bar)
	print(string.format("Launch Test Report — %s", player.Name))
	print(string.format("  launched=%d  resolved=%d  timed_out=%d", launched, n, launched - n))
	if n == 0 then
		print("  (no balls resolved — none reached a DestroyTarget within the timeout)")
		print(bar)
		return
	end

	print("-- per-ball stats (mean / variance / std) --")
	printStatLines(results, "  ")

	-- Histogram of the final slot multiplier. A ball that landed in an additive /
	-- non-multiplier slot has no multiplier; it is bucketed under 1× (identity).
	local hist: { [number]: number } = {}
	for _, info in results do
		local m = info.finalMultiplier or 1
		hist[m] = (hist[m] or 0) + 1
	end
	local keys: { number } = {}
	for m in hist do
		table.insert(keys, m)
	end
	table.sort(keys, function(a, b)
		return a > b
	end)
	print("-- final slot multiplier histogram --")
	for _, m in keys do
		local c = hist[m]
		print(string.format("  %7sx : %4d  (%5.1f%%)", tostring(m), c, 100 * c / n))
	end
	print(bar)
end

-- Fire `count` balls from the player's current loadout/upgrades (bypassing
-- cooldown, cost, and the concurrency cap), collecting each ball's ScoreInfo as it
-- banks. Spaced by `interval` so balls don't pile up, then drains all in-flight
-- balls before returning (bounded by the stuck-timeout, so it always finishes).
-- Yields for the whole batch; returns (results, launched).
local function runBatch(player: Player, count: number, interval: number): ({ ScoringService.ScoreInfo }, number)
	local results: { ScoringService.ScoreInfo } = {}
	local pending: { [BasePart]: true } = {}
	local launched = 0

	local conn = ScoringService.BallScored:Connect(function(ball: BasePart, info: ScoringService.ScoreInfo)
		if pending[ball] then
			pending[ball] = nil
			table.insert(results, info)
		end
	end)

	for _ = 1, count do
		local ball = BallLaunchService.LaunchTest(player)
		pending[ball] = true
		launched += 1
		task.wait(interval)
	end

	-- Wait for the balls still in flight, up to the timeout.
	local deadline = os.clock() + TEST_TIMEOUT
	while #results < launched and os.clock() < deadline do
		task.wait(0.1)
	end
	conn:Disconnect()

	return results, launched
end

-- /test: fire one batch from the player's current loadout and print full stats.
local function runLaunchTest(player: Player, count: number, interval: number)
	print(string.format("[Dev] Launch test: firing %d balls (interval %.2fs)...", count, interval))
	local results, launched = runBatch(player, count, interval)
	printReport(player, results, launched)
end

-- Evenly-spaced sample values across an axis's currently-unlocked range. Falls
-- back to a single midpoint when the range is a point (or only one level wanted).
local function axisLevels(player: Player, axis: string, levels: number): { number }
	local min, max = ProfileStats.GetAxisRange(ProfileService.GetUpgrades(player), axis)
	if levels <= 1 or max <= min then
		return { (min + max) / 2 }
	end
	local out: { number } = {}
	for i = 0, levels - 1 do
		table.insert(out, min + (max - min) * (i / (levels - 1)))
	end
	return out
end

-- Stored axis units → display: Angle/Arc are radians (show degrees); Size and
-- Elasticity are plain scalars.
local function fmtBuildParams(p: { [string]: number }): string
	return string.format("Arc=%2d°  Angle=%3d°  Size=%.2f  Elast=%.2f",
		math.round(math.deg(p.Arc)), math.round(math.deg(p.Angle)), p.Size, p.Elasticity)
end

-- One build's summary: params, resolve count, mean/var/std for every stat, and a
-- one-line final-slot multiplier histogram.
local function printComprBuild(idx: number, total: number, p: { [string]: number }, results: { ScoringService.ScoreInfo }, launched: number)
	local n = #results
	print(string.format("[%2d/%d] %s | resolved %d/%d", idx, total, fmtBuildParams(p), n, launched))
	if n == 0 then
		print("        (none resolved)")
		return
	end
	printStatLines(results, "        ")

	local hist: { [number]: number } = {}
	for _, info in results do
		local m = info.finalMultiplier or 1
		hist[m] = (hist[m] or 0) + 1
	end
	local keys: { number } = {}
	for m in hist do
		table.insert(keys, m)
	end
	table.sort(keys, function(x, y)
		return x > y
	end)
	local parts: { string } = {}
	for _, m in keys do
		table.insert(parts, string.format("%sx:%d", tostring(m), hist[m]))
	end
	print("        slots: " .. table.concat(parts, "  "))
end

-- /comprtest: sweep every combination of the four landing axes (Arc, Angle, Size,
-- Elasticity), firing N balls per combination, then print a per-build summary of
-- all of them. Unlocks those four axes' tiers so the full range is sampleable;
-- other upgrades are left as-is (constant across builds, so comparisons hold).
local function runComprTest(player: Player, n: number)
	for _, axis in COMPR_AXES do
		ProfileService.SetUpgradeTier(player, axis, MAX_TIER)
	end

	local levels: { [string]: { number } } = {}
	local total = 1
	for _, axis in COMPR_AXES do
		levels[axis] = axisLevels(player, axis, COMPR_LEVELS)
		total *= #levels[axis]
	end

	if total * n > COMPR_MAX_TOTAL_BALLS then
		print(string.format("[Dev] comprtest aborted: %d builds × %d balls = %d > cap %d. Lower N.",
			total, n, total * n, COMPR_MAX_TOTAL_BALLS))
		return
	end

	-- Restore the player's chosen positions afterward (tiers stay raised — monotonic).
	local saved: { [string]: number } = {}
	for _, axis in COMPR_AXES do
		saved[axis] = ProfileService.GetAxis(player, axis)
	end

	print(string.format("[Dev] comprtest: %d builds × %d balls = %d launches; running...", total, n, total * n))

	type Build = { params: { [string]: number }, results: { ScoringService.ScoreInfo }, launched: number }
	local builds: { Build } = {}
	for _, arc in levels.Arc do
		for _, angle in levels.Angle do
			for _, size in levels.Size do
				for _, elasticity in levels.Elasticity do
					ProfileService.SetAxis(player, "Arc", arc)
					ProfileService.SetAxis(player, "Angle", angle)
					ProfileService.SetAxis(player, "Size", size)
					ProfileService.SetAxis(player, "Elasticity", elasticity)
					local results, launched = runBatch(player, n, TEST_INTERVAL)
					table.insert(builds, {
						params = { Arc = arc, Angle = angle, Size = size, Elasticity = elasticity },
						results = results,
						launched = launched,
					})
				end
			end
		end
	end

	for _, axis in COMPR_AXES do
		ProfileService.SetAxis(player, axis, saved[axis])
	end

	local bar = string.rep("=", 78)
	print(bar)
	print(string.format("Comprehensive Build Test — %s — %d builds × %d balls", player.Name, #builds, n))
	print(bar)
	for i, b in builds do
		printComprBuild(i, #builds, b.params, b.results, b.launched)
	end
	print(bar)
end

-- Returns a short result string for the console.
local function handle(player: Player, cmd: string, a2: string?, a3: string?): string?
	if cmd == "help" then
		return "commands: tier, maxall, bet, axis, money, preset, test, comprtest, show"
	elseif cmd == "show" then
		showState(player)
		return nil
	elseif cmd == "maxall" then
		setAllTiers(player, MAX_TIER)
		return "maxed all tiers"
	elseif cmd == "tier" then
		local track = a2 and tierByLower[a2:lower()]
		local n = tonumber(a3)
		if not track or not n then
			return "usage: /tier <Track> <n>  (incl. axes: Arc, Angle, Size, Elasticity)"
		end
		ProfileService.SetUpgradeTier(player, track, math.floor(n))
		return string.format("%s -> tier %d", track, math.floor(n))
	elseif cmd == "bet" then
		local n = tonumber(a2)
		if not n then return "usage: /bet <n>" end
		ProfileService.SetBet(player, n)
		return string.format("bet -> %.1f (clamped to max bet)", ProfileService.GetLoadout(player).Bet)
	elseif cmd == "axis" then
		local axis = a2 and axisByLower[a2:lower()]
		local n = tonumber(a3)
		if not axis or not n then
			return "usage: /axis <Arc|Angle|Size|Elasticity> <value>"
		end
		ProfileService.SetAxis(player, axis, n)
		return string.format("%s -> %.2f (clamped to range)", axis, ProfileService.GetAxis(player, axis))
	elseif cmd == "money" then
		local n = tonumber(a2)
		if not n then return "usage: /money <n>" end
		CurrencyService.SetPoints(player, n, "Dev")
		return string.format("balance -> %.0f", n)
	elseif cmd == "preset" then
		local preset = a2 and PRESETS[a2:lower()]
		if not preset then
			return "usage: /preset <targeting|chaos|hybrid>"
		end
		preset(player)
		return "applied preset: " .. (a2 :: string):lower()
	elseif cmd == "test" then
		local count = tonumber(a2)
		if not count then
			return "usage: /test <n> [interval]"
		end
		count = math.clamp(math.floor(count), 1, TEST_MAX_BALLS)
		local interval = math.max(tonumber(a3) or TEST_INTERVAL, 0)
		-- Spawn the runner off the chat thread so the command returns immediately;
		-- the report prints to the server console when the test finishes.
		task.spawn(runLaunchTest, player, count, interval)
		return string.format("running launch test: %d balls (results in server console)", count)
	elseif cmd == "comprtest" then
		local n = tonumber(a2)
		if not n then
			return "usage: /comprtest <n>  (n balls per build)"
		end
		n = math.clamp(math.floor(n), 1, TEST_MAX_BALLS)
		task.spawn(runComprTest, player, n)
		return string.format("running comprehensive build test: %d balls/build (results in server console)", n)
	end
	return nil -- not a dev command; ignore
end

local function onChatted(player: Player, message: string)
	if not isDev(player) then
		return
	end
	if message:sub(1, 1) ~= "/" then
		return
	end
	local args = message:sub(2):split(" ")
	local result = handle(player, args[1]:lower(), args[2], args[3])
	if result then
		print("[Dev] " .. player.Name .. ": " .. result)
	end
end

function DevService.Init()
	for _, player in Players:GetPlayers() do
		player.Chatted:Connect(function(msg)
			onChatted(player, msg)
		end)
	end
	Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(msg)
			onChatted(player, msg)
		end)
	end)
end

return DevService
