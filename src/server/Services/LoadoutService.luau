--!strict
-- The bonus-slot LOADOUT: which owned skins sit in the N bonus slots, and the money
-- multiplier that pays (ScoreHandler applies it at banking). Split out of CosmeticService,
-- which now only owns CC currency, skin ownership, crate rolling, and the single VISUAL
-- equipped skin — a distinct concept from a loadout slot.
--
-- Depends on CosmeticService only for CosmeticService.IsOwned/GetCopies (one-way; CosmeticService
-- has no knowledge of loadouts at all anymore).
--
-- Passive data service: DataService owns the lifecycle (ApplyData/SerializeData/Clear), this
-- just holds state, mutates it, and pushes changes to the owning client.

local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")

local CosmeticsConfig = require(RS.Shared.Config.Cosmetics)
local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local Signal = require(RS.Shared.Utility.Signal)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local ProfileService = require(SSS.Scripts.Services.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)

local LoadoutService = {}

-- Static ceiling: CosmeticBonus/LoadoutUI are Studio-authored around exactly this many
-- physical slots, so a player's dynamic per-Frequency-tier cap (GetMaxSlots below) can never
-- exceed it even if their unlocked tier would otherwise allow more (CORE LOOP REWORK).
local SLOTS = CosmeticsConfig.LoadoutSlots

-- How many equip slots this player can currently fill: the Frequency upgrade's slot count
-- (CORE LOOP REWORK — see ProfileStats.GetMaxSlots), hard-capped at SLOTS. Also the batch
-- size BallLaunchService round-robins over (it reads the loadout up to this many slots).
function LoadoutService.GetMaxSlots(player: Player): number
	return math.min(ProfileStats.GetMaxSlots(ProfileService.GetUpgrades(player)), SLOTS)
end

-- Slot -> skin id, keyed by STRING slot number ("1".."LoadoutSlots") so DataStore round trips
-- never mangle a sparse array.
export type LoadoutData = { [string]: string }

export type LoadoutInfo = {
	loadout: LoadoutData,
	loadoutBonus: number, -- current total bonus (the +X% the loadout pays)
}

local data: { [number]: LoadoutData } = {}

-- (player, info) — fired after any loadout change.
LoadoutService.Changed = Signal.new()

local changedRE: RemoteEvent

local function get(userId: number): LoadoutData
	return data[userId] or {}
end

local function countEquipped(loadout: LoadoutData): number
	local n = 0
	for _ in loadout do
		n += 1
	end
	return n
end

-- Loadout as a numeric slot array (holes allowed) for CosmeticBonus.
local function loadoutArray(loadout: LoadoutData): { [number]: string? }
	local arr: { [number]: string? } = {}
	for slot = 1, SLOTS do
		arr[slot] = loadout[tostring(slot)]
	end
	return arr
end

-- Global banked multiplier from the loadout: ×(1 + sum of slotted skins' bonuses).
-- Applied by ScoreHandler at banking, alongside the prestige/cash multipliers.
function LoadoutService.GetMult(player: Player): number
	local loadout = data[player.UserId]
	if not loadout then
		return 1
	end
	return 1 + CosmeticBonus.LoadoutBonus(loadoutArray(loadout), CosmeticService.GetCopies(player))
end

local function buildInfo(player: Player): LoadoutInfo
	local loadout = get(player.UserId)
	return {
		loadout = loadout,
		loadoutBonus = LoadoutService.GetMult(player) - 1,
	}
end

local function announce(player: Player)
	local info = buildInfo(player)
	LoadoutService.Changed:Fire(player, info)
	if changedRE then
		changedRE:FireClient(player, info)
	end
end

function LoadoutService.GetInfo(player: Player): LoadoutInfo
	return buildInfo(player)
end

-- Put an owned skin in a loadout slot (clears it from any other slot), or clear the
-- slot with skinId = nil. At least one ball must always be equipped, so clearing the
-- last remaining slotted skin is rejected.
function LoadoutService.SetSlot(player: Player, slot: number, skinId: string?): boolean
	local loadout = data[player.UserId]
	if not loadout or slot ~= math.floor(slot) or slot < 1 or slot > LoadoutService.GetMaxSlots(player) then
		return false
	end
	if skinId ~= nil and not CosmeticService.IsOwned(player, skinId) then
		return false
	end
	if skinId == nil and loadout[tostring(slot)] ~= nil and countEquipped(loadout) <= 1 then
		return false -- would clear the only equipped ball — not allowed
	end
	if skinId then
		for s, id in loadout do
			if id == skinId then
				loadout[s] = nil
			end
		end
	end
	loadout[tostring(slot)] = skinId
	announce(player)
	return true
end

-- Fill the loadout with the highest-bonus owned skins (CosmeticBonus.BestLoadout).
function LoadoutService.EquipBest(player: Player)
	local loadout = data[player.UserId]
	if not loadout then
		return
	end
	local best = CosmeticBonus.BestLoadout(CosmeticService.GetCopies(player))
	table.clear(loadout)
	for slot, id in best do
		loadout[tostring(slot)] = id
	end
	announce(player)
end

--------------------------------------------------------------------------------
-- Data lifecycle (DataService-driven)
--------------------------------------------------------------------------------
function LoadoutService.ApplyData(player: Player, saved: LoadoutData?)
	local loadout: LoadoutData = {}
	local maxSlots = LoadoutService.GetMaxSlots(player)
	if saved then
		for slotStr, id in saved do
			local slot = tonumber(slotStr)
			if slot and slot >= 1 and slot <= maxSlots and type(id) == "string" and CosmeticService.IsOwned(player, id) then
				loadout[tostring(slot)] = id
			end
		end
	end
	-- At least one ball always equipped: brand-new players (no saved loadout) and any save
	-- that validated down to nothing both start on Classic in slot 1.
	if countEquipped(loadout) == 0 then
		loadout["1"] = BallSkins.GetDefaultId()
	end
	data[player.UserId] = loadout
	announce(player)
end

function LoadoutService.SerializeData(player: Player): LoadoutData
	return get(player.UserId)
end

function LoadoutService.Clear(player: Player)
	data[player.UserId] = nil
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

function LoadoutService.Init()
	changedRE = LoadoutNet.LoadoutChanged

	;LoadoutNet.GetLoadoutInfo.OnServerInvoke = function(player: Player)
		return buildInfo(player)
	end
	;LoadoutNet.SetLoadoutSlot.OnServerEvent:Connect(function(player: Player, slot: any, skinId: any)
		if type(slot) == "number" and (skinId == nil or type(skinId) == "string") then
			LoadoutService.SetSlot(player, slot, skinId)
		end
	end)
	;LoadoutNet.EquipBestLoadout.OnServerEvent:Connect(function(player: Player)
		LoadoutService.EquipBest(player)
	end)
end

return LoadoutService
