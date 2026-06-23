--!strict
-- Handles active obstacle behaviour

local RS = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RS.Shared.Config)

local HEARTBEAT_DELAY = 0.01

local toRotate: { [Instance]: Vector3 } = {}

local function applyRotation(instance: Instance, rotation)
    if instance:IsA("BasePart") then
        instance.CFrame = instance.CFrame * rotation
    elseif instance:IsA("Model") then
        instance:PivotTo(instance:GetPivot() * rotation)
        for _, c in instance:GetChildren() do
            applyRotation(c, rotation)
        end
    end
end

local function applyRotations(timeDelta: number)
    for obs, angles in toRotate do
        local anglesScaled = angles * timeDelta
        local rotateBy = CFrame.Angles(math.rad(anglesScaled.X), math.rad(anglesScaled.Y), math.rad(anglesScaled.Z))
        applyRotation(obs, rotateBy)
    end
end

-- Runs every heartbeat
local function heartbeat(timeDelta: number)
    applyRotations(timeDelta)
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
        if rotateAttr then
            toRotate[o] = rotateAttr 
        end
    end

    doHeartbeat()   
end


init()