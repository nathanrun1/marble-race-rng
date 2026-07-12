--!strict
-- Loadout display: above each loadout-slot Model's "Platform" child (Config.Tags.Slot, attribute
-- "SlotNum" = which loadout slot it represents), floats a sample ball wearing whatever skin is
-- actually equipped in that slot — same bobbing/spinning/real-appearance treatment as
-- CosmeticBallSample, just per-slot instead of a single "selected" skin. An empty slot shows no
-- ball. Driven by LoadoutService's GetLoadoutInfo/LoadoutChanged (not CosmeticService — the
-- loadout is a separate system from the single visual-equipped skin).

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)
local BallEffects = require(RS.Shared.BallEffects)

local LoadoutDisplay = {}

local HEIGHT = 3.5   -- studs the ball floats above its Platform
local BOB_AMP = 0.4
local BOB_SPEED = 1.4
local SPIN_SPEED = 1.0
local SHOWCASE_INTERVAL = 3.0 -- seconds between bounce-burst showcases, same as CosmeticBallSample

type Rig = {
	platform: BasePart,
	ball: BasePart?,
	nextBurst: number,
}

local rigsBySlot: { [number]: Rig } = {}
local clock = 0

local function ensureBall(rig: Rig): BasePart
	if rig.ball then
		return rig.ball
	end
	local ball = (Config.Templates.Ball :: BasePart):Clone()
	ball.Name = "LoadoutSampleBall"
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball:RemoveTag(Config.Tags.Ball) -- appearance only; never a real (scored/hideable) ball
	ball.Parent = workspace
	rig.ball = ball
	return ball
end

local function applySlot(rig: Rig, skinId: string?)
	if not skinId then
		if rig.ball then
			rig.ball:Destroy()
			rig.ball = nil
		end
		return
	end
	local ball = ensureBall(rig)
	BallEffects.ApplyAppearance(ball, { skinId = skinId, heat = 0 })
end

local function setup(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local slotNum = inst:GetAttribute("SlotNum")
	if type(slotNum) ~= "number" then
		return
	end
	local platform = inst:FindFirstChild("Platform")
	if not (platform and platform:IsA("BasePart")) then
		return
	end
	rigsBySlot[slotNum] = { platform = platform, ball = nil, nextBurst = SHOWCASE_INTERVAL }
end

local function onStep(dt: number)
	clock += dt
	for _, rig in rigsBySlot do
		local ball = rig.ball
		if ball then
			local bob = math.sin(clock * BOB_SPEED * math.pi * 2) * BOB_AMP
			local pos = rig.platform.Position + Vector3.new(0, HEIGHT + bob, 0)
			ball.CFrame = CFrame.new(pos) * CFrame.Angles(0, clock * SPIN_SPEED, 0)
			BallEffects.UpdateOrbits(ball)
			if clock >= rig.nextBurst then
				rig.nextBurst = clock + SHOWCASE_INTERVAL
				BallEffects.EmitBounce(ball)
			end
		end
	end
end

local function onLoadoutInfo(info: any)
	if type(info) ~= "table" or type(info.loadout) ~= "table" then
		return
	end
	for slotNum, rig in rigsBySlot do
		applySlot(rig, info.loadout[tostring(slotNum)])
	end
end

function LoadoutDisplay.Init()
	for _, inst in CollectionService:GetTagged(Config.Tags.Slot) do
		setup(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.Slot):Connect(setup)

	local remote = RS:WaitForChild("Remote")
	local changedRE = remote:WaitForChild("LoadoutChanged") :: RemoteEvent
	changedRE.OnClientEvent:Connect(onLoadoutInfo)
	local getInfoRF = remote:WaitForChild("GetLoadoutInfo") :: RemoteFunction
	task.spawn(function()
		local ok, info = pcall(function()
			return getInfoRF:InvokeServer()
		end)
		if ok then
			onLoadoutInfo(info)
		end
	end)

	RunService.RenderStepped:Connect(onStep)
end

return LoadoutDisplay
