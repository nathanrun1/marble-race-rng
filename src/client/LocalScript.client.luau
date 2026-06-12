-- LocalScript inside StarterPlayerScripts
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player.PlayerGui

local remote = ReplicatedStorage:WaitForChild("GroupRewardRemote")

local function formatNumber(n)
	local s = tostring(math.floor(n))
	local result = ""
	local count = 0
	for i = #s, 1, -1 do
		if count > 0 and count % 3 == 0 then
			result = "," .. result
		end
		result = s:sub(i, i) .. result
		count += 1
	end
	return result
end

local function updateSign(coins)
	local dailyRewards = workspace:FindFirstChild("Daily Rewards")
	if not dailyRewards then return end
	local model = dailyRewards:FindFirstChild("Model")
	if not model then return end
	local screen = model:FindFirstChild("Screen")
	if not screen then return end
	local gui = screen:FindFirstChildOfClass("SurfaceGui")
	if not gui then return end
	local label = gui:FindFirstChild("CoinsLabel")
	if not label then return end
	label.Text = "You can claim: " .. formatNumber(math.floor(coins * 0.50)) .. " Coins"
end

-- Try to update sign using BalanceChanged remote
local balanceChanged = ReplicatedStorage:FindFirstChild("Remote") and ReplicatedStorage.Remote:FindFirstChild("BalanceChanged")
if balanceChanged then
	balanceChanged.OnClientEvent:Connect(function(newBalance)
		updateSign(newBalance)
	end)
end

-- Fallback: watch leaderstats directly
task.spawn(function()
	task.wait(3)
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		for _, stat in pairs(leaderstats:GetChildren()) do
			updateSign(stat.Value)
			stat.Changed:Connect(function(val)
				updateSign(val)
			end)
			break
		end
	end
end)

local function showPopup(status, totalCoins, reward, timeLeft)
	if playerGui:FindFirstChild("RewardPopup") then
		playerGui.RewardPopup:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RewardPopup"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, 600, 0, 340)
	frame.Position = UDim2.new(0.5, -300, 0.5, -170)
	frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 105, 180)
	stroke.Thickness = 4
	stroke.Parent = frame

	local banner = Instance.new("Frame")
	banner.Size = UDim2.new(1, 0, 0.25, 0)
	banner.Position = UDim2.new(0, 0, 0, 0)
	banner.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
	banner.BorderSizePixel = 0
	banner.Parent = frame

	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0, 16)
	bannerCorner.Parent = banner

	local bannerFix = Instance.new("Frame")
	bannerFix.Size = UDim2.new(1, 0, 0.5, 0)
	bannerFix.Position = UDim2.new(0, 0, 0.5, 0)
	bannerFix.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
	bannerFix.BorderSizePixel = 0
	bannerFix.Parent = banner

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 1, 0)
	title.BackgroundTransparency = 1
	title.Text = "Daily Group Reward"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextScaled = true
	title.Font = Enum.Font.GothamBold
	title.Parent = banner

	local line1 = Instance.new("TextLabel")
	line1.Size = UDim2.new(0.9, 0, 0.18, 0)
	line1.Position = UDim2.new(0.05, 0, 0.28, 0)
	line1.BackgroundTransparency = 1
	line1.TextScaled = true
	line1.Font = Enum.Font.GothamBold
	line1.TextWrapped = true
	line1.Parent = frame

	local line2 = Instance.new("TextLabel")
	line2.Size = UDim2.new(0.9, 0, 0.15, 0)
	line2.Position = UDim2.new(0.05, 0, 0.48, 0)
	line2.BackgroundTransparency = 1
	line2.TextScaled = true
	line2.Font = Enum.Font.Gotham
	line2.TextWrapped = true
	line2.Parent = frame

	local line3 = Instance.new("TextLabel")
	line3.Size = UDim2.new(0.9, 0, 0.13, 0)
	line3.Position = UDim2.new(0.05, 0, 0.63, 0)
	line3.BackgroundTransparency = 1
	line3.TextScaled = true
	line3.Font = Enum.Font.Gotham
	line3.TextWrapped = true
	line3.Parent = frame

	if status == "success" then
		line1.Text = "🎉 You claimed your daily reward!"
		line1.TextColor3 = Color3.fromRGB(255, 105, 180)
		line2.Text = "+ " .. formatNumber(reward) .. " Coins added! (50%)"
		line2.TextColor3 = Color3.fromRGB(50, 180, 50)
		line3.Text = "Total Coins: " .. formatNumber(totalCoins)
		line3.TextColor3 = Color3.fromRGB(80, 80, 80)
	elseif status == "onCooldown" then
		line1.Text = "⏳ Already claimed today!"
		line1.TextColor3 = Color3.fromRGB(255, 105, 180)
		line2.Text = "Come back in: " .. timeLeft
		line2.TextColor3 = Color3.fromRGB(200, 100, 0)
		line3.Text = "Total Coins: " .. formatNumber(totalCoins)
		line3.TextColor3 = Color3.fromRGB(80, 80, 80)
	elseif status == "notInGroup" then
		line1.Text = "❌ You are not in the group!"
		line1.TextColor3 = Color3.fromRGB(220, 50, 50)
		line2.Text = "Join X. Studio's to claim 50% of your coins every 24 hours!"
		line2.TextColor3 = Color3.fromRGB(80, 80, 80)
		line3.Text = "Your Coins: " .. formatNumber(totalCoins)
		line3.TextColor3 = Color3.fromRGB(80, 80, 80)
	end

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0.4, 0, 0.16, 0)
	closeBtn.Position = UDim2.new(0.3, 0, 0.8, 0)
	closeBtn.BackgroundColor3 = Color3.fromRGB(255, 105, 180)
	closeBtn.Text = "Close"
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextScaled = true
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Parent = frame

	local closeBtnCorner = Instance.new("UICorner")
	closeBtnCorner.CornerRadius = UDim.new(0, 10)
	closeBtnCorner.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		screenGui:Destroy()
	end)

	task.delay(8, function()
		if screenGui and screenGui.Parent then
			screenGui:Destroy()
		end
	end)
end

remote.OnClientEvent:Connect(function(status, totalCoins, reward, timeLeft)
	showPopup(status, totalCoins, reward, timeLeft)
	updateSign(totalCoins)
end)