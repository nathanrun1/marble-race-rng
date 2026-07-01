--!strict
-- Controller for the small "tool" buttons: camera view, ball visibility, SFX mute,
-- music mute. The button feel/animation lives in the shared UIButton module; this
-- file just owns the app palette and wires each host to its service.
--
-- Each host has the shape:  Host > { Shadow, Button > { Hover, Icon, ... } }.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local SoundService = require(RS.Shared.SoundService)
local BallEffects = require(RS.Shared.BallEffects)
local UIButton = require(RS.Shared.UIButton)
local ProductService = require(RS.Shared.ProductService)
local Config = require(RS.Shared.Config)
local CameraService = require(script.Parent:WaitForChild("CameraService"))

local MiscUI = {}

local player = Players.LocalPlayer
local MainGui = player.PlayerGui:WaitForChild("MainGui")

-- App palette for the toggle states.
local BLUE: UIButton.Gradient = {
	top = Color3.fromRGB(127, 211, 255),
	mid = Color3.fromRGB(58, 166, 245),
	bot = Color3.fromRGB(36, 134, 224),
}
local GOLD: UIButton.Gradient = {
	top = Color3.fromRGB(255, 224, 122),
	mid = Color3.fromRGB(255, 211, 77),
	bot = Color3.fromRGB(240, 176, 33),
}
local RED: UIButton.Gradient = {
	top = Color3.fromRGB(255, 138, 138),
	mid = Color3.fromRGB(240, 70, 70),
	bot = Color3.fromRGB(200, 38, 38),
}

-- Cash-multiplier button colour for the level it's offering. The gradient is left as
-- authored; this tints the button's BackgroundColor3 (which the gradient multiplies).
local CASH_LEVEL_COLOR: { [number]: Color3 } = {
	[2] = Color3.fromRGB(97, 236, 86),
	[4] = Color3.fromRGB(66, 232, 219),
	[8] = Color3.fromRGB(110, 120, 231),
	[16] = Color3.fromRGB(255, 255, 255),
}

-- A mute-style toggle: blue when idle, red while active, with the Button.MuteIcon
-- shown only while active. Shared by the ball-visibility / SFX / music buttons.
local function bindMuteToggle(host: Instance, initial: boolean, onChange: (boolean) -> ())
	return UIButton.bind(host, {
		toggle = { initial = initial, onChange = onChange },
		idleGradient = BLUE,
		activeGradient = RED,
		onRender = function(button: GuiButton, active: boolean)
			local icon = button:FindFirstChild("MuteIcon")
			if icon and icon:IsA("GuiObject") then
				icon.Visible = active
			end
		end,
	})
end

type Stats = {
	upgradesPurchased: number,
	cashMultiplier: number,
	ownsStarterPack: boolean,
}

-- RightBar monetization buttons (cash multiplier + starter pack). Their state comes
-- from the server's StatsChanged / GetStats remotes; products are prompted by id.
local function initRightBar()
	local rightBar = MainGui:WaitForChild("RightBar")
	local Remote = RS:WaitForChild("Remote")
	local getStats = Remote:WaitForChild("GetStats") :: RemoteFunction
	local statsChanged = Remote:WaitForChild("StatsChanged") :: RemoteEvent

	-- Cash multiplier: the button always shows the next purchasable level and vanishes
	-- once the top level (last in Config.CashMultiplier.Levels) is owned.
	local cashHost = rightBar:WaitForChild("CashMultHost") :: GuiObject
	local cashButton = cashHost:WaitForChild("Button") :: GuiObject
	local multLabel = cashButton:WaitForChild("MultLabel") :: TextLabel
	local cashNextId: number? = nil
	local cashHandle = UIButton.bind(cashHost, {
		onClick = function()
			if cashNextId then
				ProductService.Prompt(cashNextId)
			end
		end,
	})
	local function refreshCash(current: number)
		local nextLevel: number? = nil
		for _, lvl in Config.CashMultiplier.Levels do
			if lvl > current then
				nextLevel = lvl
				break
			end
		end
		if nextLevel then
			multLabel.Text = tostring(nextLevel) .. "× Cash"
			cashNextId = tonumber((Config.Products :: any)["Multiplier" .. tostring(nextLevel) .. "x"])
			local color = CASH_LEVEL_COLOR[nextLevel]
			if color then
				cashHandle.SetColor(color)
			end
			cashHost.Visible = true
		else
			cashNextId = nil
			cashHost.Visible = false -- top tier owned → remove the button
		end
	end

	local ballDropHost = rightBar:FindFirstChild("BallDropHost")
	-- Read the count from Config rather than trusting the model's static label text, so a
	-- future Config.BallDrop.Count change can't silently drift from what the button displays.
	local ballDropLabel = ballDropHost:FindFirstChild("Button")
	ballDropLabel = ballDropLabel and ballDropLabel:FindFirstChild("MultLabel")
	if ballDropLabel and ballDropLabel:IsA("TextLabel") then
		ballDropLabel.Text = "DROP " .. tostring(Config.BallDrop.Count) .. " FREE"
	end
	local ballDropId = tonumber(Config.Products.BallDropMaxBet)
	if ballDropId and ballDropId ~= 0 then
		UIButton.bind(ballDropHost, {
			onClick = function()
				ProductService.Prompt(ballDropId)
			end,
		})
	end

	-- Starter pack: a game pass, shown only while unowned and under the upgrade
	-- threshold.
	local starterHost = rightBar:WaitForChild("StarterPackHost") :: GuiObject
	local starterId = tonumber(Config.GamePasses.StarterPack)
	UIButton.bind(starterHost, {
		onClick = function()
			if starterId then
				ProductService.PromptGamePass(starterId)
			end
		end,
	})
	local function refreshStarter(stats: Stats)
		starterHost.Visible = (not stats.ownsStarterPack)
			and stats.upgradesPurchased < Config.StarterPack.MaxUpgrades
	end

	local function apply(stats: Stats)
		refreshCash(stats.cashMultiplier)
		refreshStarter(stats)
	end

	statsChanged.OnClientEvent:Connect(apply)
	local ok, stats = pcall(function()
		return getStats:InvokeServer()
	end)
	if ok and stats then
		apply(stats)
	end
end

function MiscUI.Init()
	local leftBar = MainGui:WaitForChild("LeftBar")
	local tools = leftBar:WaitForChild("Tools")

	-- Camera: gold while the alternate board view is active.
	UIButton.bind(tools:WaitForChild("CamButtonHost"), {
		toggle = { initial = CameraService.IsBoardView(), onChange = CameraService.SetBoardView },
		idleGradient = BLUE,
		activeGradient = GOLD,
	})

	-- Ball visibility: red + MuteIcon while other players' balls are hidden.
	bindMuteToggle(tools:WaitForChild("BallVisibleButtonHost"), BallEffects.AreBallsHidden(), function(hidden)
		BallEffects.SetBallsHidden(hidden)
	end)

	-- Sound (ball-effects / SFX) mute.
	bindMuteToggle(tools:WaitForChild("SoundButtonHost"), SoundService.IsSFXMuted(), function(muted)
		SoundService.SetSFXMuted(muted)
	end)

	-- Music mute.
	bindMuteToggle(tools:WaitForChild("MusicButtonHost"), SoundService.IsMusicMuted(), function(muted)
		SoundService.SetMusicMuted(muted)
	end)

	initRightBar()
end

return MiscUI
