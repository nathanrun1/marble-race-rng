local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(RS.Shared.Config)
local Signal = require(RS.Shared.Signal)

local CurrencyService = {}

-- Generous bankroll when playtesting in Studio so dev tools (big bets, jackpot
-- tests) aren't starved; live servers use Config.Currency.StartingBalance.
local STUDIO_STARTING_BALANCE = 1e15

local function startingBalance(): number
	return if RunService:IsStudio() then STUDIO_STARTING_BALANCE else Config.Currency.StartingBalance
end

-- balances[userId] = number
local balances: { [number]: number } = {}

-- (player, newBalance, delta, reason)
CurrencyService.Changed = Signal.new()

-- (player, newBalance, delta, reason) - fired when player's balance changes
local BalanceChangedRE = RS.Remote.BalanceChanged
local GetBalanceRF = RS.Remote.GetBalance

-- Retrieve amount of points
function CurrencyService.GetPoints(player: Player): number
	return balances[player.UserId] or 0
end

-- Adds given amount of points to player's point count
-- 	Returns: New point count
function CurrencyService.AddPoints(player: Player, amount: number, reason: string?): number
	if amount ~= amount then -- NaN guard
		return CurrencyService.GetPoints(player)
	end
	local userId = player.UserId
	local new = (balances[userId] or 0) + amount
	-- new = math.max(new, 0) -- enable if balances cannot go negative
	balances[userId] = new
	CurrencyService.Changed:Fire(player, new, amount, reason)
	BalanceChangedRE:FireClient(player, new, amount, reason)
	return new
end

-- Sets player's point count to given amount
-- 	Returns: New point count
function CurrencyService.SetPoints(player: Player, amount: number, reason: string?): number
	balances[player.UserId] = amount
	CurrencyService.Changed:Fire(player, amount, 0, reason)
	BalanceChangedRE:FireClient(player, amount, 0, reason)
	return amount
end


-- Set the balance from saved data (or the starting balance for a new player) and
-- announce it. Called by DataService on join (defaults pass, then saved pass).
function CurrencyService.ApplyData(player: Player, savedBalance: number?)
	local start = savedBalance or startingBalance()
	balances[player.UserId] = start
	CurrencyService.Changed:Fire(player, start, 0, "Initial")
	BalanceChangedRE:FireClient(player, start, 0, "Initial")
end

-- The value to persist for this player.
function CurrencyService.SerializeData(player: Player): number
	return balances[player.UserId] or startingBalance()
end

function CurrencyService.Clear(player: Player)
	balances[player.UserId] = nil
end

function CurrencyService.Init()
	GetBalanceRF.OnServerInvoke = CurrencyService.GetPoints
end

return CurrencyService
