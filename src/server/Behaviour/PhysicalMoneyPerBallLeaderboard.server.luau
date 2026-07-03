--!strict
-- Global, persistent "Avg $/Marble" physical leaderboard. Same GUI structure/visual style as
-- the ServerCoins board (PhysicalLeaderboards.server.luau) — Leaderboard.SurfaceGui.ScrollingFrame
-- with a cloned Item per row, top-3 gradient — but global instead of per-server: each player's
-- server-authoritative $/marble average (StatsService.GetAvgMoneyPerBall — derived purely from
-- cash the server itself credited on ball banking, so it can't be spoofed) is written to an
-- OrderedDataStore and the top N across every server are rendered here, same pattern as
-- PhysicalRebirthsLeaderboard.
--
-- Tracks each player's ALL-TIME BEST average, not their current one: PrestigeService resets
-- the live average back to 0 on every rebirth, so a plain "write whatever they report now"
-- would erase a player's record the moment they prestige. Instead a value only ever overwrites
-- the store when it beats what's already there — seeded at join from the store itself so a
-- fresh session can't undercut a record set on a previous one.
--
-- Also reports each visible player's own global rank to their client via a RemoteEvent, so
-- MoneyPerBallUI can show it under the $/marble readout. Ranks are only known for players inside
-- the top TOP_N (computing an exact rank further down an OrderedDataStore is prohibitively
-- expensive), so players outside it are reported as unranked.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(ReplicatedStorage.Shared.StringUtils)
local Config = require(ReplicatedStorage.Shared.Config)
local DataService = require(SSS.Scripts.Modules.DataService)
local StatsService = require(SSS.Scripts.Modules.StatsService)

local GOLD_SEQ = ColorSequence.new(Color3.fromRGB(254,256,107), Color3.fromRGB(187,170,56))
local SILV_SEQ = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(162,183,190))
local BRNZ_SEQ = ColorSequence.new(Color3.fromRGB(242,191,130), Color3.fromRGB(190,143,70))
local NORM_SEQ = ColorSequence.new(Color3.fromRGB(199,170,251), Color3.fromRGB(162,132,201))

local TOP_N = 50               -- how many ranks to display / report
local REFRESH_INTERVAL = 120   -- seconds between full re-reads (picks up other servers)
local WRITE_INTERVAL = 30      -- min seconds between persisted writes for a given player
-- DataService leaderboard board name. Version (…_v2, _v3…) to wipe the all-time board.
local BOARD = "MoneyPerBall_v1"

local leaderboardsRoot = game.Workspace:WaitForChild("Leaderboards")
local moneyPerBallScroll = leaderboardsRoot
    :WaitForChild("MoneyPerBall")
    :WaitForChild("Leaderboard")
    :WaitForChild("SurfaceGui")
    :WaitForChild("ScrollingFrame")

local moneyPerBallBoard = {
    itemsParent = moneyPerBallScroll,
    item = moneyPerBallScroll:WaitForChild("Item"),
}

local rankRE = Instance.new("RemoteEvent")
rankRE.Name = "MoneyPerBallRank"
rankRE.Parent = ReplicatedStorage.Remote

-- Persistent leaderboard via DataService (false in Studio → per-server fallback below).
local enabled = DataService.LeaderboardsEnabled()

-- Admins are hidden from leaderboards: never written to the store, filtered from the
-- persisted (top-N) display.
local function isExcluded(userId: number): boolean
    return table.find(Config.Admins, userId) ~= nil
end

-- Studio's fallback render (localEntries) reads live self-reported values, not the store, so
-- relaxing this for admins there is safe — it never affects what gets persisted (writeAverage
-- always uses isExcluded, regardless of Studio).
local function isHiddenInLocalView(userId: number): boolean
    if RunService:IsStudio() then
        return false
    end
    return isExcluded(userId)
end

-- Cloned rows currently shown (rebuilt each refresh).
local rows: { GuiObject } = {}
-- Each player's persisted all-time-best (rounded) average — the write gate: a report only
-- overwrites the store when it beats this. Seeded from the store itself on join (see
-- seedLastWritten below), then kept current as we successfully write new records.
local lastWritten: { [number]: number } = {}
-- Last time (os.clock()) we wrote for a player, throttling how often we spend a write.
local lastWriteTime: { [number]: number } = {}
-- Highest average reported THIS SESSION per connected player, keyed by userId. Used for the
-- Studio fallback render and to flush the session's best on leave (bypassing the throttle) —
-- using the session best rather than merely the latest report means a post-prestige dip never
-- masks a genuine record set earlier in the session.
local bestReported: { [number]: number } = {}
-- userId -> resolved username, so we don't re-hit GetNameFromUserIdAsync each refresh.
local nameCache: { [number]: string } = {}
-- Ranks from the most recent render, so a player who joins mid-session gets an immediate rank
-- (from cache) instead of waiting up to REFRESH_INTERVAL for the next full rebuild.
local lastRanks: { [number]: number } = {}

local function resolveName(userId: number): string
    local cached = nameCache[userId]
    if cached then
        return cached
    end
    local ok, name = pcall(function()
        return Players:GetNameFromUserIdAsync(userId)
    end)
    local resolved = (ok and name) or ("User " .. userId)
    nameCache[userId] = resolved
    return resolved
end

