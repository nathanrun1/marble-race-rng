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
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)

local DevService = {}

-- Add your UserId here to enable the commands in a live (non-Studio) server.
local ALLOWED_USERIDS: { number } = {}

local MAX_TIER = 12    -- /maxall and presets set every track to this (caps self-clamp)
local BIG_BET = 1e9   -- SetBet clamps this down to the player's current max bet

-- /test tuning.
local TEST_INTERVAL = 0.001   -- default seconds between launches; spaced so balls don't pile up
local TEST_TIMEOUT = 45      -- max seconds to wait for stragglers after the last launch
local TEST_MAX_BALLS = 1000  -- hard cap on n, so a typo can't spawn forever

-- /comprtest tuning. Independent variables: the four landing axes (Arc, Angle,
-- Size, Elasticity) plus Bet (to exercise the jackpot gate, which keys off ball
-- value). One batch is fired per combination ("build").
local COMPR_AXES = { "Arc", "Angle", "Size", "Elasticity" }
local COMPR_LEVELS = 3        -- evenly-spaced samples per axis across its full range
local COMPR_BET_LEVELS = 2    -- bet sweeps i/COMPR_BET_LEVELS × maxBet for i = 1..this (=> tests the jackpot gate)
local COMPR_PEGHEAT_TIERS = { 0, 6, 12 } -- PegHeat upgrade tiers to sweep (12-tier system)
-- Batches fire back-to-back (no waiting for the previous batch to land), so balls
-- from several builds are in flight at once. This forced delay between the last
-- launch of one batch and the first of the next caps how many pile up — raise it
-- to lower peak concurrent ball count, lower it to run faster.
local COMPR_BATCH_GAP = 0.001
-- Hard cap on how many build batches have balls in play at once: once this many
-- are airborne, firing blocks until one fully lands before the next batch starts.
-- Bounds peak concurrent balls to ~this × N. Raise for speed, lower for less load.
local COMPR_MAX_ACTIVE_BUILDS = 20

-- /comprtest analysis. Intended (base - jackpot) / value for a non-jackpot slot;
-- the analysis pass reports the observed ratio against this so a hot multiplier
-- table is visible without leaving the console.
local SLOT_EV_TARGET = 0.85

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

