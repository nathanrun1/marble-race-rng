--!strict
-- Teleport pads: touching one teleports the player to the pad's "Teleport" attribute (a
-- Vector3 destination), with a SpawnLocation-style Y bump so the character lands standing
-- on the target spot instead of pivoting into the floor. The attribute is read at touch
-- time, so retargeting a pad live takes effect immediately.
--
-- Discovery — CollectionService only queries by TAG (there is no get-by-attribute API),
-- so pads are found two ways:
--   * Tagged TagsConfig.Teleport ("Teleport") — the preferred, codebase-standard combo
--     (tag = discovery, attribute = data). Works for parts tagged at any time, including
--     runtime, via GetInstanceAddedSignal.
--   * Attribute-only fallback: a BasePart (or a Model — its BaseParts are all wired,
--     reading the destination from the model) carrying the attribute at server start or
--     when it enters the workspace.
-- Wired pads are printed at startup ("[TeleportService] wired ...") — if a pad is missing
-- from that list, it wasn't discovered (add the tag, or check the attribute is a Vector3
-- on a part/model that exists at start).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local TagsConfig = require(RS.Shared.Config.Tags)

local TeleportService = {}

local TAG = TagsConfig.Teleport
local TELEPORT_ATTRIBUTE = "Teleport"
local Y_OFFSET = 4 -- studs added to the destination (≈ root-pivot height + clearance)
local DEBOUNCE_SECONDS = 1 -- per-player; Touched fires many times per step on a walk-over

local lastTeleport: { [number]: number } = {}
-- part -> the instance holding the Teleport attribute (the part itself, or its pad model).
local wired: { [BasePart]: Instance } = {}
-- Holders already warned about a missing/mistyped attribute (once, not per Touched).
local warned: { [Instance]: true } = {}

local function onTouched(holder: Instance, hit: BasePart)
	local character = hit.Parent
	if not character or not character:IsA("Model") then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	local destination = holder:GetAttribute(TELEPORT_ATTRIBUTE)
	if typeof(destination) ~= "Vector3" then
		if not warned[holder] then
			warned[holder] = true
			warn(("TeleportService: %s has no Vector3 'Teleport' attribute"):format(holder:GetFullName()))
		end
		return
	end
	local now = os.clock()
	if now - (lastTeleport[player.UserId] or 0) < DEBOUNCE_SECONDS then
		return
	end
	lastTeleport[player.UserId] = now
	-- Keep the character's facing; only the position moves.
	local target = (destination :: Vector3) + Vector3.new(0, Y_OFFSET, 0)
	character:PivotTo(CFrame.new(target) * character:GetPivot().Rotation)
end

local function wirePart(part: BasePart, holder: Instance)
	if wired[part] then
		return
	end
	wired[part] = holder
	part.Touched:Connect(function(hit: BasePart)
		onTouched(holder, hit)
	end)
	print(("[TeleportService] wired %s"):format(part:GetFullName()))
end

-- Wire a discovered pad: a BasePart directly, or every BasePart of a pad Model (the
-- destination attribute then lives on the model).
local function wire(inst: Instance)
	if inst:IsA("BasePart") then
		wirePart(inst, inst)
	elseif inst:IsA("Model") then
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				wirePart(d, inst)
			end
		end
	end
end

-- Attribute-only fallback: present at server start or when entering the workspace.
local function tryWireByAttribute(inst: Instance)
	if inst:GetAttribute(TELEPORT_ATTRIBUTE) ~= nil then
		wire(inst)
	end
end

function TeleportService.Init()
	-- Tag-driven discovery (works at any time, including tags added at runtime).
	for _, inst in CollectionService:GetTagged(TAG) do
		wire(inst)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(wire)

	for _, inst in workspace:GetDescendants() do
		tryWireByAttribute(inst)
	end
	workspace.DescendantAdded:Connect(tryWireByAttribute)

	local wiredCount = 0
	for _ in wired do
		wiredCount += 1
	end
	print(("[TeleportService] %d pad part(s) wired at startup"):format(wiredCount))

	Players.PlayerRemoving:Connect(function(player: Player)
		lastTeleport[player.UserId] = nil
	end)
end

return TeleportService
