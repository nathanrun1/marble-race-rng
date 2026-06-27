--!strict
-- Client-built rebirths podium. The server only tells us the top 3 (PodiumTop / GetPodiumTop);
-- each client builds its own avatar statues from the marker rigs and dances them locally. This
-- has to be client-side: a KeyframeSequence dance is driven by writing Motor6D joints, which
-- only works on a rig this peer OWNS — a server-built NPC's pose just gets overwritten by
-- replication. Since every client does this, everyone sees the statues dancing.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.Config)
local AnimationService = require(RS.Shared:WaitForChild("AnimationService"))

local PodiumStatues = {}

local GOLD_SEQ = ColorSequence.new(Color3.fromRGB(254, 256, 107), Color3.fromRGB(187, 170, 56))
local SILV_SEQ = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(162, 183, 190))
local BRNZ_SEQ = ColorSequence.new(Color3.fromRGB(242, 191, 130), Color3.fromRGB(190, 143, 70))

local ANIM_BY_SLOT = {
	Config.Podium.Animations.First,
	Config.Podium.Animations.Second,
	Config.Podium.Animations.Third,
}

type Slot = {
	cframe: CFrame,
	footY: number,
	scale: number,
	animationName: string,
	nameTemplate: BillboardGui?,
	usernameColor: Color3,
	userId: number?,             -- who's currently shown (skip rebuild if unchanged)
	model: Model?,
	anim: AnimationService.Handle?,
}

local podium: Instance
local slots: { Slot } = {}

local function gradientFor(slot: number): ColorSequence
	if slot == 1 then
		return GOLD_SEQ
	elseif slot == 2 then
		return SILV_SEQ
	end
	return BRNZ_SEQ
end

-- Capture each marker rig's transform + Username billboard (the markers are just reference
-- points now), then hide the marker locally so it doesn't show under the built statue.
local function captureMarkers()
	-- Match the statue username's text colour to the board's Item template (best-effort).
	local usernameColor = Color3.new(1, 1, 1)
	pcall(function()
		local item = podium.Parent.FramePart.SurfaceGui.ScrollingFrame.Item
		usernameColor = (item.Username :: TextLabel).TextColor3
	end)

	for slot, rigName in { "FirstRig", "SecondRig", "ThirdRig" } do
		local rig = podium:WaitForChild(rigName)
		local nameTemplate: BillboardGui? = nil
		local existing = rig:FindFirstChild("Username", true)
		if existing and existing:IsA("BillboardGui") then
			nameTemplate = existing:Clone()
		end
		local bbCF, bbSize = (rig :: Model):GetBoundingBox()
		slots[slot] = {
			cframe = (rig :: PVInstance):GetPivot(),
			footY = bbCF.Position.Y - bbSize.Y / 2,
			scale = if rig:IsA("Model") then rig:GetScale() else 1,
			animationName = ANIM_BY_SLOT[slot] or "",
			nameTemplate = nameTemplate,
			usernameColor = usernameColor,
		}
		-- Hide the marker locally (cosmetic; the server keeps it as our transform reference).
		for _, d in rig:GetDescendants() do
			if d:IsA("BasePart") then
				d.Transparency = 1
				d.CanCollide = false
			elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
				d.Enabled = false
			end
		end
	end
end

local function styleNameGui(gui: BillboardGui, slot: number, name: string)
	local label = gui:FindFirstChild("TextLabel")
	if not (label and label:IsA("TextLabel")) then
		return
	end
	label.Text = name
	label.TextColor3 = slots[slot].usernameColor
	local grad = label:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = gradientFor(slot)
	end
end

local function clearSlot(slot: number)
	local s = slots[slot]
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

-- Build the player's avatar, pose/scale it onto the slot, dress its name, dance it. Yields
-- (CreateHumanoidModelFromUserId), so it's spawned; userId is claimed before the yield.
local function buildStatue(slot: number, userId: number, name: string)
	local s = slots[slot]

	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromUserId(userId)
	end)
	if not ok or not model then
		warn(("PodiumStatues: CreateHumanoidModelFromUserId failed for %d: %s"):format(userId, tostring(model)))
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
		local gui = s.nameTemplate:Clone()
		gui.Enabled = true
		styleNameGui(gui, slot, name)
		gui.Parent = hrp or model
	end

	model.Parent = podium -- client-local instance; other clients build their own

	local handle: AnimationService.Handle? = nil
	if s.animationName ~= "" then
		handle = AnimationService.Play(model, s.animationName, { looped = true })
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

local function applyTop(top: { { userId: number, name: string } }?)
	for slot = 1, 3 do
		local entry = top and top[slot]
		local s = slots[slot]
		if not entry then
			clearSlot(slot)
		elseif s.userId ~= entry.userId then
			s.userId = entry.userId -- claim before the async build
			task.spawn(buildStatue, slot, entry.userId, entry.name)
		end
	end
end

function PodiumStatues.Init()
	local board = workspace:WaitForChild("Leaderboards"):WaitForChild("Rebirths")
	podium = board:WaitForChild("Podium")
	captureMarkers()

	local remote = RS.Remote:WaitForChild("PodiumTop") :: RemoteEvent
	local getTop = RS.Remote:WaitForChild("GetPodiumTop") :: RemoteFunction
	remote.OnClientEvent:Connect(applyTop)
	-- Fetch the current standing (we may have joined after the last broadcast).
	task.spawn(function()
		applyTop(getTop:InvokeServer())
	end)
end

return PodiumStatues
