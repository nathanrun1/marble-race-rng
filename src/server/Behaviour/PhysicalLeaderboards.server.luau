--!strict
-- Handles physical leaderboards

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SSS = game:GetService("ServerScriptService")

local StringUtils = require(ReplicatedStorage.Shared.StringUtils)
local Config = require(ReplicatedStorage.Shared.Config)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

-- Admins are hidden from leaderboards: no item is created for them. Except in Studio, where
-- admins should show up too so the boards can be tested/eyeballed solo.
local function isExcluded(userId: number): boolean
    if RunService:IsStudio() then
        return false
    end
    return table.find(Config.Admins, userId) ~= nil
end

local GOLD_SEQ = ColorSequence.new(Color3.fromRGB(254,256,107), Color3.fromRGB(187,170,56))
local SILV_SEQ = ColorSequence.new(Color3.fromRGB(255,255,255), Color3.fromRGB(162,183,190))
local BRNZ_SEQ = ColorSequence.new(Color3.fromRGB(242,191,130), Color3.fromRGB(190,143,70))
local NORM_SEQ = ColorSequence.new(Color3.fromRGB(199,170,251), Color3.fromRGB(162,132,201))

local leaderboardsRoot = game.Workspace:WaitForChild("Leaderboards")

local serverCoinsBoard = {
    itemsParent = leaderboardsRoot:WaitForChild("ServerCoins"):WaitForChild("Leaderboard"):WaitForChild("SurfaceGui"):WaitForChild("ScrollingFrame"),
    item = leaderboardsRoot:WaitForChild("ServerCoins"):WaitForChild("Leaderboard"):WaitForChild("SurfaceGui"):WaitForChild("ScrollingFrame"):WaitForChild("Item")
}

type ServerCoinItem = {
    object: GuiObject,
    balance: number
}
local serverCoinItems: { [number]: ServerCoinItem } = {}

-- Refresh server coins visuals and arrangement
local function refreshServerCoins()
    local users: {number} = {}
    for k in serverCoinItems do
        table.insert(users, k)
    end
    table.sort(users, function(a: number, b: number)
        return serverCoinItems[a].balance > serverCoinItems[b].balance
    end)

    for i, k in ipairs(users) do
        local obj = serverCoinItems[k].object
        if i == 1 then
            obj.Username.UIGradient.Color = GOLD_SEQ
        elseif i == 2 then
            obj.Username.UIGradient.Color = SILV_SEQ
        elseif i == 3 then
            obj.Username.UIGradient.Color = BRNZ_SEQ
        else
            obj.Username.UIGradient.Color = NORM_SEQ
        end
        obj.LayoutOrder = i
    end
end

local function initServerCoins()
    Players.PlayerAdded:Connect(function(player: Player)
        if isExcluded(player.UserId) then return end
        local playerItem = serverCoinsBoard.item:Clone()
        playerItem.Visible = true
        playerItem.Parent = serverCoinsBoard.itemsParent
        serverCoinItems[player.UserId] = { object = playerItem, balance = CurrencyService.GetPoints(player) }
        refreshServerCoins()
    end)

    Players.PlayerRemoving:Connect(function(player: Player)
        local item = serverCoinItems[player.UserId]
        if not item then return end
        item.object:Destroy()
        serverCoinItems[player.UserId] = nil
        refreshServerCoins()
    end)

    CurrencyService.Changed:Connect(function(player, newBalance)
        local item = serverCoinItems[player.UserId]
        if not item then return end
        item.object.Balance.Text = StringUtils.FormatMoney(newBalance)
        item.object.Username.Text = player.Name
        item.balance = newBalance
        refreshServerCoins()
    end)
end

local function init()
    initServerCoins()
end

init()
