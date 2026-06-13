-- Script inside ServerScriptService
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = Instance.new("RemoteEvent")
remote.Name = "GroupRewardRemote"
remote.Parent = ReplicatedStorage
