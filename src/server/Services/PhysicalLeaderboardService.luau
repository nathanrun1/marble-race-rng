--!strict
-- The physical leaderboard boards in the world, all in one place (they share their whole
-- rendering vocabulary — row template cloning, top-3 gradients, name resolution):
--
--   * ServerCoins  — per-server live balances (no persistence): one row per connected
--     player, resorted on every CurrencyService.Changed.
--   * MoneyPerBall — global, persistent Avg $/Marble board (OrderedDataStore via
--     DataService). Tracks each player's ALL-TIME BEST average — PrestigeService resets
--     the live average on rebirth, so a value only overwrites the store when it beats
--     what's already there, seeded from the store at join so a fresh session can't
--     undercut an old record. Also pushes each player's global rank to their client
--     (LeaderboardNet.MoneyPerBallRank) for the HUD readout.
--   * Rebirths     — global, persistent top-Rebirths board + a 3-slot podium of built
--     avatar statues looping published emotes.
--
-- Both global boards fall back to ranking the players in THIS server when DataService
-- leaderboards are unavailable (Studio without API access), so they can be eyeballed solo.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(RS.Shared.Utility.StringUtils)
local AnimationService = require(RS.Shared.Utility.AnimationService)
local AdminConfig = require(RS.Shared.Config.Admin)
local WorldConfig = require(RS.Shared.Config.World)
local LeaderboardNet = require(RS.Shared.Remote.LeaderboardNet)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local DataService = require(SSS.Scripts.Services.DataService)
local PrestigeService = require(SSS.Scripts.Services.PrestigeService)
local StatsService = require(SSS.Scripts.Services.StatsService)

local PhysicalLeaderboardService = {}

local GOLD_SEQ = ColorSequence.new(Color3.fromRGB(254, 256, 107), Color3.fromRGB(187, 170, 56))
local SILV_SEQ = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(162, 183, 190))
local BRNZ_SEQ = ColorSequence.new(Color3.fromRGB(242, 191, 130), Color3.fromRGB(190, 143, 70))
local NORM_SEQ = ColorSequence.new(Color3.fromRGB(199, 170, 251), Color3.fromRGB(162, 132, 201))

local TOP_N = 50 -- ranks displayed / reported on the global boards
local REFRESH_INTERVAL = 120 -- seconds between full store re-reads (picks up other servers)
local WRITE_INTERVAL = 30 -- min seconds between $/marble writes for a given player
-- DataService leaderboard board names. Version (…_v2, _v3…) to wipe an all-time board.
local MONEY_BOARD = "MoneyPerBall_v1"
local REBIRTHS_BOARD = "Rebirths_v3"

-- Admins are hidden from leaderboards: never written to a store, filtered from the display.
local function isExcluded(userId: number): boolean
	return AdminConfig.IsAdmin(userId)
end

-- The Studio fallback renders read live self-reported values, not the store, so relaxing the
-- filter for admins there is safe (boards can be tested solo) — it never affects what gets
-- persisted (the write paths always use isExcluded, regardless of Studio).
local function isHiddenInLocalView(userId: number): boolean
	if RunService:IsStudio() then
		return false
	end
	return isExcluded(userId)
end

-- userId -> resolved username, shared by every board so a name is fetched at most once.
local nameCache: { [number]: string } = {}

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

-- A physical board: the ScrollingFrame rows live in + the hidden Item row template.
type Board = { itemsParent: Instance, item: any }

local function resolveBoard(scroll: Instance): Board
	return { itemsParent = scroll, item = scroll:WaitForChild("Item") }
end

-- Fill one cloned row (shared row vocabulary: Username text + gradient, Balance text).
local function fillRow(board: Board, rank: number, name: string, valueText: string): GuiObject
	local obj = board.item:Clone()
	obj.Visible = true
	obj.Username.Text = name
	obj.Username.UIGradient.Color = gradientFor(rank)
	obj.Balance.Text = valueText
	obj.LayoutOrder = rank
	obj.Parent = board.itemsParent
	return obj
end

--------------------------------------------------------------------------------
-- ServerCoins — per-server live balances
--------------------------------------------------------------------------------
type ServerCoinItem = { object: any, balance: number }
local serverCoinItems: { [number]: ServerCoinItem } = {}

-- Admins show in Studio so the board can be eyeballed solo (this board persists nothing).
local function serverCoinsExcluded(userId: number): boolean
	return isHiddenInLocalView(userId)
end

