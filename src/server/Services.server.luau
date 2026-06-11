local SSS = game:GetService('ServerScriptService')

local ScoringService = require(SSS.Modules.ScoringService)
local CurrencyService = require(SSS.Modules.CurrencyService)
local BallService = require(SSS.Modules.BallService)
local BallLaunchService = require(SSS.Modules.BallLaunchService)

ScoringService.Init()
CurrencyService.Init()
BallService.Init()
BallLaunchService.Init()
