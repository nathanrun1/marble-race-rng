--!strict
-- One-time "Getting Started" quest chain: a fixed, sequential ladder (Launch marbles -> Buy
-- upgrades -> Collect coins -> Unlock a lock -> Prestige) meant to give a brand-new session a
-- spine reaching past the first few minutes, unlike QuestService's daily-random quests which
-- assume the player already understands the loop.
--
-- Only ONE step is active at a time; each pays Diamonds (CosmeticService.AddCC) and
-- auto-claims the instant it completes (no manual claim button — fewer clicks for a player who
-- doesn't know the UI yet). Runs once ever per account; QuestService-shaped passive data
-- service (DataService owns ApplyData/SerializeData/Clear), progress tracked purely from
-- server-side signals so it can't be spoofed by a client remote.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local SoundsConfig = require(RS.Shared.Config.Sounds)
local Signal = require(RS.Shared.Utility.Signal)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local WarnUI = require(RS.Shared.WarnUI)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local SoundService = require(RS.Shared.SoundService)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local StatsService = require(SSS.Scripts.Services.StatsService)
local PrestigeService = require(SSS.Scripts.Services.PrestigeService)
local BallService = require(SSS.Scripts.Services.BallService)
local UpgradeLockService = require(SSS.Scripts.Services.UpgradeLockService)
local StarterQuestNet = require(RS.Shared.Remote.StarterQuestNet)

local StarterQuestService = {}

local CHAIN_GREEN = Color3.fromRGB(90, 220, 120)
local CHAIN_GOLD = Color3.fromRGB(255, 210, 80)

-- Fixed ladder — one entry active at a time, in this order. `key` matches what report()
-- is called with below; unrelated to QuestService's own (separate) key vocabulary.
local STEPS = {
	{ key = "LaunchBalls", target = 10, reward = 20, text = "Launch %d marbles" },
	{ key = "BuyUpgrades", target = 3, reward = 20, text = "Buy %d upgrades" },
	{ key = "CollectCoins", target = 5, reward = 20, text = "Collect %d coins" },
	{ key = "UnlockLock", target = 1, reward = 40, text = "Unlock your first upgrade lock" },
	{ key = "Prestige", target = 1, reward = 100, text = "Prestige for the first time" },
}

export type ChainSave = {
	step: number,     -- 1..#STEPS while running; #STEPS+1 once the whole chain is done
	progress: number, -- progress on the CURRENT step only
}

export type ChainInfo = {
	step: number,
	total: number, -- #STEPS, so the client can render "Step step/total"
	text: string?, -- nil once done
	target: number?,
	progress: number?,
	done: boolean,
}

-- (player, info) — fired on load, progress, step completion, and chain completion.
StarterQuestService.Changed = Signal.new()

local states: { [number]: ChainSave } = {}
local changedRE: RemoteEvent? = nil

local function defaultSave(): ChainSave
	return { step = 1, progress = 0 }
end

local function buildInfo(data: ChainSave): ChainInfo
	if data.step > #STEPS then
		return { step = data.step, total = #STEPS, done = true }
	end
	local s = STEPS[data.step]
	return {
		step = data.step,
		total = #STEPS,
		text = string.format(s.text, s.target),
		target = s.target,
		progress = math.min(data.progress, s.target),
		done = false,
	}
end

local function fireChanged(player: Player)
	local data = states[player.UserId]
	if not data then
		return
	end
	local info = buildInfo(data)
	StarterQuestService.Changed:Fire(player, info)
	if changedRE then
		changedRE:FireClient(player, info)
	end
end

function StarterQuestService.GetInfo(player: Player): ChainInfo?
	local data = states[player.UserId]
	if not data then
		return nil
	end
	return buildInfo(data)
end

-- Advance the CURRENT step's progress by `key`/`amount` (a report for any other key, or once
-- the chain is done, is simply ignored — no cross-step credit). Completing a step pays its
-- reward immediately and moves on to the next; completing the last step ends the chain.
local function report(player: Player, key: string, amount: number)
	local data = states[player.UserId]
	if not data or data.step > #STEPS then
		return
	end
	local s = STEPS[data.step]
	if s.key ~= key then
		return
	end
	data.progress = math.min(data.progress + amount, s.target)
	if data.progress < s.target then
		fireChanged(player)
		return
	end

	CosmeticService.AddCC(player, s.reward)
	WarnUI.Warn(player, "Getting Started: " .. string.format(s.text, s.target) .. "! +" .. StringUtils.FormatShort(s.reward) .. " Diamonds", CHAIN_GREEN, 3)
	SoundService.PlayForClient(player, { soundId = SoundsConfig.Combo })

	data.step += 1
	data.progress = 0
	if data.step > #STEPS then
		AnnounceUI.Announce(player, "Getting Started: Complete!", CHAIN_GOLD, 3)
	end
	fireChanged(player)
end

----------------------------------------------------------------
-- Data lifecycle (DataService-driven; never a direct DataStore call).
----------------------------------------------------------------

local function sanitize(saved: any): ChainSave?
	if type(saved) ~= "table" or type(saved.step) ~= "number" or type(saved.progress) ~= "number" then
		return nil
	end
	return { step = math.max(saved.step, 1), progress = math.max(saved.progress, 0) }
end

function StarterQuestService.ApplyData(player: Player, saved: ChainSave?)
	states[player.UserId] = sanitize(saved) or defaultSave()
	fireChanged(player)
end

function StarterQuestService.SerializeData(player: Player): ChainSave
	return states[player.UserId] or defaultSave()
end

function StarterQuestService.Clear(player: Player)
	states[player.UserId] = nil
end

----------------------------------------------------------------
-- Init: remotes + signal hooks.
----------------------------------------------------------------


function StarterQuestService.Init()
	changedRE = StarterQuestNet.StarterQuestChanged
	;StarterQuestNet.GetStarterQuestInfo.OnServerInvoke = function(player: Player)
		return StarterQuestService.GetInfo(player)
	end

	BallService.BallSpawned:Connect(function(_ball: BasePart, info: any)
		local ownerId = info.ownerUserId :: number?
		local player = if ownerId then Players:GetPlayerByUserId(ownerId) else nil
		if player then
			report(player, "LaunchBalls", 1)
		end
	end)

	-- Coins credit through CurrencyService with the "Coin pickup" reason (same signal
	-- QuestService's own CollectCoins quest keys on).
	CurrencyService.Changed:Connect(function(player: Player, _new: number, delta: number, reason: any)
		if reason == "Coin pickup" and delta > 0 then
			report(player, "CollectCoins", 1)
		end
	end)

	StatsService.UpgradesAdded:Connect(function(player: Player, count: number)
		report(player, "BuyUpgrades", count)
	end)

	UpgradeLockService.Purchased:Connect(function(player: Player, _lockId: string, _price: number, _tracks: { string })
		report(player, "UnlockLock", 1)
	end)

	PrestigeService.Prestiged:Connect(function(player: Player, _newCount: number)
		report(player, "Prestige", 1)
	end)
end

return StarterQuestService
