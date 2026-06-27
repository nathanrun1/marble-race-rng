--!strict
-- All-time top Rebirths physical leaderboard. Same visual style as the ServerCoins board
-- (PhysicalLeaderboards.server.luau), but global instead of per-server: rebirth counts are
-- written to an OrderedDataStore and the top N across every server are rendered here.
--
-- "Balance" shows the player's rebirth (prestige) count, and only players with >0 rebirths
-- appear. The scrolling frame lives at Workspace.Leaderboards.Rebirths.FramePart.ScrollingFrame,
-- with the Item template inside it (cloned per entry).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(ReplicatedStorage.Shared.StringUtils)
local Config = require(ReplicatedStorage.Shared.Config)
local AnimationService = require(ReplicatedStorage.Shared.AnimationService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)
local DataService = require(SSS.Scripts.Modules.DataService)

local GOLD_SEQ = ColorSequence.new(Color3.fromRGB(254,256,107), Color3.fromRGB(187,170,56))
local SILV_SEQ = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(162,183,190))
local BRNZ_SEQ = ColorSequence.new(Color3.fromRGB(242,191,130), Color3.fromRGB(190,143,70))
local NORM_SEQ = ColorSequence.new(Color3.fromRGB(199,170,251), Color3.fromRGB(162,132,201))

local TOP_N = 50               -- how many ranks to display
local REFRESH_INTERVAL = 120   -- seconds between full re-reads (picks up other servers)
-- DataService leaderboard board name. Version (…_v3, _v4…) to wipe the all-time board.
local BOARD = "Rebirths_v3"

local leaderboardsRoot = game.Workspace:WaitForChild("Leaderboards")
local rebirthsScroll = leaderboardsRoot
    :WaitForChild("Rebirths")
    :WaitForChild("FramePart")
    :WaitForChild("SurfaceGui")
    :WaitForChild("ScrollingFrame")

local rebirthsBoard = {
    itemsParent = rebirthsScroll,
    item = rebirthsScroll:WaitForChild("Item"),
}

-- Podium slots: each top-3 player is shown as a freshly built avatar that loops a (published)
-- emote. The authored rigs (FirstRig/SecondRig/ThirdRig) are only markers — we read their pivot
-- CFrame, scale, and Username billboard, then delete them and spawn built avatars in their place.
local podium = leaderboardsRoot:WaitForChild("Rebirths"):WaitForChild("Podium")

type PodiumSlot = {
    cframe: CFrame,
    footY: number,               -- world Y of the marker's feet (bbox bottom), to stand the statue on
    scale: number,
    animationId: string,         -- emote asset id this slot loops (Config.Podium.Animations)
    nameTemplate: BillboardGui?, -- styled Username billboard lifted off the marker rig
    userId: number?,             -- who's currently shown (skip rebuild if unchanged)
    model: Model?,               -- the live built-avatar statue
    anim: AnimationService.Handle?,
}

local SLOT_DEFS = {
    { rig = "FirstRig", anim = Config.Podium.Animations.First },
    { rig = "SecondRig", anim = Config.Podium.Animations.Second },
    { rig = "ThirdRig", anim = Config.Podium.Animations.Third },
}

local podiumSlots: { PodiumSlot } = {}
for slot, def in SLOT_DEFS do
    local rig = podium:WaitForChild(def.rig)
    local nameTemplate: BillboardGui? = nil
    local existingName = rig:FindFirstChild("Username", true)
    if existingName and existingName:IsA("BillboardGui") then
        nameTemplate = existingName:Clone()
    end
    local bbCF, bbSize = rig:GetBoundingBox()
    podiumSlots[slot] = {
        cframe = rig:GetPivot(),
        footY = bbCF.Position.Y - bbSize.Y / 2,
        scale = if rig:IsA("Model") then rig:GetScale() else 1,
        animationId = def.anim,
        nameTemplate = nameTemplate,
    }
    rig:Destroy() -- marker consumed; built avatars take its place
end

-- Persistent leaderboard via DataService (false in Studio → per-server fallback below).
local enabled = DataService.LeaderboardsEnabled()

-- Admins are hidden from leaderboards: never written, filtered from display.
local function isExcluded(userId: number): boolean
    return table.find(Config.Admins, userId) ~= nil
end

-- Cloned rows currently shown (rebuilt each refresh).
local rows: { GuiObject } = {}
-- Last count we successfully wrote per player, so a Changed that doesn't move the count
-- (e.g. a banking that only bumps lifetimeBanked) doesn't spend a DataStore write.
local lastWritten: { [number]: number } = {}
-- userId -> resolved username, so we don't re-hit GetNameFromUserIdAsync each refresh.
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