local function gradientFor(rank: number): ColorSequence
    if rank == 1 then
        return GOLD_SEQ
    elseif rank == 2 then
        return SILV_SEQ
    elseif rank == 3 then
        return BRNZ_SEQ
    end
    return NORM_SEQ
end

type Entry = { userId: number, value: number }

-- Rebuild the board from a descending, already-filtered (>0) entry list, then tell every
-- currently-connected player their rank (unranked if they're outside the top TOP_N).
local function renderEntries(entries: { Entry })
    for _, row in rows do
        row:Destroy()
    end
    table.clear(rows)

    local ranks: { [number]: number } = {}
    for rank, e in ipairs(entries) do
        ranks[e.userId] = rank
        if rank > TOP_N then
            continue
        end
        local obj = moneyPerBallBoard.item:Clone()
        obj.Visible = true
        obj.Username.Text = resolveName(e.userId)
        obj.Username.UIGradient.Color = gradientFor(rank)
        obj.Balance.Text = StringUtils.FormatMoney(e.value)
        obj.LayoutOrder = rank
        obj.Parent = moneyPerBallBoard.itemsParent
        table.insert(rows, obj)
    end

    lastRanks = ranks
    for _, player in Players:GetPlayers() do
        rankRE:FireClient(player, ranks[player.UserId])
    end
end

-- Studio (no OrderedDataStore): rank the players currently in this server by their best
-- self-reported average this session, so the board can be tested without API access.
local function localEntries(): { Entry }
    local entries: { Entry } = {}
    for userId, value in bestReported do
        if value > 0 and not isHiddenInLocalView(userId) then
            table.insert(entries, { userId = userId, value = value })
        end
    end
    table.sort(entries, function(a, b)
        return a.value > b.value
    end)
    return entries
end

local function refreshMoneyPerBall()
    if not enabled then
        renderEntries(localEntries()) -- Studio fallback
        return
    end
    local top = DataService.LeaderboardTop(BOARD, TOP_N)
    if not top then
        return -- store errored; keep the current render, retry next refresh
    end
    local entries: { Entry } = {}
    for _, e in top do
        if e.value > 0 and not isExcluded(e.userId) then
            table.insert(entries, { userId = e.userId, value = e.value })
        end
    end
    renderEntries(entries)
end

-- Debounced refresh for the Studio path, where frequent reports/roster changes shouldn't each
-- trigger a full rebuild.
local studioRefreshQueued = false
local function scheduleStudioRefresh()
    if studioRefreshQueued then
        return
    end
    studioRefreshQueued = true
    task.delay(0.5, function()
        studioRefreshQueued = false
        refreshMoneyPerBall()
    end)
end

-- Persist a player's average (rounded to the nearest dollar; OrderedDataStore values must be
-- integers) — but only when it's a new all-time best, throttled so continuous reports don't
-- spend a write every few seconds.
local function writeAverage(player: Player, value: number, force: boolean?)
    if not enabled or isExcluded(player.UserId) then
        return
    end
    local rounded = math.round(value)
    if rounded <= 0 then
        return
    end
    if rounded <= (lastWritten[player.UserId] or 0) then
        return -- not a new record (includes the post-prestige reset to 0) — never overwrite the board
    end
    local last = lastWriteTime[player.UserId]
    if not force and last and (os.clock() - last) < WRITE_INTERVAL then
        return
    end
    if DataService.LeaderboardSet(BOARD, player.UserId, rounded) then
        lastWritten[player.UserId] = rounded
        lastWriteTime[player.UserId] = os.clock()
        task.spawn(refreshMoneyPerBall)
    else
        warn("PhysicalMoneyPerBallLeaderboard: leaderboard write failed for " .. player.Name)
    end
end

-- Seed lastWritten from the store at join, so this session can't undercut a record set on a
-- previous one before this session's own average has climbed back past it.
local function seedLastWritten(player: Player)
    if not enabled or isExcluded(player.UserId) then
        return
    end
    task.spawn(function()
        local existing = DataService.LeaderboardGet(BOARD, player.UserId)
        if existing then
            lastWritten[player.UserId] = existing
        end
    end)
end

local function init()
    -- Give a joining player their rank from the last render immediately, rather than making
    -- them wait for the next periodic refresh or their first ball banked this session.
    Players.PlayerAdded:Connect(function(player: Player)
        rankRE:FireClient(player, lastRanks[player.UserId])
        seedLastWritten(player)
    end)
    for _, player in Players:GetPlayers() do
        seedLastWritten(player)
    end

    StatsService.BallBanked:Connect(function(player: Player, avg: number)
        if avg > (bestReported[player.UserId] or 0) then
            bestReported[player.UserId] = avg
        end
        if enabled then
            writeAverage(player, avg)
        else
            scheduleStudioRefresh()
        end
    end)

    Players.PlayerRemoving:Connect(function(player: Player)
        if enabled then
            -- Flush a final write covering the session's best, in case it beat the store but
            -- hadn't cleared the throttle yet.
            local value = bestReported[player.UserId]
            if value then
                writeAverage(player, value, true)
            end
        end
        bestReported[player.UserId] = nil
        lastWritten[player.UserId] = nil
        lastWriteTime[player.UserId] = nil
        if not enabled then
            scheduleStudioRefresh()
        end
    end)

    refreshMoneyPerBall()
    task.spawn(function()
        while true do
            task.wait(REFRESH_INTERVAL)
            refreshMoneyPerBall()
        end
    end)
end

init()
