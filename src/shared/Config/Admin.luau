--!strict
-- Admin UserIds + analytics exclusions.

local Admin = {
	-- Granted dev commands (DevService) and hidden from every leaderboard.
	UserIds = { 89831196 },

	-- Custom day-by-day analytics (MetricsService): DAU, new players, sessions, playtime, and
	-- D1/D7/D30 retention — the Roblox-dashboard numbers, minus the players below, because
	-- dev/tester sessions distort a small game's stats and the official dashboard can't filter
	-- them. UserIds above are ALWAYS excluded on top of this list. Only live servers record;
	-- print anywhere with /metrics [days] (needs API access enabled in Studio).
	Metrics = {
		ExcludedUserIds = { 338455474, 110797589, 1244172772, 245715627, 1244172772 }, -- extra user ids to exclude besides the admins
		ReportDays = 14, -- default day rows /metrics prints
	},
}

-- True if this user id is an admin (dev commands, leaderboard exclusion).
function Admin.IsAdmin(userId: number): boolean
	return table.find(Admin.UserIds, userId) ~= nil
end

table.freeze(Admin)
table.freeze(Admin.UserIds)

return Admin
