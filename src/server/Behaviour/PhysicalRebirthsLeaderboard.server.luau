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
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(ReplicatedStorage.Shared.StringUtils)
local Config = require(ReplicatedStorage.Shared.Config)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)

local GOLD_SEQ = ColorSequence.new(Color3.fromRGB(254,256,107), Color3.fromRGB(187,170,56))
local SILV_SEQ = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(162,183,190))
local BRNZ_SEQ = ColorSequence.new(Color3.fromRGB(242,191,130), Color3.fromRGB(190,143,70))
local NORM_SEQ = ColorSequence.new(Color3.fromRGB(199,170,251), Color3.fromRGB(162,132,201))

local TOP_N = 50               -- how many ranks to display
local REFRESH_INTERVAL = 120   -- seconds between full re-reads (picks up other servers)
-- OrderedDataStore needs API access, which Studio lacks by default; flip to test there.
local ENABLE_IN_STUDIO = false

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

-- Podium slots: each top-3 player is shown as a freshly built avatar, posed by a single-pose
-- animation. The authored rigs (FirstRig/SecondRig/ThirdRig) are only markers — we read their
-- pivot CFrame, scale, and Username billboard, then delete them, and spawn built avatars in
-- their place. (ApplyDescription on a hand-posed anchored rig fights the baked pose, so we
-- build the avatar properly and let an animation carry the pose instead.)
local podium = leaderboardsRoot:WaitForChild("Rebirths"):WaitForChild("Podium")

