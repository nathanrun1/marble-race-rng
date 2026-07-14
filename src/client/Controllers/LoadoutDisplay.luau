--!strict
-- Loadout display: above each loadout-slot Model's "Platform" child (TagsConfig.Slot, attribute
-- "SlotNum" = which loadout slot it represents), floats a sample ball wearing whatever skin is
-- actually equipped in that slot — same bobbing/spinning/real-appearance treatment as
-- CosmeticBallSample, just per-slot instead of a single "selected" skin. An empty slot shows no
-- ball. Driven by LoadoutService's GetLoadoutInfo/LoadoutChanged (not CosmeticService — the
-- loadout is a separate system from the single visual-equipped skin).

local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local BallConfig = require(RS.Shared.Config.Ball)
local TagsConfig = require(RS.Shared.Config.Tags)
local BallEffects = require(RS.Shared.BallEffects)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)

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
	nameRow: TextLabel?, -- billboard top row: skin name (rarity-coloured)
	multRow: TextLabel?, -- billboard bottom row: bet multiplier "N×" (rarity-coloured)
}

local rigsBySlot: { [number]: Rig } = {}
local clock = 0

-- Two-row readout on the sample ball — skin name / bet multiplier ("N×"), both in the
-- skin's rarity colour. Same style family as FreeRollBallSample's roll billboard:
-- STUD-sized (Scale) + TextScaled FredokaOne rows with a vertical shading gradient,
-- WORLD-space offset, AlwaysOnTop (which is also what puts it visually in FRONT of the
-- ball). Sits slightly BELOW the ball's centre so it doesn't cover the skin itself.
local function makeBillboard(ball: BasePart): (TextLabel, TextLabel)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "LoadoutSkinBillboard"
	billboard.Adornee = ball
	billboard.Size = UDim2.fromScale(8, 2.2)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, -1.1, 0) -- slightly below centre
	billboard.MaxDistance = 120
	billboard.AlwaysOnTop = true
	billboard.Parent = ball

	local function makeRow(name: string, yScale: number, heightScale: number): TextLabel
		local row = Instance.new("TextLabel")
		row.Name = name
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, heightScale, 0)
		row.Position = UDim2.fromScale(0, yScale)
		row.Font = Enum.Font.FredokaOne
		row.TextScaled = true
		row.TextColor3 = Color3.new(1, 1, 1)
		row.TextStrokeColor3 = Color3.new(0, 0, 0)
		row.TextStrokeTransparency = 0.3
		row.Text = ""
		row.Parent = billboard
		-- Vertical shading, same as the roll billboard: multiplies TextColor3, so the
		-- rows keep their rarity hue.
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 150, 150))
		gradient.Parent = row
		return row
	end
	return makeRow("SkinName", 0, 0.5), makeRow("Mult", 0.5, 0.5)
end

local function ensureBall(rig: Rig): BasePart
	if rig.ball then
		return rig.ball
	end
	local ball = (BallConfig.Prefab :: BasePart):Clone()
	ball.Name = "LoadoutSampleBall"
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball:RemoveTag(TagsConfig.Ball) -- appearance only; never a real (scored/hideable) ball
	ball.Parent = workspace
	local nameRow, multRow = makeBillboard(ball)
	rig.ball = ball
	rig.nameRow = nameRow
	rig.multRow = multRow
	return ball
end

local function applySlot(rig: Rig, skinId: string?)
	if not skinId then
		if rig.ball then
			rig.ball:Destroy() -- the billboard rows are its children and die with it
			rig.ball = nil
			rig.nameRow = nil
			rig.multRow = nil
		end
		return
	end
	local ball = ensureBall(rig)
	BallEffects.ApplyAppearance(ball, { skinId = skinId, heat = 0 })
	local skin = BallSkins.Get(skinId)
	local rarity = if skin then skin.rarity else 1
	local color = BallSkins.RarityColor(rarity)
	if rig.nameRow then
		rig.nameRow.Text = if skin then skin.name else skinId
		rig.nameRow.TextColor3 = color
	end
	if rig.multRow then
		rig.multRow.Text = StringUtils.FormatShort(CosmeticBonus.RarityBetMult(rarity)) .. "×"
		rig.multRow.TextColor3 = color
	end
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
	rigsBySlot[slotNum] = { platform = platform, ball = nil, nextBurst = SHOWCASE_INTERVAL, nameRow = nil, multRow = nil }
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
	for _, inst in CollectionService:GetTagged(TagsConfig.Slot) do
		setup(inst)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.Slot):Connect(setup)

	local changedRE = LoadoutNet.LoadoutChanged :: RemoteEvent
	changedRE.OnClientEvent:Connect(onLoadoutInfo)
	local getInfoRF = LoadoutNet.GetLoadoutInfo :: RemoteFunction
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