-- Resort + regrade the per-player rows in place (rows persist; only order/gradient change).
local function refreshServerCoins()
	local users: { number } = {}
	for k in serverCoinItems do
		table.insert(users, k)
	end
	table.sort(users, function(a: number, b: number)
		return serverCoinItems[a].balance > serverCoinItems[b].balance
	end)

	for i, k in ipairs(users) do
		local obj = serverCoinItems[k].object
		obj.Username.UIGradient.Color = gradientFor(i)
		obj.LayoutOrder = i
	end
end

local function initServerCoins(board: Board)
	Players.PlayerAdded:Connect(function(player: Player)
		if serverCoinsExcluded(player.UserId) then
			return
		end
		local playerItem = board.item:Clone()
		playerItem.Visible = true
		playerItem.Parent = board.itemsParent
		serverCoinItems[player.UserId] = { object = playerItem, balance = CurrencyService.GetPoints(player) }
		refreshServerCoins()
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local item = serverCoinItems[player.UserId]
		if not item then
			return
		end
		item.object:Destroy()
		serverCoinItems[player.UserId] = nil
		refreshServerCoins()
	end)

	CurrencyService.Changed:Connect(function(player, newBalance)
		local item = serverCoinItems[player.UserId]
		if not item then
			return
		end
		item.object.Balance.Text = StringUtils.FormatMoney(newBalance)
		item.object.Username.Text = player.Name
		item.balance = newBalance
		refreshServerCoins()
	end)
end

--------------------------------------------------------------------------------
-- MoneyPerBall — global all-time-best Avg $/Marble
--------------------------------------------------------------------------------
type Entry = { userId: number, value: number }

local moneyBoard: Board? = nil
local moneyRows: { GuiObject } = {}
-- Each player's persisted all-time-best (rounded) average — the write gate: a report only
-- overwrites the store when it beats this. Seeded from the store itself on join, then kept
-- current as we successfully write new records.
local lastWrittenMoney: { [number]: number } = {}
-- Last time (os.clock()) we wrote for a player, throttling how often we spend a write.
local lastWriteTime: { [number]: number } = {}
-- Highest average reported THIS SESSION per connected player. Used for the Studio fallback
-- render and to flush the session's best on leave (bypassing the throttle) — the session best
-- rather than the latest report, so a post-prestige dip never masks a record set earlier.
local bestReported: { [number]: number } = {}
-- Ranks from the most recent render, so a player who joins mid-session gets an immediate rank
-- (from cache) instead of waiting up to REFRESH_INTERVAL for the next full rebuild.
local lastRanks: { [number]: number } = {}

-- Rebuild the board from a descending, already-filtered (>0) entry list, then tell every
-- currently-connected player their rank (unranked if they're outside the top TOP_N).
local function renderMoneyEntries(entries: { Entry })
	local board = moneyBoard
	if not board then
		return
	end
	for _, row in moneyRows do
		row:Destroy()
	end
	table.clear(moneyRows)

	local ranks: { [number]: number } = {}
	for rank, e in ipairs(entries) do
		ranks[e.userId] = rank
		if rank > TOP_N then
			continue
		end
		table.insert(moneyRows, fillRow(board, rank, resolveName(e.userId), StringUtils.FormatMoney(e.value)))
	end

	lastRanks = ranks
	for _, player in Players:GetPlayers() do
		LeaderboardNet.MoneyPerBallRank:FireClient(player, ranks[player.UserId])
	end
end

-- Studio (no OrderedDataStore): rank the players currently in this server by their best
-- self-reported average this session, so the board can be tested without API access.
local function localMoneyEntries(): { Entry }
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
	if not DataService.LeaderboardsEnabled() then
		renderMoneyEntries(localMoneyEntries()) -- Studio fallback
		return
	end
	local top = DataService.LeaderboardTop(MONEY_BOARD, TOP_N)
	if not top then
		return -- store errored; keep the current render, retry next refresh
	end
	local entries: { Entry } = {}
	for _, e in top do
		if e.value > 0 and not isExcluded(e.userId) then
			table.insert(entries, { userId = e.userId, value = e.value })
		end
	end
	renderMoneyEntries(entries)
end

-- Persist a player's average (rounded to the nearest dollar; OrderedDataStore values must be
-- integers) — but only when it's a new all-time best, throttled so continuous reports don't
-- spend a write every few seconds.
local function writeAverage(player: Player, value: number, force: boolean?)
	if not DataService.LeaderboardsEnabled() or isExcluded(player.UserId) then
		return
	end
	local rounded = math.round(value)
	if rounded <= 0 then
		return
	end
	if rounded <= (lastWrittenMoney[player.UserId] or 0) then
		return -- not a new record (includes the post-prestige reset to 0) — never overwrite the board
	end
	local last = lastWriteTime[player.UserId]
	if not force and last and (os.clock() - last) < WRITE_INTERVAL then
		return
	end
	if DataService.LeaderboardSet(MONEY_BOARD, player.UserId, rounded) then
		lastWrittenMoney[player.UserId] = rounded
		lastWriteTime[player.UserId] = os.clock()
		task.spawn(refreshMoneyPerBall)
	else
		warn("PhysicalLeaderboardService: $/marble write failed for " .. player.Name)
	end
