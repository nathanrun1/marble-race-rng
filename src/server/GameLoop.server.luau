--!strict
local SSS = game:GetService("ServerScriptService")

local ScoringService = require(SSS.Scripts.Modules.ScoringService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local BallService = require(SSS.Scripts.Modules.BallService)

local NRPLAYS_ID = 89831196

CurrencyService.Init()
ScoringService.Init()

--local NR: Player = game:GetService("Players"):FindFirstChild()

--print("Added points to NR, new count: "..CurrencyService.AddPoints(NR, 100, "cause i want some points"))

local DefaultBallPosition = Vector3.new(43.859, 190.14, 332.272)
local TestBallPos = Vector3.new(-529.103, 251.34, 261.423)

local left: number = 43.859
local right: number = -1.218


--BallService.Spawn(TestBallPos, {ownerUserId = 89831196})
--BallService.Spawn(Vector3.new(math.random(right, left), DefaultBallPosition.Y, DefaultBallPosition.Z), {ownerUserId = game.Players:FindFirstChildWhichIsA("Player").UserId })
--while true do
--	wait(1.5)
--	local ball = BallService.Spawn(Vector3.new(math.random(right, left), DefaultBallPosition.Y, DefaultBallPosition.Z), {ownerUserId = game.Players:FindFirstChildWhichIsA("Player").UserId })
--	ball:FindFirstChild("ValueUI").TextLabel.Text = math.random(1, 1000000)
--end