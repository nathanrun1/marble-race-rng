--!strict
-- Populates Roblox's built-in player-list leaderboard with each player's currency
-- and prestige level. The default leaderboard renders a "leaderstats" folder under
-- the Player, showing each value object as a column (ordered alphabetically).
--
-- Cash is a StringValue so it can show a StringUtils-formatted balance ("$1.2M")
-- rather than a raw integer. The core player list only sorts rows by NUMBER-typed
-- leaderstats, so it won't order rows by a string Cash; rows fall back to the
-- remaining numeric column (Prestige). True cash-ranked ordering needs a custom UI.
--
-- The stats mirror their services: seeded from current state and updated on
-- CurrencyService.Changed / PrestigeService.Changed. Both of those services'
-- Init must run first (so balance + prestige data exist) — see Services bootstrap.

local Players = game:GetService("Players")
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)
local PrestigeService = require(SSS.Scripts.Modules.PrestigeService)
local StringUtils = require(RS.Shared.StringUtils)

local LeaderboardService = {}

local CASH_STAT = "Cash"
local PRESTIGE_STAT = "Prestige"

-- userId -> the value objects we update
local stats: { [number]: { cash: StringValue, prestige: IntValue } } = {}

local function onPlayerAdded(player: Player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	local cash = Instance.new("StringValue")
	cash.Name = CASH_STAT
	cash.Value = StringUtils.FormatMoney(math.floor(CurrencyService.GetPoints(player)))
	cash.Parent = leaderstats

	local prestige = Instance.new("IntValue")
	prestige.Name = PRESTIGE_STAT
	prestige.Value = PrestigeService.GetCount(player)
	prestige.Parent = leaderstats

	-- Parent last, once fully built, so the leaderboard never shows a half-set row.
	leaderstats.Parent = player
	stats[player.UserId] = { cash = cash, prestige = prestige }
end

local function onPlayerRemoving(player: Player)
	stats[player.UserId] = nil
end

function LeaderboardService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end

	CurrencyService.Changed:Connect(function(player: Player, newBalance: number)
		local s = stats[player.UserId]
		if s then
			s.cash.Value = StringUtils.FormatMoney(math.floor(newBalance))
		end
	end)

	PrestigeService.Changed:Connect(function(player: Player, info: PrestigeService.PrestigeInfo)
		local s = stats[player.UserId]
		if s then
			s.prestige.Value = info.count
		end
	end)
end

return LeaderboardService
