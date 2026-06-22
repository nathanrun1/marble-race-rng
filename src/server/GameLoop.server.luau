--!strict
local SSS = game:GetService("ServerScriptService")

local ScoringService = require(SSS.Scripts.Modules.ScoringService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local BallService = require(SSS.Scripts.Modules.BallService)

local NRPLAYS_ID = 89831196

CurrencyService.Init()
ScoringService.Init()

local DefaultBallPosition = Vector3.new(43.859, 190.14, 332.272)
local TestBallPos = Vector3.new(-529.103, 251.34, 261.423)

local left: number = 43.859
local right: number = -1.218