-- Style the slot's Username billboard like the leaderboard row for that rank (same per-rank
-- gradient + the template's text colour) and set the player's name.
local function styleNameGui(gui: BillboardGui, slot: number, userId: number)
    local label = gui:FindFirstChild("TextLabel")
    if not (label and label:IsA("TextLabel")) then
        return
    end
    label.TextColor3 = rebirthsBoard.item.Username.TextColor3
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

    local ok, model = pcall(function()
        return Players:CreateHumanoidModelFromUserId(userId)
    end)
    if not ok or not model then
        warn(("PhysicalRebirthsLeaderboard: CreateHumanoidModelFromUserId failed for %d: %s"):format(userId, tostring(model)))
        if s.userId == userId then
            s.userId = nil
        end
        return
    end
    if s.userId ~= userId then
        model:Destroy() -- slot moved on while we were fetching
        return
    end

    model.Name = "PodiumStatue" .. slot
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    end

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

    model.Parent = podium

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

type Entry = { userId: number, count: number }

-- Rebuild the board (and podium) from a descending, already-filtered (>0) entry list.
local function renderEntries(entries: { Entry })
    for _, row in rows do
        row:Destroy()
    end
    table.clear(rows)

    local podiumIds: { number } = {}
    for rank, e in ipairs(entries) do
        if rank > TOP_N then
            break
        end
        local obj = rebirthsBoard.item:Clone()
        obj.Visible = true
        obj.Username.Text = resolveName(e.userId)
        obj.Username.UIGradient.Color = gradientFor(rank)
        obj.Balance.Text = StringUtils.FormatCompact(e.count)
        obj.LayoutOrder = rank
        obj.Parent = rebirthsBoard.itemsParent
        table.insert(rows, obj)
        if rank <= 3 then
            podiumIds[rank] = e.userId
        end
    end

    applyPodium(podiumIds)
end

-- Studio (no OrderedDataStore): rank the players currently in this server by their live
-- prestige count, so the board + podium can be tested without API access.
local function localEntries(): { Entry }
    local entries: { Entry } = {}
    for _, player in Players:GetPlayers() do
        local count = PrestigeService.GetCount(player)
        if count > 0 and not isExcluded(player.UserId) then
            table.insert(entries, { userId = player.UserId, count = count })
        end
    end
    table.sort(entries, function(a, b)
        return a.count > b.count
    end)
    return entries
end

local function refreshRebirths()
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
            table.insert(entries, { userId = e.userId, count = e.value })
        end
    end
    renderEntries(entries)
end

-- Debounced refresh for the Studio path, where many Changed fires (banking) shouldn't each
-- trigger a full rebuild.
local studioRefreshQueued = false
local function scheduleStudioRefresh()
    if studioRefreshQueued then
        return
    end
    studioRefreshQueued = true
    task.delay(0.5, function()
        studioRefreshQueued = false
        refreshRebirths()
    end)
end

-- Persist a player's rebirth count (>0 only), skipping no-op writes.
local function writeCount(player: Player, count: number)
    if not enabled or count <= 0 or isExcluded(player.UserId) then
        return
    end
    if lastWritten[player.UserId] == count then
        return
    end
    if DataService.LeaderboardSet(BOARD, player.UserId, count) then
        lastWritten[player.UserId] = count
        -- Reflect the new standing promptly (e.g. the player who just rebirthed).
        task.spawn(refreshRebirths)
    else
        warn("PhysicalRebirthsLeaderboard: leaderboard write failed for " .. player.Name)
    end
end

local function init()
    if enabled then
        -- Live: persist count changes globally. Changed fires on join (ApplyData) and on
        -- every prestige; writeCount dedupes so only an actual count change spends a write.
        PrestigeService.Changed:Connect(function(player: Player, info)
            writeCount(player, info.count)
        end)
        -- Final write on leave (covers a count that changed since the last write).
        Players.PlayerRemoving:Connect(function(player: Player)
            writeCount(player, PrestigeService.GetCount(player))
            lastWritten[player.UserId] = nil
        end)
    else
        -- Studio: rebuild from this server's live prestige counts on any roster/count change.
        PrestigeService.Changed:Connect(scheduleStudioRefresh)
        Players.PlayerAdded:Connect(scheduleStudioRefresh)
        Players.PlayerRemoving:Connect(scheduleStudioRefresh)
    end

    -- Dev hook (DevService /podium): force a userId onto all three podium spots so the statue
    -- build/pose/scale can be eyeballed without three rebirthed players. Server-only Bindable,
    -- so it's unreachable from clients. The next real refresh overwrites it.
    local devEvent = Instance.new("BindableEvent")
    devEvent.Name = "PodiumDevTest"
    devEvent.Parent = ServerStorage
    devEvent.Event:Connect(function(userId: number)
        applyPodium({ userId, userId, userId })
    end)

    refreshRebirths()
    task.spawn(function()
        while true do
            task.wait(REFRESH_INTERVAL)
            refreshRebirths()
        end
    end)
end

init()
