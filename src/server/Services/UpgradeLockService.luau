--!strict
-- World upgrade locks: Studio-authored Models tagged TagsConfig.UpgradeLock. Each
-- model's "UpgradeLock" attribute lists the upgrade tracks it gates (separated by
-- commas/spaces), and its "Price" attribute is the flat cash unlock cost; a child
-- "Pad" part is where the player walks to buy it (client UpgradeLocks wires the
-- billboard/touch and fades the model out once bought).
--
-- Per-player state is ONE flag per lock in the player's profile
-- (ProfileService.GetUnlockedLocks — persisted by DataService, wiped by prestige's
-- ResetProfile so the locks return). This module owns the purchase and the "is this
-- track still gated for this player" question that UpgradeService checks before
-- selling a gated track.
--
-- Lock id = the model's UpgradeLock attribute string (stable across sessions as long
-- as the authored attribute doesn't change; renaming it forfeits bought unlocks).

local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local TagsConfig = require(RS.Shared.Config.Tags)
local UpgradeInfo = require(RS.Shared.UpgradeInfo)
local Signal = require(RS.Shared.Utility.Signal)
local UpgradeNet = require(RS.Shared.Remote.UpgradeNet)
local ProfileService = require(SSS.Scripts.Services.ProfileService)
local CurrencyService = require(SSS.Scripts.Services.CurrencyService)

local UpgradeLockService = {}

export type LockDef = { price: number, tracks: { string } }
export type PurchaseResult = { ok: boolean, reason: string? } -- "invalid_lock" | "already_unlocked" | "cannot_afford"

-- (player, lockId, price, tracks) — fired on a successful purchase only.
UpgradeLockService.Purchased = Signal.new()

local locks: { [string]: LockDef } = {}
-- track -> every lock id listing it. A track listed by SEVERAL locks stays locked
-- until ALL of them are bought (the authored maps overlap, e.g. Frequency).
local trackLocks: { [string]: { string } } = {}

local function registerLock(model: Instance)
	local list = model:GetAttribute(TagsConfig.UpgradeLock)
	local price = tonumber(model:GetAttribute("Price")) -- authored as string or number
	if type(list) ~= "string" or not price then
		warn(("UpgradeLockService: %s is missing the UpgradeLock (string) or Price attribute"):format(model:GetFullName()))
		return
	end
	if locks[list] then
		return -- same lock id already registered (shared attribute string)
	end
	local tracks: { string } = {}
	for token in string.gmatch(list, "[%w_]+") do
		if UpgradeInfo.Defs[token] then
			table.insert(tracks, token)
			local ids = trackLocks[token] or {}
			table.insert(ids, list)
			trackLocks[token] = ids
		else
			warn(("UpgradeLockService: %s lists unknown upgrade track '%s'"):format(model:GetFullName(), token))
		end
	end
	locks[list] = { price = price, tracks = tracks }
end

function UpgradeLockService.GetLocks(): { [string]: LockDef }
	return locks
end

-- Whether `track` is still gated for this player (false for tracks no lock lists;
-- true while ANY lock listing it is unbought).
function UpgradeLockService.IsTrackLocked(player: Player, track: string): boolean
	local ids = trackLocks[track]
	if not ids then
		return false
	end
	local owned = ProfileService.GetUnlockedLocks(player)
	for _, id in ids do
		if owned[id] ~= true then
			return true
		end
	end
	return false
end

-- Buy a lock outright (flat cash price). The profile flag flip pushes ProfileChanged,
-- which is what the client's lock views re-render from.
function UpgradeLockService.Purchase(player: Player, lockId: string): PurchaseResult
	local lock = locks[lockId]
	if not lock then
		return { ok = false, reason = "invalid_lock" }
	end
	if ProfileService.GetUnlockedLocks(player)[lockId] then
		return { ok = false, reason = "already_unlocked" }
	end
	if CurrencyService.GetPoints(player) < lock.price then
		return { ok = false, reason = "cannot_afford" }
	end
	CurrencyService.AddPoints(player, -lock.price, "Upgrade lock: " .. lockId)
	ProfileService.SetLockUnlocked(player, lockId)
	UpgradeLockService.Purchased:Fire(player, lockId, lock.price, lock.tracks)
	return { ok = true }
end

function UpgradeLockService.Init()
	for _, model in CollectionService:GetTagged(TagsConfig.UpgradeLock) do
		registerLock(model)
	end
	CollectionService:GetInstanceAddedSignal(TagsConfig.UpgradeLock):Connect(registerLock)

	UpgradeNet.PurchaseUpgradeLock.OnServerInvoke = function(player: Player, lockId: any)
		if type(lockId) ~= "string" then
			return { ok = false, reason = "invalid_lock" }
		end
		return UpgradeLockService.Purchase(player, lockId)
	end
end

return UpgradeLockService
