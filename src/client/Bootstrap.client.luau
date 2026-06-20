local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local PlayerScripts = player:WaitForChild("PlayerScripts")

local UpgradeShop = require(PlayerScripts:WaitForChild("UpgradeShop"))
local BallEffects = require(RS.Shared:WaitForChild("BallEffects"))
local ScoreUI = require(RS.Shared:WaitForChild("ScoreUI"))
local SoundService = require(RS.Shared:WaitForChild("SoundService"))
local BallTuningUI = require(PlayerScripts:WaitForChild("BallTuningUI"))
local BallLaunchUI = require(PlayerScripts:WaitForChild("BallLaunchUI"))
local PrestigeUI = require(PlayerScripts:WaitForChild("PrestigeUI"))
local AutoScale = require(RS.Shared:WaitForChild("AutoScale"))

UpgradeShop.Init()
BallEffects.Init()
ScoreUI.Init()
SoundService.Init()
BallTuningUI.init()
BallLaunchUI.Init()
PrestigeUI.Init()
AutoScale.Init()