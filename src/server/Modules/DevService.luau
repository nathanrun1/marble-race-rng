--!strict
-- Dev-only testing tool: set upgrade tiers and loadout values live via chat,
-- bypassing cost and the shop. Studio-only by default (plus an optional UserId
-- allowlist for live servers), so it is inert in production. Uses only public
-- ProfileService / CurrencyService APIs — no other module is modified.
--
-- Chat commands (type in the in-game chat):
--   /tier <Track> <n>      set an upgrade tier (raises only; rejoin to lower)
--   /maxall                max every upgrade tier (unlocks all ranges)
--   /bet <n>               set total bet (clamps to current max bet)
--   /n <n>                 set ball count N
--   /phase <0..1>          set launch phase
--   /axis <Name> <0..1>    set a continuous axis (Weight, Size)
--   /money <n>             set balance
--   /preset <name>         targeting | chaos | hybrid
--   /show                  print current tiers + loadout to the server console
--   /help                  list commands
--
-- To reset everything, restart the playtest (no persistence yet, so a rejoin
-- returns the profile to defaults). Tiers only raise, so /maxall is a one-way
-- door within a session — by design, that mirrors real upgrade monotonicity.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Config = require(RS.Shared.Config)
local ProfileService = require(SSS.Scripts.Modules.ProfileService)
local CurrencyService = require(SSS.Scripts.Modules.CurrencyService)

local DevService = {}

-- Add your UserId here to enable the commands in a live (non-Studio) server.
local ALLOWED_USERIDS: { number } = {}

local MAX_TIER = 5    -- /maxall and presets set every track to this (caps self-clamp)
local BIG_BET = 1e9   -- SetBet clamps this down to the player's current max bet

-- Loose indexer views for dynamic (string-keyed) access under --!strict.
local UPGRADES: { [string]: any } = Config.Upgrades :: any
local AXES: { [string]: any } = Config.Axes :: any

-- Case-insensitive name lookups. tierByLower covers every purchasable tier key
-- (Config.Upgrades tracks AND Config.Axes axes, e.g. /tier Size 2). axisByLower
-- is just the continuous axes, for setting a loadout position (/axis Weight 1).
local tierByLower: { [string]: string } = {}
local axisByLower: { [string]: string } = {}
for track in UPGRADES do
	tierByLower[track:lower()] = track
end
for axis in AXES do
	tierByLower[axis:lower()] = axis
	axisByLower[axis:lower()] = axis
end

local function isDev(player: Player): boolean
	return RunService:IsStudio() or table.find(ALLOWED_USERIDS, player.UserId) ~= nil
end

local function setAllTiers(player: Player, value: number)
	for track in UPGRADES do
		ProfileService.SetUpgradeTier(player, track, value)
	end
	for axis in AXES do -- axis unlock tiers too, else presets' weight/size clamp
		ProfileService.SetUpgradeTier(player, axis, value)
	end
end

-- Presets unlock all tiers, then set the loadout that defines the build. The
-- loadout (N / weight / phase) is what actually shapes play; maxing tiers just
-- removes the range gates so the extremes are reachable.
local PRESETS: { [string]: (Player) -> () } = {
	targeting = function(player)
		setAllTiers(player, MAX_TIER)
		ProfileService.SetBallCount(player, 1)
		ProfileService.SetAxis(player, "Weight", 1)   -- heavy / aimable
		ProfileService.SetAxis(player, "Size", 0.5)   -- small
		ProfileService.SetLaunchPhase(player, 0.25)   -- pinned to an edge
		ProfileService.SetBet(player, BIG_BET)
	end,
	chaos = function(player)
		setAllTiers(player, MAX_TIER)
		ProfileService.SetBallCount(player, 16)
		ProfileService.SetAxis(player, "Weight", 0)   -- light / bouncy
		ProfileService.SetAxis(player, "Size", 1)
		ProfileService.SetLaunchPhase(player, 0.5)    -- high N spreads coverage
		ProfileService.SetBet(player, BIG_BET)
	end,
	hybrid = function(player)
		setAllTiers(player, MAX_TIER)
		ProfileService.SetBallCount(player, 6)
		ProfileService.SetAxis(player, "Weight", 0.5)
		ProfileService.SetAxis(player, "Size", 1)
		ProfileService.SetLaunchPhase(player, 0.25)
		ProfileService.SetBet(player, BIG_BET)
	end,
}

