-- Script in ServerScriptService
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local CurrencyService = require(SSS.Modules.CurrencyService)

-- Create remote if it doesn't exist
local remote = ReplicatedStorage:FindFirstChild("LeaderboardRemote")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "LeaderboardRemote"
	remote.Parent = ReplicatedStorage
end

local REFRESH_RATE = 5
local TOP_COUNT = 5

local function getTopPlayers()
	local list = {}
	for _, player in Players:GetPlayers() do
		local coins = CurrencyService.GetPoints(player)
		table.insert(list, { name = player.Name, coins = coins, userId = player.UserId })
	end
	table.sort(list, function(a, b) return a.coins > b.coins end)
	local top = {}
	for i = 1, math.min(TOP_COUNT, #list) do
		table.insert(top, list[i])
	end
	return top
end

while true do
	task.wait(REFRESH_RATE)
	local top = getTopPlayers()
	remote:FireAllClients(top)
end