-- Pearson correlation of two equal-length samples. Returns 0 when either side
-- has no variance (an all-constant axis can't correlate with anything), matching
-- the "undefined -> ignore" treatment in the offline analysis. The analysis pass
-- separately warns when an axis is constant, so a +0.000 from this isn't mistaken
-- for a real null result.
local function pearson(xs: { number }, ys: { number }): number
	local n = #xs
	if n ~= #ys or n < 2 then
		return 0
	end
	local mx, my = 0, 0
	for i = 1, n do
		mx += xs[i]
		my += ys[i]
	end
	mx /= n
	my /= n
	local sxy, sxx, syy = 0, 0, 0
	for i = 1, n do
		local dx, dy = xs[i] - mx, ys[i] - my
		sxy += dx * dy
		sxx += dx * dx
		syy += dy * dy
	end
	if sxx == 0 or syy == 0 then
		return 0
	end
	return sxy / math.sqrt(sxx * syy)
end

-- The per-ball numeric fields we summarize, in print order. Each adds up across
-- balls; `banked` is the sum of base + heatBonus + comboBonus + additiveBonus +
-- trickle (and the test prints all of them so the breakdown is verifiable).
local STAT_ORDER = {
	"initialValue", "base", "heatBonus", "comboBonus",
	"additiveBonus", "trickle", "banked", "combo",
	"hotPegs", "coldPegs", "neutralPegs",
	"jackpot", "jackpotHit",  -- jackpot value, and hit rate (mean of 1/0)
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
		table.insert(arrays.hotPegs, info.hotPegs)
		table.insert(arrays.coldPegs, info.coldPegs)
		table.insert(arrays.neutralPegs, info.neutralPegs)
		table.insert(arrays.jackpot, info.jackpot)
		table.insert(arrays.jackpotHit, if info.jackpotHit then 1 else 0)
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

	for i = 1, count do
		local ball = BallLaunchService.LaunchTest(player, { phase = (i - 1) / count })
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
-- Elasticity are plain scalars; Bet is a coin amount.
local function fmtBuildParams(p: { [string]: number }): string
	return string.format("Bet=%6.0f  Arc=%2d°  Angle=%3d°  Size=%.2f  Elast=%.2f  PegHeat=%d",
		p.Bet, math.round(math.deg(p.Arc)), math.round(math.deg(p.Angle)), p.Size, p.Elasticity, p.PegHeatTier)
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

-- A build reduced to its scalar inputs (axis settings, in display units) and the
-- per-build mean of each output stat. One BuildRow is one data point for the
-- cross-build correlations; the means come from the same arrays the per-build
-- summary uses, so the analysis can't diverge from the printed numbers.
type BuildRow = {
	bet: number, arc: number, angle: number, size: number, elast: number, pegHeatTier: number,
	stat: { [string]: number },
}

local function buildRow(p: { [string]: number }, results: { ScoringService.ScoreInfo }): BuildRow?
	if #results == 0 then
		return nil
	end
	local arrays = statArrays(results)
	local stat: { [string]: number } = {}
	for _, name in STAT_ORDER do
		local mean = meanVar(arrays[name])
		stat[name] = mean
	end
	return {
		bet = p.Bet,
		arc = math.deg(p.Arc),
		angle = math.deg(p.Angle),
		size = p.Size,
		elast = p.Elasticity,
		pegHeatTier = p.PegHeatTier,
		stat = stat,
	}
end

-- Cross-build diagnostics over the finished comprtest. This is the offline
-- correlation pass moved server-side: which axes drive jackpot access, whether
-- edge-aiming actually moves landing mass to hot pegs (the aim-channel check),
-- whether size is still the jackpot axis, the slot-EV ratio, and the value-gate
-- check across bet tiers. Marginal correlations can mislead when two axes interact
-- (a flat corr(size, jackpotHit) once hid an angle×size interaction), so the
-- conditioned breakdowns below the corr tables are the ones to trust on conflict.
local function printComprAnalysis(rows: { BuildRow })
	local bar = string.rep("=", 78)
	if #rows < 2 then
		print(bar)
		print("Analysis: too few resolved builds to correlate.")
		print(bar)
		return
	end

	-- Distinct bet tiers; the EV/aim sections use the top tier (jackpot reachable),
	-- the gate check spans all tiers.
	local betsSeen: { [number]: boolean } = {}
	for _, r in rows do
		betsSeen[r.bet] = true
	end
	local betList: { number } = {}
	for b in betsSeen do
		table.insert(betList, b)
	end
	table.sort(betList)
	local topBet = betList[#betList]

	-- Top-bet rows, and a representative ball value at that bet (initialValue mean).
	local top: { BuildRow } = {}
	for _, r in rows do
		if r.bet == topBet then
			table.insert(top, r)
		end
	end
	local val = 0
	for _, r in top do
		val += r.stat.initialValue
	end
	val /= #top

	-- Column extractors over the top-bet rows.
	local function axisCol(name: string): { number }
		local out: { number } = {}
		for _, r in top do
			local v
			if name == "absAngle" then
				v = math.abs(r.angle)
			elseif name == "arc" then
				v = r.arc
			elseif name == "size" then
				v = r.size
			elseif name == "elast" then
				v = r.elast
			else
				v = r.angle
			end
			table.insert(out, v)
		end
		return out
	end
	local function statCol(name: string): { number }
		local out: { number } = {}
		for _, r in top do
			table.insert(out, r.stat[name])
		end
		return out
	end

	-- True only if a column actually varies — used to flag degenerate sweeps so a
	-- constant axis reading +0.000 isn't mistaken for a real null finding.
	local function varies(xs: { number }): boolean
		for i = 2, #xs do
			if xs[i] ~= xs[1] then
				return true
			end
		end
		return false
	end

	print(bar)
	print(string.format("Analysis — %d builds resolved | bets seen: %d | top bet=%.0f (value~%.0f)",
		#rows, #betList, topBet, val))
	print(bar)

	-- Warn on any constant landing axis (correlations against it are meaningless).
	local flat: { string } = {}
	for _, ax in { "absAngle", "size", "arc", "elast" } do
		if not varies(axisCol(ax)) then
			table.insert(flat, ax)
		end
	end
	if #flat > 0 then
		print("WARNING: constant across top-bet builds (corr = 0, not a finding): " .. table.concat(flat, ", "))
		print("  (raise COMPR_LEVELS, or check the axis range is actually unlocked)\n")
	end

	print("JACKPOT ACCESS DRIVERS  (corr with jackpotHit, top bet)")
	for _, ax in { "absAngle", "size", "arc", "elast" } do
		print(string.format("  %-8s : %+.3f", ax, pearson(statCol("jackpotHit"), axisCol(ax))))
	end

	print("\nAIM DIAGNOSTIC — does edge-aiming move mass to hot pegs? (corr hotPegs)")
	for _, ax in { "absAngle", "size", "arc", "elast" } do
		print(string.format("  %-8s : %+.3f", ax, pearson(statCol("hotPegs"), axisCol(ax))))
	end

	-- Distinct sorted values of a row field over the top-bet rows.
	local function distinct(getter: (BuildRow) -> number): { number }
		local seen: { [number]: boolean } = {}
		local out: { number } = {}
		for _, r in top do
			local v = getter(r)
			if not seen[v] then
				seen[v] = true
				table.insert(out, v)
			end
		end
		table.sort(out)
		return out
	end

	-- Mean of a stat over top rows matching an exact size and exact |angle|.
	local function meanSizeAngle(statName: string, sizeV: number, absAngleV: number): number
		local sum, cnt = 0, 0
		for _, r in top do
			if r.size == sizeV and math.abs(r.angle) == absAngleV then
				sum += r.stat[statName]
				cnt += 1
			end
		end
		return if cnt > 0 then sum / cnt else 0
	end

	-- Mean of a stat over top rows matching a single field value.
	local function meanBySize(statName: string, sizeV: number): number
		local sum, cnt = 0, 0
		for _, r in top do
			if r.size == sizeV then
				sum += r.stat[statName]
				cnt += 1
			end
		end
		return if cnt > 0 then sum / cnt else 0
	end
	local function meanByAbsAngle(statName: string, absAngleV: number): number
		local sum, cnt = 0, 0
		for _, r in top do
			if math.abs(r.angle) == absAngleV then
				sum += r.stat[statName]
				cnt += 1
			end
		end
		return if cnt > 0 then sum / cnt else 0
	end

	local sizes = distinct(function(r)
		return r.size
	end)
	local absAngles = distinct(function(r)
		return math.abs(r.angle)
	end)
	local maxAbsAngle = absAngles[#absAngles]

	-- Conditioned: hotPegs centered (|angle|=0) vs widest |angle|, per size. This
	-- is the read that exposes an angle×size interaction the marginal corr hides.
	print(string.format("\n  hotPegs centered(|angle|=0) vs edge(|angle|=%.0f), by size:", maxAbsAngle))
	for _, sv in sizes do
		local h0 = meanSizeAngle("hotPegs", sv, 0)
		local h1 = meanSizeAngle("hotPegs", sv, maxAbsAngle)
		print(string.format("    size=%-5.2f centered=%5.2f  edge=%5.2f  d=%+.2f", sv, h0, h1, h1 - h0))
	end

	print("\njackpotHit by SIZE (top bet) — is size the jackpot axis?")
	for _, sv in sizes do
		print(string.format("  size=%-5.2f : %.3f", sv, meanBySize("jackpotHit", sv)))
	end

	print("\njackpotHit by |angle| (top bet):")
	for _, av in absAngles do
		print(string.format("  |angle|=%-4.0f : %.3f", av, meanByAbsAngle("jackpotHit", av)))
	end

	-- Targeting ball: heaviest size, centered vs widest aim.
	local heavy = sizes[#sizes]
	local jc = meanSizeAngle("jackpotHit", heavy, 0)
	local je = meanSizeAngle("jackpotHit", heavy, maxAbsAngle)
	local hc = meanSizeAngle("hotPegs", heavy, 0)
	local he = meanSizeAngle("hotPegs", heavy, maxAbsAngle)
	print(string.format("\nTARGETING BALL (size=%.2f): centered jph=%.3f  edge jph=%.3f  hotPegs %.2f->%.2f",
		heavy, jc, je, hc, he))

	-- Slot EV at top bet.
	local baseM, jpM = 0, 0
	for _, r in top do
		baseM += r.stat.base
		jpM += r.stat.jackpot
	end
	baseM /= #top
	jpM /= #top
	print("\nSLOT EV (top bet)")
	print(string.format("  base/value           = %.3f", baseM / val))
	print(string.format("  (base-jackpot)/value = %.3f   (target ~%.2f)", (baseM - jpM) / val, SLOT_EV_TARGET))
	print(string.format("  jackpot/value        = %.3f", jpM / val))
	print(string.format("  --> non-jackpot floor is %.2fx target", ((baseM - jpM) / val) / SLOT_EV_TARGET))

	-- Value gate: jackpotHit and any-jackpot count per bet tier.
	print("\nVALUE GATE CHECK (gate = ball value >= fraction of max bet)")
	for _, bv in betList do
		local sumHit, cnt, anyJp = 0, 0, 0
		for _, r in rows do
			if r.bet == bv then
				sumHit += r.stat.jackpotHit
				cnt += 1
				if r.stat.jackpot > 0 then
					anyJp += 1
				end
			end
		end
		print(string.format("  bet=%-7.0f mean jackpotHit=%.3f  builds with any jackpot=%d/%d",
			bv, if cnt > 0 then sumHit / cnt else 0, anyJp, cnt))
	end
	print(bar)
end

-- /comprtest: sweep every combination of the four landing axes (Arc, Angle, Size,
-- Elasticity) × COMPR_BET_LEVELS bet sizes, firing N balls per combination, then
-- print a per-build summary of all of them followed by the cross-build analysis.
-- Unlocks those four axes' tiers so the full range is sampleable; other upgrades
-- are left as-is (constant across builds, so comparisons hold).
local function runComprTest(player: Player, n: number, ballsPerInterval: number)
	for _, axis in COMPR_AXES do
		ProfileService.SetUpgradeTier(player, axis, MAX_TIER)
	end
	ProfileService.SetUpgradeTier(player, "PegHeat", MAX_TIER)

	local levels: { [string]: { number } } = {}
	local total = 1
	for _, axis in COMPR_AXES do
		levels[axis] = axisLevels(player, axis, COMPR_LEVELS)
		total *= #levels[axis]
	end

	local maxBet = ProfileStats.GetMaxBet(ProfileService.GetUpgrades(player))
	local betLevels: { number } = {}
	for i = 1, COMPR_BET_LEVELS do
		table.insert(betLevels, ((COMPR_BET_LEVELS - i + 1) / COMPR_BET_LEVELS) * maxBet)
	end
	total *= #betLevels
	total *= #COMPR_PEGHEAT_TIERS

	local saved: { [string]: number } = {}
	for _, axis in COMPR_AXES do
		saved[axis] = ProfileService.GetAxis(player, axis)
	end
	local savedBet = ProfileService.GetLoadout(player).Bet
	local savedPegHeatTier = ProfileService.GetUpgrades(player).PegHeat or 0

	print(string.format("[Dev] comprtest: %d builds × %d balls = %d launches; running...", total, n, total * n))

	-- One connection for the whole run. A ball is spawned with its build's axes
	-- baked in (size/weight/velocity are set at spawn), so once fired it can land
	-- whenever — we attribute its ScoreInfo by the build it was tagged with, which
	-- lets batches overlap in flight. Firing itself must stay sequential because
	-- the axes are shared player state set right before each batch's launches.
	-- `fired` = all of this build's launches are out; `done` = all of them have also
	-- landed (resolved). A build counts as "in play" between firing and done.
	type Build = { params: { [string]: number }, results: { ScoringService.ScoreInfo }, launched: number, fired: boolean, done: boolean }
	local builds: { Build } = {}
	local ballBuild: { [BasePart]: Build } = {}
	local launchedTotal, resolved, activeBuilds = 0, 0, 0

	local conn = ScoringService.BallScored:Connect(function(ball: BasePart, info: ScoringService.ScoreInfo)
		local b = ballBuild[ball]
		if b then
			ballBuild[ball] = nil
			table.insert(b.results, info)
			resolved += 1
			-- Last ball of a fully-fired build just landed → that batch left play.
			if b.fired and not b.done and #b.results >= b.launched then
				b.done = true
				activeBuilds -= 1
			end
		end
	end)

	local function fireBuild(params: { [string]: number })
		if not player.Parent then
			return -- player left mid-test; their profile is gone, so stop launching
		end
		for key, value in params do
			if key == "Bet" then
				ProfileService.SetBet(player, value)
			elseif key == "PegHeatTier" then
				ProfileService.SetUpgradeTier(player, "PegHeat", value)
			else
				ProfileService.SetAxis(player, key, value)
			end
		end
		local build: Build = { params = params, results = {}, launched = 0, fired = false, done = false }
		table.insert(builds, build)
		activeBuilds += 1
		local i = 0
		while i < n do
			if not player.Parent then
				return -- left mid-build (between intervals); stop
			end
			local batch = math.min(ballsPerInterval, n - i)
			for j = 0, batch - 1 do
				local ball = BallLaunchService.LaunchTest(player, { phase = (i + j) / n })
				ballBuild[ball] = build
				build.launched += 1
				launchedTotal += 1
			end
			i += batch
			task.wait(TEST_INTERVAL)
		end
		build.fired = true
		-- Fast builds can fully land before firing finishes; close them out here.
		if not build.done and #build.results >= build.launched then
			build.done = true
			activeBuilds -= 1
		end
	end

	-- Fire combinations back-to-back, throttled two ways: a COMPR_BATCH_GAP pause
	-- between batches, and a hard cap on how many batches are in play at once —
	-- once COMPR_MAX_ACTIVE_BUILDS are airborne, wait for one to fully land first.
	local first = true
	for _, bet in betLevels do
		for _, pegHeatTier in COMPR_PEGHEAT_TIERS do
			for _, arc in levels.Arc do
				for _, angle in levels.Angle do
					for _, size in levels.Size do
						for _, elasticity in levels.Elasticity do
							if not first then
								task.wait(COMPR_BATCH_GAP)
							end
							first = false
							while activeBuilds >= COMPR_MAX_ACTIVE_BUILDS do
								task.wait(0.1)
							end
							fireBuild({ Bet = bet, PegHeatTier = pegHeatTier, Arc = arc, Angle = angle, Size = size, Elasticity = elasticity })
							print(string.format("[Dev] comprtest progress: %d/%d builds launched (%d in play)", #builds, total, activeBuilds))
						end
					end
				end
			end
		end
	end

	-- Restore the player's pre-test loadout (skip if they left mid-test; profile gone).
	if player.Parent then
		for _, axis in COMPR_AXES do
			ProfileService.SetAxis(player, axis, saved[axis])
		end
		ProfileService.SetBet(player, savedBet)
		ProfileService.SetUpgradeTier(player, "PegHeat", savedPegHeatTier)
	end

	-- Single drain: wait for the balls still in flight across all batches.
	print(string.format("[Dev] comprtest: all %d builds launched; draining in-flight balls...", #builds))
	local deadline = os.clock() + TEST_TIMEOUT
	while resolved < launchedTotal and os.clock() < deadline do
		task.wait(0.1)
	end
	conn:Disconnect()

	local bar = string.rep("=", 78)
	print(bar)
	print(string.format("Comprehensive Build Test — %s — %d builds × %d balls", player.Name, #builds, n))
	print(bar)
	for i, b in builds do
		printComprBuild(i, #builds, b.params, b.results, b.launched)
	end
	print(bar)

	-- Cross-build diagnostics on the finished sweep (one row per resolved build).
	local rows: { BuildRow } = {}
	for _, b in builds do
		local row = buildRow(b.params, b.results)
		if row then
			table.insert(rows, row)
		end
	end
	printComprAnalysis(rows)
end

-- Returns a short result string for the console.
local function handle(player: Player, cmd: string, a2: string?, a3: string?): string?
	if cmd == "help" then
		return "commands: tier, maxall, bet, axis, money, preset, test, comprtest, show, reset_upgrades, prestige, pmoney, attempt_prestige"
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
			return "usage: /comprtest <n> [ballsPerInterval]"
		end
		n = math.clamp(math.floor(n), 1, TEST_MAX_BALLS)
		local bpi = math.max(1, math.floor(tonumber(a3) or 1))
		task.spawn(runComprTest, player, n, bpi)
		return string.format("running comprehensive build test: %d balls/build × %d per interval (results in server console)", n, bpi)
	elseif cmd == "reset_upgrades" then
		ProfileService.ResetProfile(player)
		return "profile reset: all tiers 0, loadout defaults"
	elseif cmd == "prestige" then
		local n = tonumber(a2)
		if not n then return "usage: /prestige <count>" end
		n = math.max(0, math.floor(n))
		PrestigeService.SetCount(player, n)
		local mult = PrestigeService.GetMultiplier(player)
		return string.format("prestige count -> %d  multiplier -> %.4fx", n, mult)
	elseif cmd == "pmoney" then
		local n = tonumber(a2)
		if not n then return "usage: /pmoney <lifetimeBanked>" end
		PrestigeService.SetLifetimeBanked(player, math.max(0, n))
		local info = PrestigeService.GetInfo(player)
		return string.format("lifetimeBanked -> %.0f  PP -> %d  nextCost -> %d  canPrestige -> %s",
			info.lifetimeBanked, info.prestigePoints, info.nextCost, tostring(info.canPrestige))
	elseif cmd == "attempt_prestige" then
		local ok, reason = PrestigeService.Prestige(player)
		if ok then
			local info = PrestigeService.GetInfo(player)
			return string.format("prestige! count -> %d  multiplier -> %.4fx", info.count, info.multiplier)
		else
			local info = PrestigeService.GetInfo(player)
			return string.format("prestige failed: %s (PP=%d, need=%d)", tostring(reason), info.prestigePoints, info.nextCost)
		end
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