local function showState(player: Player)
	local up = ProfileService.GetUpgrades(player)
	print("===== Dev: " .. player.Name .. " =====")
	print("-- Upgrades --")
	for track in UPGRADES do
		print(string.format("  %s: tier %d", track, up[track] or 0))
	end
	local lo = ProfileService.GetLoadout(player)
	print(string.format("-- Loadout -- bet=%.1f  N=%d  phase=%.2f", lo.Bet, lo.BallCount, lo.LaunchPhase))
	for axis, v in lo.axes do
		print(string.format("  axis %s = %.2f", axis, v))
	end
	print(string.format("-- Balance -- %.0f", CurrencyService.GetPoints(player)))
end

-- Returns a short result string for the console.
local function handle(player: Player, cmd: string, a2: string?, a3: string?): string?
	if cmd == "help" then
		return "commands: tier, maxall, bet, n, phase, axis, money, preset, show"
	elseif cmd == "show" then
		showState(player)
		return nil
	elseif cmd == "maxall" then
		setAllTiers(player, MAX_TIER)
		return "maxed all tiers"
	elseif cmd == "tier" then
		local track = a2 and tierByLower[a2:lower()]
		local n = tonumber(a3)
		if not track or not n then
			return "usage: /tier <Track> <n>  (incl. Weight, Size)"
		end
		ProfileService.SetUpgradeTier(player, track, math.floor(n))
		return string.format("%s -> tier %d", track, math.floor(n))
	elseif cmd == "bet" then
		local n = tonumber(a2)
		if not n then return "usage: /bet <n>" end
		ProfileService.SetBet(player, n)
		return string.format("bet -> %.1f (clamped to max bet)", ProfileService.GetLoadout(player).Bet)
	elseif cmd == "n" then
		local n = tonumber(a2)
		if not n then return "usage: /n <count>" end
		ProfileService.SetBallCount(player, n)
		return string.format("N -> %d (clamped to cap)", ProfileService.GetLoadout(player).BallCount)
	elseif cmd == "phase" then
		local n = tonumber(a2)
		if not n then return "usage: /phase <0..1>" end
		ProfileService.SetLaunchPhase(player, n)
		return string.format("phase -> %.2f", ProfileService.GetLoadout(player).LaunchPhase)
	elseif cmd == "axis" then
		local axis = a2 and axisByLower[a2:lower()]
		local n = tonumber(a3)
		if not axis or not n then
			return "usage: /axis <Weight|Size> <0..1>"
		end
		ProfileService.SetAxis(player, axis, n)
		return string.format("%s -> %.2f (clamped to range)", axis, ProfileService.GetAxis(player, axis))
	elseif cmd == "money" then
		local n = tonumber(a2)
		if not n then return "usage: /money <n>" end
		CurrencyService.SetPoints(player, n, "Dev")
		return string.format("balance -> %.0f", n)
	elseif cmd == "preset" then
		local preset = a2 and PRESETS[a2:lower()]
		if not preset then
			return "usage: /preset <targeting|chaos|hybrid>"
		end
		preset(player)
		return "applied preset: " .. (a2 :: string):lower()
	end
	return nil -- not a dev command; ignore
end

local function onChatted(player: Player, message: string)
	if not isDev(player) then
		return
	end
	if message:sub(1, 1) ~= "/" then
		return
	end
	local args = message:sub(2):split(" ")
	local result = handle(player, args[1]:lower(), args[2], args[3])
	if result then
		print("[Dev] " .. player.Name .. ": " .. result)
	end
end

function DevService.Init()
	for _, player in Players:GetPlayers() do
		player.Chatted:Connect(function(msg)
			onChatted(player, msg)
		end)
	end
	Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(msg)
			onChatted(player, msg)
		end)
	end)
end

return DevService
