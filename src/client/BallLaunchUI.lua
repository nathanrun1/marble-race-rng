--!strict

local Players: Players = game:GetService("Players")
local RunService       = game:GetService("RunService")
local RS               = game:GetService("ReplicatedStorage")

-- Shared, pure derivation + config — the same source the server clamps against, so
-- the client computes identical axis ranges locally (no extra "get ranges" remote).
local ProfileStats = require(RS.Shared.ProfileStats)

local player = Players.LocalPlayer

-- Loadout remotes (see ProfileService): SetAxis is the submit RF (returns whether
-- the change was accepted), ProfileChanged pushes the authoritative profile after
-- any mutation, GetProfile is the initial pull.
local Remote           = RS:WaitForChild("Remote")
local GetProfileRF     = Remote:WaitForChild("GetProfile")     :: RemoteFunction

local MainGui = player.PlayerGui:WaitForChild("MainGui")

local RequestLaunchRE = Remote:WaitForChild("RequestLaunch")

local Controller = {}
print("requried")

----------------------------------------------------------------
-- ASSET IDS  (replace the zeros — single source of truth)
----------------------------------------------------------------
Controller.ASSETS = {
	btnUpImage = "rbxassetid://81241010426987",
    btnDownImage = "rbxassetid://133100387605055"
}

Controller.STYLE = {
    autoBtnUpColor = Color3.fromRGB(255, 120, 120),
    autoBtnDownColor = Color3.fromRGB(4, 255, 0)
}

Controller.UI = {
    launchBtn = MainGui:WaitForChild("Launch") :: ImageButton,
    launchBtnText = MainGui:WaitForChild("Launch"):WaitForChild("TextLabel") :: TextLabel, 
    autoBtn = MainGui:WaitForChild("Auto") :: ImageButton,
    autoBtnText = MainGui:WaitForChild("Auto"):WaitForChild("TextLabel") :: TextLabel,
    betAmount = MainGui:WaitForChild("Bet"):WaitForChild("BetAmount"):WaitForChild("BetBox") :: TextBox
}

local doAutoLaunch = false

local launchBtnActive = true
local launchBtnTextRestPos: UDim2 = Controller.UI.launchBtnText.Position
local launchBtnTextDownPos: UDim2 = launchBtnTextRestPos + UDim2.fromOffset(0, 6)
local launchBtnDefaultText: string = Controller.UI.launchBtnText.Text
local function onLaunchBtnActivated()
    if not launchBtnActive then return end
	launchBtnActive = false
	local betAmount = tonumber(Controller.UI.betAmount.Text)
    print(Controller.UI.betAmount.Text)
	if (betAmount) then
		RequestLaunchRE:FireServer(betAmount)
	end
	Controller.UI.launchBtn.Image = Controller.ASSETS.btnDownImage
	Controller.UI.launchBtnText.Position = launchBtnTextDownPos             -- text drops with the face
	
	local upgrades = GetProfileRF:InvokeServer().upgrades
	local delay = ProfileStats.GetLaunchDelay(upgrades)
	print(delay)
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
end


function Controller.Init()
    RunService.Heartbeat:Connect(onHeartbeat)
    Controller.UI.launchBtn.Activated:Connect(onLaunchBtnActivated)
    Controller.UI.autoBtn.Activated:Connect(onAutoBtnActivated)

    initStyle()
end

return Controller
