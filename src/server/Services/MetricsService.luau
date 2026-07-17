--!strict
-- Custom day-by-day analytics mirroring the Roblox dashboard numbers — DAU, new players,
-- sessions, playtime, mean + median session length, average playtime per player, and
-- D1/D7/D30 retention — but EXCLUDING the players listed in
-- AdminConfig.Metrics.ExcludedUserIds (plus AdminConfig.UserIds). That exclusion is the whole point:
-- dev/tester sessions badly distort a small game's numbers, and the official dashboard
-- can't filter them out.
--
-- Storage (DataStore METRICS_STORE, one record per UTC day):
--   day_<n>     n = floor(os.time()/86400). { sessions, playtime (sec),
--                 sessionLens = { sec, ... } (one entry per cleanly-ENDED session, credited
--                 to the day it ended; crashes contribute playtime but no length sample, so
--                 the median leans slightly on clean sessions),
--                 players = { [userIdStr]: true }, new = { [userIdStr]: true } }
--   seen_<uid>  the first UTC day this player ever joined (drives "new" + cohorts).
--                 Players who predate this system count as "new" on their first visit
--                 after it ships — a one-time skew that washes out of the window fast.
--
-- Retention uses the dashboard definition: D1 of day X's cohort = the fraction of that
-- day's NEW players who played again exactly on day X+1 (D7: X+7, D30: X+30). It's
-- computed at report time from the stored day records, so nothing runs on a schedule
-- and a cohort's numbers keep filling in as its target days arrive.
--
-- Recording only happens on LIVE servers (Studio playtests would pollute the data).
-- Reading works anywhere the DataStore API is reachable: in Studio, turn on "Enable
-- Studio Access to API Services" and run `/metrics [days]` in the chat (DevService), or
-- from the command bar:
--   require(game.ServerScriptService.Scripts.Services.MetricsService).PrintReport(14)

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local AdminConfig = require(RS.Shared.Config.Admin)
local MetricsService = {}

local METRICS_STORE = "GameMetrics_v1"
local DAY = 86400
local MAX_TRIES = 3
local FLUSH_INTERVAL = 300 -- seconds between periodic playtime flushes (bounds crash loss;
                           -- also credits a midnight-spanning session to both days' DAU)

-- The store is created wherever the API is reachable; RECORDING is additionally gated to
-- live servers only. (Same tolerate-in-Studio shape as DataService: GetDataStore throws in
-- Studio when API access is off — report commands then just say so instead of erroring.)
local store: GlobalDataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(METRICS_STORE)
	end)
	if ok then
		store = result
	elseif RunService:IsStudio() then
		warn("MetricsService: DataStore unavailable in Studio (enable API access to read reports): " .. tostring(result))
	else
		warn("MetricsService: GetDataStore failed on a live server; metrics disabled: " .. tostring(result))
	end
end
local recording = store ~= nil and not RunService:IsStudio()

-- Excluded from every metric: the explicit AdminConfig.Metrics list plus all admins.
local function isExcluded(userId: number): boolean
	return table.find(AdminConfig.Metrics.ExcludedUserIds, userId) ~= nil
		or AdminConfig.IsAdmin(userId)
end

local function withRetry(fn: () -> any): (boolean, any)
	local attempt = 0
	while true do
		attempt += 1
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt >= MAX_TRIES then
			warn("MetricsService: DataStore op failed after " .. attempt .. " tries: " .. tostring(result))
			return false, nil
		end
		task.wait(0.2 * 2 ^ attempt)
	end
end

local function todayIndex(): number
	return os.time() // DAY
end

local function dayKey(day: number): string
	return "day_" .. day
end

-- One day's aggregate record shape (all fields optional on old/missing records).
type DayRecord = {
	sessions: number?,
	playtime: number?,
	sessionLens: { number }?,
	players: { [string]: boolean }?,
	new: { [string]: boolean }?,
}

