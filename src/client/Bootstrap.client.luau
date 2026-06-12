local Players = game:GetService("Players")
local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")
local UpgradeShop = require(PlayerScripts:WaitForChild("UpgradeShop"))

UpgradeShop.Init()
