--!strict

local Players: Players = game:GetService("Players")
local RunService       = game:GetService("RunService")
local RS               = game:GetService("ReplicatedStorage")

-- Shared, pure derivation + config — the same source the server clamps against, so
-- the client computes identical axis ranges locally (no extra "get ranges" remote).
local ProfileStats = require(RS.Shared.ProfileStats)
local SoundService = require(RS.Shared.SoundService)
local Config = require(RS.Shared.Config)

local player = Players.LocalPlayer

-- Loadout remotes (see ProfileService): SetAxis is the submit RF (returns whether
-- the change was accepted), ProfileChanged pushes the authoritative profile after
-- any mutation, GetProfile is the initial pull.
local Remote           = RS:WaitForChild("Remote")
local GetProfileRF     = Remote:WaitForChild("GetProfile")     :: RemoteFunction
local GetBalanceRF     = Remote:WaitForChild("GetBalance")     :: RemoteFunction

local MainGui = player.PlayerGui:WaitForChild("MainGui")

local RequestLaunchRE = Remote:WaitForChild("RequestLaunch")

local Controller = {}

local BALL_LAUNCH_POS = Vector3.new(21.45, 170.032, 296.331)

Controller.ASSETS = {
	btnUpImage = "rbxassetid://81241010426987",
	btnDownImage = "rbxassetid://133100387605055"
}

Controller.STYLE = {
    autoBtnUpColor = Color3.fromRGB(255, 120, 120),
    autoBtnDownColor = Color3.fromRGB(4, 255, 0)
}

local betAmountFrame = MainGui:WaitForChild("LeftBar"):WaitForChild("Bet"):WaitForChild("BetAmount")

Controller.UI = {
    launchBtn = MainGui:WaitForChild("Launch") :: ImageButton,
    launchBtnText = MainGui:WaitForChild("Launch"):WaitForChild("TextLabel") :: TextLabel,
    autoBtn = MainGui:WaitForChild("Auto") :: ImageButton,
    autoBtnText = MainGui:WaitForChild("Auto"):WaitForChild("TextLabel") :: TextLabel,
    betAmount = betAmountFrame:WaitForChild("BetBox") :: TextBox,
    betQuarterBtn = betAmountFrame:WaitForChild("quarter") :: GuiButton,
    betHalfBtn = betAmountFrame:WaitForChild("half") :: GuiButton,
    betMaxBtn = betAmountFrame:WaitForChild("max") :: GuiButton,
}

-- Max bet the player's current upgrades allow (same pure derivation the server
-- clamps against), and their current balance.
local function getMaxBet(): number
    return ProfileStats.GetMaxBet(GetProfileRF:InvokeServer().upgrades)
end

local function getPlrBalance(): number
    return GetBalanceRF:InvokeServer()
end

-- On focus loss, clamp the typed bet to what the player can actually afford
-- (min of balance and the upgrade-allowed max). Launching is handled by the
-- launch button, so we only normalise the value here.
local function onBetBoxFocusLost()
    local betAmount = tonumber(Controller.UI.betAmount.Text)
    if not betAmount then
        Controller.UI.betAmount.Text = tostring(Config.LoadoutDefaults.Bet)
        return
    end
    local maxBet = math.min(getPlrBalance(), getMaxBet())
    Controller.UI.betAmount.Text = tostring(math.min(betAmount, maxBet))
end

local function onBetQuarterActivated()
    Controller.UI.betAmount.Text = string.format("%.1f", math.ceil(getMaxBet() / 4))
end

local function onBetHalfActivated()
    Controller.UI.betAmount.Text = string.format("%.1f", math.ceil(getMaxBet() / 2))
end

local function onBetMaxActivated()
    Controller.UI.betAmount.Text = string.format("%.1f", getMaxBet())
end

local doAutoLaunch = false

local launchBtnActive = true
local launchBtnTextRestPos: UDim2 = Controller.UI.launchBtnText.Position
local launchBtnTextDownPos: UDim2 = launchBtnTextRestPos + UDim2.fromOffset(0, 6)
local launchBtnDefaultText: string = Controller.UI.launchBtnText.Text
local function onLaunchBtnActivated()
    if not launchBtnActive then return end
	launchBtnActive = false

    if not doAutoLaunch then
        SoundService.Play({ soundId = Config.Sounds.Launch, volume = 1.0 })
    end

	local betAmount = tonumber(Controller.UI.betAmount.Text)
	if (betAmount) then
		RequestLaunchRE:FireServer(betAmount)
	end
	Controller.UI.launchBtn.Image = Controller.ASSETS.btnDownImage
	Controller.UI.launchBtnText.Position = launchBtnTextDownPos             -- text drops with the face
	
	local upgrades = GetProfileRF:InvokeServer().upgrades
	local delay = ProfileStats.GetLaunchDelay(upgrades)
	local start = os.clock()
	while os.clock() - start < delay do
		Controller.UI.launchBtnText.Text = string.format("%.1f", delay - (os.clock() - start))
		task.wait(0.1)
	end
	
	Controller.UI.launchBtn.Image = Controller.ASSETS.btnUpImage
	Controller.UI.launchBtnText.Position = launchBtnTextRestPos
	Controller.UI.launchBtnText.Text = launchBtnDefaultText
	
	launchBtnActive = true
end

local autoBtnTextRestPos: UDim2 = Controller.UI.autoBtnText.Position
local autoBtnTextDownPos: UDim2 = autoBtnTextRestPos + UDim2.fromOffset(0, 6)
local function onAutoBtnActivated()
    doAutoLaunch = not doAutoLaunch
    if doAutoLaunch then
        Controller.UI.autoBtn.ImageColor3 = Controller.STYLE.autoBtnDownColor
        Controller.UI.autoBtn.Image = Controller.ASSETS.btnDownImage
        Controller.UI.autoBtnText.Position = autoBtnTextDownPos
    else
        Controller.UI.autoBtn.ImageColor3 = Controller.STYLE.autoBtnUpColor
        Controller.UI.autoBtn.Image = Controller.ASSETS.btnUpImage
        Controller.UI.autoBtnText.Position = autoBtnTextRestPos
    end
end

local function onHeartbeat()
    if doAutoLaunch then
        onLaunchBtnActivated()
    end
end


local function initStyle()
    -- Launch btn
    Controller.UI.launchBtn.Image = Controller.ASSETS.btnUpImage
	Controller.UI.launchBtnText.Position = launchBtnTextRestPos
	Controller.UI.launchBtnText.Text = launchBtnDefaultText

    -- Auto btn
    Controller.UI.autoBtn.ImageColor3 = Controller.STYLE.autoBtnUpColor
    Controller.UI.autoBtn.Image = Controller.ASSETS.btnUpImage
    Controller.UI.autoBtnText.Position = autoBtnTextRestPos

    -- Bet box default
    Controller.UI.betAmount.Text = tostring(Config.LoadoutDefaults.Bet)
end


function Controller.Init()
    RunService.Heartbeat:Connect(onHeartbeat)
    Controller.UI.launchBtn.Activated:Connect(onLaunchBtnActivated)
    Controller.UI.autoBtn.Activated:Connect(onAutoBtnActivated)

    Controller.UI.betAmount.FocusLost:Connect(onBetBoxFocusLost)
    Controller.UI.betQuarterBtn.Activated:Connect(onBetQuarterActivated)
    Controller.UI.betHalfBtn.Activated:Connect(onBetHalfActivated)
    Controller.UI.betMaxBtn.Activated:Connect(onBetMaxActivated)

    initStyle()
end

return Controller
