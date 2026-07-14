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

local BallSkins = require(RS.Shared.BallSkins)
local CosmeticBonus = require(RS.Shared.CosmeticBonus)
local Signal = require(RS.Shared.Utility.Signal)
local CosmeticService = require(SSS.Scripts.Services.CosmeticService)
local ProfileService = require(SSS.Scripts.Services.ProfileService)
local ProfileStats = require(RS.Shared.ProfileStats)
local LoadoutNet = require(RS.Shared.Remote.LoadoutNet)

local LoadoutService = {}

-- How many equip/launch slots this player currently owns: the NumSlots upgrade IS the
-- authority on slot count (PER-SLOT LAUNCH REWORK — see ProfileStats.GetMaxSlots, already
-- bounded by the track's MaxTier). Also the range of slots BallLaunchService will fire
-- (each independently, off its Interact pad).
function LoadoutService.GetMaxSlots(player: Player): number
	return ProfileStats.GetMaxSlots(ProfileService.GetUpgrades(player))
end

-- Slot -> skin id, keyed by STRING slot number ("1"..the NumSlots cap) so DataStore round
-- trips never mangle a sparse array.
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

-- Loadout as a numeric slot array (holes allowed) for CosmeticBonus, truncated to the
-- slots the player currently OWNS. The STORED table is deliberately not clamped — a slot
-- lost to a prestige reset keeps its skin saved — every read gates instead: entries above
-- the cap don't pay (here), don't replicate (buildInfo), and don't launch (BallLaunchService).
local function loadoutArray(loadout: LoadoutData, maxSlots: number): { [number]: string? }
	local arr: { [number]: string? } = {}
	for slot = 1, maxSlots do
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
	return 1 + CosmeticBonus.LoadoutBonus(loadoutArray(loadout, LoadoutService.GetMaxSlots(player)), CosmeticService.GetCopies(player))
end

-- What replicates to the owning client (and other services): only the slots the player
-- currently owns. Beyond-cap entries stay in the stored table but are invisible here, so
-- every consumer (LoadoutDisplay previews, LoadoutUI, BallLaunchService's batch read)
-- acknowledges the current cap for free.
local function buildInfo(player: Player): LoadoutInfo
	local maxSlots = LoadoutService.GetMaxSlots(player)
	local visible: LoadoutData = {}
	for slotStr, id in get(player.UserId) do
		local slot = tonumber(slotStr)
		if slot and slot <= maxSlots then
			visible[slotStr] = id
		end
	end
	return {
		loadout = visible,
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

-- Fill the loadout with the highest-bonus owned skins (CosmeticBonus.BestLoadout), only
-- into slots the player has actually unlocked — a skin in a locked slot would still pay
-- its bonus and preview above the locked world slot.
function LoadoutService.EquipBest(player: Player)
	local loadout = data[player.UserId]
	if not loadout then
		return
	end
	local best = CosmeticBonus.BestLoadout(CosmeticService.GetCopies(player), LoadoutService.GetMaxSlots(player))
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
	-- Validated against the ABSOLUTE cap, not the player's current unlocked count: an entry
	-- in a slot they've lost (prestige reset) stays stored — reads gate it out until the
	-- slot is re-unlocked (see loadoutArray/buildInfo).
	local slotCap = ProfileStats.GetMaxSlotsCap()
	if saved then
		for slotStr, id in saved do
			local slot = tonumber(slotStr)
			if slot and slot >= 1 and slot <= slotCap and type(id) == "string" and CosmeticService.IsOwned(player, id) then
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
