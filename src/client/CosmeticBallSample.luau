--!strict
-- Floating sample ball for the cosmetics shop. Above the part tagged Config.Tags.CosmeticBallSample
-- it shows an appearance-only ball wearing the player's currently-SELECTED cosmetic (the one
-- highlighted in CosmeticsShop), bobbing up and down and slowly spinning. Appearance is applied
-- through BallEffects.ApplyAppearance — the same path the ball-tuning preview uses.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)
local BallEffects = require(RS.Shared.BallEffects)
local BallSkins = require(RS.Shared.BallSkins)

local CosmeticBallSample = {}

local HEIGHT     = 4.0  -- studs the ball floats above the sample part's centre
local BOB_AMP    = 0.5  -- bob height
local BOB_SPEED  = 1.6  -- bob cycles/sec (×2π)
local SPIN_SPEED = 1.2  -- radians/sec
local SHOWCASE_INTERVAL = 3.0 -- seconds between bounce-burst showcases on the sample ball

local samplePart: BasePart? = nil
local sampleBall: BasePart? = nil
local selectedSkinId = BallSkins.GetDefaultId()
local clock = 0
local nextBurst = SHOWCASE_INTERVAL

local function applySkin()
	if sampleBall then
		BallEffects.ApplyAppearance(sampleBall, { skinId = selectedSkinId, heat = 0 })
	end
end

local function ensureBall()
	if sampleBall or not samplePart then
		return
	end
	local ball = (Config.Templates.Ball :: BasePart):Clone()
	ball.Name = "CosmeticSampleBall"
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball:RemoveTag(Config.Tags.Ball) -- appearance only; never a real (scored/hideable) ball
	ball.Parent = workspace
	sampleBall = ball
	applySkin()
end

local function onStep(dt: number)
	clock += dt
	local part, ball = samplePart, sampleBall
	if not (part and ball) then
		return
	end
	local bob = math.sin(clock * BOB_SPEED * math.pi * 2) * BOB_AMP
	local pos = part.Position + Vector3.new(0, HEIGHT + bob, 0)
	ball.CFrame = CFrame.new(pos) * CFrame.Angles(0, clock * SPIN_SPEED, 0)
	BallEffects.UpdateOrbits(ball) -- animate the skin's orbiting parts around the sample

	-- Showcase the skin's bounce burst periodically (no-op if the skin has no bounce effect set).
	if clock >= nextBurst then
		nextBurst = clock + SHOWCASE_INTERVAL
		BallEffects.EmitBounce(ball)
	end
end

function CosmeticBallSample.Init()
	local function setPart(inst: Instance)
		if inst:IsA("BasePart") and not samplePart then
			samplePart = inst
			ensureBall()
		end
	end
	for _, inst in CollectionService:GetTagged(Config.Tags.CosmeticBallSample) do
		setPart(inst)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CosmeticBallSample):Connect(setPart)

	-- Track the selected cosmetic (CosmeticsShop selection drives this).
	local changedRE = RS.Remote:WaitForChild("CosmeticChanged") :: RemoteEvent
	changedRE.OnClientEvent:Connect(function(info: any)
		if info and type(info.selected) == "string" then
			selectedSkinId = info.selected
			applySkin()
		end
	end)
	local getInfo = RS.Remote:FindFirstChild("GetCosmeticInfo")
	if getInfo and getInfo:IsA("RemoteFunction") then
		local info = getInfo:InvokeServer()
		if info and type(info.selected) == "string" then
			selectedSkinId = info.selected
			applySkin()
		end
	end

	RunService.RenderStepped:Connect(onStep)
end

return CosmeticBallSample
