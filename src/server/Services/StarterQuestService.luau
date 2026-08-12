--!strict
-- One-time "Getting Started" quest chain: a fixed ladder (Launch marbles -> Buy upgrades ->
-- Unlock a lock -> Prestige) meant to give a brand-new session a spine
-- reaching past the first few minutes, unlike QuestService's daily-random quests which
-- assume the player already understands the loop.
--
-- The first Config/StarterQuests.ActiveCount uncompleted steps (in ladder order) are ALL
-- live at once, each with its own progress; later steps enter the window as earlier ones
-- finish, so the window can complete out of order. Every step pays Diamonds
-- (CosmeticService.AddCC) and auto-claims the instant it completes (no manual claim button —
-- fewer clicks for a player who doesn't know the UI yet). Runs once ever per account;
-- QuestService-shaped passive data service (DataService owns ApplyData/SerializeData/Clear),
-- progress tracked purely from server-side signals so it can't be spoofed by a client remote.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local SoundsConfig = require(RS.Shared.Config.Sounds)
local StarterQuestsConfig = require(RS.Shared.Config.StarterQuests)
local Signal = require(RS.Shared.Utility.Signal)
local StringUtils = require(RS.Shared.Utility.StringUtils)
local WarnUI = require(RS.Shared.WarnUI)
local AnnounceUI = require(RS.Shared.AnnounceUI)
local SoundService = require(RS.Shared.SoundService)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local StatsService = require(SSS.Scripts.Services.StatsService)
local PrestigeService = require(SSS.Scripts.Services.PrestigeService)
local BallService = require(SSS.Scripts.Services.BallService)
local UpgradeLockService = require(SSS.Scripts.Services.UpgradeLockService)
-- UpgradeService is required LAZILY in Init() (not here): a top-level require closes the
-- documented cycle UpgradeService -> ProductService -> DataService -> StarterQuestService.
-- Deferring it to Init() (after every module has loaded) dodges it, same as PrestigeService/
-- QuestService do elsewhere.
local StarterQuestNet = require(RS.Shared.Remote.StarterQuestNet)
local FxNet = require(RS.Shared.Remote.FxNet)

local StarterQuestService = {}

local CHAIN_GREEN = Color3.fromRGB(90, 220, 120)
local CHAIN_GOLD = Color3.fromRGB(255, 210, 80)

-- Fixed ladder (Config/StarterQuests); the first WINDOW uncompleted entries are live.
local STEPS = StarterQuestsConfig.Steps
local WINDOW = StarterQuestsConfig.ActiveCount

export type ChainSave = {
	completed: { string },         -- keys of completed steps (completion order)
	progress: { [string]: number }, -- progress per not-yet-completed step key
}

export type MissionInfo = {
	index: number, -- position in the ladder (stable identity for the client's cards)
	text: string,
	target: number,
	progress: number,
	reward: number,
}

export type ChainInfo = {
	missions: { MissionInfo }, -- the live window, in ladder order (empty once done)
	completed: number,
	total: number, -- #STEPS, so the client can render "completed/total"
	done: boolean,
}

-- (player, info) — fired on load, progress, step completion, and chain completion.
StarterQuestService.Changed = Signal.new()

local states: { [number]: ChainSave } = {}
local changedRE: RemoteEvent? = nil

local function defaultSave(): ChainSave
	return { completed = {}, progress = {} }
end

local function buildInfo(data: ChainSave): ChainInfo
	local missions: { MissionInfo } = {}
	for i, s in STEPS do
		if not table.find(data.completed, s.key) then
			table.insert(missions, {
				index = i,
				text = string.format(s.text, s.target),
				target = s.target,
				progress = math.min(data.progress[s.key] or 0, s.target),
				reward = s.reward,
			})
			if #missions >= WINDOW then
				break
			end
		end
	end
	return {
		missions = missions,
		completed = #data.completed,
		total = #STEPS,
		done = #missions == 0,
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

-- Advance a step's progress by `key`/`amount`. Only steps inside the live window (the
-- first WINDOW uncompleted, in ladder order) accept progress — a report for any other
-- key, a not-yet-windowed step, or once the chain is done, is simply ignored. Completing
-- a windowed step pays its reward immediately; the next unshown step slides into the
-- window; completing the last step ends the chain.
local function report(player: Player, key: string, amount: number)
	local data = states[player.UserId]
	if not data then
		return
	end
	local active: StarterQuestsConfig.StepDef? = nil
	local seen = 0
	for _, s in STEPS do
		if not table.find(data.completed, s.key) then
			if s.key == key then
				active = s
				break
			end
			seen += 1
			if seen >= WINDOW then
				break
			end
		end
	end
	if not active then
		return
	end

	local cur = math.min((data.progress[key] or 0) + amount, active.target)
	data.progress[key] = cur
	if cur < active.target then
		fireChanged(player)
		return
	end

	data.progress[key] = nil
	table.insert(data.completed, key)
	-- Fly BEFORE the grant (ordered delivery): the client's live-sum hold seeds from the
	-- pre-grant balance, then the reward streams into the Diamonds readout.
	FxNet.PlayCurrencyFly:FireClient(player, "Diamonds", nil, active.reward)
	CosmeticService.AddCC(player, active.reward)
	WarnUI.Warn(player, "Getting Started: " .. string.format(active.text, active.target) .. "! +" .. StringUtils.FormatShort(active.reward) .. " Diamonds", CHAIN_GREEN, 3)
	SoundService.PlayForClient(player, { soundId = SoundsConfig.Combo })

	if #data.completed >= #STEPS then
		AnnounceUI.Announce(player, "Getting Started: Complete!", CHAIN_GOLD, 3)
	end
	fireChanged(player)
end

----------------------------------------------------------------
-- Data lifecycle (DataService-driven; never a direct DataStore call).
----------------------------------------------------------------

local function isStepKey(key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	for _, s in STEPS do
		if s.key == key then
			return true
		end
	end
	return false
end

local function sanitize(saved: any): ChainSave?
	if type(saved) ~= "table" then
		return nil
	end
	-- Current shape: { completed: {key}, progress: {[key]: number} }.
	if type(saved.completed) == "table" and type(saved.progress) == "table" then
		local out = defaultSave()
		for _, key in saved.completed :: { any } do
			if isStepKey(key) and not table.find(out.completed, key) then
				table.insert(out.completed, key)
			end
		end
		for key, v in saved.progress :: { [any]: any } do
			if isStepKey(key) and type(v) == "number" and not table.find(out.completed, key) then
				out.progress[key] = math.max(v, 0)
			end
		end
		return out
	end
	-- Legacy one-step-at-a-time shape: { step: number, progress: number } — steps below
	-- `step` were completed, `progress` belonged to the step that was current.
	if type(saved.step) == "number" and type(saved.progress) == "number" then
		local out = defaultSave()
		for i = 1, math.min(saved.step - 1, #STEPS) do
			table.insert(out.completed, STEPS[i].key)
		end
		local current = STEPS[saved.step]
		if current and saved.progress > 0 then
			out.progress[current.key] = saved.progress
		end
		return out
	end
	return nil
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

	StatsService.UpgradesAdded:Connect(function(player: Player, count: number)
		report(player, "BuyUpgrades", count)
	end)

	UpgradeLockService.Purchased:Connect(function(player: Player, _lockId: string, _price: number, _tracks: { string })
		report(player, "UnlockLock", 1)
	end)

	local UpgradeService = require(SSS.Scripts.Services.UpgradeService)
	UpgradeService.ZoneUpgraded:Connect(function(player: Player, _newTier: number)
		report(player, "UpgradeZone", 1)
	end)

	PrestigeService.Prestiged:Connect(function(player: Player, _newCount: number)
		report(player, "Prestige", 1)
	end)
end

return StarterQuestService