end

-- Seed lastWrittenMoney from the store at join, so this session can't undercut a record set
-- on a previous one before this session's own average has climbed back past it.
local function seedLastWritten(player: Player)
	if not DataService.LeaderboardsEnabled() or isExcluded(player.UserId) then
		return
	end
	task.spawn(function()
		local existing = DataService.LeaderboardGet(MONEY_BOARD, player.UserId)
		if existing then
			lastWrittenMoney[player.UserId] = existing
		end
	end)
end

--------------------------------------------------------------------------------
-- Rebirths — global top-Rebirths board + podium statues
--------------------------------------------------------------------------------
type PodiumSlot = {
	cframe: CFrame,
	footY: number, -- world Y of the marker's feet (bbox bottom), to stand the statue on
	scale: number,
	animationId: string, -- emote asset id this slot loops (WorldConfig.Podium.Animations)
	nameTemplate: BillboardGui?, -- styled Username billboard lifted off the marker rig
	userId: number?, -- who's currently shown (skip rebuild if unchanged)
	model: Model?, -- the live built-avatar statue
	anim: AnimationService.Handle?,
}

local rebirthsBoard: Board? = nil
local rebirthRows: { GuiObject } = {}
-- Last count we successfully wrote per player, so a Changed that doesn't move the count
-- (e.g. a banking that only bumps lifetimeBanked) doesn't spend a DataStore write.
local lastWrittenCount: { [number]: number } = {}
local podium: Instance? = nil
local podiumSlots: { PodiumSlot } = {}
local r15Rig: Model? = nil

-- Style the slot's Username billboard like the leaderboard row for that rank (same per-rank
-- gradient + the template's text colour) and set the player's name.
local function styleNameGui(gui: BillboardGui, slot: number, userId: number)
	local label = gui:FindFirstChild("TextLabel")
	if not (label and label:IsA("TextLabel")) then
		return
	end
	local board = rebirthsBoard
	if board then
		label.TextColor3 = board.item.Username.TextColor3
	end
	local grad = label:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = gradientFor(slot)
	end
	task.spawn(function()
		label.Text = resolveName(userId)
	end)
end

-- Stop showing a slot's statue (unoccupied rank).
local function clearSlot(slot: number)
	local s = podiumSlots[slot]
	if s.anim then
		s.anim.Stop()
		s.anim = nil
	end
	if s.model then
		s.model:Destroy()
		s.model = nil
	end
	s.userId = nil
end

-- Build the player's avatar, pose it on the slot, and loop its emote. Yields (network), so it's
-- called inside task.spawn; the slot's userId is claimed before the yield to avoid double-builds.
local function buildStatue(slot: number, userId: number)
	local s = podiumSlots[slot]
	local rig = r15Rig
	local podiumFolder = podium
	if not rig or not podiumFolder then
		return
	end

	local ok, humDesc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if not ok or not humDesc then
		warn(("PhysicalLeaderboardService: GetHumanoidDescriptionFromUserIdAsync failed for %d"):format(userId))
		if s.userId == userId then
			s.userId = nil
		end
		return
	end

	local model = rig:Clone()
	model.Name = "PodiumStatue" .. slot
	model.Parent = podiumFolder
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warn(("PhysicalLeaderboardService: loaded R15 rig does not contain a Humanoid: %s"):format(tostring(rig)))
		return
	end

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid:ApplyDescriptionAsync(humDesc)

	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp.Anchored = true
	end
	model:PivotTo(s.cframe)
	model:ScaleTo(s.scale)
	-- Align by feet (marker pivot is bbox-centre; a built avatar pivots at the HRP).
	local abbCF, abbSize = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + Vector3.new(0, s.footY - (abbCF.Position.Y - abbSize.Y / 2), 0))

	if s.nameTemplate then
		local nameGui = s.nameTemplate:Clone()
		styleNameGui(nameGui, slot, userId)
		nameGui.Parent = hrp or model
	end

	local handle: AnimationService.Handle? = nil
	if s.animationId ~= "" then
		handle = AnimationService.Play(model, s.animationId, { looped = true })
	end

	-- Swap in the finished statue (avoids a visible gap), retiring the previous one.
	if s.anim then
		s.anim.Stop()
	end
	if s.model then
		s.model:Destroy()
	end
	s.model = model
	s.anim = handle
