--!strict
-- Board look scales with the LOCAL player's current bet tier (BoardAppearanceConfig) —
-- the physical board is shared, but each client repaints it to reflect ITS OWN viewer's
-- bet size, same "local view of shared state" pattern as GoldenPegView (per-player peg
-- recolor) and BoardMultiplierView (per-player label rewrite).
--
-- Four tags feed this: TagsConfig.Grass parts get the color-only Grass ramp (muted echo
-- of the board theme; authored material untouched); TagsConfig.BoardFloor / BoardSide
-- pick a part's specific ramp
-- (darker default for the floor marbles roll on, lighter default for the side barriers);
-- a part tagged only TagsConfig.Board (not further specialized as Floor/Side) falls back
-- to the Floor ramp, since most plain structural board parts read closer to the floor's
-- neutral tones than the side barriers' — retag it BoardSide in Studio if that's wrong for
-- a given part.
--
-- The Zone kiosk's preview model (TagsConfig.ZonePreviewGrass / ZonePreviewFloor /
-- ZonePreviewSide) rides the same ramps but at the NEXT zone: the tier the player's next
-- MaxBet purchase unlocks (owned MaxBet tier + 1), so the kiosk shows what buying gets you
-- rather than what you already have. The preview Models also bob up and down
-- (TagsConfig.ZonePreviewBob, tagged on the whole Model so untinted parts like the dirt
-- cube and pegs ride along) — client-local PivotTo, same local-view idea as the tinting.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BoardAppearanceConfig = require(RS.Shared.Config.BoardAppearance)
local TagsConfig = require(RS.Shared.Config.Tags)
local ProfileNet = require(RS.Shared.Remote.ProfileNet)
local BoardAppearanceView = {}

-- Material is optional so the Grass ramp (color-only keyframes) shares the same lookup.
type Keyframe = { Tier: number, Color: Color3, Material: Enum.Material? }

local FLOOR: { Keyframe } = BoardAppearanceConfig.Floor
local SIDE: { Keyframe } = BoardAppearanceConfig.Side
local GRASS: { Keyframe } = BoardAppearanceConfig.Grass
local MAX_TIER: number = BoardAppearanceConfig.MaxTier

local currentTier = 0
local nextZoneTier = 1 -- owned MaxBet tier + 1: what the next Zone purchase unlocks

-- Bob juice (visual only)
local BOB_HEIGHT = 0.35 -- studs of travel each side of the authored rest position
local BOB_PERIOD = 2.6 -- seconds per full up-down cycle
local BOB_STAGGER = math.pi * 0.7 -- phase offset between preview models so they don't move in lockstep

-- Model -> its authored rest pivot + fixed phase; bobbed every Heartbeat via PivotTo.
type BobEntry = { base: CFrame, phase: number }
local bobbing: { [Model]: BobEntry } = {}
local bobCount = 0

-- part -> "Floor" | "Side" | "Grass" | "PreviewFloor" | "PreviewSide" | "PreviewGrass"
-- (Generic Board-tagged parts are stored as "Floor", their fallback; Preview* kinds paint
-- at nextZoneTier instead of currentTier).
local partKind: { [BasePart]: string } = {}