-- Mutate today's (or any day's) aggregate under UpdateAsync. `mutate` receives a
-- non-nil record with all fields present and returns it.
local function updateDay(day: number, mutate: (DayRecord) -> ())
	if not store then
		return
	end
	withRetry(function()
		return (store :: GlobalDataStore):UpdateAsync(dayKey(day), function(record: DayRecord?)
			local r: DayRecord = record or {}
			r.sessions = r.sessions or 0
			r.playtime = r.playtime or 0
			r.sessionLens = r.sessionLens or {}
			r.players = r.players or {}
			r.new = r.new or {}
			mutate(r)
			return r
		end)
	end)
end

----------------------------------------------------------------------------------
-- Recording (live servers only)
----------------------------------------------------------------------------------

-- userId -> os.clock() the un-flushed playtime slice started (join, or the last flush).
local tracked: { [number]: number } = {}
-- userId -> os.clock() at join (whole-session length for the median sample).
local joinedAt: { [number]: number } = {}

-- Credit the playtime since the last flush to TODAY's record (and mark the player
-- present today — a session crossing midnight lands in both days' DAU this way).
-- endingSession also records the whole join->now session length (median sample),
-- credited to the day the session ends.
local function flush(userId: number, endingSession: boolean?)
	local last = tracked[userId]
	if not last then
		return
	end
	local now = os.clock()
	tracked[userId] = now
	local delta = now - last
	local joined = joinedAt[userId]
	local sessionLen: number? = if endingSession and joined then now - joined else nil
	if delta < 1 and not sessionLen then
		return
	end
	local uid = tostring(userId)
	updateDay(todayIndex(), function(r)
		r.playtime = (r.playtime :: number) + delta
		;(r.players :: { [string]: boolean })[uid] = true
		if sessionLen then
			table.insert(r.sessionLens :: { number }, math.floor(sessionLen + 0.5))
		end
	end)
end

local function onPlayerAdded(player: Player)
	if not recording or isExcluded(player.UserId) then
		return
	end
	local userId = player.UserId
	tracked[userId] = os.clock()
	joinedAt[userId] = os.clock()

	task.spawn(function()
		-- First-ever visit? Claim the seen-key under UpdateAsync so two servers can't
		-- both count the same player as new.
		local isNew = false
		withRetry(function()
			return (store :: GlobalDataStore):UpdateAsync("seen_" .. userId, function(firstDay)
				if firstDay == nil then
					isNew = true
					return todayIndex()
				end
				return firstDay
			end)
		end)

		local uid = tostring(userId)
		updateDay(todayIndex(), function(r)
			r.sessions = (r.sessions :: number) + 1
			;(r.players :: { [string]: boolean })[uid] = true
			if isNew then
				(r.new :: { [string]: boolean })[uid] = true
			end
		end)
	end)
end

local function onPlayerRemoving(player: Player)
	if tracked[player.UserId] then
		flush(player.UserId, true)
		tracked[player.UserId] = nil
	end
	joinedAt[player.UserId] = nil
end

----------------------------------------------------------------------------------
-- Report
----------------------------------------------------------------------------------

local function setSize(set: { [string]: boolean }?): number
	local n = 0
	if set then
		for _ in set do
			n += 1
		end
	end
	return n
end

-- How many of `cohort`'s members appear in `dayRecord`'s players set.
local function returnedCount(cohort: { [string]: boolean }, dayRecord: DayRecord?): number
	local players = dayRecord and dayRecord.players
	if not players then
		return 0
	end
	local n = 0
	for uid in cohort do
		if players[uid] then
			n += 1
		end
	end
	return n
end

local function fmtHours(seconds: number): string
	if seconds >= 3600 then
		return string.format("%.1fh", seconds / 3600)
	end
	return string.format("%.0fm", seconds / 60)
end