end

-- Place the top 1/2/3 players on the podium. podiumIds[rank] = userId (sparse if <3 players);
-- an unoccupied slot is cleared.
local function applyPodium(podiumIds: { number })
	for slot in podiumSlots do
		local userId = podiumIds[slot]
		local s = podiumSlots[slot]
		if not userId then
			clearSlot(slot)
		elseif s.userId ~= userId then
			s.userId = userId -- claim before the async build
			task.spawn(buildStatue, slot, userId)
		end
	end
end

type CountEntry = { userId: number, count: number }

-- Rebuild the board (and podium) from a descending, already-filtered (>0) entry list.
local function renderRebirthEntries(entries: { CountEntry })
	local board = rebirthsBoard
	if not board then
		return
	end
	for _, row in rebirthRows do
		row:Destroy()
	end
	table.clear(rebirthRows)

	local podiumIds: { number } = {}
	for rank, e in ipairs(entries) do
		if rank > TOP_N then
			break
		end
		table.insert(rebirthRows, fillRow(board, rank, resolveName(e.userId), StringUtils.FormatCompact(e.count)))
		if rank <= 3 then
			podiumIds[rank] = e.userId
		end
	end

	applyPodium(podiumIds)
end

-- Studio (no OrderedDataStore): rank the players currently in this server by their live
-- prestige count, so the board + podium can be tested without API access.
local function localRebirthEntries(): { CountEntry }
	local entries: { CountEntry } = {}
	for _, player in Players:GetPlayers() do
		local count = PrestigeService.GetCount(player)
		if count > 0 and not isHiddenInLocalView(player.UserId) then
			table.insert(entries, { userId = player.UserId, count = count })
		end
	end
	table.sort(entries, function(a, b)
		return a.count > b.count
	end)
	return entries
end

local function refreshRebirths()
	if not DataService.LeaderboardsEnabled() then
		renderRebirthEntries(localRebirthEntries()) -- Studio fallback
		return
	end
	local top = DataService.LeaderboardTop(REBIRTHS_BOARD, TOP_N)
	if not top then
		return -- store errored; keep the current render, retry next refresh
	end
	local entries: { CountEntry } = {}
	for _, e in top do
		if e.value > 0 and not isExcluded(e.userId) then
			table.insert(entries, { userId = e.userId, count = e.value })
		end
	end
	renderRebirthEntries(entries)
end

-- Persist a player's rebirth count (>0 only), skipping no-op writes.
local function writeCount(player: Player, count: number)
	if not DataService.LeaderboardsEnabled() or count <= 0 or isExcluded(player.UserId) then
		return
	end
	if lastWrittenCount[player.UserId] == count then
		return
	end
	if DataService.LeaderboardSet(REBIRTHS_BOARD, player.UserId, count) then
		lastWrittenCount[player.UserId] = count
		-- Reflect the new standing promptly (e.g. the player who just rebirthed).
		task.spawn(refreshRebirths)
	else
		warn("PhysicalLeaderboardService: rebirths write failed for " .. player.Name)
	end
end

--------------------------------------------------------------------------------
-- Shared refresh plumbing + lifecycle
--------------------------------------------------------------------------------
-- Debounced refreshes for the Studio path, where frequent reports/roster changes
-- shouldn't each trigger a full rebuild.
local function debounced(fn: () -> ()): () -> ()
	local queued = false
	return function()
		if queued then
			return
		end
		queued = true
		task.delay(0.5, function()
			queued = false
			fn()
		end)
	end
end
local scheduleStudioMoneyRefresh = debounced(refreshMoneyPerBall)
local scheduleStudioRebirthRefresh = debounced(refreshRebirths)

-- Dev hook (DevService /podium): force a userId onto all three podium spots so the statue
-- build/pose/scale can be eyeballed without three rebirthed players. The next real refresh
-- overwrites it.
function PhysicalLeaderboardService.TestPodium(userId: number)
	applyPodium({ userId, userId, userId })
end

function PhysicalLeaderboardService.Init() end

