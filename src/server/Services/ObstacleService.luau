--!strict
-- Active obstacle behaviour: rotates/alternates every TagsConfig.Obstacle instance per its
-- ObstacleRotate / ObstacleAlternation attributes.

local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local AttributesConfig = require(RS.Shared.Config.Attributes)
local TagsConfig = require(RS.Shared.Config.Tags)

local ObstacleService = {}

local HEARTBEAT_DELAY = 0.01
-- Guard against a huge single rotation jump (e.g. the very first tick, or a lag spike) — dt is
-- clamped to this before being applied, since a stray huge dt would otherwise snap the obstacle
-- to a wildly different angle in one frame instead of smoothly catching up.
local MAX_DT = 0.25

-- Rotation speed, degrees/second per axis. Composed incrementally each tick — dt is the REAL
-- elapsed time between ticks, measured via os.clock() (task.wait(0.01) never delivers exactly
-- 0.01, so a fixed constant would silently skew the true rotation rate).
local toRotate: { [Instance]: Vector3 } = {}

type AlternationInfo = {
	angles: Vector3,
	initialCF: CFrame,
}
local toAlternate: { [Instance]: AlternationInfo } = {}

-- Non-asserting: Init() runs this over every TagsConfig.Obstacle instance in the whole game in
-- one loop, so throwing on an unsupported type would abort Init() before the heartbeat loop ever
-- runs — silently killing rotation/alternation for every obstacle in the game, not just the
-- offending one.
local function tryGetCFrame(instance: Instance): CFrame?
	if instance:IsA("BasePart") then
		return instance.CFrame
	elseif instance:IsA("Model") then
		return instance:GetPivot()
	end
	return nil
end

local function applyRotation(instance: Instance, angles: Vector3, dt: number)
	local anglesScaled = angles * dt
	local rotation = CFrame.Angles(math.rad(anglesScaled.X), math.rad(anglesScaled.Y), math.rad(anglesScaled.Z))
	if instance:IsA("BasePart") then
		instance.CFrame = instance.CFrame * rotation
	elseif instance:IsA("Model") then
		instance:PivotTo(instance:GetPivot() * rotation)
		for _, c in instance:GetChildren() do
			applyRotation(c, angles, dt)
		end
	end
end

local function applyAlternation(instance: Instance, altInfo: AlternationInfo)
	local altSpeed: number = (instance:GetAttribute(AttributesConfig.OObstacleAlternationSpeed) or 1) :: number
	local angles = altInfo.angles * math.sin(time() * 2 * math.pi * altSpeed)
	local rot = CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))

	local newCF = altInfo.initialCF * rot
	if instance:IsA("BasePart") then
		instance.CFrame = newCF
	elseif instance:IsA("Model") then
		instance:PivotTo(newCF)
	end
end

-- pcall-wrapped: this runs every ~0.01s for every tracked obstacle in one loop with no yields
-- in between, so an uncaught error from ANY single entry (e.g. one that got Destroyed elsewhere
-- in the game while still tracked here) would otherwise kill the whole heartbeat loop
-- permanently on that tick — silently stopping rotation/alternation for every obstacle forever,
-- not just the offending one. warn() surfaces the failure instead of eating it silently.
local function applyRotations(dt: number)
	for obs, angles in toRotate do
		local ok, err = pcall(applyRotation, obs, angles, dt)
		if not ok then
			warn(("ObstacleService: rotation failed for %s: %s"):format(obs:GetFullName(), tostring(err)))
		end
	end
end

local function applyAlternations()
	for obs, altInfo in toAlternate do
		local ok, err = pcall(applyAlternation, obs, altInfo)
		if not ok then
			warn(("ObstacleService: alternation failed for %s: %s"):format(obs:GetFullName(), tostring(err)))
		end
	end
end

local lastTime = os.clock()
local function heartbeat()
	local now = os.clock()
	local dt = math.min(now - lastTime, MAX_DT)
	lastTime = now
	applyRotations(dt)
	applyAlternations()
end

-- Gather the tagged obstacles and their behaviour attributes.
function ObstacleService.Init()
	local obstacles: { Instance } = CollectionService:GetTagged(TagsConfig.Obstacle)
	for _, o in ipairs(obstacles) do
		local rotateAttr: Vector3 = o:GetAttribute(AttributesConfig.ObstacleRotate) :: Vector3
		local altAttr: Vector3 = o:GetAttribute(AttributesConfig.ObstacleAlternation) :: Vector3

		if rotateAttr then
			toRotate[o] = rotateAttr
		end
		if altAttr then
			local cf = tryGetCFrame(o)
			if cf then
				toAlternate[o] = { angles = altAttr, initialCF = cf }
			else
				warn(("ObstacleService: %s is tagged %s with an ObstacleAlternation attribute but isn't a BasePart/Model (%s) — skipping")
					:format(o:GetFullName(), TagsConfig.Obstacle, o.ClassName))
			end
		end
	end
end

-- The tick loop never returns; the bootstrap spawns Start.
function ObstacleService.Start()
	while true do
		task.wait(HEARTBEAT_DELAY)
		heartbeat()
	end
end

return ObstacleService
