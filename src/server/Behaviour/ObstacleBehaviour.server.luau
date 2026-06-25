--!strict
-- Handles active obstacle behaviour

local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)

local HEARTBEAT_DELAY = 0.01

local toRotate: { [Instance]: Vector3 } = {}

type AlternationInfo = {
    angles: Vector3,
    initialCF: CFrame
}
local toAlternate: { [Instance]: AlternationInfo } = {}

local function getCFrame(instance: Instance)
    if instance:IsA("BasePart") then
        return instance.CFrame
    elseif instance:IsA("Model") then
        return instance:GetPivot()
    else
        assert(false, "getCFrame() not implemented for type: "..instance.ClassName)
    end
end

local function applyRotation(instance: Instance, angles: Vector3, timeDelta: number)
    local anglesScaled = angles * timeDelta
    local rotation = CFrame.Angles(math.rad(anglesScaled.X), math.rad(anglesScaled.Y), math.rad(anglesScaled.Z))
    if instance:IsA("BasePart") then
        instance.CFrame = instance.CFrame * rotation
    elseif instance:IsA("Model") then
        instance:PivotTo(instance:GetPivot() * rotation)
        for _, c in instance:GetChildren() do
            applyRotation(c, angles, timeDelta)
        end
    end
end

local function applyAlternation(instance: Instance, altInfo: AlternationInfo)
    local altSpeed: number = (instance:GetAttribute(Config.Attributes.OObstacleAlternationSpeed) or 1) :: number
    local angles = altInfo.angles * math.sin(time() * 2 * math.pi * altSpeed)
    local rot = CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))

    local newCF = altInfo.initialCF * rot
    if instance:IsA("BasePart") then
        instance.CFrame = newCF
    elseif instance:IsA("Model") then
        instance:PivotTo(newCF)
    end
end

local function applyRotations(timeDelta: number)
    for obs, angles in toRotate do
        applyRotation(obs, angles, timeDelta)
    end
end

local function applyAlternations()
    for obs, altInfo in toAlternate do
        applyAlternation(obs, altInfo)
    end
end

-- Runs every heartbeat
local function heartbeat(timeDelta: number)
    applyRotations(timeDelta)
    applyAlternations()
end

-- Run heartbeat loop
local function doHeartbeat()
    while true do
        task.wait(HEARTBEAT_DELAY)
        heartbeat(HEARTBEAT_DELAY)
    end
end

-- Initialize obstacle behaviours
local function init()
    local obstacles: {Instance} = CollectionService:GetTagged(Config.Tags.Obstacle)
    for _, o in ipairs(obstacles) do
        local rotateAttr: Vector3 = o:GetAttribute(Config.Attributes.ObstacleRotate) :: Vector3
        local altAttr: Vector3 = o:GetAttribute(Config.Attributes.ObstacleAlternation) :: Vector3

        if rotateAttr then
            toRotate[o] = rotateAttr 
        end
        if altAttr then
            toAlternate[o] = { angles = altAttr, initialCF = getCFrame(o) }
        end
    end

    doHeartbeat()   
end


init()