-- Resolves the authored boards (WaitForChild) and wires everything, so it runs spawned.
function PhysicalLeaderboardService.Start()
	local leaderboardsRoot = workspace:WaitForChild("Leaderboards")
	local enabled = DataService.LeaderboardsEnabled()

	----------------------------------------------------------------------------
	-- ServerCoins
	----------------------------------------------------------------------------
	initServerCoins(resolveBoard(leaderboardsRoot
		:WaitForChild("ServerCoins")
		:WaitForChild("Leaderboard")
		:WaitForChild("SurfaceGui")
		:WaitForChild("ScrollingFrame")))

	----------------------------------------------------------------------------
	-- MoneyPerBall
	----------------------------------------------------------------------------
	moneyBoard = resolveBoard(leaderboardsRoot
		:WaitForChild("MoneyPerBall")
		:WaitForChild("Leaderboard")
		:WaitForChild("SurfaceGui")
		:WaitForChild("ScrollingFrame"))

	-- Give a joining player their rank from the last render immediately, rather than making
	-- them wait for the next periodic refresh or their first ball banked this session.
	Players.PlayerAdded:Connect(function(player: Player)
		LeaderboardNet.MoneyPerBallRank:FireClient(player, lastRanks[player.UserId])
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
			scheduleStudioMoneyRefresh()
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
		lastWrittenMoney[player.UserId] = nil
		lastWriteTime[player.UserId] = nil
		if not enabled then
			scheduleStudioMoneyRefresh()
		end
	end)

	----------------------------------------------------------------------------
	-- Rebirths + podium
	----------------------------------------------------------------------------
	rebirthsBoard = resolveBoard(leaderboardsRoot
		:WaitForChild("Rebirths")
		:WaitForChild("FramePart")
		:WaitForChild("SurfaceGui")
		:WaitForChild("ScrollingFrame"))

	r15Rig = RS:WaitForChild("Assets"):WaitForChild("R15Rig") :: Model

	-- Podium slots: each top-3 player is shown as a freshly built avatar that loops a
	-- (published) emote. The authored rigs (FirstRig/SecondRig/ThirdRig) are only markers —
	-- we read their pivot CFrame, scale, and Username billboard, then delete them and spawn
	-- built avatars in their place.
	local podiumFolder = leaderboardsRoot:WaitForChild("Rebirths"):WaitForChild("Podium")
	podium = podiumFolder

	local SLOT_DEFS = {
		{ rig = "FirstRig", anim = WorldConfig.Podium.Animations.First },
		{ rig = "SecondRig", anim = WorldConfig.Podium.Animations.Second },
		{ rig = "ThirdRig", anim = WorldConfig.Podium.Animations.Third },
	}
	for slot, def in SLOT_DEFS do
		local rig = podiumFolder:WaitForChild(def.rig)
		local nameTemplate: BillboardGui? = nil
		local existingName = rig:FindFirstChild("Username", true)
		if existingName and existingName:IsA("BillboardGui") then
			nameTemplate = existingName:Clone()
		end
		assert(rig:IsA("Model"), "podium marker rig must be a Model: " .. def.rig)
		local bbCF, bbSize = rig:GetBoundingBox()
		podiumSlots[slot] = {
			cframe = rig:GetPivot(),
			footY = bbCF.Position.Y - bbSize.Y / 2,
			scale = rig:GetScale(),
			animationId = def.anim,
			nameTemplate = nameTemplate,
		}
		rig:Destroy()
	end

	if enabled then
		-- Live: persist count changes globally. Changed fires on join (ApplyData) and on
		-- every prestige; writeCount dedupes so only an actual count change spends a write.
		PrestigeService.Changed:Connect(function(player: Player, info)
			writeCount(player, info.count)
		end)
		-- Final write on leave (covers a count that changed since the last write).
		Players.PlayerRemoving:Connect(function(player: Player)
			writeCount(player, PrestigeService.GetCount(player))
			lastWrittenCount[player.UserId] = nil
		end)
	else
		-- Studio: rebuild from this server's live prestige counts on any roster/count change.
		PrestigeService.Changed:Connect(scheduleStudioRebirthRefresh)
		Players.PlayerAdded:Connect(scheduleStudioRebirthRefresh)
		Players.PlayerRemoving:Connect(scheduleStudioRebirthRefresh)
	end

	----------------------------------------------------------------------------
	-- Refresh loops
	----------------------------------------------------------------------------
	refreshMoneyPerBall()
	refreshRebirths()
	while true do
		task.wait(REFRESH_INTERVAL)
		refreshMoneyPerBall()
		refreshRebirths()
	end
end

return PhysicalLeaderboardService
