--!strict
-- Auto board-view trigger. Any part tagged Config.Tags.CameraZone is a volume: while the
-- local player's character stands inside it, the board camera (CameraService board view) is
-- on; stepping out hands the camera back. This makes the good vantage point discoverable —
-- you just walk into the play area instead of hunting for the camera toggle.
--
-- Detection is a per-frame oriented-box containment test on the HumanoidRootPart (robust to
-- rotated zones and respawns), and we only push a state change on the IN/OUT transition — so
-- the manual camera toggle (MiscUI) still works and isn't fought every frame.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)
local CameraService = require(script.Parent.CameraService)

local CameraZone = {}

local player = Players.LocalPlayer
local root: BasePart? = nil
local lastInside = false

local function zones(): { Instance }
	return CollectionService:GetTagged(Config.Tags.CameraZone)
end

-- A camera zone is a pure trigger: never visible, never blocks the player.
local function makeTrigger(inst: Instance)
	if inst:IsA("BasePart") then
		inst.CanCollide = false
		inst.Transparency = 1
	end
end

-- Is `pos` inside the part's oriented bounding box?
local function inBox(part: BasePart, pos: Vector3): boolean
	local lp = part.CFrame:PointToObjectSpace(pos)
	local h = part.Size * 0.5
	return math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z
end

local function isInsideAnyZone(): boolean
	if not root then
		return false
	end
	local pos = root.Position
	for _, zone in zones() do
		if zone:IsA("BasePart") and inBox(zone, pos) then
			return true
		end
	end
	return false
end

local function onCharacter(character: Model)
	root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	-- Force re-evaluation next frame: a respawn resets CameraService's board view (it drops
	-- view state on a CurrentCamera swap), so if we spawn inside a zone we must re-assert it.
	lastInside = false
end

function CameraZone.Init()
	for _, inst in zones() do
		makeTrigger(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CameraZone):Connect(makeTrigger)

	if player.Character then
		onCharacter(player.Character)
	end
	player.CharacterAdded:Connect(onCharacter)

	RunService.Heartbeat:Connect(function()
		local inside = isInsideAnyZone()
		if inside ~= lastInside then
			lastInside = inside
			CameraService.SetBoardView(inside)
		end
	end)
end

return CameraZone
