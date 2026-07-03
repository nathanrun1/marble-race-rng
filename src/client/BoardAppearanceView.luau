--!strict
-- Board look scales with the LOCAL player's current bet tier (Config.BoardAppearance) —
-- the physical board is shared, but each client repaints it to reflect ITS OWN viewer's
-- bet size, same "local view of shared state" pattern as GoldenPegView (per-player peg
-- recolor) and BoardMultiplierView (per-player label rewrite).
--
-- Three tags feed this: Config.Tags.BoardFloor / BoardSide pick a part's specific ramp
-- (darker default for the floor marbles roll on, lighter default for the side barriers);
-- a part tagged only Config.Tags.Board (not further specialized as Floor/Side) falls back
-- to the Floor ramp, since most plain structural board parts read closer to the floor's
-- neutral tones than the side barriers' — retag it BoardSide in Studio if that's wrong for
-- a given part.

local CollectionService = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)

local BoardAppearanceView = {}

type Keyframe = { Tier: number, Color: Color3, Material: Enum.Material }

local FLOOR: { Keyframe } = Config.BoardAppearance.Floor
local SIDE: { Keyframe } = Config.BoardAppearance.Side
local MAX_TIER: number = Config.BoardAppearance.MaxTier

local currentTier = 0

-- part -> "Floor" | "Side" (Generic-tagged parts are stored as "Floor", their fallback).
local partKind: { [BasePart]: string } = {}

-- (color, material) for `tier` within a keyframe list (ascending Tier): Color lerps
-- linearly between the two keyframes straddling the tier; Material holds the LOWER
-- keyframe's value until the tier reaches the next one. Clamped to [0, MaxTier], so a
-- tier past the last keyframe holds that keyframe's look.
local function lookup(keyframes: { Keyframe }, tier: number): (Color3, Enum.Material)
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
	local ramp = if partKind[part] == "Side" then SIDE else FLOOR
	local color, material = lookup(ramp, currentTier)
	part.Color = color
	part.Material = material
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
	if CollectionService:HasTag(inst, Config.Tags.BoardFloor) then
		return "Floor"
	elseif CollectionService:HasTag(inst, Config.Tags.BoardSide) then
		return "Side"
	elseif CollectionService:HasTag(inst, Config.Tags.Board) then
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

-- The board is shared, but tier only ever comes from the LOCAL player's own profile.
local function setTierFromProfile(profile: any)
	local tier = if type(profile) == "table" and type(profile.loadout) == "table"
		then profile.loadout.BetTier
		else nil
	if type(tier) == "number" and tier ~= currentTier then
		currentTier = tier
		repaintAll()
	end
end

function BoardAppearanceView.Init()
	for _, tag in { Config.Tags.Board, Config.Tags.BoardFloor, Config.Tags.BoardSide } do
		for _, inst in CollectionService:GetTagged(tag) do
			track(inst)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
	end

	local Remote = RS:WaitForChild("Remote")
	local getProfileRF = Remote:WaitForChild("GetProfile") :: RemoteFunction
	local profileChangedRE = Remote:WaitForChild("ProfileChanged") :: RemoteEvent

	profileChangedRE.OnClientEvent:Connect(setTierFromProfile)

	local ok, profile = pcall(function()
		return getProfileRF:InvokeServer()
	end)
	if ok then
		setTierFromProfile(profile)
	end
end

return BoardAppearanceView