type PodiumSlot = {
    cframe: CFrame,
    footY: number,               -- world Y of the marker's feet (bbox bottom), to stand the statue on
    scale: number,
    animationId: string,
    nameTemplate: BillboardGui?, -- styled Username billboard lifted off the marker rig
    userId: number?,             -- who's currently shown (skip rebuild if unchanged)
    model: Model?,               -- the live built-avatar statue
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
    -- Feet = bottom of the (upright) bounding box, so we can stand the built avatar on the
    -- same spot regardless of pivot conventions.
    local bbCF, bbSize = rig:GetBoundingBox()
    podiumSlots[slot] = {
        cframe = rig:GetPivot(),
        footY = bbCF.Position.Y - bbSize.Y / 2,
        scale = if rig:IsA("Model") then rig:GetScale() else 1,
        animationId = def.anim,
        nameTemplate = nameTemplate,
        userId = nil,
        model = nil,
    }
    rig:Destroy() -- marker consumed; built avatars take its place
end


local enabled = (not RunService:IsStudio()) or ENABLE_IN_STUDIO
local store: OrderedDataStore? = nil
if enabled then
    local ok, result = pcall(function()
        return DataStoreService:GetOrderedDataStore("RebirthsLeaderboard_v2")
    end)
    if ok then
        store = result
    else
        warn("PhysicalRebirthsLeaderboard: OrderedDataStore unavailable: " .. tostring(result))
    end
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
-- gradient + the template's text colour) and set the player's name. Parented onto the built
-- statue.
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
    if s.model then
        s.model:Destroy()
        s.model = nil
    end
    s.userId = nil
end

-- Build the player's avatar, pose it, and stand it on the slot. Yields (network), so it's
-- called inside task.spawn. The slot's userId is set optimistically before the yield so a
-- rapid re-refresh doesn't double-build.
local function buildStatue(slot: number, userId: number)
    local s = podiumSlots[slot]

    local ok, model = pcall(function()
        return Players:CreateHumanoidModelFromUserId(userId)
    end)
    if not ok or not model then
        warn(("PhysicalRebirthsLeaderboard: CreateHumanoidModelFromUserId failed for %d: %s"):format(userId, tostring(model)))
        if s.userId == userId then
            s.userId = nil -- let a later refresh retry
        end
        return
    end

    -- The slot may have moved on (or been cleared) while we were fetching; drop this build.
    if s.userId ~= userId then
        model:Destroy()
        return
    end

    model.Name = "PodiumStatue" .. slot

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid then
        -- Suppress the default overhead name tag (we show our own styled billboard).
        humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    end

    -- Anchor the root before parenting so it never falls, then place + scale (ScaleTo keeps
    -- the pivot, so it stays where we put it).
    local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
    if hrp then
        hrp.Anchored = true
    end
    model:PivotTo(s.cframe)
    model:ScaleTo(s.scale)
    -- Pivots differ between the marker (bbox center) and a built avatar (HumanoidRootPart),
    -- so align by feet: drop/raise the statue until its bbox bottom sits on the marker's.
    local abbCF, abbSize = model:GetBoundingBox()
    local dy = s.footY - (abbCF.Position.Y - abbSize.Y / 2)
    model:PivotTo(model:GetPivot() + Vector3.new(0, dy, 0))

    if s.nameTemplate then
        local nameGui = s.nameTemplate:Clone()
        styleNameGui(nameGui, slot, userId)
        nameGui.Parent = hrp or model
    end

    model.Parent = podium

    -- Carry the pose with a looped single-pose animation (the anchored root holds the body
    -- in place while the animator drives the limbs into the pose).
    if humanoid and s.animationId ~= "" then
        local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
        local anim = Instance.new("Animation")
        anim.AnimationId = s.animationId
        local okTrack, track = pcall(function()
            return (animator :: Animator):LoadAnimation(anim)
        end)
        if okTrack and track then
            track.Looped = true
            track:Play(0)
        else
            warn(("PhysicalRebirthsLeaderboard: pose animation failed on slot %d: %s"):format(slot, tostring(track)))
        end
    end

    -- Replace the previous statue only now the new one is ready (avoids a visible gap).
    if s.model then
        s.model:Destroy()
    end
    s.model = model
end

-- Place the top 1/2/3 players on the podium. podiumIds[1..3] = top userIds (shorter if fewer
-- than three players have rebirthed); an unoccupied slot is cleared.
local function applyPodium(podiumIds: { number })
    for slot in podiumSlots do
        local userId = podiumIds[slot]
        local s = podiumSlots[slot]
        if not userId then
            clearSlot(slot)
        elseif s.userId ~= userId then
            s.userId = userId -- claim before the async build so we don't double-build
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
        if count > 0 then
            table.insert(entries, { userId = player.UserId, count = count })
        end
    end
    table.sort(entries, function(a, b)
        return a.count > b.count
    end)
    return entries
end

local function refreshRebirths()
    if not store then
        renderEntries(localEntries()) -- Studio fallback
        return
    end
    local ok, pages = pcall(function()
        return (store :: OrderedDataStore):GetSortedAsync(false, TOP_N)
    end)
    if not ok then
        warn("PhysicalRebirthsLeaderboard: GetSortedAsync failed: " .. tostring(pages))
        return
    end

    local entries: { Entry } = {}
    for _, entry in ipairs(pages:GetCurrentPage()) do
        local userId = tonumber(entry.key)
        local count = tonumber(entry.value)
        if userId and count and count > 0 then
            table.insert(entries, { userId = userId, count = count })
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
    if not store or count <= 0 then
        return
    end
    if lastWritten[player.UserId] == count then
        return
    end
    local ok, err = pcall(function()
        (store :: OrderedDataStore):SetAsync(player.UserId, count)
    end)
    if ok then
        lastWritten[player.UserId] = count
        -- Reflect the new standing promptly (e.g. the player who just rebirthed).
        task.spawn(refreshRebirths)
    else
        warn("PhysicalRebirthsLeaderboard: SetAsync failed: " .. tostring(err))
    end
end

local function init()
    if store then
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

    -- Dev hook (DevService /podium): force a userId onto all three podium spots so the
    -- statue build/pose/scale can be eyeballed without three rebirthed players. Server-only
    -- Bindable, so it's unreachable from clients. The next real refresh overwrites it.
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