-- Median of a list (nil when empty; mean of the middle two on even counts).
local function median(list: { number }): number?
	local n = #list
	if n == 0 then
		return nil
	end
	local sorted = table.clone(list)
	table.sort(sorted)
	if n % 2 == 1 then
		return sorted[(n + 1) // 2]
	end
	return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

-- Print the last `days` (default AdminConfig.Metrics.ReportDays) UTC days, one row each, plus
-- window totals. Retention cells show "—" while their target day hasn't happened yet (or
-- the cohort is empty). Yields (DataStore reads); run via task.spawn from a command.
function MetricsService.PrintReport(days: number?)
	if not store then
		print("[Metrics] DataStore unavailable — in Studio, enable 'Studio Access to API Services'.")
		return
	end
	local nDays = math.clamp(math.floor(days or AdminConfig.Metrics.ReportDays), 1, 90)
	local today = todayIndex()

	-- Fetch every needed record once (the window itself + each cohort's D1/D7/D30 targets,
	-- which mostly overlap the window anyway).
	local cache: { [number]: DayRecord? } = {}
	local function fetch(day: number): DayRecord?
		if cache[day] == nil then
			local ok, record = withRetry(function()
				return (store :: GlobalDataStore):GetAsync(dayKey(day))
			end)
			cache[day] = if ok and type(record) == "table" then record :: DayRecord else ({} :: DayRecord)
		end
		return cache[day]
	end

	local bar = string.rep("=", 116)
	print(bar)
	print(string.format(
		"Game Metrics — last %d days (UTC) — excluding %d listed + %d admin user ids%s",
		nDays,
		#AdminConfig.Metrics.ExcludedUserIds,
		#AdminConfig.UserIds,
		if recording then "" else "  [this server is NOT recording]"
	))
	print(string.format(
		"%-12s %5s %5s %6s %9s %9s %9s %9s %8s %8s %8s",
		"date", "DAU", "new", "sess", "playtime", "avg sess", "med sess", "avg plr", "D1", "D7", "D30"
	))

	-- A retention cell: cohort day + offset. "—" when the target day is still in the
	-- future or the cohort had no new players.
	local function retentionCell(day: number, cohort: { [string]: boolean }?, cohortSize: number, offset: number): string
		if cohortSize == 0 or day + offset > today or not cohort then
			return "—"
		end
		return string.format("%.0f%%", 100 * returnedCount(cohort, fetch(day + offset)) / cohortSize)
	end

	local totalSessions, totalPlaytime, totalNew, dauSum = 0, 0, 0, 0
	local allSessionLens: { number } = {}
	for day = today - nDays + 1, today do
		local r = fetch(day) or {}
		local dau = setSize(r.players)
		local newCount = setSize(r.new)
		local sessions = r.sessions or 0
		local playtime = r.playtime or 0
		local dayMedian = median(r.sessionLens or {})
		totalSessions += sessions
		totalPlaytime += playtime
		totalNew += newCount
		dauSum += dau
		for _, len in r.sessionLens or {} do
			table.insert(allSessionLens, len)
		end

		print(string.format(
			"%-12s %5d %5d %6d %9s %9s %9s %9s %8s %8s %8s",
			os.date("!%Y-%m-%d", day * DAY) :: string,
			dau,
			newCount,
			sessions,
			fmtHours(playtime),
			if sessions > 0 then fmtHours(playtime / sessions) else "—",
			if dayMedian then fmtHours(dayMedian) else "—",
			if dau > 0 then fmtHours(playtime / dau) else "—", -- avg playtime per player
			retentionCell(day, r.new, newCount, 1),
			retentionCell(day, r.new, newCount, 7),
			retentionCell(day, r.new, newCount, 30)
		))
	end

	local windowMedian = median(allSessionLens)
	print(string.format(
		"WINDOW: avg DAU %.1f | new %d | sessions %d | playtime %s | avg session %s | med session %s | avg playtime/player-day %s",
		dauSum / nDays,
		totalNew,
		totalSessions,
		fmtHours(totalPlaytime),
		if totalSessions > 0 then fmtHours(totalPlaytime / totalSessions) else "—",
		if windowMedian then fmtHours(windowMedian) else "—",
		if dauSum > 0 then fmtHours(totalPlaytime / dauSum) else "—"
	))
	print(bar)
end

----------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------

function MetricsService.Init()
	if not recording then
		return -- report-only context (Studio / store unavailable); nothing to hook
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end

	-- Periodic playtime flush: bounds what a crash can lose to FLUSH_INTERVAL, and keeps
	-- long sessions crediting the correct (current) day.
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			for userId in tracked do
				task.spawn(flush, userId)
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for userId in tracked do
			pending += 1
			task.spawn(function()
				flush(userId, true) -- shutdown ends every session; keep the median samples
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
	end)
end

return MetricsService
