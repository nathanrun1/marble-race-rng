-- LocalScript in StarterPlayerScripts
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

local remote = ReplicatedStorage:WaitForChild("LeaderboardRemote")

local medals = { "🥇", "🥈", "🥉", "4️⃣", "5️⃣" }

local function formatNumber(n)
	local s = tostring(math.floor(n))
	local result = ""
	local count = 0
	for i = #s, 1, -1 do
		if count > 0 and count % 3 == 0 then result = "," .. result end
		result = s:sub(i, i) .. result
		count += 1
	end
	return result
end

local function findDescendant(parent, name)
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then return child end
		local found = findDescendant(child, name)
		if found then return found end
	end
	return nil
end

-- ───── PHYSICAL BOARD ─────
local function updatePhysicalBoard(data)
	local board = findDescendant(workspace, "CoinLeaderboard")
	if not board then return end

	local surfaceGui = board:FindFirstChildOfClass("SurfaceGui")
	if not surfaceGui then return end

	for i = 1, 5 do
		local label = surfaceGui:FindFirstChild("Rank" .. i)
		if label then
			local entry = data[i]
			if entry then
				label.Text = medals[i] .. " " .. entry.name .. "  |  " .. formatNumber(entry.coins)
			else
				label.Text = medals[i] .. " ---"
			end
		end
	end
end

remote.OnClientEvent:Connect(function(data)
	updatePhysicalBoard(data)
end)