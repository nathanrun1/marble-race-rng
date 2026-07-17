--!strict
-- Daily quests (QuestsConfig): every UTC day each player gets Count quests drawn from
-- the templates with randomized targets; completing one pays CC (the cosmetics currency —
-- flat amounts, since skin prices don't scale with prestige). Short-session goals + a
-- reason to come back tomorrow, feeding the skin-collection loop.
--
-- Passive data service, PlaytimeBonusService-shaped: DataService owns the lifecycle
-- (ApplyData / SerializeData / Clear) — this never touches a DataStore. Persisted state
-- is { day, quests }; a saved set from a previous UTC day is regenerated on load, and a
-- rollover while online regenerates live (checked periodically).
--
-- Progress is tracked purely from server-side signals (ball banks, coin credits, upgrade
-- counts, prestiges), so it can't be spoofed by a client remote. Per-ball metrics push to
-- the client on a small throttle (banks can happen many times a second); completions and
-- claims push immediately.

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local AttributesConfig = require(RS.Shared.Config.Attributes)
local QuestsConfig = require(RS.Shared.Config.Quests)
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
local QuestNet = require(RS.Shared.Remote.QuestNet)

local QuestService = {}

local QUEST_GREEN = Color3.fromRGB(90, 220, 120)
local QUEST_GOLD = Color3.fromRGB(255, 210, 80)
local COMPLETE_WARN_LIFETIME = 4
local ROLLOVER_CHECK_INTERVAL = 30 -- seconds between UTC-day rollover checks
local PUSH_INTERVAL = 1.5          -- seconds between throttled progress pushes to a client

-- (player, info) — fired on load, regen, progress, completion, and claim.
QuestService.Changed = Signal.new()

-- One persisted quest. The CC reward is locked in at generation.
export type QuestSave = {
	key: string,    -- QuestsConfig.Templates key
	target: number,
	progress: number,
	claimed: boolean,
	reward: number, -- CC paid on claim
}
export type QuestData = {
	day: number, -- UTC day (floor(os.time() / 86400)) the set was generated for
	quests: { QuestSave },
}

export type QuestInfo = {
	key: string,
	text: string,   -- formatted template text ("Bank 120 marbles")
	icon: string,
	target: number,
	progress: number,
	completed: boolean,
	claimed: boolean,
	reward: number, -- CC paid on claim
}
export type Info = {
	day: number,
	resetIn: number, -- seconds until the next UTC day (client counts down from this)
	quests: { QuestInfo },
}

local states: { [number]: QuestData } = {}
local dirty: { [number]: boolean } = {} -- players owed a throttled QuestsChanged push

local changedRE: RemoteEvent? = nil

local function currentDay(): number
	return math.floor(os.time() / 86400)
end

local function secondsToNextDay(): number
	return (currentDay() + 1) * 86400 - os.time()
end

local function templateFor(key: string): any
	return (QuestsConfig.Templates :: any)[key]
end

-- Random target snapped to Step in [Min, Max], plus the CC reward lerped by where the
-- target landed in its range (bigger ask = bigger payout).
local function rollQuest(key: string): QuestSave
	local t = templateFor(key)
	local steps = math.max(math.floor((t.Target.Max - t.Target.Min) / t.Target.Step + 0.5), 0)
	local pick = math.random(0, steps)
	local target = t.Target.Min + pick * t.Target.Step
	local frac = if steps > 0 then pick / steps else 1
	return {
		key = key,
		target = target,
		progress = 0,
		claimed = false,
		reward = math.floor(t.Reward.Min + (t.Reward.Max - t.Reward.Min) * frac + 0.5),
	}
end

local function generate(): QuestData
	local keys: { string } = {}
	for key in QuestsConfig.Templates do
		table.insert(keys, key)
	end
	table.sort(keys) -- deterministic base order; the shuffle below is the randomness
	for i = #keys, 2, -1 do
		local j = math.random(i)
		keys[i], keys[j] = keys[j], keys[i]
	end
	local quests: { QuestSave } = {}
	for i = 1, math.min(QuestsConfig.Count, #keys) do
		table.insert(quests, rollQuest(keys[i]))
	end
	return { day = currentDay(), quests = quests }
end

local function questText(q: QuestSave): string
	local t = templateFor(q.key)
	return if t then string.format(t.Text, q.target) else q.key
end

local function buildInfo(player: Player, data: QuestData): Info
	local quests: { QuestInfo } = {}
	for i, q in data.quests do
		local t = templateFor(q.key)
		quests[i] = {
			key = q.key,
			text = questText(q),
			icon = if t then t.Icon else "❓",
			target = q.target,
			progress = math.min(q.progress, q.target),
			completed = q.progress >= q.target,
			claimed = q.claimed,
			reward = q.reward,
		}
	end
	return { day = data.day, resetIn = secondsToNextDay(), quests = quests }
end

local function fireChanged(player: Player)
	local data = states[player.UserId]
	if not data then
		return
	end
	dirty[player.UserId] = nil
	local info = buildInfo(player, data)
	QuestService.Changed:Fire(player, info)
	if changedRE then
		changedRE:FireClient(player, info)
	end
end

function QuestService.GetInfo(player: Player): Info?
	local data = states[player.UserId]
	if not data then
		return nil
	end
	return buildInfo(player, data)
end

-- Regenerate the player's daily set (fresh day). Announced so a live rollover is noticed.
local function regenerate(player: Player, announce: boolean)
	states[player.UserId] = generate()
	if announce then
		AnnounceUI.Announce(player, "New Daily Quests!", QUEST_GOLD, 3)
	end
	fireChanged(player)
end

-- Advance a quest's progress. "count" templates accumulate (clamped at target); "best"
-- templates keep the high-water mark. Completion moments announce immediately; plain
-- progress is pushed on the PUSH_INTERVAL throttle.
local function report(player: Player, key: string, amount: number)
	local data = states[player.UserId]
	if not data then
		return
	end
	local isBest = templateFor(key).Kind == "best"
	for _, q in data.quests do
		if q.key ~= key or q.claimed or q.progress >= q.target then
			continue
		end
		local new = if isBest then math.max(q.progress, amount) else math.min(q.progress + amount, q.target)
		if new == q.progress then
			continue
		end
		q.progress = new
		if q.progress >= q.target then
			WarnUI.Warn(player, "Quest Complete: " .. questText(q) .. "!", QUEST_GREEN, COMPLETE_WARN_LIFETIME)
			SoundService.PlayForClient(player, { soundId = SoundsConfig.Collect2 })
			fireChanged(player)
		else
			dirty[player.UserId] = true
		end
	end
end

-- Claim one completed quest by index. Returns the Diamonds granted (0 if not claimable).
function QuestService.Claim(player: Player, index: number): number
	local data = states[player.UserId]
	if not data then
		return 0
	end
	local q = data.quests[index]
	if not q or q.claimed or q.progress < q.target then
		return 0
	end
	q.claimed = true
	CosmeticService.AddCC(player, q.reward)
	WarnUI.Warn(player, "Quest Reward: " .. StringUtils.FormatShort(q.reward) .. " Diamonds", QUEST_GREEN, 2.5)
	SoundService.PlayForClient(player, { soundId = SoundsConfig.Combo })
	fireChanged(player)
	return q.reward
end

----------------------------------------------------------------
-- Data lifecycle (DataService-driven; never a direct DataStore call).
----------------------------------------------------------------

-- A saved quest is only trusted if its template still exists and its fields are sane
-- (templates may be renamed/removed between releases).
local function sanitize(saved: any): QuestData?
	if type(saved) ~= "table" or type(saved.day) ~= "number" or type(saved.quests) ~= "table" then
		return nil
	end
	local quests: { QuestSave } = {}
	for _, q in saved.quests :: { any } do
		if
			type(q) == "table"
			and type(q.key) == "string"
			and templateFor(q.key) ~= nil
			and type(q.target) == "number"
			and type(q.progress) == "number"
			and type(q.reward) == "number"
		then
			table.insert(quests, {
				key = q.key,
				target = q.target,
				progress = q.progress,
				claimed = q.claimed == true,
				reward = q.reward,
			})
		end
	end
	if #quests == 0 then
		return nil
	end
	return { day = saved.day, quests = quests }
end

function QuestService.ApplyData(player: Player, saved: QuestData?)
	local data = sanitize(saved)
	if data and data.day == currentDay() then
		states[player.UserId] = data
		fireChanged(player)
	else
		regenerate(player, false)
	end
end

function QuestService.SerializeData(player: Player): QuestData
	return states[player.UserId] or generate()
end

function QuestService.Clear(player: Player)
	states[player.UserId] = nil
	dirty[player.UserId] = nil
end

----------------------------------------------------------------
-- Init: remotes + metric hooks + rollover/push loops.
----------------------------------------------------------------


function QuestService.Init()
	changedRE = QuestNet.QuestsChanged
	;QuestNet.GetQuestInfo.OnServerInvoke = function(player: Player)
		return QuestService.GetInfo(player)
	end
	;QuestNet.ClaimQuest.OnServerInvoke = function(player: Player, index: any)
		local granted = if type(index) == "number" then QuestService.Claim(player, index) else 0
		return { granted = granted, info = QuestService.GetInfo(player) }
	end

	-- Per-ball metrics off the banking breakdown. Lazy-require to avoid a load-time
	-- cycle (ScoringService → ScoreHandler → the data services this file also uses);
	-- by the time Init runs, the Services bootstrap has already loaded everything.
	local ScoringService = require(SSS.Scripts.Services.ScoringService)
	ScoringService.BallScored:Connect(function(ball: BasePart, info: any)
		local ownerId = ball:GetAttribute(AttributesConfig.OwnerUserId) :: number?
		local player = if ownerId then Players:GetPlayerByUserId(ownerId) else nil
		if not player then
			return
		end
		report(player, "BankBalls", 1)
		if info.jackpotHit then
			report(player, "HitJackpots", 1)
		end
		if info.combo > 0 then
			report(player, "BestCombo", info.combo)
		end
		if info.hotPegs > 0 then
			report(player, "HotPegHits", info.hotPegs)
		end
	end)

	-- Coins credit through CurrencyService with the "Coin pickup" reason (CoinService).
	CurrencyService.Changed:Connect(function(player: Player, _new: number, delta: number, reason: any)
		if reason == "Coin pickup" and delta > 0 then
			report(player, "CollectCoins", 1)
		end
	end)

	-- Upgrades bought / rebirths: session-action signals (never fired on load, so a loaded
	-- lifetime total can't be mistaken for fresh progress).
	StatsService.UpgradesAdded:Connect(function(player: Player, count: number)
		report(player, "BuyUpgrades", count)
	end)
	PrestigeService.Prestiged:Connect(function(player: Player, _newCount: number)
		report(player, "Rebirth", 1)
	end)

	-- Throttled progress pushes (per-ball quests would otherwise fire a remote per bank).
	task.spawn(function()
		while true do
			task.wait(PUSH_INTERVAL)
			for _, player in Players:GetPlayers() do
				if dirty[player.UserId] then
					fireChanged(player)
				end
			end
		end
	end)

	-- UTC-day rollover while online: regenerate + announce.
	task.spawn(function()
		while true do
			task.wait(ROLLOVER_CHECK_INTERVAL)
			local day = currentDay()
			for _, player in Players:GetPlayers() do
				local data = states[player.UserId]
				if data and data.day ~= day then
					regenerate(player, true)
				end
			end
		end
	end)
end

return QuestService
