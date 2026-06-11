-- Script inside the "join" part
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local rewardStore = DataStoreService:GetDataStore("GroupRewardStore")

local GROUP_ID = 559054633
local COOLDOWN = 24 * 60 * 60 -- 24 hours in seconds
local PERCENT = 0.50 -- 50%
local part = script.Parent
local debounce = {}

local function getCoins(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		local coins = leaderstats:FindFirstChild("Coins")
		if coins then return coins end
	end
	return nil
end

local function getTimeLeft(lastClaim)
	local diff = COOLDOWN - (os.time() - lastClaim)
	if diff <= 0 then return nil end
	local hours = math.floor(diff / 3600)
	local mins = math.floor((diff % 3600) / 60)
	return string.format("%dh %dm", hours, mins)
end

part.Touched:Connect(function(hit)
	local character = hit.Parent
	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end
	if debounce[player.UserId] then return end
	debounce[player.UserId] = true

	local coinsObj = getCoins(player)
	if not coinsObj then
		debounce[player.UserId] = nil
		return
	end

	local currentCoins = coinsObj.Value
	local reward = math.floor(currentCoins * PERCENT)
	local inGroup = player:IsInGroup(GROUP_ID)

	local lastClaim = nil
	local success, data = pcall(function()
		return rewardStore:GetAsync("player_" .. player.UserId)
	end)
	if success and data then
		lastClaim = data
	end

	local timeLeft = lastClaim and getTimeLeft(lastClaim) or nil

	local remote = game:GetService("ReplicatedStorage"):FindFirstChild("GroupRewardRemote")
	if remote then
		if not inGroup then
			remote:FireClient(player, "notInGroup", currentCoins, reward, nil)
		elseif timeLeft then
			remote:FireClient(player, "onCooldown", currentCoins, reward, timeLeft)
		else
			coinsObj.Value = currentCoins + reward
			pcall(function()
				rewardStore:SetAsync("player_" .. player.UserId, os.time())
			end)
			remote:FireClient(player, "success", currentCoins + reward, reward, nil)
		end
	end

	task.wait(5)
	debounce[player.UserId] = nil
end)
