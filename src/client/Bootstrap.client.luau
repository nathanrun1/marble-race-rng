local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")

local UpgradeShop = require(PlayerScripts:WaitForChild("UpgradeShop"))
local BallEffects = require(RS.Shared:WaitForChild("BallEffects"))
local ScoreUI = require(RS.Shared:WaitForChild("ScoreUI"))
local BallTuningUI = require(PlayerScripts:WaitForChild("BallTuningUI"))
local BallLaunchUI = require(PlayerScripts:WaitForChild("BallLaunchUI"))

UpgradeShop.Init()
BallEffects.Init()
ScoreUI.Init()
BallTuningUI.init()
BallLaunchUI.Init()