-- (color, material) for `tier` within a keyframe list (ascending Tier): Color lerps
-- linearly between the two keyframes straddling the tier; Material holds the LOWER
-- keyframe's value until the tier reaches the next one. Clamped to [0, MaxTier], so a
-- tier past the last keyframe holds that keyframe's look.
local function lookup(keyframes: { Keyframe }, tier: number): (Color3, Enum.Material?)
	tier = math.clamp(tier, 0, MAX_TIER)
	local lo = keyframes[1]
	local hi = keyframes[#keyframes]
	for _, kf in keyframes do
		if kf.Tier <= tier and kf.Tier >= lo.Tier then
			lo = kf
		end
	end
	for i = #keyframes, 1, -1 do
		local kf = keyframes[i]
		if kf.Tier >= tier then
			hi = kf
		end
	end
	if lo.Tier == hi.Tier then
		return lo.Color, lo.Material
	end
	local t = (tier - lo.Tier) / (hi.Tier - lo.Tier)
	return lo.Color:Lerp(hi.Color, t), lo.Material
end

local function paintOne(part: BasePart)
	local kind = partKind[part]
	local ramp = if kind == "Side" or kind == "PreviewSide" then SIDE
		elseif kind == "Grass" or kind == "PreviewGrass" then GRASS
		else FLOOR
	local tier = if string.sub(kind, 1, 7) == "Preview" then nextZoneTier else currentTier
	local color, material = lookup(ramp, tier)
	part.Color = color
	if material then -- Grass keyframes carry no Material: color-only, keep the authored material
		part.Material = material
	end
end

local function repaintAll()
	for part in partKind do
		paintOne(part)
	end
end

local function kindFor(inst: Instance): string?
	if not inst:IsA("BasePart") then
		return nil
	end
	if CollectionService:HasTag(inst, TagsConfig.ZonePreviewFloor) then
		return "PreviewFloor"
	elseif CollectionService:HasTag(inst, TagsConfig.ZonePreviewSide) then
		return "PreviewSide"
	elseif CollectionService:HasTag(inst, TagsConfig.ZonePreviewGrass) then
		return "PreviewGrass"
	elseif CollectionService:HasTag(inst, TagsConfig.BoardFloor) then
		return "Floor"
	elseif CollectionService:HasTag(inst, TagsConfig.BoardSide) then
		return "Side"
	elseif CollectionService:HasTag(inst, TagsConfig.Grass) then
		return "Grass"
	elseif CollectionService:HasTag(inst, TagsConfig.Board) then
		return "Floor" -- generic/unspecialized Board part: falls back to the Floor ramp
	end
	return nil
end

local function track(inst: Instance)
	local kind = kindFor(inst)
	if not kind then
		return
	end
	local part = inst :: BasePart
	partKind[part] = kind
	paintOne(part)
end

local function untrack(inst: Instance)
	partKind[inst :: any] = nil
end

-- The rest pivot is captured at discovery, so a re-streamed model (whose parts come back
-- at their authored, server-side CFrames) re-captures a correct base.
local function trackBob(inst: Instance)
	if not inst:IsA("Model") or bobbing[inst] then
		return
	end
	bobCount += 1
	bobbing[inst] = { base = inst:GetPivot(), phase = bobCount * BOB_STAGGER }
end

local function untrackBob(inst: Instance)
	bobbing[inst :: any] = nil
end

local function onHeartbeat()
	local t = os.clock() * (2 * math.pi / BOB_PERIOD)
	for model, entry in bobbing do
		model:PivotTo(entry.base + Vector3.new(0, BOB_HEIGHT * math.sin(t + entry.phase), 0))
	end
end

-- The board is shared, but tier only ever comes from the LOCAL player's own profile.
-- One repaint covers both the current-zone tier (loadout.BetTier) and the next-zone
-- preview tier (upgrades.MaxBet + 1).
local function setTierFromProfile(profile: any)
	if type(profile) ~= "table" then
		return
	end
	local changed = false
	local tier = if type(profile.loadout) == "table" then profile.loadout.BetTier else nil
	if type(tier) == "number" and tier ~= currentTier then
		currentTier = tier
		changed = true
	end
	local maxBetTier = if type(profile.upgrades) == "table" then profile.upgrades.MaxBet else nil
	if type(maxBetTier) == "number" and maxBetTier + 1 ~= nextZoneTier then
		nextZoneTier = maxBetTier + 1
		changed = true
	end
	if changed then
		repaintAll()
	end
end

function BoardAppearanceView.Init()
	for _, tag in {
		TagsConfig.Board,
		TagsConfig.BoardFloor,
		TagsConfig.BoardSide,
		TagsConfig.Grass,
		TagsConfig.ZonePreviewFloor,
		TagsConfig.ZonePreviewSide,
		TagsConfig.ZonePreviewGrass,
	} do
		for _, inst in CollectionService:GetTagged(tag) do
			track(inst)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
	end

	for _, inst in CollectionService:GetTagged(TagsConfig.ZonePreviewBob) do
		trackBob(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.ZonePreviewBob):Connect(trackBob)
	CollectionService:GetInstanceRemovedSignal(TagsConfig.ZonePreviewBob):Connect(untrackBob)
	RunService.Heartbeat:Connect(onHeartbeat)

	local getProfileRF = ProfileNet.GetProfile :: RemoteFunction
	local profileChangedRE = ProfileNet.ProfileChanged :: RemoteEvent

	profileChangedRE.OnClientEvent:Connect(setTierFromProfile)

	local ok, profile = pcall(function()
		return getProfileRF:InvokeServer()
	end)
	if ok then
		setTierFromProfile(profile)
	end
end

return BoardAppearanceView
